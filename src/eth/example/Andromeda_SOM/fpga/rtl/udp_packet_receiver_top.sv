`resetall
`timescale 1ns / 1ps
`default_nettype none

module udp_packet_receiver_top #(
    parameter DATA_W            = 64,
    parameter MAC_RX_FIFO_DEPTH = 32,
    parameter UI_RX_FIFO_DEPTH  = 32,
    parameter MAX_PKT_BYTES     = 4096
)(
    input  wire logic clk,
    input  wire logic rst,
    input  wire logic mac_rx_clk,
    input  wire logic mac_rx_rst,

    // Entrada directa desde la IP MAC (10G/25G Ethernet Subsystem)
    taxi_axis_if.snk  s_axis_mac_rx,

    // Salida final con el Payload UDP puro hacia tu FIFO / lógica de usuario
    taxi_axis_if.src  m_axis_ui_rx,

    // Contador de paquetes UDP válidos entregados
    output logic [31:0] rx_pkt_count
);

    // ---------------------------------------------------------
    // Interfaces internas
    // ---------------------------------------------------------
    taxi_axis_if #(.DATA_W(DATA_W), .USER_EN(1), .USER_W(1)) axis_ingress_to_egress();
    taxi_axis_if #(.DATA_W(DATA_W), .USER_EN(1), .USER_W(1)) axis_egress_to_extractor();

    taxi_axis_if #(.DATA_W(64), .USER_EN(1), .USER_W(1)) axis_meta_hdr();
    taxi_axis_if #(.DATA_W(32), .USER_EN(1), .USER_W(1)) axis_meta_len();

    // ---------------------------------------------------------
    // PASO 1: ZIRCON INGRESS
    // Cruza relojes, analiza cabeceras y genera metadatos
    // ---------------------------------------------------------
    zircon_ip_rx_ingress #(
        .IPV6_EN(1'b0),
        .HASH_EN(1'b0),
        .MAC_RX_FIFO_DEPTH(MAC_RX_FIFO_DEPTH),
        .MAC_RX_FIFO_EB_MODE(1'b1)
    )
    ingress_inst (
        .clk(clk),
        .rst(rst),
        .mac_rx_clk(mac_rx_clk),
        .mac_rx_rst(mac_rx_rst),

        .s_axis_mac_rx(s_axis_mac_rx),

        .m_axis_pkt(axis_ingress_to_egress),
        .m_axis_meta_hdr(axis_meta_hdr),
        .m_axis_meta_len(axis_meta_len)
    );

    // Drenar metadatos de longitud/checksum L4 para no bloquear el Ingress
    assign axis_meta_len.tready = 1'b1;

    // ---------------------------------------------------------
    // PASO 2: ZIRCON EGRESS
    // Buffer FIFO de recepción hacia el dominio de usuario
    // ---------------------------------------------------------
    zircon_ip_rx_egress #(
        .N_UI(1),
        .UI_RX_FIFO_DEPTH(UI_RX_FIFO_DEPTH),
        .UI_RX_FIFO_EB_MODE(1'b1)
    )
    egress_inst (
        .clk(clk),
        .rst(rst),

        .s_axis_pkt(axis_ingress_to_egress),

        .ui_clk(clk),
        .ui_rst(rst),

        .m_axis_ui_rx(axis_egress_to_extractor)
    );

    // ---------------------------------------------------------
    // PASO 3: UDP PAYLOAD EXTRACTOR (Store & Forward)
    // Une la trama del Egress con los metadatos del Ingress
    // ---------------------------------------------------------
    udp_payload_extractor #(
        .DATA_W(DATA_W),
        .MAX_PKT_BYTES(MAX_PKT_BYTES)
    )
    extractor_inst (
        .clk(clk),
        .rst(rst),

        .s_axis_pkt(axis_egress_to_extractor),
        .s_axis_meta(axis_meta_hdr),

        .m_axis_ui(m_axis_ui_rx)
    );

    // ---------------------------------------------------------
    // PASO 4: CONTADOR DE PAYLOADS ENTREGADOS
    // ---------------------------------------------------------
    always_ff @(posedge clk) begin
        if (rst) begin
            rx_pkt_count <= '0;
        end else if (
            m_axis_ui_rx.tvalid &&
            m_axis_ui_rx.tready &&
            m_axis_ui_rx.tlast
        ) begin
            rx_pkt_count <= rx_pkt_count + 1'b1;
        end
    end

endmodule

`default_nettype wire