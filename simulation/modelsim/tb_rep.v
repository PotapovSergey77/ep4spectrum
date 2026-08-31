// tb_rep - what the core holds when a repeating INIR sets its flags
`timescale 1ns / 1ps
module tb_rep;
	reg clk = 1'b0; always #10 clk = ~clk;
	reg nreset = 1'b0;
	wire [15:0] a; wire [7:0] dout; reg [7:0] din;
	wire m1_n, mreq_n, iorq_n, rd_n, wr_n;
	T80se cpu (
		.RESET_n(nreset), .CLK_n(clk), .CLKEN(1'b1), .WAIT_n(1'b1),
		.INT_n(1'b1), .NMI_n(1'b1), .BUSRQ_n(1'b1),
		.M1_n(m1_n), .MREQ_n(mreq_n), .IORQ_n(iorq_n),
		.RD_n(rd_n), .WR_n(wr_n), .RFSH_n(), .HALT_n(), .BUSAK_n(),
		.A(a), .DI(din), .DO(dout), .MC(), .TS(), .IO_CYC());
	reg [7:0] mem [0:255];
	always @* din = mem[a[7:0]];
	always @(posedge clk)
		if (nreset && mreq_n == 1'b0 && wr_n == 1'b0) mem[a[7:0]] <= dout;

	// Every clock the block IO flag rule is live, say what the core holds.
	always @(posedge clk) if (nreset && cpu.u0.I_BTR)
		$display("  T%0d I_BTR=1 BTR_r=%b BusA=%02h DI=%02h k8=%b F=%02h",
		         cpu.u0.TState, cpu.u0.BTR_r, cpu.u0.BusA, cpu.u0.DI_Reg,
		         cpu.u0.BIO_ioq[8], cpu.u0.F);

	integer i;
	initial begin
		for (i = 0; i < 256; i = i + 1) mem[i] = 8'h00;
		mem[8'h00]=8'hF3;
		mem[8'h01]=8'h21; mem[8'h02]=8'h90; mem[8'h03]=8'h00; // LD HL,$0090
		mem[8'h04]=8'h01; mem[8'h05]=8'hF0; mem[8'h06]=8'h02; // LD BC,$02F0
		mem[8'h07]=8'hED; mem[8'h08]=8'hB2;                   // INIR, B=2
		mem[8'h09]=8'h18; mem[8'h0A]=8'hFE;
		mem[8'hF0]=8'hFF;                                     // port data
		nreset = 1'b0; repeat (4) @(posedge clk); nreset = 1'b1;
	end
	initial begin #20000; $display("DONE"); $finish; end
endmodule
