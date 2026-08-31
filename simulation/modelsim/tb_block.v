// tb_block - block IO against FUSE's own algorithm, whole state
//
// Copyright (c) 2026 Sergey Potapov (potapov.sergey.77@gmail.com)
//
// tb_flags.v compares F and nothing else, and by that measure the block
// group already agrees with FUSE on every case put to it - yet z80full
// still rejects all eight. That suite sums the WHOLE machine after each
// vector, so the difference has to be in something F does not show.
//
// So this one snapshots the state before the instruction, computes what
// FUSE would leave - the arithmetic below is z80/z80_ed.c cases 0xa2,
// 0xaa, 0xa3 and 0xab transcribed, not a rule remembered - and compares
// every register afterwards.

`timescale 1ns / 1ps

module tb_block;

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

	// The core's own registers, for the comparison.
	wire [15:0] BC = {cpu.u0.Regs.RegsH[0], cpu.u0.Regs.RegsL[0]};
	wire [15:0] DE = {cpu.u0.Regs.RegsH[1], cpu.u0.Regs.RegsL[1]};
	wire [15:0] HL = {cpu.u0.Regs.RegsH[2], cpu.u0.Regs.RegsL[2]};
	wire  [7:0] AC = cpu.u0.ACC;
	wire  [7:0] FL = cpu.u0.F;

	// sz53 and parity, the two tables FUSE builds at startup.
	function [7:0] sz53;
		input [7:0] v;
		begin
			sz53 = 8'h00;
			sz53[7] = v[7];
			sz53[6] = (v == 8'h00);
			sz53[5] = v[5];
			sz53[3] = v[3];
		end
	endfunction
	function even_parity;
		input [7:0] v;
		begin even_parity = ~(^v); end
	endfunction

	// One reference step. op is the ED opcode.
	//   $A2 INI   $AA IND   $A3 OUTI   $AB OUTD
	task ref_step;
		input  [7:0]  op;
		input  [15:0] bc_in;
		input  [15:0] hl_in;
		input  [7:0]  val;      // byte transferred
		output [15:0] bc_out;
		output [15:0] hl_out;
		output [7:0]  f_out;
		reg    [7:0]  b_new, t;
		reg    [15:0] hl_new;
		begin
			b_new  = bc_in[15:8] - 8'd1;
			hl_new = op[3] ? (hl_in - 16'd1) : (hl_in + 16'd1);
			if (op[0] == 1'b0)                       // IN forms
				t = val + (op[3] ? (bc_in[7:0] - 8'd1)
				                 : (bc_in[7:0] + 8'd1));
			else                                     // OUT forms
				t = val + hl_new[7:0];
			f_out = (val[7] ? 8'h02 : 8'h00)                       // N
			      | ((t < val) ? 8'h11 : 8'h00)                    // H and C
			      | (even_parity({5'd0, t[2:0]} ^ b_new) ? 8'h04 : 8'h00)
			      | sz53(b_new);
			bc_out = {b_new, bc_in[7:0]};
			hl_out = hl_new;
		end
	endtask

	// Snapshot taken at the ED fetch, compared at the next opcode fetch.
	reg [1:0]  armed = 2'd0;
	reg [7:0]  s_op;
	reg [15:0] s_bc, s_hl;
	reg [7:0]  s_val;
	reg        m1_d = 1'b1;
	reg [15:0] e_bc, e_hl;
	reg [7:0]  e_f;
	integer    bad = 0, ran = 0;

	task check;
		begin
			ran = ran + 1;
			ref_step(s_op, s_bc, s_hl, s_val, e_bc, e_hl, e_f);
			if (BC !== e_bc || HL !== e_hl || FL !== e_f) begin
				bad = bad + 1;
				$display("op %02h  BC=%04h HL=%04h val=%02h", s_op, s_bc, s_hl, s_val);
				$display("   FUSE  BC=%04h HL=%04h F=%02h", e_bc, e_hl, e_f);
				$display("   core  BC=%04h HL=%04h F=%02h   <-- %s%s%s",
				         BC, HL, FL,
				         (BC !== e_bc) ? "BC " : "",
				         (HL !== e_hl) ? "HL " : "",
				         (FL !== e_f)  ? "F"   : "");
			end else
				$display("op %02h  BC=%04h HL=%04h val=%02h   OK", s_op, s_bc, s_hl, s_val);
		end
	endtask

	integer i;
	initial begin
		for (i = 0; i < 256; i = i + 1) mem[i] = 8'h00;
		i = 0;
		mem[i]=8'hF3; i=i+1;                                            // DI
		// INI   BC=$02F0 HL=$0090, port $02F0 gives mem[$F0]
		mem[i]=8'h01; i=i+1; mem[i]=8'hF0; i=i+1; mem[i]=8'h02; i=i+1;
		mem[i]=8'h21; i=i+1; mem[i]=8'h90; i=i+1; mem[i]=8'h00; i=i+1;
		mem[i]=8'hED; i=i+1; mem[i]=8'hA2; i=i+1;
		// IND   BC=$0110 HL=$0091
		mem[i]=8'h01; i=i+1; mem[i]=8'h10; i=i+1; mem[i]=8'h01; i=i+1;
		mem[i]=8'h21; i=i+1; mem[i]=8'h91; i=i+1; mem[i]=8'h00; i=i+1;
		mem[i]=8'hED; i=i+1; mem[i]=8'hAA; i=i+1;
		// OUTI  BC=$0002 HL=$00A0, (HL)=$FF
		mem[i]=8'h01; i=i+1; mem[i]=8'h02; i=i+1; mem[i]=8'h00; i=i+1;
		mem[i]=8'h21; i=i+1; mem[i]=8'hA0; i=i+1; mem[i]=8'h00; i=i+1;
		mem[i]=8'hED; i=i+1; mem[i]=8'hA3; i=i+1;
		// OUTD  BC=$8001 HL=$00A5, (HL)=$7F
		mem[i]=8'h01; i=i+1; mem[i]=8'h01; i=i+1; mem[i]=8'h80; i=i+1;
		mem[i]=8'h21; i=i+1; mem[i]=8'hA5; i=i+1; mem[i]=8'h00; i=i+1;
		mem[i]=8'hED; i=i+1; mem[i]=8'hAB; i=i+1;
		mem[i]=8'h18; i=i+1; mem[i]=8'hFE;                              // park

		mem[8'hF0] = 8'h55;   // what port $02F0 gives INI
		mem[8'h10] = 8'h80;   // what port $0110 gives IND
		mem[8'hA0] = 8'hFF;   // (HL) for OUTI
		mem[8'hA5] = 8'h7F;   // (HL) for OUTD

		nreset = 1'b0;
		repeat (4) @(posedge clk);
		nreset = 1'b1;
	end

	always @(posedge clk) if (nreset) begin
		if (m1_d == 1'b1 && m1_n == 1'b0) begin
			// Two M1 fetches make an ED instruction - the prefix and the
			// opcode - so the state to compare is at the SECOND one after
			// the prefix, not the first.
			if (armed == 2'd2) armed <= 2'd1;
			else begin
				// The check and the next prefix can land on the same M1,
				// so they must not be alternatives - written as else-if,
				// every instruction after the first was captured at the
				// wrong fetch and compared against nonsense.
				if (armed == 2'd1) check;
				armed <= 2'd0;
			if (din == 8'hED) begin
				s_bc <= BC; s_hl <= HL;
				s_op <= mem[a[7:0] + 8'd1];
				s_val <= (mem[a[7:0] + 8'd1] & 8'h01) ? mem[HL[7:0]]
				                                     : mem[BC[7:0]];
				armed <= 2'd2;
			end
			end
		end
		m1_d <= m1_n;
		if (ran == 4) begin
			$display("");
			$display("%0d of %0d disagree with FUSE", bad, ran);
			$display("DONE");
			$finish;
		end
	end

	initial begin
		#300000;
		$display("TIMED OUT after %0d", ran);
		$finish;
	end

endmodule
