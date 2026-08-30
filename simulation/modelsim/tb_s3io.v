// tb_s3io - what the bus looks like during an OUT on the +2A/+3 path
//
// Copyright (c) 2026 Sergey Potapov (potapov.sergey.77@gmail.com)
//
// The +2A/+3 charges no IO contention at all, so ep4spectrum forces
// io_cyc low on that machine. io_cyc is also the term that masks the IO
// machine cycle out of the MEMORY path:
//
//   cont_mem = ~io_cyc & cont_trigger & cont_addr & ~mreq_paid
//
// With io_cyc gone the mask is gone with it, and the only thing left
// standing between an OUT and a memory delay is cont_trigger, which on
// this machine is the bare level ~MREQ_n. scroll17-128 streams to port
// $7FFC - high byte $7F, so cpu_a[14] is set and cont_addr is true - so
// if MREQ_n is still low anywhere in that cycle while the port address
// is on the bus, every one of those OUTs is charged a memory delay the
// real machine never charges.
//
// This prints the bus T-state by T-state through LD BC,$7FFC / OUT (C),A
// so the question is answered by the core rather than by reading it.

`timescale 1ns / 1ps

module tb_s3io;

	reg clk = 1'b0;
	always #10 clk = ~clk;
	reg nreset = 1'b0;

	wire [15:0] a;
	wire  [7:0] dout;
	reg   [7:0] din;
	wire m1_n, mreq_n, iorq_n, rd_n, wr_n, io_cyc, rfsh_n;
	wire [2:0] ts;

	T80se cpu (
		.RESET_n(nreset), .CLK_n(clk), .CLKEN(1'b1), .WAIT_n(1'b1),
		.INT_n(1'b1), .NMI_n(1'b1), .BUSRQ_n(1'b1),
		.M1_n(m1_n), .MREQ_n(mreq_n), .IORQ_n(iorq_n),
		.RD_n(rd_n), .WR_n(wr_n), .RFSH_n(rfsh_n), .HALT_n(), .BUSAK_n(),
		.A(a), .DI(din), .DO(dout), .MC(), .TS(ts), .IO_CYC(io_cyc)
	);

	reg [7:0] mem [0:255];
	always @* din = mem[a[7:0]];

	// cont_addr as ep4spectrum computes it on a +2A/+3 with page 7 at
	// $C000, which is what the demo pages in: cont_page is then 1, so
	// the term reduces to cpu_a[14].
	wire cont_addr = a[14] & (~a[15] | 1'b1);
	// And what cont_mem would be with io_cyc forced low, which is the
	// state the +2A/+3 runs in.
	wire cont_mem_s3 = ~mreq_n & cont_addr;

	integer tick = 0;
	integer charged = 0;
	always @(posedge clk) if (nreset) begin
		tick = tick + 1;
		if (tick > 20 && tick < 60) begin
			$display("T%0d  A=%04h  M1=%b MREQ=%b RFSH=%b IORQ=%b  cont_addr=%b  cont_mem=%b%s",
			         tick, a, m1_n, mreq_n, rfsh_n, iorq_n,
			         cont_addr, cont_mem_s3,
			         (!rfsh_n && cont_mem_s3) ? "   <== charged on a REFRESH" : "");
			if (!rfsh_n && cont_mem_s3) charged = charged + 1;
		end
		if (tick == 60) begin
			$display("");
			$display("refresh T-states the +2A/+3 memory path would charge: %0d", charged);
			$display("DONE");
			$finish;
		end
	end

	integer i;
	initial begin
		for (i = 0; i < 256; i = i + 1) mem[i] = 8'h00;
		i = 0;
		mem[i]=8'hF3; i=i+1;                          // DI
		// I is what the Z80 puts on the top half of the bus during
		// refresh. A demo in IM2 chooses it, and $FE is what the board
		// showed - so give it the same and watch what the +2A/+3
		// contention formula does with the refresh cycles.
		mem[i]=8'h3E; i=i+1; mem[i]=8'hFE; i=i+1;     // LD A,$FE
		mem[i]=8'hED; i=i+1; mem[i]=8'h47; i=i+1;     // LD I,A
		mem[i]=8'h3E; i=i+1; mem[i]=8'h07; i=i+1;     // LD A,$07
		mem[i]=8'h01; i=i+1; mem[i]=8'hFC; i=i+1; mem[i]=8'h7F; i=i+1; // LD BC,$7FFC
		mem[i]=8'hED; i=i+1; mem[i]=8'h79; i=i+1;     // OUT (C),A
		mem[i]=8'h00; i=i+1;                          // NOP
		mem[i]=8'h18; i=i+1; mem[i]=8'hFE;            // JR -2

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
