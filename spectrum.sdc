create_clock -name CLOCK_50 -period 20.000 [get_ports {CLOCK_50}]
derive_pll_clocks

# --------------------------------------------------------------------
# Clocks the design makes in logic
# --------------------------------------------------------------------
#
# These are the reason builds behaved like a lottery. TimeQuest listed
# them as "was determined to be a clock but was found without an
# associated clock assignment", which means it did not analyse anything
# they clock - and `clock` is the 28MHz system clock that runs the CPU,
# the video and effectively the whole design. So almost nothing was
# being timed, the fitter placed it however it liked, and unrelated
# edits (down to which signal drove an LED) flipped the board between
# working and hanging while simulation stayed clean throughout.
#
# There were two more generated clocks here, clk28 and clk_psg, both
# hung off [get_pins {clock|q}] - a register that halved clk56. It has
# not existed since the system clock was taken from its own PLL output,
# so neither constraint has matched anything for a long time: ask
# TimeQuest for all_clocks and they do not appear. Dead text either way,
# and misleading about how the design is clocked, so they are gone.

derive_clock_uncertainty

# --------------------------------------------------------------------
# SDRAM interface
# --------------------------------------------------------------------
#
# Without these the whole external memory interface is unconstrained -
# TimeQuest reported "Design is not fully constrained" and simply did
# not analyse it, so the fitter was free to place those paths however it
# liked and every build got different timing. On the board that showed
# up as builds differing only in trivial ways (which signal drives an
# LED) either working or hanging, while simulation was always clean.
#
# SDRAM_CLK is the phase-shifted PLL output that actually clocks the
# chip, so the chip's setup/hold are relative to that, not to the
# internal clk56.
# The pin now carries whichever PLL is selected, so it needs a clock
# from each. They are declared exclusive above, so TimeQuest analyses
# the interface twice - once per machine speed - instead of inventing
# transfers between them.
create_generated_clock -name SDRAM_CLK_EXT \
	-source [get_pins {pll|altpll_component|auto_generated|pll1|clk[1]}] \
	[get_ports {SDRAM_CLK}]
create_generated_clock -name SDRAM_CLK_128 -add \
	-source [get_pins {pll128|altpll_component|auto_generated|pll1|clk[1]}] \
	[get_ports {SDRAM_CLK}]

# The two PLLs are alternatives, never both live: ep4spectrum.v gates one
# off before the other comes on. Without saying so, TimeQuest treats
# every register as reachable from both and times paths between two
# unrelated oscillators - launch on one PLL, latch on the other. That
# reported -17ns and meant nothing, because no such transfer happens.
#
# This has to sit here, below the two SDRAM clocks, and not up with the
# other clock declarations. SDC is read top to bottom, and named clocks
# that do not exist yet are not an error - the line is quietly dropped
# with "could not be matched with a clock" among a thousand info lines,
# leaving the constraint looking present and doing nothing.
set_clock_groups -exclusive \
	-group { pll|altpll_component|auto_generated|pll1|clk[0] \
	         pll|altpll_component|auto_generated|pll1|clk[1] \
	         pll|altpll_component|auto_generated|pll1|clk[2] \
	         SDRAM_CLK_EXT } \
	-group { pll128|altpll_component|auto_generated|pll1|clk[0] \
	         pll128|altpll_component|auto_generated|pll1|clk[1] \
	         pll128|altpll_component|auto_generated|pll1|clk[2] \
	         SDRAM_CLK_128 }

set sdram_out_ports [get_ports { \
	SDRAM_A[*] SDRAM_BA[*] SDRAM_DQ[*] \
	SDRAM_DQML SDRAM_DQMH \
	SDRAM_nWE SDRAM_nCAS SDRAM_nRAS SDRAM_nCS SDRAM_CKE }]

# FPGA -> chip. Numbers are the usual figures for a -7 grade 64Mbit
# part: ~1.5ns setup, ~0.8ns hold required at the chip's pins.
#
# chip -> FPGA, on the bidirectional data bus only: access time from
# clock (tAC) as max, output hold (tOH) as min.
#
# Both apply against both clocks - the chip's own requirements do not
# change with which PLL is driving it.
foreach sdclk { SDRAM_CLK_EXT SDRAM_CLK_128 } {
	set_output_delay -clock $sdclk -max  1.5 -add_delay $sdram_out_ports
	set_output_delay -clock $sdclk -min -0.8 -add_delay $sdram_out_ports
	set_input_delay  -clock $sdclk -max  6.0 -add_delay [get_ports {SDRAM_DQ[*]}]
	set_input_delay  -clock $sdclk -min  2.5 -add_delay [get_ports {SDRAM_DQ[*]}]
}

# The read data is not captured on the edge that launches it. The
# controller samples it a further clock later (see the dout_r comment in
# sdram_ep4ce.v), gated by its q phase counter - which TimeQuest cannot
# see, so by default it analyses this as a same-cycle transfer and
# reports a ~7ns setup violation that does not exist. Tell it the real
# relationship.
set_multicycle_path -setup -end 2 \
	-from [get_ports {SDRAM_DQ[*]}] \
	-to   [get_registers {sdram_ep4ce:sdr|dout_r[*]}]
set_multicycle_path -hold -end 1 \
	-from [get_ports {SDRAM_DQ[*]}] \
	-to   [get_registers {sdram_ep4ce:sdr|dout_r[*]}]

# Write data reaches SDRAM_DQ combinationally, from registers a long way
# back (the boot-copy ROM, or the CPU through the arbitration mux), so
# by a single-cycle measure it misses setup at the chip. In reality the
# mux selects a requester for a whole slot and the data sits there well
# before the WRITE command is issued later in the same q cycle.
set_multicycle_path -setup -start 2 -to [get_ports {SDRAM_DQ[*]}]
set_multicycle_path -hold  -start 1 -to [get_ports {SDRAM_DQ[*]}]

# The video controller reads the bus through the unregistered dout_raw
# and latches it on its own schedule, which is likewise not the edge
# that launched the data. Same correction as above.
set_multicycle_path -setup -end 2 \
	-from [get_ports {SDRAM_DQ[*]}] \
	-to   [get_registers {video:vid|*}]
set_multicycle_path -hold -end 1 \
	-from [get_ports {SDRAM_DQ[*]}] \
	-to   [get_registers {video:vid|*}]

# --------------------------------------------------------------------
# Asynchronous / non-timing-critical I/O
# --------------------------------------------------------------------
set_false_path -from [get_ports {RESET_BTN KEY[*] PS2_CLK PS2_DATA SD_MISO}]
set_false_path -to   [get_ports {LED[*] SEG[*] DIG[*] BEEP \
	VGA_R VGA_G VGA_B VGA_HS VGA_VS \
	SD_CS SD_SCK SD_MOSI}]
