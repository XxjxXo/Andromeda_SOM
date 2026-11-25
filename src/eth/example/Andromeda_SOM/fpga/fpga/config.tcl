# SPDX-License-Identifier: MIT
#
# Copyright (c) 2025 FPGA Ninja, LLC
#
# Authors:
# - Alex Forencich
#

set params [dict create]

# MAC configuration
# 0: GTY with TX buffer (no TX buffer bypass / phase alignment)
dict set params CFG_LOW_LATENCY "0"
dict set params COMBINED_MAC_PCS "1"
dict set params MAC_DATA_W "512"

# apply parameters to top-level
set param_list {}
dict for {name value} $params {
    lappend param_list $name=$value
}

set_property generic $param_list [get_filesets sources_1]
