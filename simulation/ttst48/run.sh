#!/bin/sh
# run.sh - run ttst48 contended tests on tb_ttst48 and score them
#
# usage: ./run.sh [test ...]     (default: 1 to 37)
#        C=0 ./run.sh [test ...]  the uncontended halves instead
#
# 35, 36 and 37 read the floating bus, so gen.py draws the screen the
# BASIC leaves for them. The uncontended half of 35 runs with whatever
# the earlier tests printed, which is not reproduced - leave it out of
# C=0 runs.
cd "$(dirname "$0")"
V=/c/altera/13.1/modelsim_ase/win32aloem
SRC=../../source
TESTS=${*:-$(seq 1 37)}
fail=0
for t in $TESTS; do
	exp=$(python gen.py $t ${C:-1})
	rm -rf work; $V/vlib work >/dev/null
	$V/vlog -work work -quiet +incdir+. +incdir+$SRC $SRC/T80/*.v \
		$SRC/clocks.v $SRC/video.v $SRC/ula_port.v tb_ttst48.v | grep -i error
	got=$($V/vsim -c -do "run 200ms; quit -f" work.tb_ttst48 2>&1 \
		| grep RESULT | sed 's/.*RESULT //')
	if [ "$got" = "$exp" ]; then v=PASS; else v=FAIL; fail=$((fail+1)); fi
	echo "test $t $v  got: $got  expected: $exp"
done
echo "$fail failed"
