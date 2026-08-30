// tb_intt - what accepting an interrupt costs
//
// Copyright (c) 2026 Sergey Potapov (potapov.sergey.77@gmail.com)
//
// BBG128 on a 128K reaches the address the interrupt returns to at
// T-state 970 here and 983 in FUSE - thirteen T-states early, and
// thirteen is exactly what a Z80 spends accepting an interrupt in mode
// 1: the acknowledge M1 stretched to seven, then two stack writes of
// three each. Nothing else lies between the interrupt and that address
// but the ROM handler, which is the real one, and the top border, where
// neither machine contends.
//
// So this counts it. The CPU sits in a NOP loop, INT goes low, and the
// gap between the last opcode fetch before the acknowledge and the
// first fetch at $0038 is the cost. A real Z80 spends 13; the fetch at
// $0038 then takes its own 4 on top.

`timescale 1ns / 1ps

module tb_intt;

	reg clk = 1'b0;
	always #10 clk = ~clk;
	reg nreset = 1'b0;
	reg int_n  = 1'b1;

	wire [15:0] a;
	wire  [7:0] dout;
	reg   [7:0] din;
	wire m1_n, mreq_n, iorq_n, rd_n, wr_n;

	T80se cpu (
		.RESET_n(nreset), .CLK_n(clk), .CLKEN(1'b1), .WAIT_n(1'b1),
		.INT_n(int_n), .NMI_n(1'b1), .BUSRQ_n(1'b1),
		.M1_n(m1_n), .MREQ_n(mreq_n), .IORQ_n(iorq_n),
		.RD_n(rd_n), .WR_n(wr_n), .RFSH_n(), .HALT_n(), .BUSAK_n(),
		.A(a), .DI(din), .DO(dout)
	);

	// $0000-$00FF is the "ROM": NOPs, a loop at $0010, and a marker at
	// $0038 that just parks. $FF00 up is stack.
	reg [7:0] mem [0:65535];
	always @* din = mem[a];
	always @(posedge clk)
		if (nreset && mreq_n == 1'b0 && wr_n == 1'b0)
			mem[a] <= dout;

	integer  tick = 0;
	integer  prev = 0;
	integer  n = 0;
	reg      m1_d = 1'b1;
	reg [15:0] prev_a = 16'h0000;
	reg      seen38 = 1'b0;

	always @(posedge clk) if (nreset) begin
		tick = tick + 1;
		if (m1_d == 1'b1 && m1_n == 1'b0) begin
			if (n > 0)
				$display("  $%04h: %0d T", prev_a, tick - prev);
			prev   = tick;
			prev_a = a;
			n      = n + 1;
			if (a == 16'h0038) seen38 = 1'b1;
			if (n > 16) begin
				$display("DONE");
				$finish;
			end
		end
		m1_d <= m1_n;
	end

	integer i;
	initial begin
		for (i = 0; i < 65536; i = i + 1) mem[i] = 8'h00;
		mem[16'h0000] = 8'hF3;                       // DI
		mem[16'h0001] = 8'h31; mem[16'h0002] = 8'h00;
		mem[16'h0003] = 8'hFF;                       // LD SP,$FF00
		mem[16'h0004] = 8'hED; mem[16'h0005] = 8'h56; // IM 1
		mem[16'h0006] = 8'hFB;                       // EI
		mem[16'h0007] = 8'h00;                       // NOP
		mem[16'h0008] = 8'h18; mem[16'h0009] = 8'hFD; // JR $0007
		mem[16'h0038] = 8'h18; mem[16'h0039] = 8'hFE; // park at the handler

		nreset = 1'b0;
		repeat (4) @(posedge clk);
		nreset = 1'b1;
		// Well clear of the EI, so the loop is settled when it arrives.
		repeat (60) @(posedge clk);
		int_n = 1'b0;
	end

	initial begin
		#200000;
		$display("TIMED OUT");
		$finish;
	end

endmodule
