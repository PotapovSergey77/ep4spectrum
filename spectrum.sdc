create_clock -name CLOCK_50 -period 20.000 [get_ports {CLOCK_50}]
derive_pll_clocks
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
create_generated_clock -name SDRAM_CLK_EXT \
	-source [get_pins {pll|altpll_component|auto_generated|pll1|clk[1]}] \
	[get_ports {SDRAM_CLK}]

set sdram_out_ports [get_ports { \
	SDRAM_A[*] SDRAM_BA[*] SDRAM_DQ[*] \
	SDRAM_DQML SDRAM_DQMH \
	SDRAM_nWE SDRAM_nCAS SDRAM_nRAS SDRAM_nCS SDRAM_CKE }]

# FPGA -> chip. Numbers are the usual figures for a -7 grade 64Mbit
# part: ~1.5ns setup, ~0.8ns hold required at the chip's pins.
set_output_delay -clock SDRAM_CLK_EXT -max  1.5 $sdram_out_ports
set_output_delay -clock SDRAM_CLK_EXT -min -0.8 $sdram_out_ports

# chip -> FPGA, on the bidirectional data bus only: access time from
# clock (tAC) as max, output hold (tOH) as min.
set_input_delay -clock SDRAM_CLK_EXT -max 6.0 [get_ports {SDRAM_DQ[*]}]
set_input_delay -clock SDRAM_CLK_EXT -min 2.5 [get_ports {SDRAM_DQ[*]}]

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

# --------------------------------------------------------------------
# Asynchronous / non-timing-critical I/O
# --------------------------------------------------------------------
set_false_path -from [get_ports {RESET_BTN KEY[*] PS2_CLK PS2_DATA SD_MISO}]
set_false_path -to   [get_ports {LED[*] SEG[*] DIG[*] BEEP \
	VGA_R VGA_G VGA_B VGA_HS VGA_VS \
	SD_CS SD_SCK SD_MOSI}]
