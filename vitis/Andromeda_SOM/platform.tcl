# 
# Usage: To re-create this platform project launch xsct with below options.
# xsct /home/juanatco/TFM_Jorge/Taxi_mod/Taxi/taxi/vitis/Andromeda_SOM/platform.tcl
# 
# OR launch xsct and run below command.
# source /home/juanatco/TFM_Jorge/Taxi_mod/Taxi/taxi/vitis/Andromeda_SOM/platform.tcl
# 
# To create the platform in a different location, modify the -out option of "platform create" command.
# -out option specifies the output directory of the platform project.

platform create -name {Andromeda_SOM}\
-hw {/home/juanatco/TFM_Jorge/Taxi_mod/Taxi/taxi/src/eth/example/Andromeda_SOM/fpga/fpga_10g/fpga.xsa}\
-proc {psu_cortexa53_0} -os {standalone} -arch {64-bit} -fsbl-target {psu_cortexa53_0} -out {/home/juanatco/TFM_Jorge/Taxi_mod/Taxi/taxi/vitis}

platform write
platform generate -domains 
platform active {Andromeda_SOM}
platform config -updatehw {/home/juanatco/TFM_Jorge/Taxi_mod/Taxi/taxi/src/eth/example/Andromeda_SOM/fpga/fpga_10g/fpga.xsa}
domain active {zynqmp_fsbl}
bsp reload
bsp reload
bsp config extra_compiler_flags "-g -Wall -Wextra -fno-tree-loop-distribute-patterns"
bsp reload
bsp reload
domain active {standalone_domain}
bsp reload
platform generate
platform generate -domains zynqmp_fsbl 
platform config -updatehw {/home/juanatco/TFM_Jorge/Taxi_mod/Taxi/taxi/src/eth/example/Andromeda_SOM/fpga/fpga_10g/fpga.xsa}
platform generate -domains zynqmp_fsbl 
platform config -updatehw {/home/juanatco/TFM_Jorge/Taxi_mod/Taxi/taxi/src/eth/example/Andromeda_SOM/fpga/fpga_10g/fpga.xsa}
platform generate -domains 
platform clean
platform generate
domain active {zynqmp_fsbl}
bsp reload
catch {bsp regenerate}
domain active {standalone_domain}
bsp reload
catch {bsp regenerate}
domain active {zynqmp_pmufw}
bsp reload
catch {bsp regenerate}
platform generate -domains standalone_domain,zynqmp_fsbl,zynqmp_pmufw 
