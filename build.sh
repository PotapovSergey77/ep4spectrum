#!/bin/sh
# Build and program the board, refusing to program a build that did not
# close timing.
#
# The 112MHz SDRAM attempt was programmed with a setup slack of -1.85ns
# because the checks here only looked at the map/fit/asm exit codes.
# Quartus reports a timing failure as a critical warning and still exits
# 0, so the board got a build that could not work - it came up showing
# the no-ROM pattern. Timing now blocks programming the same way a
# compile error does.
#
#   ./build.sh          build, check timing, program
#   ./build.sh --no-pgm build and check only
set -e

export PATH=/c/altera/13.1/quartus/bin64:$PATH
cd "$(dirname "$0")"

quartus_map spectrum > /dev/null 2>&1 || { echo "ANALYSIS FAILED"; exit 1; }
quartus_fit spectrum > /dev/null 2>&1 || { echo "FIT FAILED";      exit 1; }
quartus_asm spectrum > /dev/null 2>&1 || { echo "ASSEMBLE FAILED"; exit 1; }

sta=$(quartus_sta spectrum 2>&1)
echo "$sta" | grep -E "Worst-case (setup|hold) slack" | sed 's/^ *//'

if echo "$sta" | grep -q "Timing requirements not met"; then
	echo "TIMING NOT MET - not programming."
	echo "$sta" | grep -A 12 "Report Timing.*setup" | head -20
	exit 2
fi

[ "$1" = "--no-pgm" ] && { echo "timing met, not programming"; exit 0; }

quartus_pgm -c USB-Blaster -m JTAG -o "p;output_files/spectrum.sof" 2>&1 |
	grep -E "successful|Error"
