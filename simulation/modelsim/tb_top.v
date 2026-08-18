// Copyright (c) 2026 Sergey Potapov (potapov.sergey.77@gmail.com)
//
// tb_top.v
//
// Whole-design testbench: the real spectrum_top against a behavioral
// SDRAM chip and SD card. Every previous testbench replaced memory with
// an instant behavioral array, which is exactly why they all looked
// healthy while the board did not - they could not show video and CPU
// competing for one SDRAM, and hardware experiment (disabling video's
// SDRAM reads made the same build boot) points straight at that.
//
// Here the video controller, the CPU, the boot copy and sdram_ep4ce.v
// all fight over the same modelled chip, at the real clock ratios.

`timescale 1ns/1ps

module tb_top;

	reg CLOCK_50 = 0;
	always #10 CLOCK_50 = ~CLOCK_50;    // 50MHz

	reg RESET_BTN = 1'b1;               // active low, released
	reg [3:0] KEY = 4'b1111;            // active low, none pressed

	wire [3:0] LED;
	wire [7:0] SEG;
	wire [3:0] DIG;
	wire VGA_R, VGA_G, VGA_B, VGA_HS, VGA_VS;

	wire [11:0] SDRAM_A;
	wire [15:0] SDRAM_DQ;
	wire SDRAM_DQML, SDRAM_DQMH;
	wire SDRAM_nWE, SDRAM_nCAS, SDRAM_nRAS, SDRAM_nCS;
	wire [1:0] SDRAM_BA;
	wire SDRAM_CLK, SDRAM_CKE;

	wire BEEP;
	wire SD_CS, SD_SCK, SD_MOSI;
	wire SD_MISO;

	// PS/2 idle (both lines released high - no key traffic)
	wire PS2_CLK  = 1'b1;
	wire PS2_DATA = 1'b1;

	spectrum_top dut (
		.CLOCK_50(CLOCK_50),
		.RESET_BTN(RESET_BTN),
		.KEY(KEY),
		.LED(LED),
		.SEG(SEG),
		.DIG(DIG),
		.VGA_R(VGA_R), .VGA_G(VGA_G), .VGA_B(VGA_B),
		.VGA_HS(VGA_HS), .VGA_VS(VGA_VS),
		.SDRAM_A(SDRAM_A),
		.SDRAM_DQ(SDRAM_DQ),
		.SDRAM_DQML(SDRAM_DQML),
		.SDRAM_DQMH(SDRAM_DQMH),
		.SDRAM_nWE(SDRAM_nWE),
		.SDRAM_nCAS(SDRAM_nCAS),
		.SDRAM_nRAS(SDRAM_nRAS),
		.SDRAM_nCS(SDRAM_nCS),
		.SDRAM_BA(SDRAM_BA),
		.SDRAM_CLK(SDRAM_CLK),
		.SDRAM_CKE(SDRAM_CKE),
		.PS2_CLK(PS2_CLK),
		.PS2_DATA(PS2_DATA),
		.BEEP(BEEP),
		.SD_CS(SD_CS),
		.SD_SCK(SD_SCK),
		.SD_MOSI(SD_MOSI),
		.SD_MISO(SD_MISO)
	);

	// The chip is clocked by SDRAM_CLK, the phase-shifted PLL output the
	// real part sees - not by the internal clk56.
	sdram_model chip (
		.sd_data(SDRAM_DQ),
		.sd_addr(SDRAM_A),
		.sd_dqm({SDRAM_DQMH, SDRAM_DQML}),
		.sd_ba(SDRAM_BA),
		.sd_cs(SDRAM_nCS),
		.sd_we(SDRAM_nWE),
		.sd_ras(SDRAM_nRAS),
		.sd_cas(SDRAM_nCAS),
		.clk(SDRAM_CLK)
	);

	sd_model sdcard (
		.clk_sys(CLOCK_50),
		.sd_cs(SD_CS),
		.sd_sck(SD_SCK),
		.sd_mosi(SD_MOSI),
		.sd_miso(SD_MISO)
	);

	// Give the CPU's register file defined contents at time zero.
	//
	// T80's registers start x in simulation, and the 48K ROM only sets
	// IY (to 0x5C3A) part way through startup - so a routine that does
	// PUSH IY before that puts x on the stack, a later POP HL pulls it
	// into HL, and from there undefined data spreads through everything
	// the program touches. On real silicon the flops power up to some
	// defined value, PUSH/POP saves and restores whatever it is, and no
	// program cares. Left as x it manufactures failures that look
	// exactly like a hardware fault, including a speed-dependent one -
	// which is precisely the trap this investigation fell into.
	integer rg;
	initial begin
		for (rg = 0; rg < 8; rg = rg + 1) begin
			dut.cpu.u0.Regs.RegsH[rg] = 8'h00;
			dut.cpu.u0.Regs.RegsL[rg] = 8'h00;
		end
	end

	// clock-liveness probe
	integer n56 = 0, n28 = 0;
	always @(posedge dut.clk56) n56 = n56 + 1;
	always @(posedge dut.clock) n28 = n28 + 1;
	initial begin
		#10_000;
		$display("[10us] clk56 edges=%0d  clock edges=%0d  pll_locked=%b",
			n56, n28, dut.pll_locked);
	end

	// ------------------------------------------------------------
	// Turbo speed override for investigation: +SPEED=0..3 forces
	// cpu_speed directly (0=3.5MHz .. 3=28MHz) from time zero, bypassing
	// the F1-F4/PS2 path entirely (there is no keyboard traffic in this
	// testbench to drive it otherwise). Omit the plusarg to keep the
	// power-up default of 3.5MHz.
	// ------------------------------------------------------------
	reg [31:0] forced_speed;
	initial begin
		if ($value$plusargs("SPEED=%d", forced_speed)) begin
			force dut.cpu_speed = forced_speed[1:0];
			$display("[%0t] cpu_speed forced to %0d", $time, forced_speed[1:0]);
		end
	end

	// +CONT=0..2 forces the contention mode F10 cycles through on the
	// board: 0 = none, 1 = memory only, 2 = full (memory and IO). The
	// power-up default is 2. There is no keyboard traffic here to press
	// F10 with, and the board reports the measured INT length changing
	// with this setting, so it has to be selectable from the command
	// line to compare runs.
	reg [31:0] forced_cont;
	initial begin
		if ($value$plusargs("CONT=%d", forced_cont)) begin
			force dut.cont_mode = forced_cont[1:0];
			$display("[%0t] cont_mode forced to %0d (0=none 1=mem 2=full)",
				$time, forced_cont[1:0]);
		end
	end

	// +CONTADJ=<n> forces the contention window's position, the same
	// value KEY3/KEY4 step on the board. Five bits signed, one CPU
	// T-state a step, so 31 is one T-state early rather than 31 late.
	// Needed here because the measured delay table comes out shifted by
	// exactly one T-state from the published 6,5,4,3,2,1,0,0, and this
	// is the knob that would move it - but which direction fixes it has
	// to be measured, not reasoned about.
	integer ob_ts = 0, ob_prev = 0, ob_shown = 0;
	// T-state of the last real nIRQ edge, so port accesses can be
	// reported as "T-states after the interrupt" - the frame of
	// reference the published figures use (first contended T-state
	// at 14335). Every phase measurement so far has been relative to
	// the display fetch instead, which cannot show the two being
	// offset from each other.
	integer irq_mark = -1;
	reg     irqm_d = 1'b1;
	always @(posedge dut.clock) begin
		irqm_d <= dut.vid_irq_n;
		if (dut.reset_n === 1'b1 && irqm_d && !dut.vid_irq_n)
			irq_mark <= ob_ts;
	end
	// +FORCEINT=<us> pulses nIRQ directly at the given time, instead
	// of waiting ~16ms of model time for the frame to bring one round.
	// The measurement wanted here is the DELAY from the interrupt edge
	// to the first OUT, which does not care where in the frame the
	// edge falls - so the wait was pure cost, about an hour a run.
	reg [31:0] forceint_us;
	integer    fi_mark = -1;
	initial begin
		if ($value$plusargs("FORCEINT=%d", forceint_us)) begin
			#(forceint_us * 1000);
			fi_mark = ob_ts;
			$display("[%0t] FORCED INT: nIRQ low, ob_ts=%0d h=%0d line=%0d",
				$time, ob_ts, dut.vid.hcounter, dut.vid.vcounter[9:1]);
			force dut.vid.nIRQ = 1'b0;
			#9143;
			release dut.vid.nIRQ;
		end
	end

	reg [31:0] forced_cadj;
	initial begin
		if ($value$plusargs("CONTADJ=%d", forced_cadj)) begin
			force dut.cont_adj = forced_cadj[4:0];
			$display("[%0t] cont_adj forced to %0d", $time, forced_cadj[4:0]);
		end
	end

	// How long the run lasts before the final summary prints and
	// $finish fires. +RUNLEN=<us> overrides the default 1.5ms. It must
	// still be <= the outer `run <N>us` given to vsim, or the run stops
	// first and the summary, along with the trace file close, never
	// happens at all.
	//
	// Read on demand rather than in an initial block of its own. Four
	// separate blocks delay off this value, all at time zero, and a
	// plain `initial` assignment races them: whichever block Verilog
	// happens to elaborate first wins, so +RUNLEN sometimes took effect
	// and sometimes did not. That silently truncated long runs - an
	// 11ms run stopping at 1.5ms and quietly reporting as if it had
	// finished - which is exactly the kind of instrument fault that has
	// already cost this investigation twice. A function has no such
	// race: every caller evaluates it for itself.
	function [31:0] run_len_us;
		input dummy;
		reg [31:0] v;
		begin
			if (!$value$plusargs("RUNLEN=%d", v)) v = 32'd1500;
			run_len_us = v;
		end
	endfunction

	// ------------------------------------------------------------
	// Live turbo transition: +LIVESPEED=1..3 lets the machine boot and
	// run normally at 3.5MHz, then - once the CPU has been running for
	// a while - drives cpu_speed_req the way an F2/F3/F4 keypress
	// actually would, through the real "landing" logic in
	// spectrum_top.v (only takes effect on a slot boundary with no
	// memory/IO cycle open and WAIT released). +SPEED forces cpu_speed
	// directly and so never exercises that landing logic at all - this
	// is the board's actual reported symptom: engage 14/28MHz and even
	// F1/F2 cannot get the machine back, which only makes sense if the
	// safe point to change speed stops arriving.
	// ------------------------------------------------------------
	reg [31:0] live_speed;
	reg        live_transition_requested = 1'b0;
	initial begin
		if ($value$plusargs("LIVESPEED=%d", live_speed)) begin
			wait (dut.reset_n === 1'b1);
			repeat (4000) @(posedge dut.clock);
			$display("[%0t] driving cpu_speed_req -> %0d (simulated F-key press)",
				$time, live_speed[1:0]);
			force dut.cpu_speed_req = live_speed[1:0];
			live_transition_requested = 1'b1;
		end
	end

	integer landed_at = -1;
	always @(posedge dut.clock) begin
		if (live_transition_requested && landed_at == -1
		    && dut.cpu_speed === live_speed[1:0]) begin
			landed_at = $time;
			$display("[%0t] cpu_speed landed on %0d", $time, live_speed[1:0]);
		end
	end

	// Watchdog: longest continuous run of WAIT held. Healthy operation
	// clears within a couple of slot boundaries every time; the board's
	// symptom - stuck permanently, F-keys unable to recover - would show
	// up here as a streak that never ends.
	integer wait_streak = 0, max_wait_streak = 0;
	always @(posedge dut.clock) begin
		if (dut.cpu_wait_n == 1'b0) begin
			wait_streak <= wait_streak + 1;
			if (wait_streak + 1 > max_wait_streak) max_wait_streak <= wait_streak + 1;
		end else
			wait_streak <= 0;
	end

	// Confirms whether an interrupt actually happened during the run,
	// so a clean result can't be mistaken for "never reached one".
	// Also measures the frame period between interrupts: for a 48K that
	// must be 69888 T-states = 19.968ms, and every raster effect in
	// every program is placed relative to it.
	integer int_count = 0;
	reg cpu_irq_n_d = 1'b1;
	time    last_irq_time = 0;
	always @(posedge dut.clock) begin
		cpu_irq_n_d <= dut.cpu_irq_n;
		if (cpu_irq_n_d == 1'b1 && dut.cpu_irq_n == 1'b0) begin
			int_count <= int_count + 1;
			if (last_irq_time != 0 && int_count < 6)
				$display("[%0t] FRAME period %0d ns (48K wants 19968000)",
					$time, $time - last_irq_time);
			last_irq_time <= $time;
		end
	end

	// --- DivMMC automapper entry, driven by an NMI ---
	//
	// The board fails at 28MHz in exactly the two places that ENTER the
	// DivMMC ROM through the automapper - cold init, and NMI - while
	// work already inside ESXDOS (loading a file) is fine. So the
	// suspect is the trigger, not the card.
	//
	// The trigger is `!mreq_n && !rd_n && !m1_n` with the address on one
	// of six values, and that condition is true for exactly as long as
	// the M1 cycle's T2 - which is eight master clocks at 3.5MHz, four
	// at 7, two at 14 and ONE at 28. The failure appears at the speed
	// where the window is a single clock.
	//
	// +NMITEST pulses NMI and reports whether the automapper actually
	// paged in and where the CPU fetched afterwards.
	reg do_nmitest = 1'b0;
	initial do_nmitest = $test$plusargs("NMITEST");
	integer nmi_at = 0;
	reg paged_seen = 1'b0;
	reg trig_seen = 1'b0;
	initial begin
		if ($test$plusargs("NMITEST")) begin
			wait (dut.reset_n === 1'b1);
			repeat (8000) @(posedge dut.clock);
			$display("[%0t] NMITEST: asserting NMI (paged_in=%b)",
				$time, dut.divmmc_paged_in);
			force dut.cpu_nmi_n = 1'b0;
			nmi_at = $time;
			repeat (2000) @(posedge dut.clock);
			release dut.cpu_nmi_n;
		end
	end
	// Did the fetch at 0x0066 even present the trigger condition, and did
	// paged_in follow? Reported separately so a failure says which half
	// broke - the CPU never taking the NMI, or the automapper missing it.
	always @(posedge dut.clock) begin
		if (do_nmitest && nmi_at != 0) begin
			if (!dut.cpu_mreq_n && !dut.cpu_rd_n && !dut.cpu_m1_n
			    && dut.cpu_a == 16'h0066 && !trig_seen) begin
				trig_seen <= 1'b1;
				$display("[%0t] NMITEST: M1 fetch at 0x0066 seen (the trigger condition)", $time);
			end
			if (dut.divmmc_paged_in && !paged_seen) begin
				paged_seen <= 1'b1;
				$display("[%0t] NMITEST: automapper paged in", $time);
			end
		end
	end
	initial begin
		#(run_len_us(0) * 1000 - 20_000);
		if (do_nmitest)
			$display("NMITEST RESULT: trigger fetch seen=%b, paged in=%b",
				trig_seen, paged_seen);
	end

	// --- Automapper transitions, counted in both directions ---
	//
	// The board's DivMMC failures at 28MHz are all in code that crosses
	// the automapper boundary: cold init, NMI, TAP and TRD loading. What
	// runs entirely inside ESXDOS - directory navigation, loading a .z80
	// - is fine. And the first NMI after init works while the next one
	// hangs, which points at the way OUT (the 0x1FF8-0x1FFF trigger)
	// being missed and leaving the DivMMC bank mapped over the 48K ROM.
	//
	// Both triggers are only live while the M1 cycle's T2 is on the bus:
	// eight master clocks at 3.5MHz, four at 7, two at 14 and ONE at 28.
	// If the counts here diverge with speed, that single sampling
	// opportunity is the fault.
	integer page_in_n = 0, page_out_n = 0;
	reg paged_d = 1'b0;
	always @(posedge dut.clock) begin
		paged_d <= dut.divmmc_paged_in;
		if (dut.reset_n === 1'b1) begin
			if (dut.divmmc_paged_in && !paged_d) page_in_n  = page_in_n + 1;
			if (!dut.divmmc_paged_in && paged_d) page_out_n = page_out_n + 1;
		end
	end
	initial begin
		#(run_len_us(0) * 1000 - 15_000);
		$display("AUTOMAPPER: %0d page-ins, %0d page-outs", page_in_n, page_out_n);
	end

	// --- Where is the stock ROM actually spending its time? ---
	//
	// Every DivMMC investigation so far has been done on purpose-built
	// test ROMs, because the real ESXDOS image never touches the SPI
	// port in simulation - `DivMMC SPI: 0 port accesses`, checked out to
	// 24.5ms. That blind spot has now sent two plausible hypotheses all
	// the way to the board before they were disproven, so it is worth
	// more than another guess to find out what the ROM is waiting for.
	//
	// +PCTRACE samples the opcode-fetch address at a fixed interval, so
	// a long run prints a picture of where execution actually sits
	// rather than only whether it finished.
	reg do_pctrace = 1'b0;
	initial do_pctrace = $test$plusargs("PCTRACE");
	integer pc_div = 0;
	integer pc_shown = 0;
	reg [15:0] last_m1_addr = 16'hFFFF;
	always @(posedge dut.clock) begin
		if (dut.reset_n === 1'b1) begin
			// The opcode fetch itself, which is MREQ and RD and M1 all
			// low together - not the falling edge of M1, where MREQ has
			// not arrived yet and this captured nothing at all.
			if (!dut.cpu_m1_n && !dut.cpu_mreq_n && !dut.cpu_rd_n)
				last_m1_addr <= dut.cpu_a;
			if (do_pctrace) begin
				pc_div <= pc_div + 1;
				if (pc_div >= 200) begin
					pc_div <= 0;
					if (pc_shown < 400) begin
						pc_shown <= pc_shown + 1;
						$display("[%0t] PC~%04h halt_n=%b paged_in=%b cs=%b ctrl=%02h spi_cnt=%0d",
							$time, last_m1_addr, dut.cpu_halt_n, dut.divmmc_paged_in,
							dut.divmmc_cs, dut.dmmc.ctrl,
							dut.dmmc.mi_spi.counter);
					end
				end
			end
		end
	end

	// --- The last opcodes actually fetched ---
	//
	// ESXDOS relocates itself into RAM early, so when it sits in a loop
	// there is nothing in the ROM image to disassemble - the code only
	// exists in the modelled chip. Recording address and opcode byte as
	// they are fetched shows the loop directly. Ring of the last 24
	// fetches, printed at the end of the run.
	reg [15:0] op_a [0:23];
	reg [7:0]  op_d [0:23];
	integer    op_w = 0;
	reg        m1_seen = 1'b0;
	always @(posedge dut.clock) begin
		if (dut.reset_n === 1'b1) begin
			if (!dut.cpu_m1_n && !dut.cpu_mreq_n && !dut.cpu_rd_n) begin
				if (!m1_seen) begin
					op_a[op_w % 24] = dut.cpu_a;
					op_d[op_w % 24] = dut.cpu_di;
					op_w = op_w + 1;
				end
				m1_seen <= 1'b1;
			end else
				m1_seen <= 1'b0;
		end
	end
	initial begin
		#(run_len_us(0) * 1000 - 5_000);
		begin : dump_ops
			integer k, idx;
			$write("LAST OPCODES:");
			for (k = 0; k < 24; k = k + 1) begin
				idx = (op_w + k) % 24;
				$write(" %04h:%02h", op_a[idx], op_d[idx]);
			end
			$display("");
		end
	end

	// --- Full fetch log, for diffing one speed against another ---
	//
	// The ring below shows the run-up to a crash but cannot answer "at
	// which instruction do 14MHz and 28MHz stop agreeing", because the
	// two runs reach any given point at different times. Writing every
	// fetch to a file instead makes that a plain diff: the boot is
	// deterministic, so the two logs share a prefix and the first line
	// that differs is the divergence.
	//
	// +FETCHLOG=<name> turns it on. Off by default - it is large.
	integer fl = 0;
	reg [255:0] flname;
	reg flm1_d = 1'b0;
	initial begin
		if ($value$plusargs("FETCHLOG=%s", flname))
			fl = $fopen(flname, "w");
	end
	always @(posedge dut.clock) begin
		if (fl != 0 && dut.reset_n === 1'b1) begin
			if (!dut.cpu_m1_n && !dut.cpu_mreq_n && !dut.cpu_rd_n) begin
				if (!flm1_d)
					$fwrite(fl, "%04h %b\n", dut.cpu_a, dut.divmmc_paged_in);
				flm1_d <= 1'b1;
			end else
				flm1_d <= 1'b0;
		end
	end
	initial begin
		#(run_len_us(0) * 1000 - 2_500);
		if (fl != 0) $fclose(fl);
	end

	// --- Every fetch leading into the crash ---
	//
	// The periodic PC trace narrowed the 28MHz failure to a bad control
	// transfer around 0x15fe -> 0x3e09, but sampling every 200 clocks
	// leaves several instructions unseen between the two. This records
	// EVERY opcode fetch, and freezes the moment the PC first lands in
	// the runaway region, so what is left is the run-up rather than
	// thousands of addresses of the sled that follows.
	reg [15:0] tr_a [0:255];
	integer    tr_w = 0;
	reg        tr_frozen = 1'b0;
	reg        tr_m1_d = 1'b0;
	always @(posedge dut.clock) begin
		if (dut.reset_n === 1'b1 && !tr_frozen) begin
			if (!dut.cpu_m1_n && !dut.cpu_mreq_n && !dut.cpu_rd_n) begin
				if (!tr_m1_d) begin
					tr_a[tr_w % 256] = {dut.divmmc_paged_in, dut.cpu_a[14:0]};
					tr_w = tr_w + 1;
					// Anything at or above this is already the runaway:
					// the healthy boot never fetches there.
					if (dut.cpu_a >= 16'h3E00 && dut.cpu_a < 16'h4100)
						tr_frozen <= 1'b1;
				end
				tr_m1_d <= 1'b1;
			end else
				tr_m1_d <= 1'b0;
		end
	end
	initial begin
		#(run_len_us(0) * 1000 - 3_000);
		begin : dump_trail
			integer k, idx, first;
			$display("FETCH TRAIL (frozen=%b, %0d fetches total):", tr_frozen, tr_w);
			first = (tr_w > 256) ? (tr_w - 256) : 0;
			$write("   ");
			for (k = first; k < tr_w; k = k + 1) begin
				idx = k % 256;
				$write(" %s%04h", tr_a[idx][15] ? "D" : ".", {1'b0, tr_a[idx][14:0]});
			end
			$display("");
		end
	end

	// --- The arbiter's overdue backstop, and what it costs ---
	//
	// spectrum_top.v credits a CPU cycle as served only when the address
	// the cycle actually fetched still matches what the CPU is asking
	// for - Sizif's cpu_read_misaddress guard - EXCEPT when cpu_overdue
	// is set, which accepts the answer whatever the address says. That
	// exception exists so a request cannot wait for ever, but it hands
	// the CPU a byte read from somewhere else.
	//
	// The 28MHz crash is a RET at 0x1600 taking a corrupted address off
	// the stack, i.e. a read that returned the wrong data. So: how often
	// does the backstop actually fire, and does it fire on a mismatch?
	// Counted separately, because firing while the address happens to
	// match is harmless and firing on a mismatch is the fault.
	integer overdue_fired = 0;
	integer overdue_wrong = 0;
	reg     ovd_d = 1'b0;
	always @(posedge dut.clock) begin
		if (dut.reset_n === 1'b1) begin
			ovd_d <= dut.cpu_overdue;
			if (dut.slot_tick_d2 && dut.prev_own == dut.OWN_CPU
			    && dut.cpu_overdue) begin
				overdue_fired = overdue_fired + 1;
				if (dut.cpu_addr_held !== dut.cpu_addr)
					overdue_wrong = overdue_wrong + 1;
			end
		end
	end
	initial begin
		#(run_len_us(0) * 1000 - 4_000);
		$display("ARBITER OVERDUE: fired %0d times, %0d of them on a MISMATCHED address",
			overdue_fired, overdue_wrong);
	end

	// --- Does the CPU get the byte memory actually holds? ---
	//
	// The 28MHz crash is a RET at 0x1600 jumping to 0x3DFD, so the two
	// bytes it took off the stack were wrong. Two possibilities, and
	// they need different fixes: the memory system handed the CPU the
	// wrong byte, or memory genuinely held those bytes because an
	// earlier write went astray. This settles which.
	//
	// Sampled where T80se itself latches the bus - `TState == 2 &&
	// WAIT_n == 1` - so it compares exactly the byte the CPU takes,
	// not whatever is on the bus at some other moment. Reads of RAM
	// only, where the physical address is known the same way the write
	// checker builds it.
	integer rd_checked = 0, rd_wrong = 0;
	always @(posedge dut.clock) begin
		if (dut.reset_n === 1'b1 && dut.cpu_clken_gated
		    && dut.cpu.u0.TState == 3'd2 && dut.cpu_wait_all_n
		    && !dut.cpu_mreq_n && !dut.cpu_rd_n && dut.ram_enable) begin
			rd_checked = rd_checked + 1;
			if (dut.cpu_di !== peek({3'b000, dut.ram_page, dut.cpu_a[13:0]})) begin
				rd_wrong = rd_wrong + 1;
				if (rd_wrong <= 8)
					$display("[%0t] BAD READ a=%04h got=%02h memory holds=%02h",
						$time, dut.cpu_a, dut.cpu_di,
						peek({3'b000, dut.ram_page, dut.cpu_a[13:0]}));
			end
		end
	end
	initial begin
		#(run_len_us(0) * 1000 - 4_500);
		$display("CPU RAM READS: %0d checked, %0d returned the wrong byte",
			rd_checked, rd_wrong);
	end

	// --- Every memory operation leading into the crash ---
	//
	// The RET at 0x1600 takes a corrupted address off the stack, and the
	// earlier read check missed the stack entirely (it was gated on
	// ram_enable). This records reads AND writes with no region filter
	// at all, so the PUSH at 0x15F3 and the POP/RET that follow are all
	// visible, and freezes on the same runaway trigger.
	//
	// Reads are sampled where T80se latches the bus (TState==2 with WAIT
	// released) because that is the only moment the byte is the one the
	// CPU actually takes; writes are recorded on the leading edge of the
	// cycle, where cpu_do is already driven. Getting that distinction
	// wrong is what made an earlier opcode ring report 0x77 for a byte
	// that was really 0x76.
	reg [15:0] mo_a [0:511];
	reg [7:0]  mo_d [0:511];
	reg        mo_wr [0:511];
	integer    mo_i = 0;
	reg        mo_frozen = 1'b0;
	reg        mo_wcyc_d = 1'b0;
	always @(posedge dut.clock) begin
		if (dut.reset_n === 1'b1 && !mo_frozen) begin
			// a read, at the instant it is taken. IO reads count too:
			// capturing only mreq cycles left IN instructions
			// invisible, and no captured memory read ever returned x
			// even though the CPU was plainly pushing x - so whatever
			// poisons HL had to be coming through a path this ring was
			// not watching.
			if (dut.cpu_clken_gated && dut.cpu.u0.TState == 3'd2
			    && dut.cpu_wait_all_n && dut.cpu_rd_n == 1'b0
			    && (dut.cpu_mreq_n == 1'b0 || dut.cpu_ioreq_n == 1'b0)) begin
				mo_a[mo_i % 512]  = dut.cpu_a;
				mo_d[mo_i % 512]  = dut.cpu_di;
				mo_wr[mo_i % 512] = 1'b0;
				mo_i = mo_i + 1;
			end
			// a write, once per cycle
			if (!dut.cpu_mreq_n && !dut.cpu_wr_n) begin
				if (!mo_wcyc_d) begin
					mo_a[mo_i % 512]  = dut.cpu_a;
					mo_d[mo_i % 512]  = dut.cpu_do;
					mo_wr[mo_i % 512] = 1'b1;
					mo_i = mo_i + 1;
				end
				mo_wcyc_d <= 1'b1;
			end else
				mo_wcyc_d <= 1'b0;

			if (!dut.cpu_m1_n && !dut.cpu_mreq_n && !dut.cpu_rd_n
			    && dut.cpu_a >= 16'h3E00 && dut.cpu_a < 16'h4100)
				mo_frozen <= 1'b1;
		end
	end
	initial begin
		#(run_len_us(0) * 1000 - 3_500);
		begin : dump_mo
			integer k, idx, first;
			$display("MEMORY OPS into the crash (frozen=%b):", mo_frozen);
			first = (mo_i > 512) ? (mo_i - 512) : 0;
			$write("   ");
			for (k = first; k < mo_i; k = k + 1) begin
				idx = k % 512;
				$write(" %s%04h=%02h", mo_wr[idx] ? "W" : "r", mo_a[idx], mo_d[idx]);
			end
			$display("");
		end
	end

	// --- INT to the first paper pixel ---
	//
	// The published figure for a 48K is 14336 T-states from the
	// interrupt to the first pixel of the display area, and Test Int
	// checks it indirectly through where border effects land. The frame
	// length and the 32-T-state INT width have both been measured
	// directly; this one had only ever been derived from the geometry,
	// and arithmetic has been wrong here before.
	//
	// Counted in ungated cpu_clken pulses - wall-clock T-states, not
	// what the CPU manages to execute - because that is what the figure
	// means.
	integer i2p_cnt = 0;
	integer i2p_shown = 0;
	reg     i2p_armed = 1'b0;
	reg     irq_d2 = 1'b1;
	reg     pic_d = 1'b0;
	always @(posedge dut.clock) begin
		irq_d2 <= dut.vid_irq_n;
		pic_d  <= dut.vid.picture;
		if (dut.reset_n === 1'b1) begin
			if (irq_d2 == 1'b1 && dut.vid_irq_n == 1'b0) begin
				i2p_armed <= 1'b1;
				i2p_cnt   <= 0;
			end else if (i2p_armed && dut.cpu_clken)
				i2p_cnt <= i2p_cnt + 1;
			// first time the display area opens after that interrupt
			if (i2p_armed && dut.vid.picture && !pic_d) begin
				i2p_armed <= 1'b0;
				if (i2p_shown < 4) begin
					i2p_shown <= i2p_shown + 1;
					$display("[%0t] INT -> first paper pixel: %0d T-states (video's own edge)",
						$time, i2p_cnt);
				end
			end
		end
	end

	// The same span measured from the edge the CPU actually sees.
	//
	// cpu_irq_n_sync resamples vid_irq_n on the CPU's enable and holds
	// it a whole T-state before T80 can sample it, so the two figures
	// differ by one and it is this one that decides where a program's
	// border writes land. 14336 is the number to hold here; the video's
	// own edge is then a T-state earlier at 14337.
	integer c2p_cnt = 0;
	integer c2p_shown = 0;
	reg     c2p_armed = 1'b0;
	reg     cirq_d = 1'b1;
	reg     cpic_d = 1'b0;
	always @(posedge dut.clock) begin
		cirq_d <= dut.cpu_irq_n;
		cpic_d <= dut.vid.picture;
		if (dut.reset_n === 1'b1) begin
			if (cirq_d == 1'b1 && dut.cpu_irq_n == 1'b0) begin
				c2p_armed <= 1'b1;
				c2p_cnt   <= 0;
			end else if (c2p_armed && dut.cpu_clken)
				c2p_cnt <= c2p_cnt + 1;
			if (c2p_armed && dut.vid.picture && !cpic_d) begin
				c2p_armed <= 1'b0;
				if (c2p_shown < 4) begin
					c2p_shown <= c2p_shown + 1;
					$display("[%0t] CPU INT -> first paper pixel: %0d T-states (48K wants 14336)",
						$time, c2p_cnt);
				end
			end
		end
	end

	// --- The INT pulse, measured in every unit that could disagree ---
	//
	// The board reports the pulse length changing with the contention
	// mode - 32 T-states in one mode, 36 in the others - which cannot
	// happen to the pulse itself: nIRQ is generated by the video counter
	// (int_len = 128 counts = 32 T-states at 14MHz) and the interrupt is
	// on line 248, sixty lines outside the display area where contention
	// is even enabled. So either the pulse reaching the CPU is not the
	// pulse video generates, or the thing a program can measure is not
	// the pulse.
	//
	// Four numbers per interrupt, and the differences between them are
	// the whole answer:
	//
	//   vid    - nIRQ low, counted in ungated enables. Wall-clock
	//            T-states, straight off the video counter. Must be 32.
	//   cpu    - cpu_irq_n low, ungated. This is after the resync in
	//            spectrum_top.v (clocked by cpu_clken, the UNGATED
	//            enable), so it should also be 32; if it is not, the
	//            resync is stretching or clipping the pulse.
	//   exec   - cpu_irq_n low, counted in GATED enables: the T-states
	//            the CPU actually got to execute inside the window.
	//            This is what a program measuring the pulse can see, and
	//            contention can only ever make it SMALLER than 32.
	//   stall  - enables the CPU was denied inside the window, and how
	//            many of those `contention` itself asked for.
	//
	// If exec comes out at 32 in every mode, the pulse is clean and the
	// test's number is being made somewhere else entirely.
	integer ip_vid = 0, ip_cpu = 0, ip_exec = 0, ip_stall = 0, ip_cont = 0;
	integer ip_shown = 0;
	reg     ip_vlow = 1'b0, ip_clow = 1'b0;
	reg     ipv_d = 1'b1, ipc_d = 1'b1;
	always @(posedge dut.clock) begin
		ipv_d <= dut.vid_irq_n;
		ipc_d <= dut.cpu_irq_n;
		if (dut.reset_n === 1'b1) begin
			// nIRQ straight from video
			if (ipv_d == 1'b1 && dut.vid_irq_n == 1'b0) begin
				ip_vlow <= 1'b1;
				ip_vid  <= 0;
			end else if (ip_vlow && dut.cpu_clken)
				ip_vid <= ip_vid + 1;
			if (ipv_d == 1'b0 && dut.vid_irq_n == 1'b1)
				ip_vlow <= 1'b0;

			// the same pulse after the resync, as the CPU sees it
			if (ipc_d == 1'b1 && dut.cpu_irq_n == 1'b0) begin
				ip_clow  <= 1'b1;
				ip_cpu   <= 0;
				ip_exec  <= 0;
				ip_stall <= 0;
				ip_cont  <= 0;
			end else if (ip_clow) begin
				if (dut.cpu_clken)        ip_cpu  <= ip_cpu + 1;
				if (dut.cpu_clken_gated)  ip_exec <= ip_exec + 1;
				if (dut.cpu_clken && !dut.cpu_clken_gated)
					ip_stall <= ip_stall + 1;
				if (dut.cpu_clken && dut.contention)
					ip_cont <= ip_cont + 1;
			end
			if (ipc_d == 1'b0 && dut.cpu_irq_n == 1'b1) begin
				ip_clow <= 1'b0;
				if (ip_shown < 8) begin
					ip_shown <= ip_shown + 1;
					$display("[%0t] INT PULSE mode=%0d  vid=%0d cpu=%0d exec=%0d  stall=%0d (contention %0d)  line=%0d",
						$time, dut.cont_mode,
						ip_vid, ip_cpu, ip_exec, ip_stall, ip_cont,
						dut.vid.vcounter[9:1]);
				end
			end
		end
	end

	// --- Contention charged per display line, tmloop.hex ------------
	//
	// Tact Meter counts turns of a two-instruction loop held wholly in
	// contended RAM:
	//
	//     7FFA: INC DE      ; 6T, M1 only
	//     7FFB: JP $7FFA    ; 10T, M1 + two operand reads
	//
	// and reports turns*16 + 192. A real 48K loses exactly 64 T-states
	// to contention on every one of the 192 display lines, so the whole
	// frame costs 12288 T and the program reads 57600 where an
	// uncontended bank reads 69888. Ours reads 57584 - sixteen T-states,
	// one turn of the loop, too few. Print the charge line by line: any
	// line that is not 64 is where our window and the ULA's part.
	integer ln_stall = 0;
	integer ln_shown = 0;
	reg [8:0] ln_prev = 9'd511;
	always @(posedge dut.clock) begin
		if (dut.reset_n === 1'b1) begin
			if (dut.vid.vcounter[9:1] != ln_prev) begin
				if (ln_prev < 9'd192 && ln_shown < 200) begin
					ln_shown <= ln_shown + 1;
					$display("[%0t] LINE %0d charged=%0d",
						 $time, ln_prev, ln_stall);
				end
				ln_prev  <= dut.vid.vcounter[9:1];
				ln_stall <= 0;
			end else if (dut.cpu_clken && !dut.cpu_clken_gated)
				ln_stall <= ln_stall + 1;
		end
	end

	// --- Does contention fire anywhere near the interrupt at all? ---
	//
	// The claim this checks is structural: the interrupt is on line 248
	// and `vid_contention` is only true on display lines 0..191, so no
	// access anywhere in the interrupt sequence should be charged. If
	// that holds, the contention mode cannot be what changes the pulse
	// the test measures, and the search moves elsewhere. Counted over
	// the whole run rather than per interrupt so one stray hit cannot
	// hide in an average.
	// --- What the canonical 48K model would charge that we do not ---
	//
	// sinclair.wiki.zxnet.co.uk: the Amstrad gate array "applies memory
	// contention only if the MREQ line is active, whereas the 16K/48K
	// ULA applies it under all circumstances". Our cont_mem carries
	// ~cpu_mreq_n unconditionally, so we implement the +2A/+3 rule on
	// every machine, and the T-states of an instruction that hold a
	// contended address without an access - the ones written hl:1 in the
	// published instruction tables - go free here.
	//
	// This counts them, without changing anything: T-states inside the
	// contention window, holding a contended address, with no MREQ. The
	// ratio to the accesses we DO charge is what the canonical model
	// would cost, and it decides whether adopting it is a small
	// correction or a large one. Aggregate contention magnitude was
	// already measured as correct once (32% against 32.7% predicted), so
	// a big number here would mean the two measurements disagree and one
	// of them is wrong - worth knowing before rewriting the model.
	integer free_internal = 0;   // would be charged by a real 48K ULA
	integer charged_mreq  = 0;   // what we charge now
	always @(posedge dut.clock) begin
		// Gated, not ungated: while contention is holding the CPU it is
		// not executing anything, and MREQ is high for part of that
		// hold. Counting ungated enables therefore counts the stall
		// itself as free internal T-states and inflates the answer -
		// which is the thing this measurement exists to size.
		if (dut.reset_n === 1'b1 && dut.cpu_clken_gated && dut.vid_contention
		    && (dut.cpu_a[14] & ~dut.cpu_a[15])) begin
			if (dut.cpu_mreq_n === 1'b1) free_internal <= free_internal + 1;
			else                         charged_mreq  <= charged_mreq + 1;
		end
	end

	// Which cycles actually collect the charge, by MCycle and TState.
	// The point is to separate the extra charges that belong - a read
	// with an internal T-state folded onto it, which the published
	// timings write as hl:3, hl:1 - from ones that are an artefact of
	// how T80 lengthens cycles for its own reasons, such as interrupt
	// acknowledge. Both look identical to a "T-state beyond the normal
	// length" test, and only the first is real.
	integer chg_ts [0:7];
	integer chg_mc [0:7];
	integer hi;
	initial for (hi = 0; hi < 8; hi = hi + 1) begin
		chg_ts[hi] = 0; chg_mc[hi] = 0;
	end
	always @(posedge dut.clock) begin
		if (dut.reset_n === 1'b1 && dut.cpu_clken && dut.contention) begin
			chg_ts[dut.cpu_ts] = chg_ts[dut.cpu_ts] + 1;
			chg_mc[dut.cpu_mc] = chg_mc[dut.cpu_mc] + 1;
		end
	end

	// --- Is the CPU losing T-states where contention is NOT running? ---
	//
	// The bird demo puts its top-border stripes in the wrong place and
	// its lower-border stripes in the right one, and no window trim
	// moves either - the window does not reach the border at all. So the
	// question is whether anything OTHER than contention is taking
	// T-states from the CPU, and whether it takes them evenly.
	//
	// If the border shows losses, the contention model is not what is
	// wrong: the screen lines would then only look right because our
	// contention undercharges by however much the other loss adds, one
	// error hiding the other. That has to be settled before any further
	// tuning of contention, or it is tuning against a moving target.
	//
	// Counted as enables offered against enables taken, separately for
	// the display area and the border.
	integer pic_offer = 0, pic_taken = 0;
	integer bor_offer = 0, bor_taken = 0;
	always @(posedge dut.clock) begin
		if (dut.reset_n === 1'b1 && dut.cpu_clken) begin
			if (dut.vid.vpicture) begin
				pic_offer <= pic_offer + 1;
				if (dut.cpu_clken_gated) pic_taken <= pic_taken + 1;
			end else begin
				bor_offer <= bor_offer + 1;
				if (dut.cpu_clken_gated) bor_taken <= bor_taken + 1;
			end
		end
	end

	// --- Where each border write lands, and how far apart they are ---
	//
	// The symptom on the board is that the gaps between border stripes
	// along a line are uneven, and nothing to do with contention touches
	// it - not the window trim, not the internal-T-state model, not the
	// output delay, not the refresh rate. So measure the thing itself:
	// for each OUT to port 0xFE, the T-states since the previous one and
	// where in the line it happened.
	//
	// A program stepping along the border writes at a fixed instruction
	// count, so the T-state gaps must all be equal. If they are, the CPU
	// is fine and the fault is in how the write reaches the screen. If
	// they are not, the number printed beside them says how much is
	// being stolen and where.

	reg     ob_d = 1'b1;
	wire    ob_now = ~dut.cpu_ioreq_n & dut.cpu_m1_n & ~dut.cpu_a[0]
	                 & (~dut.cpu_wr_n | ~dut.cpu_rd_n);
	always @(posedge dut.clock) begin
		if (dut.reset_n === 1'b1) begin
			if (dut.cpu_clken) ob_ts <= ob_ts + 1;
			ob_d <= ob_now;
			if (ob_now && !ob_d) begin
				if (ob_shown < 40) begin
					ob_shown <= ob_shown + 1;
					$display("BORDER OUT #%0d: %0d T since last, %0d T after INT, h=%0d line=%0d val=%0d vpic=%b cont=%b contio=%b",
						ob_shown, ob_ts - ob_prev, (irq_mark < 0) ? 0 : (ob_ts - irq_mark),
						dut.vid.hcounter, dut.vid.vcounter[9:1],
						dut.cpu_do[2:0], dut.vid.vpicture, dut.vid_contention, dut.vid_contention_io);
				end
				ob_prev <= ob_ts;
			end
		end
	end

	// --- Every event between the interrupt edge and the first OUT ---
	//
	// The delay from edge to OUT measures 55 T-states where a Z80
	// needs about 36. This prints each step with the CPU T-state it
	// happens on, so the excess can be attributed rather than guessed:
	// nIRQ itself, the resynchronised copy the CPU sees, the start and
	// end of the acceptance sequence, and every opcode fetched after.
	reg tr_vid_d = 1'b1, tr_cpu_d = 1'b1, tr_ic_d = 1'b0, trm1_d = 1'b1;
	integer tr_m1n = 0;
	always @(posedge dut.clock) begin
		if (dut.reset_n === 1'b1 && fi_mark >= 0) begin
			tr_vid_d <= dut.vid_irq_n;
			tr_cpu_d <= dut.cpu_irq_n;
			tr_ic_d  <= dut.cpu.u0.IntCycle;
			trm1_d  <= dut.cpu_m1_n;
			if (tr_vid_d && !dut.vid_irq_n)
				$display("  TRACE T+%0d: vid_irq_n falls", ob_ts - fi_mark);
			if (tr_cpu_d && !dut.cpu_irq_n)
				$display("  TRACE T+%0d: cpu_irq_n falls (after resync)", ob_ts - fi_mark);
			if (!tr_ic_d && dut.cpu.u0.IntCycle)
				$display("  TRACE T+%0d: acceptance begins", ob_ts - fi_mark);
			if (tr_ic_d && !dut.cpu.u0.IntCycle)
				$display("  TRACE T+%0d: acceptance ends", ob_ts - fi_mark);
			if (trm1_d && !dut.cpu_m1_n && tr_m1n < 70) begin
				tr_m1n <= tr_m1n + 1;
				$display("  TRACE T+%0d: M1 fetch at %04h", ob_ts - fi_mark, dut.cpu_a);
			end
		end
	end

	// --- From IORQ on port 0xFE to the colour reaching the screen ---
	//
	// The last unmeasured link. Everything from the interrupt edge to
	// the OUT itself now matches a Z80 to the T-state, yet the border
	// above the raster is still displaced - so the remaining candidate
	// is the output path: ula_port latching D_OUT, then video's border
	// delay chain. Prints where the write happens and where the colour
	// actually changes, both in hcounter counts (4 per T-state).
	reg [2:0] bd_prev = 3'b000;
	reg       bd_arm  = 1'b0;
	integer   bd_h = 0, bd_shown = 0;
	always @(posedge dut.clock) begin
		if (dut.reset_n === 1'b1) begin
			if (ob_now && !ob_d && !bd_arm) begin
				bd_arm <= 1'b1; bd_h <= dut.vid.hcounter;
			end
			bd_prev <= dut.vid.border_out;
			if (bd_arm && dut.vid.border_out !== bd_prev) begin
				bd_arm <= 1'b0;
				if (bd_shown < 6) begin
					bd_shown <= bd_shown + 1;
					$display("  BORDER PATH: IORQ at h=%0d, colour changes at h=%0d -> %0d counts = %0d pixels",
						bd_h, dut.vid.hcounter, dut.vid.hcounter - bd_h,
						(dut.vid.hcounter - bd_h) / 2);
				end
			end
		end
	end

	// --- Exact extent of the contention window, straight off the
	// signal rather than inferred from a program. Records the lowest
	// and highest hcounter at which vid_contention is asserted on a
	// display line, and the same for where a CPU access actually
	// gets charged. By construction the window is the first 512
	// counts (hcounter 4..515 with the -4 offset), and the phase
	// test should stop it before that: the last charging phase ends
	// at hc_cont 503, i.e. hcounter 507.
	integer win_lo = 9999, win_hi = 0;   // 0, not -1: hcounter is unsigned and the comparison would go unsigned too
	integer chg_lo = 9999, chg_hi = 0;
	always @(posedge dut.clock) begin
		if (dut.reset_n === 1'b1 && dut.vid.vpicture) begin
			if (dut.vid_contention) begin
				if (dut.vid.hcounter < win_lo) win_lo <= dut.vid.hcounter;
				if (dut.vid.hcounter > win_hi) win_hi <= dut.vid.hcounter;
			end
			if (dut.contention) begin
				if (dut.vid.hcounter < chg_lo) chg_lo <= dut.vid.hcounter;
				if (dut.vid.hcounter > chg_hi) chg_hi <= dut.vid.hcounter;
			end
		end
	end

	integer cont_in_border = 0, cont_in_pic = 0;
	integer cont_at_int    = 0;
	always @(posedge dut.clock) begin
		if (dut.reset_n === 1'b1 && dut.cpu_clken && dut.contention) begin
			if (dut.vid.vpicture) cont_in_pic    <= cont_in_pic + 1;
			else                  cont_in_border <= cont_in_border + 1;
			if (dut.cpu_irq_n == 1'b0) cont_at_int <= cont_at_int + 1;
		end
	end

	// --- Hang detector ---
	// The board's symptom, stated directly: the CPU stops fetching. A
	// healthy machine takes an opcode every few clocks at any speed, so
	// a long gap between M1 fetches means it is stuck - and the point of
	// this is to say WHY, by printing what was holding it at the moment
	// it stopped, rather than leaving a silent log to be read backwards.
	integer last_m1 = 0;
	integer hang_reported = 0;
	reg m1_d = 1'b1;
	always @(posedge dut.clock) begin
		m1_d <= dut.cpu_m1_n;
		if (dut.reset_n === 1'b1) begin
			if (dut.cpu_m1_n == 1'b0 && m1_d == 1'b1)
				last_m1 <= 0;
			else if (last_m1 < 200000)
				last_m1 <= last_m1 + 1;
			// 20000 clocks is ~700us, far beyond any legitimate stall:
			// a whole SPI byte is 128.
			if (last_m1 == 20000 && hang_reported < 4) begin
				hang_reported <= hang_reported + 1;
				$display("[%0t] HANG: no opcode fetch for 20000 clocks", $time);
				$display("   wait_all=%b arbiter_wait=%b divmmc_wait=%b spi_acc=%b busy=%b seen_busy=%b counter=%0d",
					dut.cpu_wait_all_n, dut.cpu_wait_n, dut.divmmc_wait_n,
					dut.dmmc.spi_acc, dut.dmmc.spi_busy, dut.dmmc.seen_busy,
					dut.dmmc.mi_spi.counter);
				$display("   a=%04h mreq_n=%b ioreq_n=%b rd_n=%b wr_n=%b m1_n=%b TState=%0d MCycle=%0d contention=%b",
					dut.cpu_a, dut.cpu_mreq_n, dut.cpu_ioreq_n, dut.cpu_rd_n,
					dut.cpu_wr_n, dut.cpu_m1_n, dut.cpu.u0.TState,
					dut.cpu.u0.MCycle, dut.contention);
			end
		end
	end

	// --- IM1 interrupt acceptance and the exit from HALT ---
	// The two things the 48K raster-timing investigation has never
	// actually measured. A real Z80 accepts an IM1 interrupt in 13
	// T-states (a 5-T-state RST-style M1 plus 2 automatic wait states,
	// then two 3-T-state pushes) and exiting HALT must not add or lose
	// any. If either is wrong here, programs that wait in HALT land at
	// a different raster position than programs that spin in a poll
	// loop - which is exactly the shape of "no single trim satisfies
	// both demos".
	//
	// Counted in CPU T-states, not clocks: one gated clock enable is
	// one T-state, so contention holding the CPU cannot distort it.
	// IntCycle is set by T80 as the accepting M1 begins and cleared at
	// the end of the sequence, so it brackets exactly the acceptance.
	integer int_ts = 0;
	integer int_reported = 0;
	reg     intcycle_d = 1'b0;
	reg     was_halted = 1'b0;
	// What the CPU reads off the bus in the acknowledge cycle. A 48K
	// leaves it floating and the Z80 sees $FF, which is what an IM2
	// vector table is built around; anything else here puts the vector
	// at a different address than the same program finds on real iron.
	reg [7:0] int_vec = 8'hxx;
	always @(posedge dut.clock) begin
		intcycle_d <= dut.cpu.u0.IntCycle;

		if (dut.cpu.u0.IntCycle == 1'b1 && dut.cpu.u0.MCycle == 3'd1
		    && dut.cpu.u0.TState == 3'd2 && dut.cpu_clken_gated == 1'b1)
			int_vec <= dut.cpu_di;

		if (dut.cpu.u0.IntCycle == 1'b1 && intcycle_d == 1'b0) begin
			int_ts <= 0;
			was_halted <= dut.cpu.u0.Halt_FF;
		end else if (dut.cpu.u0.IntCycle == 1'b1 &&
		             dut.cpu_clken_gated == 1'b1)
			int_ts <= int_ts + 1;

		if (dut.cpu.u0.IntCycle == 1'b0 && intcycle_d == 1'b1) begin
			if (int_reported < 6)
				$display("[%0t] INT ACCEPT: %0d T-states (from HALT: %b) bus=%02h - Z80 wants 13, a 48K bus reads FF",
					$time, int_ts, was_halted, int_vec);
			int_reported <= int_reported + 1;
		end
	end

	// --- Tact Meter's whole preamble, im2meas.hex -------------------
	//
	// What decides the number Tact Meter prints is not only contention
	// but how long the machine takes to get from the interrupt to the
	// first INC DE of the counting loop: every 16 T-states of that is
	// one turn the program never counts. On a real Z80 the path is
	//
	//   19  IM2 acceptance
	//   12  JR at $FFFF, the vector landing on the byte before the top
	//   10  JP at $FFF4
	//  121  the handler, $815F..$8186
	//   41  LD A / LD HL / LD DE / EI / JP $7FFA
	//  ---
	//  203  T-states
	//
	// Counted in gated enables, so contention cannot distort it.
	integer pre_ts = 0;
	reg     pre_run = 1'b0, pre_done = 1'b0, pre_ic = 1'b0;
	always @(posedge dut.clock) begin
		pre_ic <= dut.cpu.u0.IntCycle;
		if (!pre_done && dut.reset_n === 1'b1) begin
			if (dut.cpu.u0.IntCycle == 1'b1 && pre_ic == 1'b0) begin
				pre_run <= 1'b1;
				pre_ts  <= 0;
			end else if (pre_run && dut.cpu_clken_gated) begin
				if (dut.cpu.u0.MCycle == 3'd1
				    && dut.cpu.u0.TState == 3'd1
				    && dut.cpu_a == 16'h7ffa) begin
					$display("[%0t] PREAMBLE: %0d T-states from interrupt to $7FFA - Z80 wants 203",
						 $time, pre_ts);
					pre_run  <= 1'b0;
					pre_done <= 1'b1;
				end else
					pre_ts <= pre_ts + 1;
			end
		end
	end

	// How long the CPU sat in HALT, and that it left at all.
	integer halt_ts = 0;
	integer halt_reported = 0;
	reg     halt_d = 1'b0;
	always @(posedge dut.clock) begin
		halt_d <= dut.cpu.u0.Halt_FF;
		if (dut.cpu.u0.Halt_FF == 1'b1 && halt_d == 1'b0)
			halt_ts <= 0;
		else if (dut.cpu.u0.Halt_FF == 1'b1 && dut.cpu_clken_gated == 1'b1)
			halt_ts <= halt_ts + 1;
		if (dut.cpu.u0.Halt_FF == 1'b0 && halt_d == 1'b1) begin
			if (halt_reported < 6)
				$display("[%0t] HALT exited after %0d T-states", $time, halt_ts);
			halt_reported <= halt_reported + 1;
		end
	end

	// --- The ULA contention delay table, measured per access type ---
	//
	// Indexed by the phase of the ULA window at which the CPU's machine
	// cycle BEGINS (its T1), which is what a program can actually see
	// and time against. The canonical 48K table is 6,5,4,3,2,1,0,0 and
	// it is the same for reads and writes on real hardware.
	//
	// Split by read/write on purpose. T80se.v asserts MREQ a T-state
	// later for a write (the TState==2 edge, T80se.v:170) than for a
	// read or opcode fetch (the TState==1 edge, T80se.v:157/166), and
	// contention here is charged off MREQ going low (spectrum_top.v's
	// cont_mem). So the delay a program is charged is expected to come
	// out shifted between the two - and a shift that differs by access
	// type is exactly what no single CONT_ADJ trim can straighten,
	// which would explain why no trim has ever satisfied two demos at
	// once.
	//
	// TState only advances on a gated enable, so a stall shows up as
	// enables the CPU did not get; counting those is counting T-states.
	// IO gets its own row. An OUT is how border stripes are drawn, and
	// IO contention is a separate branch in spectrum_top.v (cont_io and
	// the io_seq walk) from the memory one. It also has a different
	// correct answer: a real Z80 puts IORQ in T2 of the IO cycle, which
	// is where T80se puts it too, whereas it puts MREQ in T1 and T80se
	// does not. So a compensation that is right for memory is not
	// automatically right for IO - and if the two end up shifted from
	// each other, an OUT-heavy program and a memory-heavy program will
	// again disagree about the trim.
	integer rd_delay [0:7];
	integer rd_count [0:7];
	integer wr_delay [0:7];
	integer wr_count [0:7];
	integer io_delay [0:7];
	integer io_count [0:7];
	integer ci;
	initial begin
		for (ci = 0; ci < 8; ci = ci + 1) begin
			rd_delay[ci] = 0; rd_count[ci] = 0;
			wr_delay[ci] = 0; wr_count[ci] = 0;
			io_delay[ci] = 0; io_count[ci] = 0;
		end
	end

	reg [2:0] mc_phase = 3'd0;
	reg       mc_inwin = 1'b0;      // cycle began inside the ULA window
	reg       mc_caddr = 1'b0;      // ...and pointed at contended RAM
	reg       mc_write = 1'b0;
	reg       mc_io    = 1'b0;
	integer   mc_stall = 0;

	always @(posedge dut.clock) begin
		if (dut.cpu_clken == 1'b1) begin
			if (dut.cpu_clken_gated == 1'b1 && dut.cpu.u0.TState == 3'd1) begin
				// A machine cycle is starting: bank the one that just
				// ended, then latch where this one begins. Which table it
				// belongs to is only known now, at the end - IORQ and WR
				// both appear part way through the cycle.
				if (mc_inwin) begin
					if (mc_io) begin
						io_delay[mc_phase] = io_delay[mc_phase] + mc_stall;
						io_count[mc_phase] = io_count[mc_phase] + 1;
					end else if (mc_caddr && mc_write) begin
						wr_delay[mc_phase] = wr_delay[mc_phase] + mc_stall;
						wr_count[mc_phase] = wr_count[mc_phase] + 1;
					end else if (mc_caddr) begin
						rd_delay[mc_phase] = rd_delay[mc_phase] + mc_stall;
						rd_count[mc_phase] = rd_count[mc_phase] + 1;
					end
				end
				// Phase counted from the first T-state of the display
				// fetch (hcounter = 8, four counts to a T-state), NOT
				// from hc_cont.
				//
				// hc_cont was the obvious choice and it is useless here:
				// it already contains CONT_ADJ and the structural -4, so
				// moving the window moves this ruler with it and the
				// table comes out identical whatever the trim. Measured -
				// a run at CONT_ADJ=+1 reproduced the CONT_ADJ=0 table to
				// the decimal, which is the instrument reporting on its
				// own coordinate system rather than on the design.
				//
				// Against the display fetch the question the published
				// table actually asks becomes measurable: phase 0 is the
				// T-state the ULA starts fetching on, and a real 48K
				// charges 6,5,4,3,2,1,0,0 from there.
				mc_phase <= dut.vid.hcounter[4:2] - 3'd2;
				// Only a cycle inside the contended part of a contended
				// line can be charged anything at all. The contended-RAM
				// test is applied on top for the memory rows: without it
				// the uncontended ROM fetches - most of the cycles in the
				// test loop - land in the same phase buckets contributing
				// zero and dilute the table into noise.
				mc_inwin <= dut.vid.vpicture & ~dut.vid.hc_cont[9];
				mc_caddr <= dut.cpu_a[14] & ~dut.cpu_a[15];
				mc_io    <= 1'b0;
				mc_write <= 1'b0;
				mc_stall <= 0;
			end else begin
				if (dut.cpu_clken_gated == 1'b0)
					mc_stall <= mc_stall + 1;
				if (dut.cpu_wr_n == 1'b0)
					mc_write <= 1'b1;
				if (dut.cpu_ioreq_n == 1'b0 && dut.cpu_m1_n == 1'b1)
					mc_io <= 1'b1;
			end
		end
	end

	initial begin
		#(run_len_us(0) * 1000 - 10_000);
		if (live_transition_requested) begin
			if (landed_at == -1)
				$display("LIVE TRANSITION: cpu_speed NEVER reached %0d - stuck at %0d",
					live_speed[1:0], dut.cpu_speed);
			else
				$display("LIVE TRANSITION: landed at time %0d ps", landed_at);
			$display("Longest continuous WAIT hold: %0d clocks", max_wait_streak);
		end
		$display("Interrupts seen this run: %0d", int_count);
		$display("CONTENTION TABLE (mean delay in T-states by phase the cycle starts at)");
		$display("  phase :    0    1    2    3    4    5    6    7");
		$write("  read  :");
		for (ci = 0; ci < 8; ci = ci + 1)
			if (rd_count[ci] == 0) $write("    -");
			else $write(" %4.1f", 1.0 * rd_delay[ci] / rd_count[ci]);
		$write("\n  write :");
		for (ci = 0; ci < 8; ci = ci + 1)
			if (wr_count[ci] == 0) $write("    -");
			else $write(" %4.1f", 1.0 * wr_delay[ci] / wr_count[ci]);
		$write("\n  io    :");
		for (ci = 0; ci < 8; ci = ci + 1)
			if (io_count[ci] == 0) $write("    -");
			else $write(" %4.1f", 1.0 * io_delay[ci] / io_count[ci]);
		$write("\n  n(rd) :");
		for (ci = 0; ci < 8; ci = ci + 1) $write(" %4d", rd_count[ci]);
		$write("\n  n(wr) :");
		for (ci = 0; ci < 8; ci = ci + 1) $write(" %4d", wr_count[ci]);
		$write("\n  n(io) :");
		for (ci = 0; ci < 8; ci = ci + 1) $write(" %4d", io_count[ci]);
		$display("\n  a real 48K ULA charges 6,5,4,3,2,1,0,0 for memory;");
		$display("  IO is the four-case table, so what matters for the io");
		$display("  row is whether its pattern lines up with the memory rows");
	end

	// ------------------------------------------------------------
	// Simulation accelerator: preload the modelled chip with the image
	// the boot copy would have written, and fast-forward the copy
	// counter once the settle delay is done. The copy itself is not
	// what is under test here - it is verified byte-perfect on hardware
	// (16384/16384) - and at 16384 slots it otherwise eats ~9.4ms of
	// simulated time before the CPU is even released. What IS under
	// test is what happens afterwards, when the CPU fetches from SDRAM
	// while video competes for the same chip.
	// ------------------------------------------------------------
	reg [7:0] esxinit [0:8191];
	// Which image to run. Default is the real ESXDOS ROM; +ROM=ramtest.hex
	// swaps in a small program that fills RAM, because ESXDOS itself does
	// not write a single byte of RAM in the window simulated here - the
	// CPU write path had no coverage at all.
	reg [255:0] romfile, romfile2;
	integer k;
	initial begin
		// Give the modelled chip defined contents before anything is
		// poked into it. A real part powers up with arbitrary but
		// defined bits; an uninitialised array holds x, which
		// propagates through every read of memory the ROM has not
		// written yet. Zeroing also makes the ROM's own two block RAM
		// clears redundant, which is what lets esxmmc_fb2.hex cut them
		// to a single iteration and save tens of milliseconds.
		//
		// It has to happen HERE, ahead of the preload in the same
		// block. Done in sdram_model.v's own initial block it raced
		// this one, and when it won it erased the image that had just
		// been poked in - the CPU then executed zeros, crashed, and sat
		// in HALT with interrupts disabled, which looked convincingly
		// like a design fault.
		for (k = 0; k < 4194304; k = k + 1)
			chip.mem[k] = 16'h0000;

		if (!$value$plusargs("ROM=%s", romfile)) romfile = "esxmmc_plain.hex";
		$readmemh(romfile, esxinit);
		for (k = 0; k < 8192; k = k + 1) begin
			poke(23'h180000 + k, esxinit[k]);
			poke(23'h1A6000 + k, esxinit[k]);
		end
		wait (dut.boot_settle_done === 1'b1);
		@(posedge dut.clock);
		force dut.boot_copy_addr = 15'd16380;
		repeat (200) @(posedge dut.clock);
		release dut.boot_copy_addr;

		// The page-clearing phase that follows the copy walks 131072
		// addresses, which is ~75ms of simulated time - fast-forward it
		// too. The pages are already zero here, since the model's memory
		// starts that way.
		wait (dut.boot_copy_active === 1'b0);
		@(posedge dut.clock);
		force dut.boot_zero_addr = 17'd131060;
		repeat (400) @(posedge dut.clock);
		release dut.boot_zero_addr;
		wait (dut.boot_zero_active === 1'b0);
		$display("[%0t] page clear finished", $time);

		// The design also holds reset for reset_cnt cycles - 32,000,000 of
		// them at power-up, which is 1.14s at 28MHz. Sensible on the board,
		// hopeless to simulate, so wind it down once the copy is done.
		wait (dut.boot_copy_active === 1'b0);
		@(posedge dut.clock);
		force dut.reset_cnt = 25'd50;
		repeat (20) @(posedge dut.clock);
		release dut.reset_cnt;
		$display("[%0t] reset counter wound down, CPU should start", $time);
	end

	// ------------------------------------------------------------
	// M1 trace, straight off the real CPU inside the design
	// ------------------------------------------------------------
	integer logfile;
	initial logfile = $fopen("trace_top.log", "w");

	reg prev_m1_n = 1'b1;
	reg [15:0] prev_pc = 16'hFFFF;
	always @(posedge dut.clock) begin
		if (dut.cpu_m1_n == 1'b0 && prev_m1_n == 1'b1) begin
			if (dut.cpu_a !== prev_pc)
				$fdisplay(logfile, "PC=%04h DI=%02h paged_in=%b page=%h conmem=%b mapram=%b copy=%b",
					dut.cpu_a, dut.cpu_di, dut.divmmc_paged_in,
					dut.divmmc_sram_page, dut.divmmc_conmem, dut.divmmc_mapram,
					dut.boot_copy_active);
			prev_pc <= dut.cpu_a;
		end
		prev_m1_n <= dut.cpu_m1_n;
	end

	// ------------------------------------------------------------
	// The measurement that matters: every opcode the CPU fetches from
	// the DivMMC fixed-ROM window should equal the ESXDOS image byte at
	// that offset. Any mismatch is a corrupted instruction fetch out of
	// SDRAM - the thing hardware does and every earlier testbench, with
	// its instant behavioral memory, structurally could not show.
	// ------------------------------------------------------------
	reg [7:0] esxrom [0:8191];
	initial begin
		if (!$value$plusargs("ROM=%s", romfile2)) romfile2 = "esxmmc_plain.hex";
		$readmemh(romfile2, esxrom);
	end

	integer bad_fetch = 0;
	integer good_fetch = 0;
	wire fetch_is_fixed_rom = dut.divmmc_paged_in && dut.esxdos_downloaded[1]
		&& (dut.cpu_a[15:13] == 3'b000)
		&& (dut.divmmc_conmem || !dut.divmmc_mapram);

	// Sample at the END of the memory cycle, not at the M1 edge. cpu_di
	// is only meaningful once MREQ/RD are asserted and the data has come
	// back; checking it the moment M1 falls just reads the mux's idle-bus
	// default (0xFF) and reports every single fetch as corrupt.
	reg [7:0]  last_di;
	reg [15:0] last_a;
	reg        last_was_fixed = 1'b0;
	reg        prev_mreq_n = 1'b1;

	always @(posedge dut.clock) begin
		if (!dut.cpu_mreq_n && !dut.cpu_rd_n && !dut.cpu_m1_n) begin
			last_di        <= dut.cpu_di;
			last_a         <= dut.cpu_a;
			last_was_fixed <= fetch_is_fixed_rom;
		end
		if (dut.cpu_mreq_n && !prev_mreq_n && last_was_fixed) begin
			if (last_di !== esxrom[last_a[12:0]]) begin
				bad_fetch = bad_fetch + 1;
				if (bad_fetch <= 20)
					$display("[%0t] BAD FETCH PC=%04h got=%02h expected=%02h",
						$time, last_a, last_di, esxrom[last_a[12:0]]);
			end else begin
				good_fetch = good_fetch + 1;
			end
		end
		prev_mreq_n <= dut.cpu_mreq_n;
	end

	// Which q phase is the read data actually on the bus in? Needed to
	// latch it inside sdram_ep4ce.v instead of relying on the consumer
	// sampling at exactly the right instant.
	integer qprobe = 0;
	always @(posedge dut.clk56) begin
		if (chip.rd_valid[3] === 1'b1 && qprobe < 12) begin
			$display("[%0t] read data on bus at q=%0d  data=%02h",
				$time, dut.sdr.q, chip.rd_data[3][7:0]);
			qprobe = qprobe + 1;
		end
	end

	// ------------------------------------------------------------
	// Video data check.
	//
	// This testbench had no view of the video side at all, which is how
	// it passed an arbiter change that broke the display into diagonal
	// stripes on hardware: the CPU's own fetches stayed perfect while
	// the video controller was being starved of the cycles it fetches
	// in. Watch the bytes the video path actually receives and compare
	// them against what the modelled chip holds at the address video
	// asked for.
	//
	// Sampled on the falling edge of the video slot, mirroring how
	// video.v takes VID_D_IN, with the address captured when the slot
	// opened.
	// ------------------------------------------------------------
	// Count clocks where the video controller is asking to read but the
	// CPU has the bus. That is exactly the failure an earlier arbiter
	// change caused - it took a cycle out of the half of the window
	// video fetches in, and the picture broke into diagonal stripes -
	// and unlike comparing the data itself it does not depend on knowing
	// the precise instant video samples the bus.
	// Reads as 3954 of 15811 on the known-good fixed-slot design, so it
	// is a load figure, not a defect count - kept only for comparison
	// between builds.
	integer vid_denied = 0;
	integer vid_reads  = 0;
	always @(posedge dut.clock) begin
		if (dut.reset_n == 1'b1 && dut.vid_rd_n == 1'b0) begin
			vid_reads <= vid_reads + 1;
			if (dut.cur_own == 2'd1)   // OWN_CPU
				vid_denied <= vid_denied + 1;
		end
	end

	// Video fetches that were still outstanding when their data was
	// due. This one is a real defect count: the arbiter is only correct
	// if every group's two bytes arrive before the group is displayed.
	integer vid_late = 0;
	always @(posedge dut.clock) begin
		if (dut.reset_n == 1'b1 && dut.vid_clken == 1'b1
		    && dut.vid.hcounter[9] == 1'b0 && dut.vid.hcounter[3:0] == 4'b0111
		    && dut.vid.read_step != 2'd2)
			vid_late <= vid_late + 1;
	end

	// ------------------------------------------------------------
	// CPU throughput: how many clock enables the CPU actually gets.
	// clocks.v withholds the second enable of each 16-clock window while
	// the CPU is mid memory access, so the machine runs short of the
	// 3.5MHz a Pentagon expects - by 224 T-states per frame even when
	// idle on hardware, and more under memory-heavy code. Measured here
	// over a fixed window so a change to the arbitration can be compared
	// against the current design without simulating a whole frame.
	// ------------------------------------------------------------
	integer cpu_ticks = 0;   // clock enables issued
	integer cpu_eff   = 0;   // enables on which the CPU actually advances
	integer cpu_wait  = 0;   // clocks spent stalled on WAIT_n
	integer meas_run  = 0;
	always @(posedge dut.clock) begin
		if (dut.reset_n == 1'b1) begin
			meas_run <= meas_run + 1;
			if (dut.cpu_clken == 1'b1) begin
				cpu_ticks <= cpu_ticks + 1;
				if (dut.cpu_wait_n == 1'b1)
					cpu_eff <= cpu_eff + 1;
			end
			if (dut.cpu_wait_n == 1'b0)
				cpu_wait <= cpu_wait + 1;
		end
	end

	// note when the boot copy finishes and the CPU is let go
	reg copy_done_seen = 0;
	always @(posedge dut.clock) begin
		if (!dut.boot_copy_active && !copy_done_seen) begin
			copy_done_seen <= 1'b1;
			$display("[%0t] boot copy finished, CPU released", $time);
		end
	end

	// Must be <= the `run` time, otherwise the trace file is never closed
	// and its buffer never reaches disk - which is why an earlier 25ms
	// run left an empty log despite the design executing.
	initial begin
		#(run_len_us(0) * 1000);
		$fclose(logfile);
		$display("=====================================================");
		$display("DivMMC fixed-ROM opcode fetches: %0d good, %0d corrupted",
			good_fetch, bad_fetch);
		$display("CPU clock enables: %0d over %0d clocks of 28MHz",
			cpu_ticks, meas_run);
		$display("  = %0d%% of the 2-per-16-clock maximum (3.5MHz)",
			(meas_run == 0) ? 0 : (cpu_ticks * 800) / meas_run);
		// What actually counts: enables on which the CPU was not held by
		// WAIT_n. Clock enables alone say nothing once WAIT exists - the
		// CPU can be issued every enable and still stand still.
		$display("  effective (CPU not stalled): %0d = %0d%% of 3.5MHz",
			cpu_eff, (meas_run == 0) ? 0 : (cpu_eff * 800) / meas_run);
		$display("  clocks spent stalled on WAIT: %0d", cpu_wait);
		$display("Video: %0d read-clocks, %0d with the bus held by the CPU",
			vid_reads, vid_denied);
		$display("Video fetches late for display: %0d", vid_late);
		$display("Contention charged: %0d in the display area, %0d outside it",
			cont_in_pic, cont_in_border);
		$display("  of which while INT was low: %0d (expected 0 - the",
			cont_at_int);
		$display("  interrupt is on line 248, outside vpicture)");
		$display("WINDOW extent: vid_contention h=%0d..%0d, charged h=%0d..%0d",
			win_lo, win_hi, chg_lo, chg_hi);
		$display("  by construction the window is h=4..515, last charging phase ends h=507");
		$display("Contended address inside the window: %0d T-states with MREQ (we charge these),",
			charged_mreq);
		$display("  %0d without MREQ (a real 48K ULA charges these too, we do not)",
			free_internal);
		$display("CPU enables taken/offered - display area: %0d/%0d (%0d%% lost)",
			pic_taken, pic_offer,
			(pic_offer == 0) ? 0 : ((pic_offer - pic_taken) * 100) / pic_offer);
		$display("                          - border      : %0d/%0d (%0d%% lost)",
			bor_taken, bor_offer,
			(bor_offer == 0) ? 0 : ((bor_offer - bor_taken) * 100) / bor_offer);
		$display("  border loss must be 0 - contention does not reach there");
		$write("Contention charged by TState :");
		for (hi = 0; hi < 8; hi = hi + 1) $write(" %0d:%0d", hi, chg_ts[hi]);
		$display("");
		$write("Contention charged by MCycle :");
		for (hi = 0; hi < 8; hi = hi + 1) $write(" %0d:%0d", hi, chg_mc[hi]);
		$display("");
		$display("=====================================================");
		$display("SIMULATION DONE");
		$finish;
	end

	// --- video data correctness ---
	// The screen area is filled with a known pattern so the bytes video
	// displays can be checked against the address the original
	// combinational formula would have produced for each group. This is
	// the check that was missing while the arbiter was being written:
	// the "denied" counter flags the known-good design and says nothing,
	// and the late-fetch counter only proves a fetch finished, not that
	// it went to the right place. Group 0 of each line in particular is
	// only reached through the line-wrap path.
	//
	// sdram_model indexes its array by byte address (a_full = addr[21:0]
	// with one byte per entry selected by DQM), so both halves get the
	// same value, as the ESXDOS preload above does.
	function [7:0] vpat;
		input [21:0] byte_addr;
		vpat = byte_addr[7:0] ^ byte_addr[15:8];
	endfunction

	integer w;
	initial begin
		// screen page: vid_addr = {6'b001010, 13 bits} -> 81920..90111
		for (w = 81920; w < 90112; w = w + 1)
			poke(w, vpat(w));
	end

	integer vid_good = 0, vid_wrong = 0;
	integer att_good = 0, att_wrong = 0;
	reg [18:0] exp_att;
	reg [7:0]  exp_att_byte;
	reg [18:0] exp_a;
	reg [7:0]  exp_byte;
	always @(posedge dut.clock) begin
		if (dut.reset_n === 1'b1 && dut.vid_clken === 1'b1
		    && dut.vid.vpicture === 1'b1 && dut.vid.hcounter[0] === 1'b1
		    && dut.vid.hcounter[9] === 1'b0 && dut.vid.hcounter[3] === 1'b0
		    && dut.vid.hcounter[2] === 1'b0 && dut.vid.hcounter[1] === 1'b1) begin
			exp_a  = {6'b001010, dut.vid.vcounter[8:7], dut.vid.vcounter[3:1],
			          dut.vid.vcounter[6:4], dut.vid.hcounter[8:4]};
			exp_byte = vpat({3'b000, exp_a});
			if (dut.vid.pixels_next === exp_byte)
				vid_good = vid_good + 1;
			else begin
				vid_wrong = vid_wrong + 1;
				if (vid_wrong <= 8)
					$display("[%0t] VID MISMATCH line=%0d group=%0d got=%02h want=%02h",
						$time, dut.vid.vcounter[9:1], dut.vid.hcounter[8:4],
						dut.vid.pixels_next, exp_byte);
			end
		end
	end
	// The attribute byte was never checked - only the pixel byte was.
	always @(posedge dut.clock) begin
		if (dut.reset_n === 1'b1 && dut.vid_clken === 1'b1
		    && dut.vid.vpicture === 1'b1 && dut.vid.hcounter[0] === 1'b1
		    && dut.vid.hcounter[9] === 1'b0 && dut.vid.hcounter[3] === 1'b0
		    && dut.vid.hcounter[2] === 1'b1 && dut.vid.hcounter[1] === 1'b1) begin
			exp_att = {6'b001010, 3'b110, dut.vid.vcounter[8:7],
			           dut.vid.vcounter[6:4], dut.vid.hcounter[8:4]};
			exp_att_byte = vpat({3'b000, exp_att});
			if (dut.vid.attr_next === exp_att_byte)
				att_good = att_good + 1;
			else begin
				att_wrong = att_wrong + 1;
				if (att_wrong <= 8)
					$display("[%0t] ATTR MISMATCH line=%0d group=%0d got=%02h want=%02h",
						$time, dut.vid.vcounter[9:1], dut.vid.hcounter[8:4],
						dut.vid.attr_next, exp_att_byte);
			end
		end
	end

	initial begin
		#1_400_000;
		$display("AUTO_REFRESH commands: %0d (needs ~90 per 1.4ms)", chip.refresh_seen);
		$display("SDRAM protocol violations: %0d", chip.prot_err);
		$display("Video pixel bytes: %0d correct, %0d wrong", vid_good, vid_wrong);
		$display("Video attribute bytes: %0d correct, %0d wrong", att_good, att_wrong);
	end

	// Did the SDRAM cycle actually fetch the address the CPU asked for?
	// The DivMMC ROM check above only covers the rom_addr path; RAM goes
	// through ram_addr, which is registered on vid_clken and so lags
	// cpu_a. If the arbiter captures it before it has caught up, the
	// cycle reads or writes the previous address.
	integer addr_ok = 0, addr_stale = 0;
	always @(posedge dut.clock) begin
		if (dut.reset_n === 1'b1 && dut.slot_tick_d2 === 1'b1
		    && dut.prev_own === 2'd1 && dut.cpu_mem_active === 1'b1) begin
			if (dut.cpu_addr_held === dut.cpu_addr)
				addr_ok = addr_ok + 1;
			else begin
				addr_stale = addr_stale + 1;
				if (addr_stale <= 8)
					$display("[%0t] STALE ADDR: used %h, CPU wants %h (a=%h ram_en=%b)",
						$time, dut.cpu_addr_held, dut.cpu_addr,
						dut.cpu_a, dut.ram_enable);
			end
		end
	end
	initial begin
		#1_400_000;
		$display("CPU cycles on the right address: %0d, stale: %0d",
			addr_ok, addr_stale);
	end

	// Diagnostic: how often a DivMMC SPI port access starts while
	// spi.v's engine is still shifting a previous byte - the trigger
	// for the drop believed to be why ESXDOS fails above 3.5MHz.
	// Watches spi_acc/spi_acc_d/mi_spi.counter directly, so this reads
	// the same whichever divmmc.v/spi.v is compiled in - pre-fix it
	// shows what spi.v's old idle-only gate would have discarded, on
	// the fixed design it should always read zero because wait_n
	// never lets a second access start early enough to see it.
	integer spi_accesses = 0;
	integer spi_would_drop = 0;
	always @(posedge dut.clock) begin
		if (dut.dmmc.spi_acc && !dut.dmmc.spi_acc_d) begin
			spi_accesses <= spi_accesses + 1;
			if (dut.dmmc.mi_spi.counter != 5'd16)
				spi_would_drop <= spi_would_drop + 1;
		end
	end
	initial begin
		#1_450_000;
		$display("DivMMC SPI: %0d port accesses, %0d landed on a busy engine",
			spi_accesses, spi_would_drop);
	end

	// Bus contention: the chip driving read data while the design is
	// driving write data. sdram_ep4ce.v holds sd_data driven for as long
	// as `we` is asserted, and a read issued in the previous cycle is
	// still coming back at the start of this one. The functional model
	// resolves the clash silently; a real part and a real FPGA fight
	// over the wire, which is the kind of fault that scales with bus
	// traffic and never shows up in simulation.
	integer dq_clash = 0;
	always @(posedge dut.clk56) begin
		if (dut.reset_n === 1'b1 && chip.rd_valid[3] === 1'b1
		    && dut.sdr.we === 1'b1) begin
			dq_clash = dq_clash + 1;
			if (dq_clash <= 5)
				$display("[%0t] DQ CONTENTION: chip driving read data while we=1",
					$time);
		end
	end
	initial begin
		#1_450_000;
		$display("SDRAM DQ contention clocks: %0d", dq_clash);
	end

	// Did every CPU write to RAM actually land, at the right address,
	// with the right data? All the other checks here watch reads - the
	// DivMMC ROM fetches and the video bytes - and the workload runs
	// almost entirely out of ROM, so the write path was barely covered.
	// "Large files fail, small ones work" on the board is the signature
	// of writes going missing at a low rate.
	//
	// Expected byte address is built from the CPU's own address and the
	// live page register, not from ram_addr, so a fault in the ram_addr
	// pipeline shows up as a mismatch rather than being assumed away.
	integer wr_ok = 0, wr_bad = 0;
	reg [19:0] wr_addr;
	reg [7:0]  wr_data;
	reg        wr_pending = 1'b0;
	reg [4:0]  wr_wait = 5'd0;
	reg        prev_mreq_w = 1'b1;
	always @(posedge dut.clock) begin
		if (dut.reset_n === 1'b1) begin
			if (!dut.cpu_mreq_n && !dut.cpu_wr_n && dut.ram_enable) begin
				wr_addr    <= {3'b000, dut.ram_page, dut.cpu_a[13:0]};
				wr_data    <= dut.cpu_do;
				wr_pending <= 1'b1;
			end
			// Wait for the SDRAM cycle to finish before looking.
			//
			// This used to compare the instant MREQ went high. A cycle
			// is eight 56MHz clocks - four of these - so at 3.5 MHz the
			// CPU holds MREQ long enough for the write to land first,
			// and above 7 MHz it does not. The checker then read the
			// location while the write was still in flight and called
			// every one of them lost. Traced on the board's own symptom
			// and found to be the instrument, not the design: the
			// arbiter had granted the cycle and latched address and
			// write flag correctly one clock earlier.
			if (dut.cpu_mreq_n && !prev_mreq_w && wr_pending)
				wr_wait <= 5'd16;
			else if (wr_wait != 5'd0)
				wr_wait <= wr_wait - 5'd1;
			if (wr_wait == 5'd1 && wr_pending) begin
				wr_pending <= 1'b0;
				if (peek(wr_addr) === wr_data)
					wr_ok = wr_ok + 1;
				else begin
					wr_bad = wr_bad + 1;
					if (wr_bad <= 10)
						$display("[%0t] LOST WRITE addr=%05h wrote=%02h found=%02h",
							$time, wr_addr, wr_data, peek(wr_addr));
				end
			end
			prev_mreq_w <= dut.cpu_mreq_n;
		end
	end
	// The same question asked without any timing in it. The checker above
	// settles for 16 clocks before it looks, and at 28MHz the CPU issues
	// a write about every 17 clocks - so the next write overwrites
	// wr_addr/wr_data while the previous check is still counting down,
	// and what it finally compares is a mixture of two accesses. That is
	// the same class of fault as the one this checker was already fixed
	// for once ("called every turbo write lost"), so its turbo verdict
	// cannot be trusted either way.
	//
	// Instead: remember every byte the CPU wrote, and compare the
	// finished memory against that list at the end of the run. A write
	// that never reached the chip shows up here and nothing else does.
	// Each address in ramtest.hex is written exactly once, so the last
	// value written is what memory must hold.
	integer wl_n = 0;
	reg [19:0] wl_addr [0:8191];
	reg [7:0]  wl_data [0:8191];
	reg        wr_cyc_d = 1'b0;
	always @(posedge dut.clock) begin
		if (dut.reset_n === 1'b1) begin
			// One entry per write cycle, on its leading edge.
			if (!dut.cpu_mreq_n && !dut.cpu_wr_n && dut.ram_enable
			    && !wr_cyc_d && wl_n < 8192) begin
				wl_addr[wl_n] = {3'b000, dut.ram_page, dut.cpu_a[13:0]};
				wl_data[wl_n] = dut.cpu_do;
				wl_n = wl_n + 1;
			end
			wr_cyc_d <= (!dut.cpu_mreq_n && !dut.cpu_wr_n && dut.ram_enable);
		end
	end

	initial begin
		#1_450_000;
		// Reported for continuity with older runs, but do not believe its
		// verdict above 7MHz - see the note on the timed checker above.
		// Measured at 28MHz it called 334 of 335 writes lost while every
		// one of them was in fact present in memory. The FINAL MEMORY
		// CHECK below is the one to read.
		$display("CPU RAM writes (timed, unreliable >7MHz): %0d landed, %0d lost",
			wr_ok, wr_bad);
		begin : final_write_check
			integer wi, wgood, wmiss;
			wgood = 0; wmiss = 0;
			for (wi = 0; wi < wl_n; wi = wi + 1) begin
				if (peek(wl_addr[wi]) === wl_data[wi])
					wgood = wgood + 1;
				else begin
					wmiss = wmiss + 1;
					if (wmiss <= 8)
						$display("  MISSING addr=%05h wrote=%02h memory holds=%02h",
							wl_addr[wi], wl_data[wi], peek(wl_addr[wi]));
				end
			end
			$display("FINAL MEMORY CHECK: %0d of %0d CPU writes are present, %0d missing",
				wgood, wl_n, wmiss);
		end
	end

	// Is the CPU clock enable ever unknown? It comes from a free-running
	// counter, so its count should not change between builds at all.
	integer ck1 = 0, ck0 = 0, ckx = 0;
	always @(posedge dut.clock) begin
		if (dut.reset_n === 1'b1) begin
			if (dut.cpu_clken === 1'b1)      ck1 = ck1 + 1;
			else if (dut.cpu_clken === 1'b0) ck0 = ck0 + 1;
			else                             ckx = ckx + 1;
		end
	end
	initial begin
		#1_450_000;
		$display("cpu_clken: %0d high, %0d low, %0d unknown", ck1, ck0, ckx);
	end

	// 128K paging check, driven by pagetest.hex: page bank 1 at 0xC000
	// and write 0x11, page bank 2 and write 0x22, page bank 1 back and
	// read. Banked RAM lives at page*16384, so bank 1 is byte 16384 and
	// bank 2 is byte 32768. The read-back result is stored at 0x9000,
	// which is in bank 2 (0x8000-0xBFFF) at offset 0x1000 -> 36864.
	initial begin
		#1_400_000;
		$display("PAGING: bank1[0]=%02h (want 11)  bank2[0]=%02h (want 22)  readback=%02h (want 11)",
			peek(16384), peek(32768), peek(36864));
		$display("PAGING: page register pram_sel=%0d mem128=%b",
			dut.pram_sel, dut.mem128);
	end


// --- temporary: geometry behind the interrupt position ---
integer gshow=0;
reg gpic_d=1'b0;
// Machine set at time zero, not at 200us. It used to be forced late, and
// since spectrum_top defaults to MACHINE_PENT - which has no contention
// at all - the first three lines of every run came out with contention
// silently disabled. That looked exactly like a defect in the window and
// was chased twice as one.
initial force dut.machine = 2'd0;
always @(posedge dut.clock) if (dut.vid.CLKEN) begin
  if (dut.vid.picture && !gpic_d && gshow<3 && $time>400000) begin
    $display("GEOM pic starts at h=%0d on line %0d", dut.vid.hcounter, dut.vid.vcounter/2);
    $display("GEOM int_line=%0d int_hpos=%0d hcount_last=%0d int_len=%0d",
             dut.vid.int_line, dut.vid.int_hpos, dut.vid.hcount_last, dut.vid.int_len);
    $display("GEOM vline_last=%0d vpic_lines_end=%0d", dut.vid.vline_last, 384);
    gshow=gshow+1;
  end
  gpic_d <= dut.vid.picture;
end


	// Two bytes to a word: the modelled chip is addressed by word, the
	// design by byte, so every poke and peek here goes through the same
	// split the controller does. Getting this wrong reads a neighbour's
	// byte, which looks exactly like corruption.
	task poke(input [24:0] byte_addr, input [7:0] data);
	begin
		if (byte_addr[0]) chip.mem[byte_addr[24:1]][15:8] = data;
		else              chip.mem[byte_addr[24:1]][7:0]  = data;
	end
	endtask

	function [7:0] peek(input [24:0] byte_addr);
	begin
		peek = byte_addr[0] ? chip.mem[byte_addr[24:1]][15:8]
		                    : chip.mem[byte_addr[24:1]][7:0];
	end
	endfunction

endmodule
