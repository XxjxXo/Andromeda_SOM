// SPDX-License-Identifier: MIT
/*

Copyright (c) 2014-2026 FPGA Ninja, LLC

Authors:
- Alex Forencich

*/

`resetall
`timescale 1ns / 1ps
`default_nettype none

/*
 * FPGA core logic
 */
module fpga_core #
(
    // simulation (set to avoid vendor primitives)
    parameter logic SIM = 1'b0,
    // vendor ("GENERIC", "XILINX", "ALTERA")
    parameter string VENDOR = "XILINX",
    // device family
    parameter string FAMILY = "zynquplus",
    // MAC configuration
    parameter logic CFG_LOW_LATENCY = 1'b1,
    parameter logic COMBINED_MAC_PCS = 1'b1,
    parameter MAC_DATA_W = 512
)
(
    /*
     * Clock: 125MHz
     * Synchronous reset
     */
    input  wire logic        clk_125mhz,
    input  wire logic        rst_125mhz,

    /*
     * GPIO
     */
    input  wire logic        btnu,
    input  wire logic        btnl,
    input  wire logic        btnd,
    input  wire logic        btnr,
    input  wire logic        btnc,
    input  wire logic [3:0]  sw,
    output wire logic [7:0]  led,

    /*
     * UART: 115200 bps, 8N1
     */
    input  wire logic        uart_rxd,
    output wire logic        uart_txd,
    input  wire logic        uart_rts,
    output wire logic        uart_cts,

    /*
     * Ethernet: 1000BASE-T SGMII
     */
    input  wire logic        phy_gmii_clk,
    input  wire logic        phy_gmii_rst,
    input  wire logic        phy_gmii_clk_en,
    input  wire logic [7:0]  phy_gmii_rxd,
    input  wire logic        phy_gmii_rx_dv,
    input  wire logic        phy_gmii_rx_er,
    output wire logic [7:0]  phy_gmii_txd,
    output wire logic        phy_gmii_tx_en,
    output wire logic        phy_gmii_tx_er,
    output wire logic        phy_reset_n,
    input  wire logic        phy_int_n,
    input  wire logic        phy_mdio_i,
    output wire logic        phy_mdio_o,
    output wire logic        phy_mdio_t,
    output wire logic        phy_mdc,

    /*
     * Ethernet: QSFP28
     */
    input  wire logic        qsfp1_rx_p[4],
    input  wire logic        qsfp1_rx_n[4],
    output wire logic        qsfp1_tx_p[4],
    output wire logic        qsfp1_tx_n[4],
    input  wire logic        qsfp1_mgt_refclk_0_p,
    input  wire logic        qsfp1_mgt_refclk_0_n,
    // input  wire logic        qsfp1_mgt_refclk_1_p,
    // input  wire logic        qsfp1_mgt_refclk_1_n,
    // output wire logic        qsfp1_recclk_p,
    // output wire logic        qsfp1_recclk_n,
    output wire logic        qsfp1_modsell,
    output wire logic        qsfp1_resetl,
    input  wire logic        qsfp1_modprsl,
    input  wire logic        qsfp1_intl,
    output wire logic        qsfp1_lpmode
);

// assign led = 8'(sw);

// XFCP
assign uart_cts = 1'b0;

taxi_axis_if #(.DATA_W(8), .USER_EN(1), .USER_W(1)) xfcp_ds(), xfcp_us();

taxi_xfcp_if_uart #(
    .TX_FIFO_DEPTH(512),
    .RX_FIFO_DEPTH(512)
)
xfcp_if_uart_inst (
    .clk(clk_125mhz),
    .rst(rst_125mhz),

    /*
     * UART interface
     */
    .uart_rxd(uart_rxd),
    .uart_txd(uart_txd),

    /*
     * XFCP downstream interface
     */
    .xfcp_dsp_ds(xfcp_ds),
    .xfcp_dsp_us(xfcp_us),

    /*
     * Configuration
     */
    .prescale(16'(125000000/921600))
);

localparam XFCP_PORTS = 1+1;

taxi_axis_if #(.DATA_W(8), .USER_EN(1), .USER_W(1)) xfcp_sw_ds[XFCP_PORTS](), xfcp_sw_us[XFCP_PORTS]();

taxi_xfcp_switch #(
    .XFCP_ID_STR("ANDROMEDA_SOM"),
    .XFCP_EXT_ID(0),
    .XFCP_EXT_ID_STR("Taxi example"),
    .PORTS($size(xfcp_sw_us))
)
xfcp_sw_inst (
    .clk(clk_125mhz),
    .rst(rst_125mhz),

    /*
     * XFCP upstream port
     */
    .xfcp_usp_ds(xfcp_ds),
    .xfcp_usp_us(xfcp_us),

    /*
     * XFCP downstream ports
     */
    .xfcp_dsp_ds(xfcp_sw_ds),
    .xfcp_dsp_us(xfcp_sw_us)
);

taxi_axis_if #(.DATA_W(16), .KEEP_W(1), .KEEP_EN(0), .LAST_EN(0), .USER_EN(1), .USER_W(1), .ID_EN(1), .ID_W(10)) axis_stat();

taxi_xfcp_mod_stats #(
    .XFCP_ID_STR("Statistics"),
    .XFCP_EXT_ID(0),
    .XFCP_EXT_ID_STR(""),
    .STAT_COUNT_W(64),
    .STAT_PIPELINE(2)
)
xfcp_stats_inst (
    .clk(clk_125mhz),
    .rst(rst_125mhz),

    /*
     * XFCP upstream port
     */
    .xfcp_usp_ds(xfcp_sw_ds[0]),
    .xfcp_usp_us(xfcp_sw_us[0]),

    /*
     * Statistics increment input
     */
    .s_axis_stat(axis_stat)
);

taxi_axis_if #(.DATA_W(16), .KEEP_W(1), .KEEP_EN(0), .LAST_EN(0), .USER_EN(1), .USER_W(1), .ID_EN(1), .ID_W(10)) axis_eth_stat[2]();

taxi_axis_arb_mux #(
    .S_COUNT($size(axis_eth_stat)),
    .UPDATE_TID(1'b0),
    .ARB_ROUND_ROBIN(1'b1),
    .ARB_LSB_HIGH_PRIO(1'b0)
)
stat_mux_inst (
    .clk(clk_125mhz),
    .rst(rst_125mhz),

    /*
     * AXI4-Stream inputs (sink)
     */
    .s_axis(axis_eth_stat),

    /*
     * AXI4-Stream output (source)
     */
    .m_axis(axis_stat)
);

// BASE-T PHY
assign phy_reset_n = !rst_125mhz;

taxi_axis_if #(.DATA_W(8), .ID_W(8), .USER_EN(1), .USER_W(1)) axis_eth();
taxi_axis_if #(.DATA_W(96), .KEEP_W(1), .ID_W(8)) axis_tx_cpl();

taxi_eth_mac_1g_fifo #(
    .STAT_EN(1),
    .STAT_TX_LEVEL(1),
    .STAT_RX_LEVEL(1),
    .STAT_ID_BASE(0),
    .STAT_UPDATE_PERIOD(1024),
    .STAT_STR_EN(1),
    .STAT_PREFIX_STR("SGMII0"),
    .TX_FIFO_DEPTH(16384),
    .TX_FRAME_FIFO(1),
    .RX_FIFO_DEPTH(16384),
    .RX_FRAME_FIFO(1)
)
eth_mac_inst (
    .rx_clk(phy_gmii_clk),
    .rx_rst(phy_gmii_rst),
    .tx_clk(phy_gmii_clk),
    .tx_rst(phy_gmii_rst),
    .logic_clk(clk_125mhz),
    .logic_rst(rst_125mhz),

    /*
     * Transmit interface (AXI stream)
     */
    .s_axis_tx(axis_eth),
    .m_axis_tx_cpl(axis_tx_cpl),

    /*
     * Receive interface (AXI stream)
     */
    .m_axis_rx(axis_eth),

    /*
     * GMII interface
     */
    .gmii_rxd(phy_gmii_rxd),
    .gmii_rx_dv(phy_gmii_rx_dv),
    .gmii_rx_er(phy_gmii_rx_er),
    .gmii_txd(phy_gmii_txd),
    .gmii_tx_en(phy_gmii_tx_en),
    .gmii_tx_er(phy_gmii_tx_er),

    /*
     * Control
     */
    .rx_clk_enable(phy_gmii_clk_en),
    .tx_clk_enable(phy_gmii_clk_en),
    .rx_mii_select(1'b0),
    .tx_mii_select(1'b0),

    /*
     * Statistics
     */
    .stat_clk(clk_125mhz),
    .stat_rst(rst_125mhz),
    .m_axis_stat(axis_eth_stat[0]),

    /*
     * Status
     */
    .tx_error_underflow(),
    .tx_fifo_overflow(),
    .tx_fifo_bad_frame(),
    .tx_fifo_good_frame(),
    .rx_error_bad_frame(),
    .rx_error_bad_fcs(),
    .rx_fifo_overflow(),
    .rx_fifo_bad_frame(),
    .rx_fifo_good_frame(),

    /*
     * Configuration
     */
    .cfg_tx_pad_en(1'b1),
    .cfg_tx_min_pkt_len(8'd60-1),
    .cfg_tx_max_pkt_len(16'd9218-1),
    .cfg_tx_ifg(8'd12),
    .cfg_tx_enable(1'b1),
    .cfg_rx_max_pkt_len(16'd9218-1),
    .cfg_rx_enable(1'b1)
);

// PHY MDIO init
reg [19:0] delay_reg = '1;

reg [1:0] mdio_cmd_st_reg = 2'b01; // clause 22
reg [1:0] mdio_cmd_op_reg = 2'b01; // write
reg [4:0] mdio_cmd_phy_addr_reg = 5'h03;
reg [4:0] mdio_cmd_reg_addr_reg = 5'h00;
reg [15:0] mdio_cmd_data_reg = '0;
reg mdio_cmd_valid_reg = 1'b0;
wire mdio_cmd_ready;

taxi_axis_if #(.DATA_W(32)) axis_mdio_cmd();
taxi_axis_if #(.DATA_W(16)) axis_mdio_rd_data();

assign axis_mdio_cmd.tdata = {mdio_cmd_st_reg, mdio_cmd_op_reg, mdio_cmd_phy_addr_reg, mdio_cmd_reg_addr_reg, 2'b10, mdio_cmd_data_reg};
assign axis_mdio_cmd.tvalid = mdio_cmd_valid_reg;
assign mdio_cmd_ready = axis_mdio_cmd.tready;

assign axis_mdio_rd_data.tready = 1'b1;

reg [3:0] state_reg = '0;

always_ff @(posedge clk_125mhz) begin
    mdio_cmd_valid_reg <= mdio_cmd_valid_reg && !mdio_cmd_ready;

    if (delay_reg != 0) begin
        delay_reg <= delay_reg - 1;
    end else if (mdio_cmd_valid_reg) begin
        // wait for ready
        state_reg <= state_reg;
    end else begin
        case (state_reg)
            // set SGMII autonegotiation timer to 11 ms
            // write 0x0070 to CFG4 (0x0031)
            4'd0: begin
                // write to REGCR to load address
                mdio_cmd_reg_addr_reg <= 5'h0D;
                mdio_cmd_data_reg <= 16'h001F;
                mdio_cmd_valid_reg <= 1'b1;
                state_reg <= 4'd1;
            end
            4'd1: begin
                // write address of CFG4 to ADDAR
                mdio_cmd_reg_addr_reg <= 5'h0E;
                mdio_cmd_data_reg <= 16'h0031;
                mdio_cmd_valid_reg <= 1'b1;
                state_reg <= 4'd2;
            end
            4'd2: begin
                // write to REGCR to load data
                mdio_cmd_reg_addr_reg <= 5'h0D;
                mdio_cmd_data_reg <= 16'h401F;
                mdio_cmd_valid_reg <= 1'b1;
                state_reg <= 4'd3;
            end
            4'd3: begin
                // write data for CFG4 to ADDAR
                mdio_cmd_reg_addr_reg <= 5'h0E;
                mdio_cmd_data_reg <= 16'h0070;
                mdio_cmd_valid_reg <= 1'b1;
                state_reg <= 4'd4;
            end
            // enable SGMII clock output
            // write 0x4000 to SGMIICTL1 (0x00D3)
            4'd4: begin
                // write to REGCR to load address
                mdio_cmd_reg_addr_reg <= 5'h0D;
                mdio_cmd_data_reg <= 16'h001F;
                mdio_cmd_valid_reg <= 1'b1;
                state_reg <= 4'd5;
            end
            4'd5: begin
                // write address of SGMIICTL1 to ADDAR
                mdio_cmd_reg_addr_reg <= 5'h0E;
                mdio_cmd_data_reg <= 16'h00D3;
                mdio_cmd_valid_reg <= 1'b1;
                state_reg <= 4'd6;
            end
            4'd6: begin
                // write to REGCR to load data
                mdio_cmd_reg_addr_reg <= 5'h0D;
                mdio_cmd_data_reg <= 16'h401F;
                mdio_cmd_valid_reg <= 1'b1;
                state_reg <= 4'd7;
            end
            4'd7: begin
                // write data for SGMIICTL1 to ADDAR
                mdio_cmd_reg_addr_reg <= 5'h0E;
                mdio_cmd_data_reg <= 16'h4000;
                mdio_cmd_valid_reg <= 1'b1;
                state_reg <= 4'd8;
            end
            // enable 10Mbps operation
            // write 0x0015 to 10M_SGMII_CFG (0x016F)
            4'd8: begin
                // write to REGCR to load address
                mdio_cmd_reg_addr_reg <= 5'h0D;
                mdio_cmd_data_reg <= 16'h001F;
                mdio_cmd_valid_reg <= 1'b1;
                state_reg <= 4'd9;
            end
            4'd9: begin
                // write address of 10M_SGMII_CFG to ADDAR
                mdio_cmd_reg_addr_reg <= 5'h0E;
                mdio_cmd_data_reg <= 16'h016F;
                mdio_cmd_valid_reg <= 1'b1;
                state_reg <= 4'd10;
            end
            4'd10: begin
                // write to REGCR to load data
                mdio_cmd_reg_addr_reg <= 5'h0D;
                mdio_cmd_data_reg <= 16'h401F;
                mdio_cmd_valid_reg <= 1'b1;
                state_reg <= 4'd11;
            end
            4'd11: begin
                // write data for 10M_SGMII_CFG to ADDAR
                mdio_cmd_reg_addr_reg <= 5'h0E;
                mdio_cmd_data_reg <= 16'h0015;
                mdio_cmd_valid_reg <= 1'b1;
                state_reg <= 4'd12;
            end
            4'd12: begin
                // done
                state_reg <= 4'd12;
            end
            default: begin
                // go to idle
                state_reg <= 4'd0;
            end
        endcase
    end

    if (rst_125mhz) begin
        state_reg <= '0;
        delay_reg <= SIM ? 100 : '1;
        mdio_cmd_valid_reg <= 1'b0;
    end
end

taxi_mdio_master
mdio_master_inst (
    .clk(clk_125mhz),
    .rst(rst_125mhz),

    .s_axis_cmd(axis_mdio_cmd),
    .m_axis_rd_data(axis_mdio_rd_data),

    .mdc_o(phy_mdc),
    .mdio_i(phy_mdio_i),
    .mdio_o(phy_mdio_o),
    .mdio_t(phy_mdio_t),

    .busy(),

    // The TI DP83867IS PHY chip supports an MDC frequency of 25 MHz
    .prescale(8'(125/25/2))
);

// QSFP28
localparam MAC_CNT = MAC_DATA_W > 64 ? 1 : 4;

assign qsfp1_modsell = 1'b0;
assign qsfp1_resetl = 1'b1;
assign qsfp1_lpmode = 1'b0;

wire qsfp_tx_clk[MAC_CNT];
wire qsfp_tx_rst[MAC_CNT];
wire qsfp_rx_clk[MAC_CNT];
wire qsfp_rx_rst[MAC_CNT];

wire qsfp_rx_status[MAC_CNT];
wire qsfp_rx_act[MAC_CNT];

wire [0:0] qsfp_gtpowergood;

// Debug LEDs for TX bring-up (qsfp_rx_act is not driven by the RX sink):
// led[3:0] RX status per MAC
// led[4]   GT power good
// led[5]   TX out of reset on all MACs
// led[6]   heartbeat in qsfp_tx_clk[0] (322.27 MHz / 2^28, about 1.2 Hz)
logic [MAC_CNT-1:0] qsfp_tx_up;

for (genvar n = 0; n < MAC_CNT; n = n + 1) begin
    assign led[n] = qsfp_rx_status[n];
    assign qsfp_tx_up[n] = !qsfp_tx_rst[n];
end

for (genvar n = MAC_CNT; n < 4; n = n + 1) begin
    assign led[n] = 1'b0;
end

logic [27:0] qsfp_tx_hb_reg = '0;

always_ff @(posedge qsfp_tx_clk[0]) begin
    qsfp_tx_hb_reg <= qsfp_tx_hb_reg + 1;
end

assign led[4] = &qsfp_gtpowergood;
assign led[5] = &qsfp_tx_up;
assign led[6] = qsfp_tx_hb_reg[27];
assign led[7] = 1'b0;

wire qsfp1_mgt_refclk_0;
wire qsfp1_mgt_refclk_0_int;

wire qsfp_rst;

taxi_axis_if #(.DATA_W(MAC_DATA_W), .ID_W(8), .USER_EN(1), .USER_W(1)) axis_qsfp_tx[MAC_CNT]();
taxi_axis_if #(.DATA_W(96), .KEEP_W(1), .ID_W(8)) axis_qsfp_tx_cpl[MAC_CNT]();
taxi_axis_if #(.DATA_W(MAC_DATA_W), .ID_W(8), .USER_EN(1), .USER_W(1)) axis_qsfp_rx[MAC_CNT]();

if (SIM) begin

    assign qsfp1_mgt_refclk_0 = qsfp1_mgt_refclk_0_p;
    assign qsfp1_mgt_refclk_0_int = qsfp1_mgt_refclk_0_p;

end else begin

    IBUFDS_GTE4 ibufds_gte4_qsfp1_mgt_refclk_0_inst (
        .I     (qsfp1_mgt_refclk_0_p),
        .IB    (qsfp1_mgt_refclk_0_n),
        .CEB   (1'b0),
        .O     (qsfp1_mgt_refclk_0),
        .ODIV2 (qsfp1_mgt_refclk_0_int)
    );

end

taxi_sync_reset #(
    .N(4)
)
// qsfp_rst drives xcvr_ctrl_rst, whose clock is clk_125mhz. (It used to be
// synchronised to the refclk through a BUFG_GT gated by gtpowergood; with
// the buffered GT IP that BUFG_GT could not be routed: its CE/CLR need a
// BUFG_GT_SYNC.)
qsfp_sync_reset_inst (
    .clk(clk_125mhz),
    .rst(rst_125mhz),
    .out(qsfp_rst)
);

wire qsfp_tx_p[4];
wire qsfp_tx_n[4];
wire qsfp_rx_p[4];
wire qsfp_rx_n[4];

assign qsfp1_tx_p = qsfp_tx_p[4*0 +: 4];
assign qsfp1_tx_n = qsfp_tx_n[4*0 +: 4];

assign qsfp_rx_p[4*0 +: 4] = qsfp1_rx_p;
assign qsfp_rx_n[4*0 +: 4] = qsfp1_rx_n;


localparam logic [8*8-1:0] STAT_PREFIX_STR_QSFP1[4] = '{"QSFP1.1", "QSFP1.2", "QSFP1.3",  "QSFP1.4"};

for (genvar n = 0; n < 1; n = n + 1) begin : gt_quad

    localparam CNT = 4;

    taxi_apb_if #(
        .ADDR_W(18),
        .DATA_W(16)
    )
    gt_apb_ctrl();

    taxi_xfcp_mod_apb #(
        .XFCP_EXT_ID_STR("GTY CTRL")
    )
    xfcp_mod_apb_inst (
        .clk(clk_125mhz),
        .rst(rst_125mhz),

        /*
         * XFCP upstream port
         */
        .xfcp_usp_ds(xfcp_sw_ds[n+1]),
        .xfcp_usp_us(xfcp_sw_us[n+1]),

        /*
         * APB master interface
         */
        .m_apb(gt_apb_ctrl)
    );

    if (MAC_DATA_W == 512) begin: mac

        // Debug signals (VIO / ILA), see the debug block after mac_inst
        wire [2:0]  dbg_gt_loopback;
        wire [19:0] dbg_gt_tx_vio;
        wire [19:0] dbg_gt_tx;
        wire        dbg_rx_rst;
        wire        dbg_tx_rst;
        wire [63:0] dbg_cmac_rx_stat;
        wire [7:0]  dbg_cmac_tx_stat;

        taxi_eth_mac_100g_us #(
            .SIM(SIM),
            .VENDOR(VENDOR),
            .FAMILY(FAMILY),

            .GT_CNT(CNT),

            // GT config
            .CFG_LOW_LATENCY(CFG_LOW_LATENCY),

            // GT TX swing and de-emphasis for the SOM + PE5 + QSFP28 channel at
            // 25.78 Gb/s: with the Taxi defaults (16/0/0) the eye at the module
            // input is closed and the link partner never syncs. 20/16/0 found by
            // sweeping from the VIO (raw BER 1e-11 before RS-FEC).
            // RX in DFE mode.
            .GT_TX_DIFFCTRL('{CNT{5'd20}}),
            .GT_TX_POSTCURSOR('{CNT{5'd16}}),
            .GT_TX_PRECURSOR('{CNT{5'd0}}),
            .GT_RX_LPM_EN('0),

            // GT type
            .GT_TYPE("GTY"),

            // MAC/PHY config
            .PTP_TS_EN(1'b0),
            .PTP_TD_EN(1'b0),
            .PTP_TS_FMT_TOD(1'b1),
            .PTP_TS_W(96),
            .PTP_TD_SDI_PIPELINE(2),
            .TX_SERDES_PIPELINE(1),
            .RX_SERDES_PIPELINE(1),
            .STAT_EN(1),
            .STAT_TX_LEVEL(1),
            .STAT_RX_LEVEL(1),
            .STAT_ID_BASE((16+16)+n*(16+16)),
            .STAT_UPDATE_PERIOD(1024),
            .STAT_STR_EN(1),
            .STAT_PREFIX_STR("QSFP1")
        )
        mac_inst (
            .xcvr_ctrl_clk(clk_125mhz),
            .xcvr_ctrl_rst(qsfp_rst),

            /*
             * Transceiver control
             */
            .s_apb_ctrl(gt_apb_ctrl),

            /*
             * Common
             */
            .xcvr_gtpowergood_out(qsfp_gtpowergood[n]),
            .xcvr_gtrefclk00_in(qsfp1_mgt_refclk_0),
            .xcvr_gtrefclk01_in(qsfp1_mgt_refclk_0),

            /*
             * Serial data
             */
            .xcvr_txp(qsfp_tx_p[n*CNT +: CNT]),
            .xcvr_txn(qsfp_tx_n[n*CNT +: CNT]),
            .xcvr_rxp(qsfp_rx_p[n*CNT +: CNT]),
            .xcvr_rxn(qsfp_rx_n[n*CNT +: CNT]),

            /*
             * MAC clocks
             */
            .rx_clk(qsfp_rx_clk[n]),
            .rx_rst_in(dbg_rx_rst),
            .rx_rst_out(qsfp_rx_rst[n]),
            .tx_clk(qsfp_tx_clk[n]),
            .tx_rst_in(dbg_tx_rst),
            .tx_rst_out(qsfp_tx_rst[n]),

            /*
             * Transmit interface (AXI stream)
             */
            .s_axis_tx(axis_qsfp_tx[n]),
            .m_axis_tx_cpl(axis_qsfp_tx_cpl[n]),

            /*
             * Receive interface (AXI stream)
             */
            .m_axis_rx(axis_qsfp_rx[n]),

            /*
             * PTP clock
             */
            .ptp_clk(1'b0),
            .ptp_rst(1'b0),
            .ptp_sample_clk(1'b0),
            .ptp_td_sdi(1'b0),
            .tx_ptp_ts_in('0),
            .tx_ptp_ts_out(),
            .tx_ptp_ts_step_out(),
            .tx_ptp_locked(),
            .rx_ptp_ts_in('0),
            .rx_ptp_ts_out(),
            .rx_ptp_ts_step_out(),
            .rx_ptp_locked(),

            /*
             * Link-level Flow Control (LFC) (IEEE 802.3 annex 31B PAUSE)
             */
            .tx_lfc_req(1'b0),
            .tx_lfc_resend(1'b0),
            .rx_lfc_en(1'b0),
            .rx_lfc_req(),
            .rx_lfc_ack(1'b0),

            /*
             * Priority Flow Control (PFC) (IEEE 802.3 annex 31D PFC)
             */
            .tx_pfc_req('0),
            .tx_pfc_resend(1'b0),
            .rx_pfc_en('0),
            .rx_pfc_req(),
            .rx_pfc_ack('0),

            /*
             * Pause interface
             */
            .tx_lfc_pause_en(1'b0),
            .tx_pause_req(1'b0),
            .tx_pause_ack(),

            /*
             * Statistics
             */
            .stat_clk(clk_125mhz),
            .stat_rst(rst_125mhz),
            .m_axis_stat(axis_eth_stat[n+1]),

            /*
             * Status
             */
            .tx_start_packet(),
            .stat_tx_byte(),
            .stat_tx_pkt_len(),
            .stat_tx_pkt_ucast(),
            .stat_tx_pkt_mcast(),
            .stat_tx_pkt_bcast(),
            .stat_tx_pkt_vlan(),
            .stat_tx_pkt_good(),
            .stat_tx_pkt_bad(),
            .stat_tx_pad_frame(),
            .stat_tx_err_oversize(),
            .stat_tx_err_user(),
            .stat_tx_err_underflow(),
            .rx_start_packet(),
            .rx_error_count(),
            .rx_block_lock(),
            .rx_high_ber(),
            .rx_status(qsfp_rx_status[n]),
            .stat_rx_byte(),
            .stat_rx_pkt_len(),
            .stat_rx_pkt_fragment(),
            .stat_rx_pkt_jabber(),
            .stat_rx_pkt_ucast(),
            .stat_rx_pkt_mcast(),
            .stat_rx_pkt_bcast(),
            .stat_rx_pkt_vlan(),
            .stat_rx_pkt_good(),
            .stat_rx_pkt_bad(),
            .stat_rx_err_oversize(),
            .stat_rx_err_bad_fcs(),
            .stat_rx_err_bad_block(),
            .stat_rx_err_framing(),
            .stat_rx_err_preamble(),
            .stat_rx_fifo_drop(1'b0),
            .stat_tx_mcf(),
            .stat_rx_mcf(),
            .stat_tx_lfc_pkt(),
            .stat_tx_lfc_xon(),
            .stat_tx_lfc_xoff(),
            .stat_tx_lfc_paused(),
            .stat_tx_pfc_pkt(),
            .stat_tx_pfc_xon(),
            .stat_tx_pfc_xoff(),
            .stat_tx_pfc_paused(),
            .stat_rx_lfc_pkt(),
            .stat_rx_lfc_xon(),
            .stat_rx_lfc_xoff(),
            .stat_rx_lfc_paused(),
            .stat_rx_pfc_pkt(),
            .stat_rx_pfc_xon(),
            .stat_rx_pfc_xoff(),
            .stat_rx_pfc_paused(),

            /*
             * Configuration
             */
            .cfg_tx_pad_en(1'b1),
            .cfg_tx_min_pkt_len(8'd60-1),
            .cfg_tx_max_pkt_len(16'd9218-1),
            .cfg_tx_ifg(8'd12),
            .cfg_tx_enable(1'b1),
            .cfg_rx_max_pkt_len(16'd9218-1),
            .cfg_rx_enable(1'b1),
            .cfg_tx_prbs31_enable(1'b0),
            .cfg_rx_prbs31_enable(1'b0),
            .cfg_mcf_rx_eth_dst_mcast(48'h01_80_C2_00_00_01),
            .cfg_mcf_rx_check_eth_dst_mcast(1'b1),
            .cfg_mcf_rx_eth_dst_ucast(48'd0),
            .cfg_mcf_rx_check_eth_dst_ucast(1'b0),
            .cfg_mcf_rx_eth_src(48'd0),
            .cfg_mcf_rx_check_eth_src(1'b0),
            .cfg_mcf_rx_eth_type(16'h8808),
            .cfg_mcf_rx_opcode_lfc(16'h0001),
            .cfg_mcf_rx_check_opcode_lfc(1'b1),
            .cfg_mcf_rx_opcode_pfc(16'h0101),
            .cfg_mcf_rx_check_opcode_pfc(1'b1),
            .cfg_mcf_rx_forward(1'b0),
            .cfg_mcf_rx_enable(1'b0),
            .cfg_tx_lfc_eth_dst(48'h01_80_C2_00_00_01),
            .cfg_tx_lfc_eth_src(48'h80_23_31_43_54_4C),
            .cfg_tx_lfc_eth_type(16'h8808),
            .cfg_tx_lfc_opcode(16'h0001),
            .cfg_tx_lfc_en(1'b0),
            .cfg_tx_lfc_quanta(16'hffff),
            .cfg_tx_lfc_refresh(16'h7fff),
            .cfg_tx_pfc_eth_dst(48'h01_80_C2_00_00_01),
            .cfg_tx_pfc_eth_src(48'h80_23_31_43_54_4C),
            .cfg_tx_pfc_eth_type(16'h8808),
            .cfg_tx_pfc_opcode(16'h0101),
            .cfg_tx_pfc_en(1'b0),
            .cfg_tx_pfc_quanta('{8{16'hffff}}),
            .cfg_tx_pfc_refresh('{8{16'h7fff}}),
            .cfg_rx_lfc_opcode(16'h0001),
            .cfg_rx_lfc_en(1'b0),
            .cfg_rx_pfc_opcode(16'h0101),
            .cfg_rx_pfc_en(1'b0),

            /*
             * Debug
             */
            .gt_loopback_in(dbg_gt_loopback),
            .gt_tx_dbg_in(dbg_gt_tx),
            .dbg_cmac_rx_stat(dbg_cmac_rx_stat),
            .dbg_cmac_tx_stat(dbg_cmac_tx_stat)
        );

        // ------------------------------------------------------------------
        // Debug: VIO (GT loopback, resets, clock frequency) and ILAs (CMAC)
        // ------------------------------------------------------------------

        // Clock frequency measurement against clk_125mhz (PS PL_CLK0).
        // The gate toggles every 2^27 cycles of clk_125mhz (1.073741824 s);
        // each clock counts its own cycles between gate edges.
        // Expected count at 322.265625 MHz: 346030080 (1 ppm = ~346 counts).
        logic [26:0] dbg_gate_cnt_reg = '0;
        logic        dbg_gate_tgl_reg = 1'b0;

        always_ff @(posedge clk_125mhz) begin
            dbg_gate_cnt_reg <= dbg_gate_cnt_reg + 1;
            if (&dbg_gate_cnt_reg) begin
                dbg_gate_tgl_reg <= !dbg_gate_tgl_reg;
            end
        end

        wire dbg_gate_tx;
        wire dbg_gate_rx;

        taxi_sync_signal #(.WIDTH(1), .N(3))
        dbg_gate_tx_sync_inst (
            .clk(qsfp_tx_clk[n]),
            .in(dbg_gate_tgl_reg),
            .out(dbg_gate_tx)
        );

        taxi_sync_signal #(.WIDTH(1), .N(3))
        dbg_gate_rx_sync_inst (
            .clk(qsfp_rx_clk[n]),
            .in(dbg_gate_tgl_reg),
            .out(dbg_gate_rx)
        );

        logic        dbg_gate_tx_d_reg = 1'b0;
        logic [31:0] dbg_tx_cyc_reg = '0;
        logic [31:0] dbg_tx_freq_reg = '0;

        always_ff @(posedge qsfp_tx_clk[n]) begin
            dbg_gate_tx_d_reg <= dbg_gate_tx;
            if (dbg_gate_tx ^ dbg_gate_tx_d_reg) begin
                dbg_tx_freq_reg <= dbg_tx_cyc_reg + 1;
                dbg_tx_cyc_reg <= '0;
            end else begin
                dbg_tx_cyc_reg <= dbg_tx_cyc_reg + 1;
            end
        end

        logic        dbg_gate_rx_d_reg = 1'b0;
        logic [31:0] dbg_rx_cyc_reg = '0;
        logic [31:0] dbg_rx_freq_reg = '0;

        always_ff @(posedge qsfp_rx_clk[n]) begin
            dbg_gate_rx_d_reg <= dbg_gate_rx;
            if (dbg_gate_rx ^ dbg_gate_rx_d_reg) begin
                dbg_rx_freq_reg <= dbg_rx_cyc_reg + 1;
                dbg_rx_cyc_reg <= '0;
            end else begin
                dbg_rx_cyc_reg <= dbg_rx_cyc_reg + 1;
            end
        end

        // Bring counts and status to clk_125mhz for the VIO. The counts are
        // stable for ~1 s between updates; a reading taken right at an update
        // can be inconsistent, so read twice if a value looks odd.
        wire [31:0] dbg_tx_freq_sync;
        wire [31:0] dbg_rx_freq_sync;
        wire [15:0] dbg_rx_stat_sync;
        wire [1:0]  dbg_tx_stat_sync;

        taxi_sync_signal #(.WIDTH(32), .N(2))
        dbg_tx_freq_sync_inst (
            .clk(clk_125mhz),
            .in(dbg_tx_freq_reg),
            .out(dbg_tx_freq_sync)
        );

        taxi_sync_signal #(.WIDTH(32), .N(2))
        dbg_rx_freq_sync_inst (
            .clk(clk_125mhz),
            .in(dbg_rx_freq_reg),
            .out(dbg_rx_freq_sync)
        );

        // RX: status, aligned, aligned_err, misaligned, hi_ber, local_fault,
        // internal_local_fault, received_local_fault, remote_fault,
        // rsfec_hi_ser, rsfec_lane_alignment_status, rsfec_am_lock[3:0],
        // plus TX reset state
        taxi_sync_signal #(.WIDTH(16), .N(2))
        dbg_rx_stat_sync_inst (
            .clk(clk_125mhz),
            .in({qsfp_rx_rst[n], dbg_cmac_rx_stat[14:0]}),
            .out(dbg_rx_stat_sync)
        );

        // TX: local_fault, TX reset state
        taxi_sync_signal #(.WIDTH(2), .N(2))
        dbg_tx_stat_sync_inst (
            .clk(clk_125mhz),
            .in({qsfp_tx_rst[n], dbg_cmac_tx_stat[0]}),
            .out(dbg_tx_stat_sync)
        );

        // VIO (clk_125mhz)
        //   probe_in0  [31:0] TX clock count per gate (expected 346030080)
        //   probe_in1  [31:0] RX clock count per gate (recovered from the
        //                     far end; equals TX in loopback)
        //   probe_in2  [15:0] {rx_rst, dbg_cmac_rx_stat[14:0]}
        //   probe_in3  [1:0]  {tx_rst, stat_tx_local_fault}
        //   probe_in4  [0:0]  gtpowergood
        //   probe_out0 [2:0]  GT loopback: 0 normal, 2 near-end PMA,
        //                     1 near-end PCS, 4 far-end PMA, 6 far-end PCS
        //   probe_out1 [0:0]  RX reset (pulse 1 -> 0 after changing loopback)
        //   probe_out2 [0:0]  TX reset
        //   probe_out3 [4:0]  TX diffctrl  (all lanes, init 16)
        //   probe_out4 [4:0]  TX postcursor (all lanes, init 0)
        //   probe_out5 [4:0]  TX precursor  (all lanes, init 0)
        //   probe_out6 [0:0]  1 = apply probe_out3..5 (0 = build parameters)
        //   probe_out7 [3:0]  TX PRBS: 0 = CMAC data, 5 = PRBS31
        wire [4:0] dbg_vio_txdiffctrl;
        wire [4:0] dbg_vio_txpostcursor;
        wire [4:0] dbg_vio_txprecursor;
        wire       dbg_vio_tx_ovrd;
        wire [3:0] dbg_vio_txprbssel;

        assign dbg_gt_tx_vio = {dbg_vio_tx_ovrd, dbg_vio_txprbssel,
            dbg_vio_txprecursor, dbg_vio_txpostcursor, dbg_vio_txdiffctrl};

        taxi_sync_signal #(.WIDTH(20), .N(2))
        dbg_gt_tx_sync_inst (
            .clk(qsfp_tx_clk[n]),
            .in(dbg_gt_tx_vio),
            .out(dbg_gt_tx)
        );

        vio_cmac
        dbg_vio_inst (
            .clk(clk_125mhz),
            .probe_in0(dbg_tx_freq_sync),
            .probe_in1(dbg_rx_freq_sync),
            .probe_in2(dbg_rx_stat_sync),
            .probe_in3(dbg_tx_stat_sync),
            .probe_in4(qsfp_gtpowergood[n]),
            .probe_out0(dbg_gt_loopback),
            .probe_out1(dbg_rx_rst),
            .probe_out2(dbg_tx_rst),
            .probe_out3(dbg_vio_txdiffctrl),
            .probe_out4(dbg_vio_txpostcursor),
            .probe_out5(dbg_vio_txprecursor),
            .probe_out6(dbg_vio_tx_ovrd),
            .probe_out7(dbg_vio_txprbssel)
        );

        // ILA on the RX clock: full CMAC RX status (see taxi_eth_mac_100g_us
        // for the bit map of dbg_cmac_rx_stat)
        ila_cmac
        dbg_ila_rx_inst (
            .clk(qsfp_rx_clk[n]),
            .probe0(dbg_cmac_rx_stat)
        );

        // ILA on the TX clock: CMAC TX status and TX reset
        ila_cmac
        dbg_ila_tx_inst (
            .clk(qsfp_tx_clk[n]),
            .probe0({55'd0, qsfp_tx_rst[n], dbg_cmac_tx_stat})
        );

    end else begin: mac

        taxi_eth_mac_25g_us #(
            .SIM(SIM),
            .VENDOR(VENDOR),
            .FAMILY(FAMILY),

            .CNT(CNT),

            // GT config
            .CFG_LOW_LATENCY(CFG_LOW_LATENCY),

            // GT type
            .GT_TYPE("GTY"),

            // MAC/PHY config
            .COMBINED_MAC_PCS(COMBINED_MAC_PCS),
            .DATA_W(axis_qsfp_tx[0].DATA_W),
            .USXGMII_EN(COMBINED_MAC_PCS),
            .DIC_EN(1'b1),
            .PTP_TS_EN(1'b0),
            .PTP_TD_EN(1'b0),
            .PTP_TS_FMT_TOD(1'b1),
            .PTP_TS_W(96),
            .PTP_TD_SDI_PIPELINE(2),
            .PRBS31_EN(1'b0),
            .TX_SERDES_PIPELINE(1),
            .RX_SERDES_PIPELINE(1),
            .COUNT_125US(125000/6.4),
            .STAT_EN(1),
            .STAT_TX_LEVEL(1),
            .STAT_RX_LEVEL(1),
            .STAT_ID_BASE((16+16)+n*CNT*(16+16)),
            .STAT_UPDATE_PERIOD(1024),
            .STAT_STR_EN(1),
            .STAT_PREFIX_STR(STAT_PREFIX_STR_QSFP1)
        )
        mac_inst (
            .xcvr_ctrl_clk(clk_125mhz),
            .xcvr_ctrl_rst(qsfp_rst),

            /*
             * Transceiver control
             */
            .s_apb_ctrl(gt_apb_ctrl),

            /*
             * Common
             */
            .xcvr_gtpowergood_out(qsfp_gtpowergood[n]),
            .xcvr_gtrefclk00_in(qsfp1_mgt_refclk_0),
            .xcvr_qpll0pd_in(1'b0),
            .xcvr_qpll0reset_in(1'b0),
            .xcvr_qpll0pcierate_in(3'd0),
            .xcvr_qpll0lock_out(),
            .xcvr_qpll0clk_out(),
            .xcvr_qpll0refclk_out(),
            .xcvr_gtrefclk01_in(qsfp1_mgt_refclk_0),
            .xcvr_qpll1pd_in(1'b0),
            .xcvr_qpll1reset_in(1'b0),
            .xcvr_qpll1pcierate_in(3'd0),
            .xcvr_qpll1lock_out(),
            .xcvr_qpll1clk_out(),
            .xcvr_qpll1refclk_out(),

            /*
             * Serial data
             */
            .xcvr_txp(qsfp_tx_p[n*CNT +: CNT]),
            .xcvr_txn(qsfp_tx_n[n*CNT +: CNT]),
            .xcvr_rxp(qsfp_rx_p[n*CNT +: CNT]),
            .xcvr_rxn(qsfp_rx_n[n*CNT +: CNT]),

            /*
             * MAC clocks
             */
            .rx_clk(qsfp_rx_clk[n*CNT +: CNT]),
            .rx_rst_in('{CNT{1'b0}}),
            .rx_rst_out(qsfp_rx_rst[n*CNT +: CNT]),
            .tx_clk(qsfp_tx_clk[n*CNT +: CNT]),
            .tx_rst_in('{CNT{1'b0}}),
            .tx_rst_out(qsfp_tx_rst[n*CNT +: CNT]),

            /*
             * Transmit interface (AXI stream)
             */
            .s_axis_tx(axis_qsfp_tx[n*CNT +: CNT]),
            .m_axis_tx_cpl(axis_qsfp_tx_cpl[n*CNT +: CNT]),

            /*
             * Receive interface (AXI stream)
             */
            .m_axis_rx(axis_qsfp_rx[n*CNT +: CNT]),

            /*
             * USXGMII autonegotiation
             */
            .an_en('{CNT{1'b1}}),
            .an_restart('{CNT{1'b0}}),
            .an_speedup('{CNT{1'b0}}),
            .an_timeout_en('{CNT{1'b1}}),
            .an_usxgmii_en('{CNT{1'b0}}),
            .an_usxgmii_auto('{CNT{1'b1}}),
            .an_intr(),
            .an_running(),
            .an_complete(),
            .an_timeout(),
            .an_usxgmii_mode(),
            .an_adv_ability_usxgmii('{CNT{16'h1601}}),
            .an_lp_adv_ability(),
            .an_lp_usxgmii_link(),
            .an_lp_usxgmii_speed(),
            .an_res_full_duplex(),

            /*
             * PTP clock
             */
            .ptp_clk(1'b0),
            .ptp_rst(1'b0),
            .ptp_sample_clk(1'b0),
            .ptp_td_sdi(1'b0),
            .tx_ptp_ts_in('{CNT{'0}}),
            .tx_ptp_ts_out(),
            .tx_ptp_ts_step_out(),
            .tx_ptp_locked(),
            .rx_ptp_ts_in('{CNT{'0}}),
            .rx_ptp_ts_out(),
            .rx_ptp_ts_step_out(),
            .rx_ptp_locked(),

            /*
             * Link-level Flow Control (LFC) (IEEE 802.3 annex 31B PAUSE)
             */
            .tx_lfc_req('{CNT{1'b0}}),
            .tx_lfc_resend('{CNT{1'b0}}),
            .rx_lfc_en('{CNT{1'b0}}),
            .rx_lfc_req(),
            .rx_lfc_ack('{CNT{1'b0}}),

            /*
             * Priority Flow Control (PFC) (IEEE 802.3 annex 31D PFC)
             */
            .tx_pfc_req('{CNT{'0}}),
            .tx_pfc_resend('{CNT{1'b0}}),
            .rx_pfc_en('{CNT{'0}}),
            .rx_pfc_req(),
            .rx_pfc_ack('{CNT{'0}}),

            /*
             * Pause interface
             */
            .tx_lfc_pause_en('{CNT{1'b0}}),
            .tx_pause_req('{CNT{1'b0}}),
            .tx_pause_ack(),

            /*
             * Statistics
             */
            .stat_clk(clk_125mhz),
            .stat_rst(rst_125mhz),
            .m_axis_stat(axis_eth_stat[n+1]),

            /*
             * Status
             */
            .tx_start_packet(),
            .stat_tx_byte(),
            .stat_tx_pkt_len(),
            .stat_tx_pkt_ucast(),
            .stat_tx_pkt_mcast(),
            .stat_tx_pkt_bcast(),
            .stat_tx_pkt_vlan(),
            .stat_tx_pkt_good(),
            .stat_tx_pkt_bad(),
            .stat_tx_pad_frame(),
            .stat_tx_err_oversize(),
            .stat_tx_err_user(),
            .stat_tx_err_underflow(),
            .rx_start_packet(),
            .rx_error_count(),
            .rx_block_lock(),
            .rx_high_ber(),
            .rx_status(qsfp_rx_status[n*CNT +: CNT]),
            .stat_rx_byte(),
            .stat_rx_pkt_len(),
            .stat_rx_pkt_fragment(),
            .stat_rx_pkt_jabber(),
            .stat_rx_pkt_ucast(),
            .stat_rx_pkt_mcast(),
            .stat_rx_pkt_bcast(),
            .stat_rx_pkt_vlan(),
            .stat_rx_pkt_good(),
            .stat_rx_pkt_bad(),
            .stat_rx_err_oversize(),
            .stat_rx_err_bad_fcs(),
            .stat_rx_err_bad_block(),
            .stat_rx_err_framing(),
            .stat_rx_err_preamble(),
            .stat_rx_fifo_drop('{CNT{1'b0}}),
            .stat_tx_mcf(),
            .stat_rx_mcf(),
            .stat_tx_lfc_pkt(),
            .stat_tx_lfc_xon(),
            .stat_tx_lfc_xoff(),
            .stat_tx_lfc_paused(),
            .stat_tx_pfc_pkt(),
            .stat_tx_pfc_xon(),
            .stat_tx_pfc_xoff(),
            .stat_tx_pfc_paused(),
            .stat_rx_lfc_pkt(),
            .stat_rx_lfc_xon(),
            .stat_rx_lfc_xoff(),
            .stat_rx_lfc_paused(),
            .stat_rx_pfc_pkt(),
            .stat_rx_pfc_xon(),
            .stat_rx_pfc_xoff(),
            .stat_rx_pfc_paused(),

            /*
             * Configuration
             */
            .cfg_tx_pad_en('{CNT{1'b1}}),
            .cfg_tx_min_pkt_len('{CNT{8'd60-1}}),
            .cfg_tx_max_pkt_len('{CNT{16'd9218-1}}),
            .cfg_tx_ifg('{CNT{8'd12}}),
            .cfg_tx_enable('{CNT{1'b1}}),
            .cfg_rx_max_pkt_len('{CNT{16'd9218-1}}),
            .cfg_rx_enable('{CNT{1'b1}}),
            .cfg_tx_prbs31_enable('{CNT{1'b0}}),
            .cfg_rx_prbs31_enable('{CNT{1'b0}}),
            .cfg_mcf_rx_eth_dst_mcast('{CNT{48'h01_80_C2_00_00_01}}),
            .cfg_mcf_rx_check_eth_dst_mcast('{CNT{1'b1}}),
            .cfg_mcf_rx_eth_dst_ucast('{CNT{48'd0}}),
            .cfg_mcf_rx_check_eth_dst_ucast('{CNT{1'b0}}),
            .cfg_mcf_rx_eth_src('{CNT{48'd0}}),
            .cfg_mcf_rx_check_eth_src('{CNT{1'b0}}),
            .cfg_mcf_rx_eth_type('{CNT{16'h8808}}),
            .cfg_mcf_rx_opcode_lfc('{CNT{16'h0001}}),
            .cfg_mcf_rx_check_opcode_lfc('{CNT{1'b1}}),
            .cfg_mcf_rx_opcode_pfc('{CNT{16'h0101}}),
            .cfg_mcf_rx_check_opcode_pfc('{CNT{1'b1}}),
            .cfg_mcf_rx_forward('{CNT{1'b0}}),
            .cfg_mcf_rx_enable('{CNT{1'b0}}),
            .cfg_tx_lfc_eth_dst('{CNT{48'h01_80_C2_00_00_01}}),
            .cfg_tx_lfc_eth_src('{CNT{48'h80_23_31_43_54_4C}}),
            .cfg_tx_lfc_eth_type('{CNT{16'h8808}}),
            .cfg_tx_lfc_opcode('{CNT{16'h0001}}),
            .cfg_tx_lfc_en('{CNT{1'b0}}),
            .cfg_tx_lfc_quanta('{CNT{16'hffff}}),
            .cfg_tx_lfc_refresh('{CNT{16'h7fff}}),
            .cfg_tx_pfc_eth_dst('{CNT{48'h01_80_C2_00_00_01}}),
            .cfg_tx_pfc_eth_src('{CNT{48'h80_23_31_43_54_4C}}),
            .cfg_tx_pfc_eth_type('{CNT{16'h8808}}),
            .cfg_tx_pfc_opcode('{CNT{16'h0101}}),
            .cfg_tx_pfc_en('{CNT{1'b0}}),
            .cfg_tx_pfc_quanta('{CNT{'{8{16'hffff}}}}),
            .cfg_tx_pfc_refresh('{CNT{'{8{16'h7fff}}}}),
            .cfg_rx_lfc_opcode('{CNT{16'h0001}}),
            .cfg_rx_lfc_en('{CNT{1'b0}}),
            .cfg_rx_pfc_opcode('{CNT{16'h0101}}),
            .cfg_rx_pfc_en('{CNT{1'b0}})
        );

    end

end

//for (genvar n = 0; n < $size(axis_qsfp_tx); n = n + 1) begin : qsfp_ch

//    wire ch_good_frame;

//    // stretch good frame pulses for RX activity LED (about 200 ms)
//    logic [25:0] act_cnt_reg = '0;
//    logic act_reg = 1'b0;

//    always_ff @(posedge qsfp_tx_clk[n]) begin
//        if (ch_good_frame) begin
//            act_cnt_reg <= '1;
//        end else if (act_cnt_reg != 0) begin
//            act_cnt_reg <= act_cnt_reg - 1;
//        end
//        act_reg <= ch_good_frame || act_cnt_reg != 0;
//    end

//    assign qsfp_rx_act[n] = act_reg;

//    taxi_axis_async_fifo #(
//        .DEPTH(16384),
//        .RAM_PIPELINE(2),
//        .FRAME_FIFO(1),
//        .USER_BAD_FRAME_VALUE(1'b1),
//        .USER_BAD_FRAME_MASK(1'b1),
//        .DROP_OVERSIZE_FRAME(1),
//        .DROP_BAD_FRAME(1),
//        .DROP_WHEN_FULL(1)
//    )
//    ch_fifo (
//        /*
//         * AXI4-Stream input (sink)
//         */
//        .s_clk(qsfp_rx_clk[n]),
//        .s_rst(qsfp_rx_rst[n]),
//        .s_axis(axis_qsfp_rx[n]),

//        /*
//         * AXI4-Stream output (source)
//         */
//        .m_clk(qsfp_tx_clk[n]),
//        .m_rst(qsfp_tx_rst[n]),
//        .m_axis(axis_qsfp_tx[n]),

//        /*
//         * Pause
//         */
//        .s_pause_req(1'b0),
//        .s_pause_ack(),
//        .m_pause_req(1'b0),
//        .m_pause_ack(),

//        /*
//         * Status
//         */
//        .s_status_depth(),
//        .s_status_depth_commit(),
//        .s_status_overflow(),
//        .s_status_bad_frame(),
//        .s_status_good_frame(),
//        .m_status_depth(),
//        .m_status_depth_commit(),
//        .m_status_overflow(),
//        .m_status_bad_frame(),
//        .m_status_good_frame(ch_good_frame)
//    );

//end


// =============================================================================
// REEMPLAZO DEL LOOPBACK FIFO: GENERACIÓN AUTÓNOMA DE TRACAS UDP A VELOCIDAD DE LÍNEA
// =============================================================================

for (genvar n = 0; n < $size(axis_qsfp_tx); n = n + 1) begin : qsfp_ch

    // Instancia del generador autónomo UDP/IP
    udp_packet_generator_top #(
        .MAC_DATA_W(MAC_DATA_W),        // Ajuste automático según 100G (512b) o 25G (64b)
        .DATA_W(MAC_DATA_W),
        .TX_RAM_SIZE(32768),
        // 100G: 8 flujos (puerto destino 5005-5012) para repartir la recepción
        // entre 8 colas / cores en el PC; 10G: un flujo por carril
        .FLOW_CNT(MAC_DATA_W == 512 ? 8 : 1)
    )
    udp_gen_inst (
        .clk(qsfp_tx_clk[n]),
        .rst(qsfp_tx_rst[n]),
        .mac_tx_clk(qsfp_tx_clk[n]),
        .mac_tx_rst(qsfp_tx_rst[n]),

        // Disparo permanente en '1' para saturación contínua a velocidad de línea (Line-Rate)
        .trigger_start(1'b1),
        .pkt_len_bytes(16'd8960),       // Tamaño del payload en bytes por paquete

        // Direcciones de red parametrizables por canal 'n'
        .src_mac(48'h80_23_31_43_54_4C + n),
        .dest_mac(48'hFF_FF_FF_FF_FF_FF), // Reemplazar con la MAC real de la NIC de tu PC
        .src_ip({8'(10 * (n + 1)), 8'd0, 8'd0, 8'd2}),
        .dest_ip({8'(10 * (n + 1)), 8'd0, 8'd0, 8'd1}),
        .src_port(16'd5005 + n),
        .dest_port(16'd5005),

        // Conexión AXI4-Stream directa a la entrada de la MAC QSFP28
        .m_axis_mac_tx(axis_qsfp_tx[n]),
        .s_axis_mac_tx_cpl(axis_qsfp_tx_cpl[n])
    );

    // Liberación del canal RX (sumidero directo para evitar desbordamiento)
    assign axis_qsfp_rx[n].tready = 1'b1;
    assign qsfp_rx_act[n] = 1'b0;

end

endmodule

`resetall
