// tb_outt - how many T-states our OUT instructions actually take
//
// Copyright (c) 2026 Sergey Potapov (potapov.sergey.77@gmail.com)
//
// esh2_48 paints its border with a counted run of ED 71 - OUT (C),0,
// the undocumented one - and the eight-pixel dash it shows on the first
// raster line sits exactly where that run ends. Eight pixels is four
// T-states. A run of instructions each a T-state out would accumulate
// exactly like that and show at the end of the run, so the length of
// these instructions is worth knowing rather than assuming.
//
// A real Z80:
//
//   OUT (n),A     11 T   4 fetch + 3 operand + 4 IO
//   OUT (C),r     12 T   4 prefix + 4 opcode + 4 IO
//   OUT (C),0     12 T   the same instruction with a different source
//   NOP            4 T
//
// The IO cycle is four T-states because the Z80 inserts one wait state
// of its own; a core that adds a second, or none, is a T-state out.
//
// Measured between M1 fetches: the count from one opcode fetch to the
// next is the length of the instruction that started at the first.

`timescale 1ns / 1ps

module tb_outt;

	reg clk = 1'b0;
	always #10 clk = ~clk;
	reg nreset = 1'b0;

	wire [15:0] a;
	wire  [7:0] dout;
	reg   [7:0] din;
	wire m1_n, mreq_n, iorq_n, rd_n, wr_n;

	T80se cpu (
		.RESET_n(nreset), .CLK_n(clk), .CLKEN(1'b1), .WAIT_n(1'b1),
		.INT_n(1'b1), .NMI_n(1'b1), .BUSRQ_n(1'b1),
		.M1_n(m1_n), .MREQ_n(mreq_n), .IORQ_n(iorq_n),
		.RD_n(rd_n), .WR_n(wr_n), .RFSH_n(), .HALT_n(), .BUSAK_n(),
		.A(a), .DI(din), .DO(dout)
	);

	reg [7:0] mem [0:255];
	always @* din = mem[a[7:0]];
	always @(posedge clk)
		if (nreset && mreq_n == 1'b0 && wr_n == 1'b0)
			mem[a[7:0]] <= dout;

	// Count every clock while running, and report the gap between one
	// M1 and the next along with what was fetched.
	integer  tick = 0;
	integer  prev = 0;
	integer  n = 0;
	reg      m1_d = 1'b1;
	reg [15:0] prev_a = 16'h0000;

	always @(posedge clk) if (nreset) begin
		tick = tick + 1;
		if (m1_d == 1'b1 && m1_n == 1'b0) begin
			if (n > 0)
				$display("  $%04h: %0d T", prev_a, tick - prev);
			prev   = tick;
			prev_a = a;
			n      = n + 1;
			if (n > 24) begin
				$display("DONE");
				$finish;
			end
		end
		m1_d <= m1_n;
	end

	integer i;
	initial begin
		for (i = 0; i < 256; i = i + 1) mem[i] = 8'h00;
		i = 0;
		mem[i]=8'hF3; i=i+1;                          // DI
		mem[i]=8'h01; i=i+1; mem[i]=8'hFE; i=i+1; mem[i]=8'h00; i=i+1; // LD BC,$00FE
		mem[i]=8'h3E; i=i+1; mem[i]=8'h07; i=i+1;     // LD A,$07
		// The three shapes esh2_48 uses, each followed by a NOP so the
		// reading for the NOP confirms the measure itself.
		mem[i]=8'hED; i=i+1; mem[i]=8'h71; i=i+1;     // OUT (C),0
		mem[i]=8'h00; i=i+1;                          // NOP
		mem[i]=8'hED; i=i+1; mem[i]=8'h41; i=i+1;     // OUT (C),B
		mem[i]=8'h00; i=i+1;                          // NOP
		mem[i]=8'hED; i=i+1; mem[i]=8'h79; i=i+1;     // OUT (C),A
		mem[i]=8'h00; i=i+1;                          // NOP
		mem[i]=8'hD3; i=i+1; mem[i]=8'hFE; i=i+1;     // OUT ($FE),A
		mem[i]=8'h00; i=i+1;                          // NOP
		mem[i]=8'hED; i=i+1; mem[i]=8'h71; i=i+1;     // OUT (C),0
		mem[i]=8'hED; i=i+1; mem[i]=8'h71; i=i+1;     // OUT (C),0
		mem[i]=8'h18; i=i+1; mem[i]=8'hFE;            // JR -2, park

		nreset = 1'b0;
		repeat (4) @(posedge clk);
		nreset = 1'b1;
	end

	initial begin
		#200000;
		$display("TIMED OUT");
		$finish;
	end

endmodule
