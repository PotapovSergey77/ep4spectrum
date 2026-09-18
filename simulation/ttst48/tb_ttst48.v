// tb_ttst48 - Richard Chandler's ttst48 timing tests, run as they run on
// the board
//
// Copyright (c) 2026 Sergey Potapov (potapov.sergey.77@gmail.com)
//
// A 48K reduced to what timing depends on: the real clocks.v, video.v,
// T80se and ula_port, with the contention block lifted verbatim out of
// ep4spectrum.v by gen.py, and a zero-wait behavioural 64K memory. No
// SDRAM, no PLL models, no scandoubler - a frame takes about ten seconds
// here where tb_top takes hours.
//
// The test's own measuring code runs from $C053 with the test copied to
// $5B00, exactly as the tape does it after its ROM-calculator preamble;
// the interrupt handler's R, loop count and interrupted PC are printed
// and run.sh compares them with the table inside the tape.
//
// Validated against the board: with the design as it stood at 1272d77
// this bench gave the same (wrong) R/loop/sp as the photographs of the
// real machine, figure for figure, on tests 17, 18, 21-25 and 30-33.
// That only held once reset_n was released on a CPU enable, as
// ep4spectrum.v releases it: the video counters start with reset_n, and
// releasing it at an arbitrary clock shifts them a fraction of a T-state
// against the CPU, which moved several results by one instruction.
`timescale 1ns / 1ps
module tb_ttst48;
	reg clock = 1'b0;
	always #17.857 clock = ~clock;
	reg reset_n = 1'b0;
	reg pll_locked = 1'b0;

	localparam MACHINE_S48  = 2'd0;
	localparam MACHINE_S128 = 2'd1;
	localparam MACHINE_S3   = 2'd2;
	localparam MACHINE_PENT = 2'd3;
	wire [1:0] machine = MACHINE_S48;
	wire [5:0] page_ram_sel = 6'd0;
	reg  [1:0] cont_model = 2'd1;
	wire [1:0] cpu_speed = 2'd0;

	wire cpu_clken, vid_clken, cpu_clken_gated;
	wire [15:0] cpu_a;
	wire [7:0] cpu_di, cpu_do;
	wire cpu_m1_n, cpu_mreq_n, cpu_ioreq_n, cpu_rd_n, cpu_wr_n, cpu_rfsh_n;
	wire [2:0] cpu_mc, cpu_ts;
	wire cpu_io_cyc, cpu_idle_cyc;
	wire vid_contention, vid_contention_io, vid_contention_io_next;
	wire vid_irq_n;
	reg  int_on = 1'b0;
	integer iv;
	initial int_on = 1'b1;

	clocks clken (
		.CLK(clock), .nRESET(pll_locked), .MREQ(~cpu_mreq_n | ~cpu_ioreq_n),
		.SPEED(cpu_speed), .CLKEN_PSG(), .CLKEN_CPU(cpu_clken), .CLKEN_MEM(),
		.CLKEN_DIO(), .CLKEN_VID(vid_clken), .VID_MEM_SYNC(), .CLK_REF(),
		.CLKEN_SLOT()
	);

	T80se #(.T2Write(1)) cpu (
		.RESET_n(reset_n), .CLK_n(clock), .CLKEN(cpu_clken_gated),
		.WAIT_n(1'b1), .INT_n(int_on ? vid_irq_n : 1'b1), .NMI_n(1'b1),
		.BUSRQ_n(1'b1), .M1_n(cpu_m1_n), .MREQ_n(cpu_mreq_n),
		.IORQ_n(cpu_ioreq_n), .RD_n(cpu_rd_n), .WR_n(cpu_wr_n),
		.RFSH_n(cpu_rfsh_n), .HALT_n(), .BUSAK_n(), .A(cpu_a),
		.DI(cpu_di), .DO(cpu_do), .MC(cpu_mc), .TS(cpu_ts),
		.IO_CYC(cpu_io_cyc), .IDLE_CYC(cpu_idle_cyc)
	);

`include "cont_block.vh"

	assign cpu_clken_gated = cpu_clken & ~contention;

	wire ula_enable = ~cpu_ioreq_n & cpu_m1_n & ~cpu_a[0];
	wire [2:0] ula_border;
	wire [7:0] ula_do;
	ula_port ula (
		.CLK(clock), .nRESET(reset_n), .D_IN(cpu_do), .D_OUT(ula_do),
		.ENABLE(ula_enable & ~ula_io_held), .nWR(cpu_wr_n),
		.BORDER_OUT(ula_border), .EAR_OUT(), .MIC_OUT(),
		.KEYB_IN(5'h1F), .EAR_IN(1'b0)
	);

	video vid (
		.CLK(clock), .CLKEN(vid_clken), .MEM_CYC(1'b0), .nRESET(reset_n),
		.VGA(1'b0), .MACHINE(machine),
		.CONTENTION(vid_contention), .CONTENTION_IO(vid_contention_io),
		.CONTENTION_IO_NEXT(vid_contention_io_next),
		.INT_ADJ(12'd0), .INT_VADJ(8'd0), .CONT_ADJ(5'd0), .IO_ADJ(8'd0),
		.BORD_PHASE(4'd5), .BORD_DELAY(2'd2),
		.OSD_SPEED(2'd0), .OSD_EXT(1'b0), .OSD_POKE(1'b0), .OSD_ACTIVE(),
		.PORT_FF_ACTIVE(), .PORT_FF_DATA(),
		.VID_A(), .VID_D_IN(8'h00), .nVID_RD(), .nWAIT(),
		.VID_REQ_STEP(), .VID_REQ_GEN(), .VID_STALE(),
		.VID_REQ_ACK(1'b0), .VID_DATA_VALID(1'b0),
		.VID_DATA_STEP(1'b0), .VID_DATA_GEN(1'b0),
		.BORDER_IN(ula_border), .SCR_WR(1'b0), .SCR_A(13'd0), .SCR_D(8'd0),
		.FWD_HIT(),
		.R(), .G(), .B(),
		.nVSYNC(), .nHSYNC(), .nCSYNC(), .nHCSYNC(), .SCANLINE(),
		.nIRQ(vid_irq_n)
	);

	// Memory: zero wait, the byte answers combinationally from the
	// address; ROM below $4000 is not writable.
	reg [7:0] mem [0:65535];
	initial $readmemh("mem.hex", mem);
	assign cpu_di = (~cpu_ioreq_n) ? 8'hFF : mem[cpu_a];
	always @(posedge clock)
		if (cpu_clken_gated && ~cpu_mreq_n && ~cpu_wr_n && cpu_a[15:14] != 2'b00)
			mem[cpu_a] <= cpu_do;

	// Stop when the handler stores the interrupted PC: LD ($EF03),HL
	// writes $EF04 last.
	integer n0 = 0;
	always @(posedge clock)
		if (cpu_clken_gated && ~cpu_mreq_n && ~cpu_wr_n && cpu_a == 16'hEF04) begin
			#1;
			$display("RESULT R=%0d loop=%0d sp=%0d", mem[16'hEF00],
				{mem[16'hEF02], mem[16'hEF01]}, {mem[16'hEF04], mem[16'hEF03]});
			$finish;
		end
	// Flag an IM1 interrupt taken through the ROM, which this harness
	// cannot model faithfully (no BASIC state behind it).
	always @(posedge clock)
		if (cpu_clken && ~cpu_m1_n && ~cpu_mreq_n && cpu_a == 16'h0038 && n0 == 0) begin
			n0 = 1; $display("NOTE: IM1 handler entered at $0038");
		end

	initial begin
		#100 pll_locked = 1'b1;
		#2000;
		// Released on a CPU enable, as ep4spectrum.v releases it: the
		// video counters start with reset_n, so this fixes their phase
		// against the CPU's T-states.
		@(posedge clock); while (cpu_clken !== 1'b1) @(posedge clock);
		reset_n <= 1'b1;
	end
endmodule
