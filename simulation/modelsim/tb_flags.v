// tb_flags - the flags T80 produces where z80full rejects them
//
// Copyright (c) 2026 Sergey Potapov (potapov.sergey.77@gmail.com)
//
// Running the suite itself in RTL is not on - it is tens of millions of
// T-states - so drive the few instructions it rejects and print what
// comes out beside the rule worked out by hand.

`timescale 1ns / 1ps

module tb_flags;

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
	always @(posedge clk)
		if (nreset && mreq_n == 1'b0 && wr_n == 1'b0)
			mem[a[7:0]] <= dout;

	wire [7:0] flags = cpu.u0.F;

	// Where an OUT actually lands. FUSE decrements B before the write,
	// so OUTI addresses $(B-1)C; a wrong port on a real machine changes
	// the machine, not just a flag, and z80full sums the whole state.
	always @(posedge clk)
		if (nreset && iorq_n == 1'b0 && wr_n == 1'b0)
			$display("      OUT to port %04h, data %02h", a, dout);

	task show;
		input [8*6:1] want;
		begin
			$display("    got  F=%02h   S=%b Z=%b f5=%b H=%b f3=%b PV=%b N=%b C=%b   %0s",
			         flags, flags[7], flags[6], flags[5], flags[4],
			         flags[3], flags[2], flags[1], flags[0],
			         (flags == want[8:1]) ? "OK" : "<-- MISMATCH");
		end
	endtask

	reg m1_d = 1'b1;
	integer i;

	initial begin
		for (i = 0; i < 256; i = i + 1) mem[i] = 8'h00;
		i = 0;
		mem[i]=8'hF3; i=i+1;                                           // 0000 DI
		mem[i]=8'h3E; i=i+1; mem[i]=8'h10; i=i+1;                      // 0001 LD A,$10
		mem[i]=8'h21; i=i+1; mem[i]=8'h80; i=i+1; mem[i]=8'h00; i=i+1; // 0003 LD HL,$0080
		mem[i]=8'h01; i=i+1; mem[i]=8'h02; i=i+1; mem[i]=8'h00; i=i+1; // 0006 LD BC,$0002
		mem[i]=8'hB7; i=i+1;                                           // 0009 OR A
		mem[i]=8'hED; i=i+1; mem[i]=8'hA1; i=i+1;                      // 000A CPI
		mem[i]=8'h00; i=i+1;                                           // 000C NOP
		mem[i]=8'h21; i=i+1; mem[i]=8'hA0; i=i+1; mem[i]=8'h00; i=i+1; // 000D LD HL,$00A0
		mem[i]=8'h01; i=i+1; mem[i]=8'h02; i=i+1; mem[i]=8'h00; i=i+1; // 0010 LD BC,$0002
		mem[i]=8'hED; i=i+1; mem[i]=8'hA3; i=i+1;                      // 0013 OUTI
		mem[i]=8'h00; i=i+1;                                           // 0015 NOP
		mem[i]=8'h21; i=i+1; mem[i]=8'h90; i=i+1; mem[i]=8'h00; i=i+1; // 0016 LD HL,$0090
		mem[i]=8'h01; i=i+1; mem[i]=8'hF0; i=i+1; mem[i]=8'h02; i=i+1; // 0019 LD BC,$02F0
		mem[i]=8'hED; i=i+1; mem[i]=8'hA2; i=i+1;                      // 001C INI
		mem[i]=8'h00; i=i+1;                                           // 001E NOP
		mem[i]=8'hDD; i=i+1; mem[i]=8'h21; i=i+1;                      // 001F LD IX,$2800
		mem[i]=8'h00; i=i+1; mem[i]=8'h28; i=i+1;
		mem[i]=8'hB7; i=i+1;                                           // 0023 OR A
		mem[i]=8'hDD; i=i+1; mem[i]=8'hCB; i=i+1;                      // 0024 BIT 0,(IX+0)
		mem[i]=8'h00; i=i+1; mem[i]=8'h46; i=i+1;
		mem[i]=8'h00; i=i+1;                                           // 0028 NOP
		mem[i]=8'h01; i=i+1; mem[i]=8'hF0; i=i+1; mem[i]=8'h00; i=i+1; // 0029 LD BC,$00F0
		mem[i]=8'hED; i=i+1; mem[i]=8'h78; i=i+1;                      // 002C IN A,(C)
		mem[i]=8'h00; i=i+1;                                           // 002E NOP
		mem[i]=8'h21; i=i+1; mem[i]=8'hA0; i=i+1; mem[i]=8'h00; i=i+1; // 002F LD HL,$00A0
		mem[i]=8'h01; i=i+1; mem[i]=8'h02; i=i+1; mem[i]=8'h02; i=i+1; // 0032 LD BC,$0202
		mem[i]=8'hED; i=i+1; mem[i]=8'hB3; i=i+1;                      // 0035 OTIR
		mem[i]=8'h00; i=i+1;                                           // 0037 NOP
		mem[i]=8'h21; i=i+1; mem[i]=8'hB0; i=i+1; mem[i]=8'h00; i=i+1; // 0038 LD HL,$00B0
		mem[i]=8'h01; i=i+1; mem[i]=8'hFF; i=i+1; mem[i]=8'h02; i=i+1; // 003B LD BC,$02FF
		mem[i]=8'hED; i=i+1; mem[i]=8'hA2; i=i+1;                      // 003E INI
		mem[i]=8'h00; i=i+1;                                           // 0040 NOP
		mem[i]=8'h18; i=i+1; mem[i]=8'hFE;                             // 0041 JR -2
		mem[8'hA1] = 8'h01;   // second byte OTIR sends
		mem[8'hFF] = 8'h80;   // what port $02FF gives INI
		mem[8'h80] = 8'h01;   // (HL) for CPI
		mem[8'hA0] = 8'hFF;   // (HL) for OUTI - bit 7 set, and k will carry
		mem[8'hF0] = 8'hFF;   // what an IN from port $xxF0 gives here

		nreset = 1'b0;
		repeat (4) @(posedge clk);
		nreset = 1'b1;
	end

	always @(posedge clk) if (nreset) begin
		if (m1_d == 1'b1 && m1_n == 1'b0) begin
			if (a >= 16'h001F) $display("      fetch %04h", a);
			// CPI  A=$10 (HL)=$01 BC=$0002, carry clear
			//   n = $0F, H = 1 (half borrow), n2 = n - H = $0E
			//   flag 3 = n2[3] = 1, flag 5 = n2[1] = 1
			//   S=0 Z=0 N=1 P/V=1 (BC-1 not zero)
			if (a == 16'h000C) begin
				$display("CPI   A=$10 (HL)=$01 BC=$0002");
				$display("    want F=3e   S=0 Z=0 f5=1 H=1 f3=1 PV=1 N=1 C=0");
				show(8'h3e);
			end
			// OUTI  (HL)=$01 HL=$0080 BC=$0202
			//   value=$FF, L becomes $A1, B becomes $01, k = $FF+$A1 = $1A0
			//   k = value + L = $82, not over 255, so H = C = 0
			//   N = value[7] = 0
			//   P/V = parity((k & 7) ^ B) = parity(2 ^ 1) = parity(3) = 1
			//   S Z 5 3 from B = $01
			if (a == 16'h0015) begin
				$display("OUTI  (HL)=$FF HL=$00A0 BC=$0002, B wraps to $FF");
				// B goes to $29 = 0010 1001, so S=0 Z=0 f5=1 f3=1
				// k = $FF + $A1 = $1A0, so H = C = 1, N = value[7] = 1
				// P/V = parity((k & 7) ^ B) = parity(0 ^ $29) = odd = 0
				$display("    want F=bf   S=1 Z=0 f5=1 H=1 f3=1 PV=1 N=1 C=1");
				show(8'hbf);
			end
			// INI   port gives $01, HL=$0090 BC=$02F0
			//   value=$FF, C stays $F0, B becomes $01, k = $FF+$F1 = $1F0
			//   k = value + ((C+1)&255) = $01 + $F1 = $F2
			//   H = C = 0, N = value[7] = 0
			//   P/V = parity(($F2 & 7) ^ 1) = parity(3) = 1
			if (a == 16'h001E) begin
				$display("INI   port gives $FF, HL=$0090 BC=$02F0");
				$display("    want F=13   S=0 Z=0 f5=0 H=1 f3=0 PV=0 N=1 C=1");
				show(8'h13);
			end
			// BIT 0,(IX+0) with IX=$2800, so the address is $2800 and
			// MEMPTR with it. The undocumented 5 and 3 come from its high
			// byte $28 = 0010 1000: bit 5 set, bit 3 set.
			//   (IX+0) aliases mem[$00] = $F3, bit 0 set, so Z = 0
			//   S=0 H=1 N=0 P/V=0, carry cleared by the OR A before it
			if (a == 16'h0028) begin
				$display("BIT 0,(IX+0)  IX=$2800");
				$display("    want F=38   S=0 Z=0 f5=1 H=1 f3=1 PV=0 N=0 C=0");
				show(8'h38);
			end
			// IN A,(C) with BC=$00F0 reads mem[$F0] = $FF.
			//   S=1 Z=0 H=0 N=0, parity of $FF is even so P/V=1,
			//   5 and 3 from the byte: both set. Carry untouched, and
			//   the BIT before it left it clear.
			if (a == 16'h002E) begin
				$display("IN A,(C)  port gives $FF");
				$display("    want F=ac   S=1 Z=0 f5=1 H=0 f3=1 PV=1 N=0 C=0");
				show(8'hac);
			end
			// OTIR, B=$02, so it repeats once. Second pass sends
			// mem[$A1]=$01 with L becoming $A2 and B becoming 0:
			//   k = $01 + $A2 = $A3, no carry, so H = C = 0
			//   N = 0, S = 0, Z = 1, 5 and 3 from B = 0
			//   P/V = parity(($A3 & 7) ^ 0) = parity(3) = even = 1
			if (a == 16'h0037) begin
				$display("OTIR  B=$02, two passes, HL=$00A0");
				$display("    want F=44   S=0 Z=1 f5=0 H=0 f3=0 PV=1 N=0 C=0");
				show(8'h44);
			end
			// INI with C=$FF, so (C+1) wraps to zero:
			//   value $80, k = $80 + $00 = $80, no carry
			//   N = value[7] = 1, B becomes $01
			//   P/V = parity(($80 & 7) ^ $01) = parity(1) = odd = 0
			if (a == 16'h0040) begin
				$display("INI   C=$FF wraps, port gives $80");
				$display("    want F=02   S=0 Z=0 f5=0 H=0 f3=0 PV=0 N=1 C=0");
				show(8'h02);
				$display("DONE");
				$finish;
			end
		end
		m1_d <= m1_n;
	end

	initial begin
		#200000;
		$display("TIMED OUT");
		$finish;
	end

endmodule
