
# CMACs
# QSFP28 GTs (GTYE4_CHANNEL_X0Y8-X0Y11) are in clock region X0Y5, the closest
# CMAC is CMACE4_X0Y1 in clock region X0Y6
set_property LOC CMACE4_X0Y1 [get_cells -hierarchical -filter {NAME =~ core_inst/gt_quad[0].mac.* && REF_NAME==CMACE4}]
