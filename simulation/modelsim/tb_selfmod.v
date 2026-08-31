// tb_selfmod - does a repeating instruction re-fetch its own opcode
//
// Copyright (c) 2026 Sergey Potapov (potapov.sergey.77@gmail.com)
//
// z80full's last four - LDIR->NOP' and its three companions - point DE
// at the second byte of the LDIR itself. The first pass writes a zero
// there, turning ED B0 into ED 00, and a Z80 going round the repeat
// does PC -= 2 and fetches the byte again: it sees the NOP and stops
// copying. One write, not four.
//
// This asks the core the question with a plain memory model, so the
// answer is about the CPU and not about SDRAM latency.

`timescale 1ns / 1ps

module tb_selfmod;

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
		.A(a), .DI(din), .DO(dout), .MC(), .TS(), .IO_CYC()
	);

	reg [7:0] mem [0:255];
	always @* din = mem[a[7:0]];

	integer writes = 0;
	always @(posedge clk)
		if (nreset && mreq_n == 1'b0 && wr_n == 1'b0) begin
			mem[a[7:0]] <= dout;
			$display("  write %02h to %04h", dout, a);
			writes = writes + 1;
		end

	integer i;
	initial begin
		for (i = 0; i < 256; i = i + 1) mem[i] = 8'h00;
		mem[8'h00] = 8'hF3;                                   // DI
		mem[8'h01] = 8'h21; mem[8'h02] = 8'h20; mem[8'h03] = 8'h00; // LD HL,$0020
		mem[8'h04] = 8'h11; mem[8'h05] = 8'h0B; mem[8'h06] = 8'h00; // LD DE,$000B
		mem[8'h07] = 8'h01; mem[8'h08] = 8'h04; mem[8'h09] = 8'h00; // LD BC,$0004
		mem[8'h0A] = 8'hED; mem[8'h0B] = 8'hB0;               // LDIR - opcode at $0B
		mem[8'h0C] = 8'h18; mem[8'h0D] = 8'hFE;               // JR -2, park
		mem[8'h20] = 8'h00;                                   // what gets copied

		nreset = 1'b0;
		repeat (4) @(posedge clk);
		nreset = 1'b1;
	end

	initial begin
		#40000;
		$display("");
		$display("writes: %0d", writes);
		if (writes == 1)
			$display("RESULT: one write - the repeat re-fetched and saw ED 00. Correct.");
		else
			$display("RESULT: %0d writes - the repeat did NOT see the changed byte.", writes);
		$display("DONE");
		$finish;
	end

endmodule
