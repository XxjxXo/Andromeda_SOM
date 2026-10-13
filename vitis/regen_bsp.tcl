# Regenerate the BSP sources and build the Andromeda_SOM platform after a clone
#
# Usage: xsct regen_bsp.tcl [xsa]
#
# If an XSA file is given, the hardware specification is updated first

set ws [file normalize [file dirname [info script]]]

setws $ws
platform read [file join $ws Andromeda_SOM platform.spr]
platform active Andromeda_SOM

if {$argc > 0} {
    platform config -updatehw [file normalize [lindex $argv 0]]
}

foreach d {zynqmp_fsbl zynqmp_pmufw standalone_domain} {
    domain active $d
    bsp regenerate
}

platform generate
