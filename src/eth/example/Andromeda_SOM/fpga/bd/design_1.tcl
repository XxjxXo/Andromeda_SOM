# SPDX-License-Identifier: MIT
#
# Block design with the Zynq UltraScale+ PS (provides pl_clk0 at 125 MHz)
#
# Created with Vivado 2024.1; output products are regenerated from design_1.bd
#

add_files -fileset sources_1 [file join [file dirname [info script]] design_1 design_1.bd]

generate_target all [get_files design_1.bd]
