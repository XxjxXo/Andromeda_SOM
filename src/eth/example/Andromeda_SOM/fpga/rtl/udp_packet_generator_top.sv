// SPDX-License-Identifier: CERN-OHL-S-2.0
/*
 * Módulo Top: Generador de Paquetes UDP/IP Parametrizado
 * Permite ajustar DATA_W (32, 64, 128, 512 bits) para saturar 10G/25G/100G a velocidad de línea.
 */

`resetall
`timescale 1ns / 1ps
`default_nettype none

module udp_packet_generator_top #
(
    parameter MAC_DATA_W = 64,             // Ancho AXI-Stream hacia la MAC (32b para 10G, 64b para 25G, 512b para 100G)
    parameter DATA_W     = 64,     // Ancho del bus interno (igual a MAC_DATA_W para 100% Line-Rate)
    parameter TX_RAM_SIZE = 32768,         // Tamaño del búfer RAM en bytes
    parameter logic [47:0] DEFAULT_SRC_MAC   = 48'h02_00_00_00_00_01,
    parameter logic [47:0] DEFAULT_DEST_MAC  = 48'hFF_FF_FF_FF_FF_FF,
    parameter logic [31:0] DEFAULT_SRC_IP   = {8'd192, 8'd168, 8'd1, 8'd50},
    parameter logic [31:0] DEFAULT_DEST_IP  = {8'd192, 8'd168, 8'd1, 8'd10},
    parameter logic [15:0] DEFAULT_SRC_PORT = 16'd5005,
    parameter logic [15:0] DEFAULT_DEST_PORT = 16'd5005,
    // Número de flujos UDP: el puerto destino rota paquete a paquete entre
    // dest_port y dest_port + FLOW_CNT - 1, para que el receptor pueda
    // repartir el tráfico entre varias colas RX / cores (RSS)
    parameter FLOW_CNT = 1
)
(
    // Relojes y resets
    input  wire logic        clk,            // Reloj de generación de lógica
    input  wire logic        rst,            // Reset síncrono
    input  wire logic        mac_tx_clk,     // Reloj de transmisión de la MAC
    input  wire logic        mac_tx_rst,     // Reset del dominio MAC

    // Control de disparo
    input  wire logic        trigger_start,  // Control de inicio (en '1' continuo para velocidad de línea)
    input  wire logic [15:0] pkt_len_bytes,  // Longitud en bytes del payload deseado

    // Configuración dinámica de red
    input  wire logic [47:0] src_mac,
    input  wire logic [47:0] dest_mac,
    input  wire logic [31:0] src_ip,
    input  wire logic [31:0] dest_ip,
    input  wire logic [15:0] src_port,
    input  wire logic [15:0] dest_port,

    // Interfaz AXI4-Stream de salida conectada directamente a la MAC
    taxi_axis_if.src         m_axis_mac_tx,
    taxi_axis_if.snk         s_axis_mac_tx_cpl
);

    localparam BYTES_PER_WORD = DATA_W / 8; // Bytes por ciclo de reloj (8B para 64b, 4B para 32b)

    // Interconexiones AXI-Stream internas parametrizadas
    taxi_axis_if #(.DATA_W(DATA_W), .USER_EN(1), .USER_W(1)) axis_ui_tx();
    taxi_axis_if #(.DATA_W(DATA_W), .USER_EN(1), .USER_W(1)) axis_pkt_ingress();
    taxi_axis_if #(.DATA_W(DATA_W), .USER_EN(1), .USER_W(1)) axis_pkt_buffered();
    taxi_axis_if #(.DATA_W(32), .USER_EN(1), .USER_W(1))     axis_meta_len();
    taxi_axis_if #(.DATA_W(64), .USER_EN(1), .USER_W(1))     axis_meta();
    taxi_axis_if #(.DATA_W(96)) axis_tx_cpl_dummy();

    // =========================================================================
    // 1. GENERACIÓN DE PAYLOAD PARAMETRIZADA (taxi_lfsr)
    // =========================================================================
    logic [30:0] lfsr_state_reg = 31'h7FFFFFFF;
    wire  [DATA_W-1:0] lfsr_data_out;
    wire  [30:0]       lfsr_state_out;

    taxi_lfsr #(
        .LFSR_W(31),
        .LFSR_POLY(31'h10000001),
        .LFSR_GALOIS(1'b0),
        .DATA_W(DATA_W),
        .DATA_IN_EN(1'b0),
        .DATA_OUT_EN(1'b1)
    )
    lfsr_inst (
        .data_in('0),
        .state_in(lfsr_state_reg),
        .data_out(lfsr_data_out),
        .state_out(lfsr_state_out)
    );

    typedef enum logic [1:0] {
        GEN_IDLE,
        GEN_PAYLOAD
    } gen_state_t;

    gen_state_t gen_state_reg = GEN_IDLE;
    logic [15:0] bytes_rem_reg = '0;

    always_ff @(posedge clk) begin
        if (rst) begin
            gen_state_reg     <= GEN_IDLE;
            lfsr_state_reg    <= 31'h7FFFFFFF;
            axis_ui_tx.tvalid <= 1'b0;
            axis_ui_tx.tlast   <= 1'b0;
        end else begin
            // La palabra presente se consume cuando tready está a '1'
            if (axis_ui_tx.tready) begin
                axis_ui_tx.tvalid <= 1'b0;
            end

            case (gen_state_reg)
                GEN_IDLE: begin
                    if (trigger_start && pkt_len_bytes > 0) begin
                        bytes_rem_reg <= pkt_len_bytes;
                        gen_state_reg <= GEN_PAYLOAD;
                    end
                end

                GEN_PAYLOAD: begin
                    // Cargar nueva palabra sólo si el registro de salida está libre
                    if (!axis_ui_tx.tvalid || axis_ui_tx.tready) begin
                        axis_ui_tx.tvalid <= 1'b1;
                        axis_ui_tx.tdata  <= lfsr_data_out;
                        lfsr_state_reg    <= lfsr_state_out;

                        if (bytes_rem_reg <= BYTES_PER_WORD) begin
                            axis_ui_tx.tlast <= 1'b1;

                            // Generación dinámica de la máscara tkeep según los bytes finales
                            for (int i = 0; i < BYTES_PER_WORD; i++) begin
                                axis_ui_tx.tkeep[i] <= (i < bytes_rem_reg);
                            end

                            gen_state_reg <= GEN_IDLE;
                        end else begin
                            axis_ui_tx.tlast <= 1'b0;
                            axis_ui_tx.tkeep <= '1; // Todos los bytes válidos
                            bytes_rem_reg    <= bytes_rem_reg - BYTES_PER_WORD;
                        end
                    end
                end
            endcase
        end
    end

    assign axis_ui_tx.tstrb = axis_ui_tx.tkeep;
    assign axis_ui_tx.tid   = '0;
    assign axis_ui_tx.tdest = '0;
    assign axis_ui_tx.tuser = '0;

    // =========================================================================
    // 2. INGRESO DE DATOS AL PIPELINE (zircon_ip_tx_ingress)
    // =========================================================================
    zircon_ip_tx_ingress #(
        .N_UI(1),
        .UI_TX_FIFO_DEPTH(32),
        .UI_TX_FIFO_EB_MODE(1'b1)
    )
    ingress_inst (
        .clk(clk),
        .rst(rst),
        .ui_clk(clk),
        .ui_rst(rst),
        .s_axis_ui_tx(axis_ui_tx),
        .m_axis_ui_tx_cpl(axis_tx_cpl_dummy),
        .m_axis_pkt(axis_pkt_ingress)
    );

    // =========================================================================
    // 3. MEDIACIÓN DE CHECKSUM Y BÚFER RAM (zircon_ip_tx_buffer)
    // =========================================================================
    zircon_ip_tx_buffer #(
        .N_UI(1),
        .TX_RAM_SIZE(TX_RAM_SIZE)
    )
    tx_buffer_inst (
        .clk(clk),
        .rst(rst),
        .s_axis_pkt_ui('{axis_pkt_ingress}),
        .m_axis_meta_len(axis_meta_len),
        .m_axis_pkt(axis_pkt_buffered)
    );

    // =========================================================================
    // 4. MÁQUINA DE ESTADOS DE METADATOS (16 Palabras x 64 bits)
    // =========================================================================
    typedef enum logic [1:0] {
        META_IDLE,
        META_SEND
    } meta_state_t;

    // Inversión de orden de bytes (byte 0 del cable en los bits [7:0])
    function automatic [47:0] swab48(input [47:0] data);
        for (int i = 0; i < 6; i++) begin
            swab48[(5-i)*8 +: 8] = data[i*8 +: 8];
        end
    endfunction

    function automatic [31:0] swab32(input [31:0] data);
        for (int i = 0; i < 4; i++) begin
            swab32[(3-i)*8 +: 8] = data[i*8 +: 8];
        end
    endfunction

    meta_state_t meta_state_reg = META_IDLE;
    logic [3:0]  meta_word_cnt_reg = '0;
    logic [15:0] captured_len_reg = '0;
    logic [15:0] captured_csum_reg = '0;

    localparam FLOW_W = FLOW_CNT > 1 ? $clog2(FLOW_CNT) : 1;
    logic [FLOW_W-1:0] flow_reg = '0;

    always_ff @(posedge clk) begin
        if (rst) begin
            meta_state_reg       <= META_IDLE;
            meta_word_cnt_reg    <= '0;
            flow_reg             <= '0;
            axis_meta_len.tready <= 1'b1;
            axis_meta.tvalid     <= 1'b0;
        end else begin
            // La palabra presente se consume cuando tready está a '1'
            if (axis_meta.tready) begin
                axis_meta.tvalid <= 1'b0;
            end

            case (meta_state_reg)
                META_IDLE: begin
                    axis_meta_len.tready <= 1'b1;
                    if (axis_meta_len.tvalid && axis_meta_len.tready) begin
                        captured_len_reg     <= axis_meta_len.tdata[15:0];
                        captured_csum_reg    <= axis_meta_len.tdata[31:16];
                        axis_meta_len.tready <= 1'b0;
                        meta_word_cnt_reg    <= '0;
                        meta_state_reg       <= META_SEND;
                    end
                end

                META_SEND: begin
                    // Cargar nueva palabra sólo si el registro de salida está libre
                    if (!axis_meta.tvalid || axis_meta.tready) begin
                        axis_meta.tvalid <= 1'b1;
                        axis_meta.tlast  <= (meta_word_cnt_reg == 4'd15);

                        // Formato de zircon_ip_tx_deparse: MAC e IP en orden de red
                        // (primer byte del cable en tdata[7:0]), ver test_zircon_ip_tx_deparse.py
                        case (meta_word_cnt_reg)
                            4'd0:    axis_meta.tdata <= {captured_csum_reg, captured_len_reg, 32'h8000_0208}; // EN | UDP | IPV4
                            4'd3:    axis_meta.tdata <= {16'd0, swab48(dest_mac)};
                            4'd4:    axis_meta.tdata <= {16'h0008, swab48(src_mac)};          // ethertype 0x0800 (big-endian)
                            4'd7:    axis_meta.tdata <= {8'd0, 8'd0, 16'h1234, 16'd0, 8'd64, 8'd17}; // DSCP/ECN, IP ID, TTL, proto
                            4'd8:    axis_meta.tdata <= {32'd0, swab32(dest_ip)};
                            4'd10:   axis_meta.tdata <= {32'd0, swab32(src_ip)};
                            4'd12:   axis_meta.tdata <= {32'd0, src_port, 16'(dest_port + 16'(flow_reg))}; // [15:0] destino, [31:16] origen
                            default: axis_meta.tdata <= '0;
                        endcase

                        if (meta_word_cnt_reg == 4'd15) begin
                            meta_state_reg <= META_IDLE;
                            // siguiente flujo para el próximo paquete
                            if (FLOW_CNT > 1) begin
                                flow_reg <= (flow_reg == FLOW_W'(FLOW_CNT-1)) ? '0 : flow_reg + 1'b1;
                            end
                        end else begin
                            meta_word_cnt_reg <= meta_word_cnt_reg + 1'b1;
                        end
                    end
                end
            endcase
        end
    end

    assign axis_meta.tkeep = '1;
    assign axis_meta.tstrb = axis_meta.tkeep;
    assign axis_meta.tid   = '0;
    assign axis_meta.tdest = '0;
    assign axis_meta.tuser = '0;

    // =========================================================================
    // 5. EGRESS Y DEPARSE (Concatenación y cambio de dominio si procede)
    // =========================================================================
    zircon_ip_tx_egress #(
        .IPV6_EN(1'b0),
        .MAC_TX_FIFO_DEPTH(32)
        )
    egress_inst (
        .clk(clk),
        .rst(rst),
        .s_axis_pkt(axis_pkt_buffered),
        .s_axis_meta(axis_meta),
        .mac_tx_clk(mac_tx_clk),
        .mac_tx_rst(mac_tx_rst),
        .m_axis_mac_tx(m_axis_mac_tx),
        .s_axis_mac_tx_cpl(s_axis_mac_tx_cpl)
    );

endmodule

`resetall