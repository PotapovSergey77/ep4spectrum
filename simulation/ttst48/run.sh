#!/bin/sh
# run.sh - run ttst48 contended tests on tb_ttst48 and score them
#
# usage: ./run.sh [test ...]     (default: 1 to 35)
#
# Tests 36 and 37 are left out: they differ from 35 only in what the
# BASIC has scrolled onto the screen first, which this bench does not do.
cd "$(dirname "$0")"
V=/c/altera/13.1/modelsim_ase/win32aloem
SRC=../../source
TESTS=${*:-$(seq 1 35)}
fail=0
for t in $TESTS; do
	exp=$(python gen.py $t)
	rm -rf work; $V/vlib work >/dev/null
	$V/vlog -work work -quiet +incdir+. +incdir+$SRC $SRC/T80/*.v \
		$SRC/clocks.v $SRC/video.v $SRC/ula_port.v tb_ttst48.v | grep -i error
	got=$($V/vsim -c -do "run 200ms; quit -f" work.tb_ttst48 2>&1 \
		| grep RESULT | sed 's/.*RESULT //')
	if [ "$got" = "$exp" ]; then v=PASS; else v=FAIL; fail=$((fail+1)); fi
	echo "test $t $v  got: $got  expected: $exp"
done
echo "$fail failed"
