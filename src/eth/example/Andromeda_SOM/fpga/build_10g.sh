#!/bin/bash
# Build the 10G design (bitstream and XSA) with Vivado, update the Vitis
# platform with the new XSA and rebuild it (BSPs, FSBL and PMUFW), then
# create the boot image in the Vitis workspace (vitis/BOOT.bin)
#
# Usage: ./build_10g.sh
#
# Set XILINX_VERSION or XILINX_DIR to use a different Xilinx installation

set -e

XILINX_DIR=${XILINX_DIR:-$HOME/Xilinx}
XILINX_VERSION=${XILINX_VERSION:-2024.1}

FPGA_DIR=$(dirname "$(readlink -f "$0")")
VITIS_DIR=$(readlink -f "$FPGA_DIR/../../../../../vitis")

if ! command -v vivado > /dev/null; then
    source "$XILINX_DIR/Vivado/$XILINX_VERSION/settings64.sh"
fi

if ! command -v xsct > /dev/null; then
    source "$XILINX_DIR/Vitis/$XILINX_VERSION/settings64.sh"
fi

make -C "$FPGA_DIR/fpga_10g"

xsct "$VITIS_DIR/regen_bsp.tcl" "$FPGA_DIR/fpga_10g/fpga.xsa"

cd "$VITIS_DIR"
bootgen -arch zynqmp -image Andromeda_SOM.bif -o BOOT.bin -w on

echo "Boot image: $VITIS_DIR/BOOT.bin"
