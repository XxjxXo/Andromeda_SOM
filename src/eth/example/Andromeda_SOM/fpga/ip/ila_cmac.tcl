# SPDX-License-Identifier: MIT
#
# Debug ILA for the 100G CMAC status (one 64-bit probe, used twice:
# on the RX clock and on the TX clock)
#

create_ip -name ila -vendor xilinx.com -library ip -module_name ila_cmac

set_property -dict [list \
    CONFIG.C_NUM_OF_PROBES {1} \
    CONFIG.C_PROBE0_WIDTH {64} \
    CONFIG.C_DATA_DEPTH {4096} \
    CONFIG.C_INPUT_PIPE_STAGES {1} \
    CONFIG.C_EN_STRG_QUAL {1} \
    CONFIG.C_ADV_TRIGGER {false} \
    CONFIG.ALL_PROBE_SAME_MU_CNT {2} \
] [get_ips ila_cmac]
