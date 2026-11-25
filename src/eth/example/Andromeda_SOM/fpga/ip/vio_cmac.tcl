# SPDX-License-Identifier: MIT
#
# Debug VIO for the 100G link: GT loopback and resets, TX driver EQ and
# PRBS, TX/RX clock frequency counters and CMAC status
#

create_ip -name vio -vendor xilinx.com -library ip -module_name vio_cmac

set_property -dict [list \
    CONFIG.C_NUM_PROBE_IN {5} \
    CONFIG.C_NUM_PROBE_OUT {8} \
    CONFIG.C_EN_PROBE_IN_ACTIVITY {1} \
    CONFIG.C_PROBE_IN0_WIDTH {32} \
    CONFIG.C_PROBE_IN1_WIDTH {32} \
    CONFIG.C_PROBE_IN2_WIDTH {16} \
    CONFIG.C_PROBE_IN3_WIDTH {2} \
    CONFIG.C_PROBE_IN4_WIDTH {1} \
    CONFIG.C_PROBE_OUT0_WIDTH {3} \
    CONFIG.C_PROBE_OUT0_INIT_VAL {0x0} \
    CONFIG.C_PROBE_OUT1_WIDTH {1} \
    CONFIG.C_PROBE_OUT1_INIT_VAL {0x0} \
    CONFIG.C_PROBE_OUT2_WIDTH {1} \
    CONFIG.C_PROBE_OUT2_INIT_VAL {0x0} \
    CONFIG.C_PROBE_OUT3_WIDTH {5} \
    CONFIG.C_PROBE_OUT3_INIT_VAL {0x10} \
    CONFIG.C_PROBE_OUT4_WIDTH {5} \
    CONFIG.C_PROBE_OUT4_INIT_VAL {0x0} \
    CONFIG.C_PROBE_OUT5_WIDTH {5} \
    CONFIG.C_PROBE_OUT5_INIT_VAL {0x0} \
    CONFIG.C_PROBE_OUT6_WIDTH {1} \
    CONFIG.C_PROBE_OUT6_INIT_VAL {0x0} \
    CONFIG.C_PROBE_OUT7_WIDTH {4} \
    CONFIG.C_PROBE_OUT7_INIT_VAL {0x0} \
] [get_ips vio_cmac]
