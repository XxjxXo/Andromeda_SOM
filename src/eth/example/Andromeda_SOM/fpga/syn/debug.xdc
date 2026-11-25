# Debug hub on the free-running 125 MHz clock (PS PL_CLK0), so the VIO and
# ILAs stay reachable while the GT RX/TX clocks stop during resets
set_property C_CLK_INPUT_FREQ_HZ 125000000 [get_debug_cores dbg_hub]
set_property C_ENABLE_CLK_DIVIDER false [get_debug_cores dbg_hub]
set_property C_USER_SCAN_CHAIN 1 [get_debug_cores dbg_hub]
connect_debug_port dbg_hub/clk [get_nets -of_objects [get_pins clk_125mhz_bufg_inst/O]]
