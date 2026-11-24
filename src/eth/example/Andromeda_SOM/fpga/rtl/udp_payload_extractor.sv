`resetall
`timescale 1ns / 1ps
`default_nettype none

module udp_payload_extractor #(
    parameter DATA_W        = 64,
    parameter MAX_PKT_BYTES = 4096
)(
    input  wire logic clk,
    input  wire logic rst,

    taxi_axis_if.snk  s_axis_pkt,
    taxi_axis_if.snk  s_axis_meta,
    taxi_axis_if.src  m_axis_ui
);

    localparam KEEP_W    = DATA_W / 8;
    localparam RAM_WORDS = (MAX_PKT_BYTES + KEEP_W - 1) / KEEP_W;
    localparam WORD_AW   = $clog2(RAM_WORDS + 1);
    localparam BYTE_AW   = $clog2(MAX_PKT_BYTES + 1);

    // Flags exactos definidos en zircon_ip_rx_parse
    localparam FLG_FRAG         = 5;
    localparam FLG_UDP          = 9;
    localparam FLG_L3_BAD_CKSUM = 24;
    localparam FLG_L4_BAD_LEN   = 25;
    localparam FLG_PARSE_DONE   = 31;

    typedef enum logic [1:0] {
        ST_CAPTURE,
        ST_CHECK,
        ST_TX
    } state_t;

    state_t state;

    // ---------------------------------------------------------
    // RAM de almacenamiento (64 bits, LUTRAM sintetizable)
    // ---------------------------------------------------------
    (* ram_style = "distributed" *)
    logic [DATA_W-1:0] ram_data [0:RAM_WORDS-1];

    // ---------------------------------------------------------
    // Registros de metadatos y control
    // ---------------------------------------------------------
    logic [3:0]  meta_count;
    logic        meta_done;
    logic        pkt_done;

    logic [31:0] flags;
    logic [15:0] udp_len_field;   // Beat 0 [47:32]: longitud UDP total (incluye 8B de cabecera UDP)
    logic [7:0]  payload_offset;  // Beat 1 [63:56]: bloques de 32-bit tras el shift de 2B

    logic [WORD_AW-1:0] rx_word_count;
    logic [BYTE_AW-1:0] rx_total_bytes;
    logic [WORD_AW-1:0] tx_word_count;
    logic [BYTE_AW-1:0] bytes_sent;

    logic pkt_overflow;
    logic rx_user;

    // Señales combinacionales de cálculo y realineación
    logic [15:0]        exact_hdr_bytes;
    logic [WORD_AW-1:0] start_word;
    logic [15:0]        actual_pyld_bytes;
    logic [2:0]         byte_shift;

    logic [DATA_W-1:0]     prev_word;
    logic [DATA_W-1:0]     read_word;
    logic [(DATA_W*2)-1:0] combined_window;

    // Función automática para contar bytes válidos en cada palabra recibida
    function automatic logic [3:0] count_keep_bytes(input logic [KEEP_W-1:0] keep);
        logic [3:0] cnt;
        cnt = 4'd0;
        for (int i = 0; i < KEEP_W; i++) begin
            if (keep[i]) cnt = cnt + 4'd1;
        end
        return cnt;
    endfunction

    // ---------------------------------------------------------
    // Cálculos combinacionales seguros y Pipeline de Lectura
    // ---------------------------------------------------------
    assign exact_hdr_bytes = (payload_offset > 8'd0) ? ((16'(payload_offset) * 16'd4) - 16'd2) : 16'd0;
    assign start_word      = WORD_AW'(exact_hdr_bytes / KEEP_W);

    assign s_axis_pkt.tready  = (state == ST_CAPTURE) && !pkt_done;
    assign s_axis_meta.tready = (state == ST_CAPTURE) && !meta_done;

    // Lectura protegida contra fuera de rango
    assign read_word       = (tx_word_count < RAM_WORDS) ? ram_data[tx_word_count] : '0;
    assign combined_window = {read_word, prev_word};

    // ---------------------------------------------------------
    // Salida AXI-Stream Combinacional (Handshake seguro)
    // ---------------------------------------------------------
    always_comb begin
        m_axis_ui.tvalid = 1'b0;
        m_axis_ui.tdata  = '0;
        m_axis_ui.tkeep  = '0;
        m_axis_ui.tstrb  = '0;
        m_axis_ui.tlast  = 1'b0;
        m_axis_ui.tuser  = '0;
        m_axis_ui.tid    = '0;
        m_axis_ui.tdest  = '0;

        if (state == ST_TX) begin
            m_axis_ui.tvalid = 1'b1;
            m_axis_ui.tdata  = combined_window >> (byte_shift * 8);

            for (int i = 0; i < KEEP_W; i++) begin
                if ((bytes_sent + i) < actual_pyld_bytes) begin
                    m_axis_ui.tkeep[i] = 1'b1;
                    m_axis_ui.tstrb[i] = 1'b1;
                end
            end

            m_axis_ui.tlast = ((bytes_sent + KEEP_W) >= actual_pyld_bytes);

            if (bytes_sent == 0) begin
                m_axis_ui.tuser = rx_user;
            end
        end
    end

    // ---------------------------------------------------------
    // Máquina de Estados Principal
    // ---------------------------------------------------------
    always_ff @(posedge clk) begin
        if (rst) begin
            state             <= ST_CAPTURE;
            meta_count        <= '0;
            meta_done         <= 1'b0;
            pkt_done          <= 1'b0;

            flags             <= '0;
            udp_len_field     <= '0;
            payload_offset    <= '0;

            rx_word_count     <= '0;
            rx_total_bytes    <= '0;
            tx_word_count     <= '0;
            bytes_sent        <= '0;

            pkt_overflow      <= 1'b0;
            rx_user           <= 1'b0;
            prev_word         <= '0;
            byte_shift        <= '0;
            actual_pyld_bytes <= '0;

        end else begin
            case (state)
                // =============================================
                // 1. CAPTURA DE METADATOS Y TRAMA COMPLETA
                // =============================================
                ST_CAPTURE: begin
                    if (s_axis_meta.tvalid && s_axis_meta.tready) begin
                        case (meta_count)
                            4'd0: begin
                                flags         <= s_axis_meta.tdata[31:0];
                                udp_len_field <= s_axis_meta.tdata[47:32];
                            end
                            4'd1: begin
                                payload_offset <= s_axis_meta.tdata[63:56];
                            end
                            default: ;
                        endcase

                        if (s_axis_meta.tlast) begin
                            meta_done <= 1'b1;
                        end else begin
                            meta_count <= meta_count + 1'b1;
                        end
                    end

                    if (s_axis_pkt.tvalid && s_axis_pkt.tready) begin
                        if (rx_word_count < RAM_WORDS) begin
                            ram_data[rx_word_count] <= s_axis_pkt.tdata;
                        end else begin
                            pkt_overflow <= 1'b1;
                        end

                        if (rx_word_count == 0) begin
                            rx_user <= s_axis_pkt.tuser;
                        end

                        rx_word_count  <= rx_word_count + 1'b1;
                        rx_total_bytes <= rx_total_bytes + count_keep_bytes(s_axis_pkt.tkeep);

                        if (s_axis_pkt.tlast) begin
                            pkt_done <= 1'b1;
                        end
                    end

                    if (meta_done && pkt_done) begin
                        state <= ST_CHECK;
                    end
                end

                // =============================================
                // 2. VALIDACIÓN Y PREPARACIÓN DE LECTURA
                // =============================================
                ST_CHECK: begin
                    actual_pyld_bytes <= (udp_len_field > 16'd8) ? (udp_len_field - 16'd8) : 16'd0;

                    if (
                        flags[FLG_PARSE_DONE] &&
                        flags[FLG_UDP] &&
                        !flags[FLG_FRAG] &&
                        !flags[FLG_L3_BAD_CKSUM] &&
                        !flags[FLG_L4_BAD_LEN] &&
                        !pkt_overflow &&
                        (payload_offset > 8'd0) &&
                        (udp_len_field > 16'd8) &&
                        ((exact_hdr_bytes + (udp_len_field - 16'd8)) <= rx_total_bytes)
                    ) begin
                        byte_shift    <= exact_hdr_bytes[2:0];
                        tx_word_count <= start_word + 1'b1;
                        prev_word     <= ram_data[start_word];
                        bytes_sent    <= '0;
                        state         <= ST_TX;
                    end else begin
                        meta_count     <= '0;
                        meta_done      <= 1'b0;
                        pkt_done       <= 1'b0;
                        rx_word_count  <= '0;
                        rx_total_bytes <= '0;
                        pkt_overflow   <= 1'b0;
                        state          <= ST_CAPTURE;
                    end
                end

                // =============================================
                // 3. TRANSMISIÓN DEL PAYLOAD PURO ALINEADO
                // =============================================
                ST_TX: begin
                    if (m_axis_ui.tvalid && m_axis_ui.tready) begin
                        if (m_axis_ui.tlast) begin
                            meta_count     <= '0;
                            meta_done      <= 1'b0;
                            pkt_done       <= 1'b0;
                            rx_word_count  <= '0;
                            rx_total_bytes <= '0;
                            pkt_overflow   <= 1'b0;
                            state          <= ST_CAPTURE;
                        end else begin
                            bytes_sent    <= bytes_sent + KEEP_W;
                            tx_word_count <= tx_word_count + 1'b1;
                            prev_word     <= read_word;
                        end
                    end
                end

                default: state <= ST_CAPTURE;
            endcase
        end
    end

endmodule

`default_nettype wire