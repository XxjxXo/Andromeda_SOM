#!/bin/bash
# Build the 100G design (fpga, CMAC hard MAC) and the boot image
#
# Usage: ./build_100g.sh

exec "$(dirname "$(readlink -f "$0")")/build_10g.sh" fpga
