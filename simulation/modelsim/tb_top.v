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
	integer k;
	initial begin
		$readmemh("esxmmc_plain.hex", esxinit);
		for (k = 0; k < 8192; k = k + 1) begin
			chip.mem[22'h180000 + k] = {esxinit[k], esxinit[k]};
			chip.mem[22'h1A6000 + k] = {esxinit[k], esxinit[k]};
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
	initial $readmemh("esxmmc_plain.hex", esxrom);

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
		#1_500_000;    // 1.5ms
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
		$display("=====================================================");
		$display("SIMULATION DONE");
		$finish;
	end

endmodule
