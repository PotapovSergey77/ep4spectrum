// Copyright (c) 2026 Sergey Potapov (potapov.sergey.77@gmail.com)
//
// tb_sdram.v
//
// Focused testbench for the one path that has never been simulated:
// getting the ESXDOS image into SDRAM and reading it back out again.
// tb_esxdos.v deliberately replaced memory with a behavioral array, so
// sdram_ep4ce.v's command sequencing and spectrum_top.v's pacing of it
// were only ever exercised on the board itself - where the image comes
// back corrupt (0xF3 at offset 0 reads back as 0x01/0x00).
//
// This replicates clocks.v, sdram_ep4ce.v, the boot-copy state machine
// and the SDRAM arbitration mux exactly as spectrum_top.v has them, so
// whatever is wrong there shows up here and can be iterated on in
// seconds instead of a rebuild-and-reflash cycle.

`timescale 1ns/1ps

module tb_sdram;

	// Two clock domains, exactly as spectrum_top.v has them: the SDRAM
	// controller runs on clk56, while clocks.v and all the top-level
	// logic run on `clock`, which is clk56 divided by two (28MHz). That
	// 2:1 relationship is what makes clkref (clocks.v counter[1], so
	// 28/4) come out at 7MHz and line up with the controller's 8-state
	// q cycle (56/8, also 7MHz). Driving clocks.v at 56MHz instead - as
	// an earlier version of this testbench did - doubles clkref and
	// throws the whole phase relationship out.
	reg clk56 = 0;
	always #8.928 clk56 = ~clk56;   // 56MHz

	reg clock = 0;
	always @(posedge clk56) clock <= ~clock;   // 28MHz

	reg pll_locked = 0;
	initial begin
		repeat (13) @(posedge clock);
		pll_locked = 1;
	end

	// ------------------------------------------------------------
	// clock enables - real clocks.v
	// ------------------------------------------------------------
	wire psg_clken, cpu_clken, mem_clken, dio_clken, vid_clken;
	wire vid_mem_sync, clk_ref;

	clocks clken (
		.CLK(clock),
		.nRESET(pll_locked),
		.MREQ(1'b0),
		.CLKEN_PSG(psg_clken),
		.CLKEN_CPU(cpu_clken),
		.CLKEN_MEM(mem_clken),
		.CLKEN_DIO(dio_clken),
		.CLKEN_VID(vid_clken),
		.VID_MEM_SYNC(vid_mem_sync),
		.CLK_REF(clk_ref)
	);

	// ------------------------------------------------------------
	// cpu_cycle, exactly as spectrum_top.v derives it
	// ------------------------------------------------------------
	reg cpu_cycle;
	always @(posedge clock) begin
		if (vid_clken == 1'b1)
			cpu_cycle <= mem_clken;
	end

	// ------------------------------------------------------------
	// behavioral stand-in for rom_esxdos (altsyncram): one clock of
	// read latency, same as the real block ROM
	// ------------------------------------------------------------
	reg [7:0] esxrom [0:8191];
	initial $readmemh("esxmmc_plain.hex", esxrom);

	reg [12:0] rom_addr_r;
	reg [7:0]  boot_copy_rom_do;
	always @(posedge clock) begin
		boot_copy_rom_do <= esxrom[rom_addr_r];
	end

	// ------------------------------------------------------------
	// boot copy state machine (mirrors spectrum_top.v)
	// ------------------------------------------------------------
	reg  [9:0] boot_settle_cnt;
	reg        boot_settle_done;
	always @(posedge clock) begin
		if (pll_locked == 1'b0) begin
			boot_settle_cnt  <= 10'd0;
			boot_settle_done <= 1'b0;
		end else if (boot_settle_done == 1'b0) begin
			if (boot_settle_cnt == 10'd1023)
				boot_settle_done <= 1'b1;
			else
				boot_settle_cnt <= boot_settle_cnt + 10'd1;
		end
	end

	reg         boot_copy_active;
	reg  [14:0] boot_copy_addr;
	reg         boot_prev_cpu_cycle;

	wire        boot_copy_wr = boot_copy_active & boot_settle_done & cpu_cycle;

	always @(posedge clock) begin
		if (pll_locked == 1'b0) begin
			boot_copy_active    <= 1'b1;
			boot_copy_addr      <= 15'd0;
			boot_prev_cpu_cycle <= 1'b0;
		end else begin
			boot_prev_cpu_cycle <= cpu_cycle;
			if (boot_prev_cpu_cycle == 1'b1 && cpu_cycle == 1'b0
			    && boot_copy_active == 1'b1 && boot_settle_done == 1'b1) begin
				if (boot_copy_addr == 15'd16383)
					boot_copy_active <= 1'b0;
				else
					boot_copy_addr <= boot_copy_addr + 15'd1;
			end
		end
	end

	// ------------------------------------------------------------
	// readback verify (mirrors the hardware diagnostic)
	// ------------------------------------------------------------
	wire [7:0]  sdram_do;

	reg         verify_active;
	reg  [13:0] verify_addr;
	reg  [13:0] verify_raddr;
	reg         verify_primed;
	reg  [15:0] verify_bad;
	reg  [7:0]  verify_byte;
	reg         verify_done;

	always @(posedge clock) begin
		if (pll_locked == 1'b0) begin
			verify_active <= 1'b0;
			verify_addr   <= 14'd0;
			verify_raddr  <= 14'd0;
			verify_primed <= 1'b0;
			verify_bad    <= 16'd0;
			verify_done   <= 1'b0;
		end else if (boot_copy_active == 1'b0 && verify_done == 1'b0) begin
			verify_active <= 1'b1;
			// Each address is held for two slots: presented in the first,
			// compared at the end of the second. The address is constant
			// across both, so the byte latched at that point is
			// unambiguously the one for verify_addr - no pipeline
			// bookkeeping to get wrong.
			if (boot_prev_cpu_cycle == 1'b1 && cpu_cycle == 1'b0) begin
				if (verify_primed == 1'b0) begin
					verify_primed <= 1'b1;
				end else begin
					verify_primed <= 1'b0;
					if (verify_byte !== esxrom[verify_addr[12:0]]) begin
						verify_bad <= verify_bad + 16'd1;
						if (verify_bad < 16'd8)
							$display("  MISMATCH at %04h: sdram=%02h expected=%02h",
								verify_addr, verify_byte, esxrom[verify_addr[12:0]]);
					end
					if (verify_addr == 14'd8191) begin
						verify_done   <= 1'b1;
						verify_active <= 1'b0;
					end else begin
						verify_addr <= verify_addr + 14'd1;
					end
				end
			end
		end
	end

	// latch read data the same instant spectrum_top.v latches mem_do
	always @(negedge cpu_cycle) begin
		verify_byte <= sdram_do;
	end

	// rom address mux, as in spectrum_top.v
	always @* begin
		if (boot_copy_active)
			rom_addr_r = boot_copy_addr[12:0];
		else
			rom_addr_r = verify_addr[12:0];
	end

	// ------------------------------------------------------------
	// SDRAM arbitration mux (mirrors spectrum_top.v)
	// ------------------------------------------------------------
	reg [24:0] sdram_addr;
	reg        sdram_we;
	reg        sdram_oe;
	reg [7:0]  sdram_di;

	always @* begin
		if (boot_copy_wr == 1'b1) begin
			sdram_oe = 1'b0;
			sdram_we = 1'b1;
			sdram_di = boot_copy_rom_do;
			sdram_addr = boot_copy_addr[13] ?
				{4'b0000, 2'b11, 6'b010011, boot_copy_addr[12:0]} :
				{4'b0000, 2'b11, 6'b000000, boot_copy_addr[12:0]};
		end else if (verify_active == 1'b1) begin
			sdram_oe = cpu_cycle;
			sdram_we = 1'b0;
			sdram_di = 8'h00;
			sdram_addr = {4'b0000, 2'b11, 6'b000000, verify_addr[12:0]};
		end else begin
			sdram_oe = 1'b0;
			sdram_we = 1'b0;
			sdram_di = 8'h00;
			sdram_addr = 25'd0;
		end
	end

	// ------------------------------------------------------------
	// SDRAM controller + model
	// ------------------------------------------------------------
	wire [15:0] SDRAM_DQ;
	wire [11:0] SDRAM_A;
	wire [1:0]  SDRAM_BA;
	wire [1:0]  sdram_dqm;
	wire        SDRAM_nCS, SDRAM_nWE, SDRAM_nRAS, SDRAM_nCAS;

	sdram_ep4ce sdr (
		.sd_data(SDRAM_DQ),
		.sd_addr(SDRAM_A),
		.sd_dqm(sdram_dqm),
		.sd_ba(SDRAM_BA),
		.sd_cs(SDRAM_nCS),
		.sd_we(SDRAM_nWE),
		.sd_ras(SDRAM_nRAS),
		.sd_cas(SDRAM_nCAS),

		.clk(clk56),
		.clkref(clk_ref),
		.init(~pll_locked),

		.din(sdram_di),
		.dout(sdram_do),
		.addr(sdram_addr),
		.we(sdram_we),
		.oe(sdram_oe)
	);

	sdram_model chip (
		.sd_data(SDRAM_DQ),
		.sd_addr(SDRAM_A),
		.sd_dqm(sdram_dqm),
		.sd_ba(SDRAM_BA),
		.sd_cs(SDRAM_nCS),
		.sd_we(SDRAM_nWE),
		.sd_ras(SDRAM_nRAS),
		.sd_cas(SDRAM_nCAS),
		.clk(clk56)
	);

	// ------------------------------------------------------------
	// report
	// ------------------------------------------------------------
	reg reported = 0;
	always @(posedge clock) begin
		if (verify_done == 1'b1 && reported == 1'b0) begin
			reported <= 1'b1;
			$display("=====================================================");
			$display("copy+readback finished: %0d mismatches out of 8192",
				verify_bad);
			$display("  sdram model saw %0d writes, %0d reads",
				chip.writes_seen, chip.reads_seen);
			$display("  mem[0x180000]=%02h (expect f3)  mem[0x180001]=%02h (expect 31)",
				chip.mem[22'h180000][7:0], chip.mem[22'h180001][7:0]);
			$display("=====================================================");
			$finish;
		end
	end

	// debug: watch the controller's internal sequencing for a short window
	// once the copy is actually running
	integer dbg = 0;
	always @(posedge clock) begin
		if (boot_settle_done && dbg < 40) begin
			dbg = dbg + 1;
			$display("t=%0t q=%0d reset=%0d clkref=%b cpu_cycle=%b we=%b oe=%b cmd=%b%b%b%b addr=%05h",
				$time, sdr.q, sdr.reset, clk_ref, cpu_cycle, sdram_we, sdram_oe,
				SDRAM_nCS, SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE, sdram_addr[19:0]);
		end
	end

	initial begin
		#50_000_000;   // 50ms safety net
		$display("TIMEOUT - copy/verify never completed");
		$display("  boot_copy_active=%b boot_copy_addr=%0d verify_addr=%0d",
			boot_copy_active, boot_copy_addr, verify_addr);
		$display("  sdram model saw %0d writes, %0d reads",
			chip.writes_seen, chip.reads_seen);
		$finish;
	end

endmodule
