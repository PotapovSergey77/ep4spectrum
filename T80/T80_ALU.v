// ****
// T80(b) core. In an effort to merge and maintain bug fixes ....
//
//
// Ver 301 parity flag is just parity for 8080, also overflow for Z80, by Sean Riddle
// Ver 300 started tidyup
// MikeJ March 2005
// Latest version from www.fpgaarcade.com (original www.opencores.org)
//
// ****
//
// Z80 compatible microprocessor core
//
// Version : 0247
//
// Copyright (c) 2001-2002 Daniel Wallner (jesus@opencores.org)
//
// All rights reserved
//
// Redistribution and use in source and synthezised forms, with or without
// modification, are permitted provided that the following conditions are met:
//
// Redistributions of source code must retain the above copyright notice,
// this list of conditions and the following disclaimer.
//
// Redistributions in synthesized form must reproduce the above copyright
// notice, this list of conditions and the following disclaimer in the
// documentation and/or other materials provided with the distribution.
//
// Neither the name of the author nor the names of other contributors may
// be used to endorse or promote products derived from this software without
// specific prior written permission.
//
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
// AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
// THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
// PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE AUTHOR OR CONTRIBUTORS BE
// LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
// CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
// SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
// INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
// CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
// ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
// POSSIBILITY OF SUCH DAMAGE.
//
// File history :
//
//      0214 : Fixed mostly flags, only the block instructions now fail the zex regression test
//
//      0238 : Fixed zero flag for 16 bit SBC and ADC
//
//      0240 : Added GB operations
//
//      0242 : Cleanup
//
//      0247 : Cleanup
//

module T80_ALU (
	Arith16,
	Z16,
	ALU_Op,
	IR,
	ISet,
	BusA,
	BusB,
	F_In,
	Q,
	F_Out
);

	parameter Mode = 0;
	parameter Flag_C = 0;
	parameter Flag_N = 1;
	parameter Flag_P = 2;
	parameter Flag_X = 3;
	parameter Flag_H = 4;
	parameter Flag_Y = 5;
	parameter Flag_Z = 6;
	parameter Flag_S = 7;

	input           Arith16;
	input           Z16;
	input   [3:0]   ALU_Op;
	input   [5:0]   IR;
	input   [1:0]   ISet;
	input   [7:0]   BusA;
	input   [7:0]   BusB;
	input   [7:0]   F_In;
	output  [7:0]   Q;
	output  reg [7:0]   F_Out;

	// AddSub cascade (technology independent nibble/bit carry chain, matches
	// the original VHDL AddSub procedure bit-for-bit)
	wire            UseCarry = ~ALU_Op[2] & ALU_Op[0];

	wire    [3:0]   B_i0 = ALU_Op[1] ? ~BusB[3:0] : BusB[3:0];
	wire            CarryIn0 = ALU_Op[1] ^ (UseCarry & F_In[Flag_C]);
	wire    [5:0]   ResI0 = {1'b0, BusA[3:0], CarryIn0} + {1'b0, B_i0, 1'b1};
	wire            HalfCarry_v = ResI0[5];
	wire    [3:0]   Q_v_lo = ResI0[4:1];

	wire    [2:0]   B_i1 = ALU_Op[1] ? ~BusB[6:4] : BusB[6:4];
	wire    [4:0]   ResI1 = {1'b0, BusA[6:4], HalfCarry_v} + {1'b0, B_i1, 1'b1};
	wire            Carry7_v = ResI1[4];
	wire    [2:0]   Q_v_mid = ResI1[3:1];

	wire            B_i2 = ALU_Op[1] ? ~BusB[7] : BusB[7];
	wire    [2:0]   ResI2 = {1'b0, BusA[7], Carry7_v} + {1'b0, B_i2, 1'b1};
	wire            Carry_v = ResI2[2];
	wire            Q_v_hi = ResI2[1];

	wire    [7:0]   Q_v = {Q_v_hi, Q_v_mid, Q_v_lo};

	// bug fix - parity flag is just parity for 8080, also overflow for Z80
	reg             OverFlow_v;
	always @(*) begin
		if (Mode == 2)
			OverFlow_v = ~(^Q_v);
		else
			OverFlow_v = Carry_v ^ Carry7_v;
	end

	reg     [7:0]   BitMask;
	always @(*) begin
		case (IR[5:3])
			3'b000: BitMask = 8'b00000001;
			3'b001: BitMask = 8'b00000010;
			3'b010: BitMask = 8'b00000100;
			3'b011: BitMask = 8'b00001000;
			3'b100: BitMask = 8'b00010000;
			3'b101: BitMask = 8'b00100000;
			3'b110: BitMask = 8'b01000000;
			default: BitMask = 8'b10000000;
		endcase
	end

	reg     [7:0]   Q_t;
	reg     [8:0]   DAA_Q;

	always @(*) begin
		Q_t = 8'hxx;
		F_Out = F_In;
		DAA_Q = 9'hxxx;
		case (ALU_Op)
			4'b0000, 4'b0001, 4'b0010, 4'b0011, 4'b0100, 4'b0101, 4'b0110, 4'b0111: begin
				F_Out[Flag_N] = 1'b0;
				F_Out[Flag_C] = 1'b0;
				case (ALU_Op[2:0])
					3'b000, 3'b001: begin // ADD, ADC
						Q_t = Q_v;
						F_Out[Flag_C] = Carry_v;
						F_Out[Flag_H] = HalfCarry_v;
						F_Out[Flag_P] = OverFlow_v;
					end
					3'b010, 3'b011, 3'b111: begin // SUB, SBC, CP
						Q_t = Q_v;
						F_Out[Flag_N] = 1'b1;
						F_Out[Flag_C] = ~Carry_v;
						F_Out[Flag_H] = ~HalfCarry_v;
						F_Out[Flag_P] = OverFlow_v;
					end
					3'b100: begin // AND
						Q_t = BusA & BusB;
						F_Out[Flag_H] = 1'b1;
					end
					3'b101: begin // XOR
						Q_t = BusA ^ BusB;
						F_Out[Flag_H] = 1'b0;
					end
					default: begin // OR "110"
						Q_t = BusA | BusB;
						F_Out[Flag_H] = 1'b0;
					end
				endcase
				if (ALU_Op[2:0] == 3'b111) begin // CP
					F_Out[Flag_X] = BusB[3];
					F_Out[Flag_Y] = BusB[5];
				end else begin
					F_Out[Flag_X] = Q_t[3];
					F_Out[Flag_Y] = Q_t[5];
				end
				if (Q_t == 8'h00) begin
					F_Out[Flag_Z] = 1'b1;
					if (Z16 == 1'b1)
						F_Out[Flag_Z] = F_In[Flag_Z]; // 16 bit ADC,SBC
				end else begin
					F_Out[Flag_Z] = 1'b0;
				end
				F_Out[Flag_S] = Q_t[7];
				case (ALU_Op[2:0])
					3'b000, 3'b001, 3'b010, 3'b011, 3'b111: begin // ADD, ADC, SUB, SBC, CP
					end
					default: begin
						F_Out[Flag_P] = ~(^Q_t);
					end
				endcase
				if (Arith16 == 1'b1) begin
					F_Out[Flag_S] = F_In[Flag_S];
					F_Out[Flag_Z] = F_In[Flag_Z];
					F_Out[Flag_P] = F_In[Flag_P];
				end
			end
			4'b1100: begin
				// DAA
				F_Out[Flag_H] = F_In[Flag_H];
				F_Out[Flag_C] = F_In[Flag_C];
				DAA_Q[7:0] = BusA;
				DAA_Q[8] = 1'b0;
				if (F_In[Flag_N] == 1'b0) begin
					// After addition
					// Alow > 9 or H = 1
					if (DAA_Q[3:0] > 4'd9 || F_In[Flag_H] == 1'b1) begin
						if (DAA_Q[3:0] > 4'd9)
							F_Out[Flag_H] = 1'b1;
						else
							F_Out[Flag_H] = 1'b0;
						DAA_Q = DAA_Q + 9'd6;
					end
					// new Ahigh > 9 or C = 1
					if (DAA_Q[8:4] > 5'd9 || F_In[Flag_C] == 1'b1)
						DAA_Q = DAA_Q + 9'd96; // 0x60
				end else begin
					// After subtraction
					if (DAA_Q[3:0] > 4'd9 || F_In[Flag_H] == 1'b1) begin
						if (DAA_Q[3:0] > 4'd5)
							F_Out[Flag_H] = 1'b0;
						DAA_Q[7:0] = DAA_Q[7:0] - 8'd6;
					end
					if (BusA > 8'd153 || F_In[Flag_C] == 1'b1)
						DAA_Q = DAA_Q - 9'd352; // 0x160
				end
				F_Out[Flag_X] = DAA_Q[3];
				F_Out[Flag_Y] = DAA_Q[5];
				F_Out[Flag_C] = F_In[Flag_C] | DAA_Q[8];
				Q_t = DAA_Q[7:0];
				if (DAA_Q[7:0] == 8'h00)
					F_Out[Flag_Z] = 1'b1;
				else
					F_Out[Flag_Z] = 1'b0;
				F_Out[Flag_S] = DAA_Q[7];
				F_Out[Flag_P] = ~(^DAA_Q[7:0]);
			end
			4'b1101, 4'b1110: begin
				// RLD, RRD
				Q_t[7:4] = BusA[7:4];
				if (ALU_Op[0] == 1'b1)
					Q_t[3:0] = BusB[7:4];
				else
					Q_t[3:0] = BusB[3:0];
				F_Out[Flag_H] = 1'b0;
				F_Out[Flag_N] = 1'b0;
				F_Out[Flag_X] = Q_t[3];
				F_Out[Flag_Y] = Q_t[5];
				if (Q_t == 8'h00)
					F_Out[Flag_Z] = 1'b1;
				else
					F_Out[Flag_Z] = 1'b0;
				F_Out[Flag_S] = Q_t[7];
				F_Out[Flag_P] = ~(^Q_t);
			end
			4'b1001: begin
				// BIT
				Q_t = BusB & BitMask;
				F_Out[Flag_S] = Q_t[7];
				if (Q_t == 8'h00) begin
					F_Out[Flag_Z] = 1'b1;
					F_Out[Flag_P] = 1'b1;
				end else begin
					F_Out[Flag_Z] = 1'b0;
					F_Out[Flag_P] = 1'b0;
				end
				F_Out[Flag_H] = 1'b1;
				F_Out[Flag_N] = 1'b0;
				F_Out[Flag_X] = 1'b0;
				F_Out[Flag_Y] = 1'b0;
				if (IR[2:0] != 3'b110) begin
					F_Out[Flag_X] = BusB[3];
					F_Out[Flag_Y] = BusB[5];
				end
			end
			4'b1010: begin
				// SET
				Q_t = BusB | BitMask;
			end
			4'b1011: begin
				// RES
				Q_t = BusB & ~BitMask;
			end
			4'b1000: begin
				// ROT
				case (IR[5:3])
					3'b000: begin // RLC
						Q_t[7:1] = BusA[6:0];
						Q_t[0] = BusA[7];
						F_Out[Flag_C] = BusA[7];
					end
					3'b010: begin // RL
						Q_t[7:1] = BusA[6:0];
						Q_t[0] = F_In[Flag_C];
						F_Out[Flag_C] = BusA[7];
					end
					3'b001: begin // RRC
						Q_t[6:0] = BusA[7:1];
						Q_t[7] = BusA[0];
						F_Out[Flag_C] = BusA[0];
					end
					3'b011: begin // RR
						Q_t[6:0] = BusA[7:1];
						Q_t[7] = F_In[Flag_C];
						F_Out[Flag_C] = BusA[0];
					end
					3'b100: begin // SLA
						Q_t[7:1] = BusA[6:0];
						Q_t[0] = 1'b0;
						F_Out[Flag_C] = BusA[7];
					end
					3'b110: begin // SLL (Undocumented) / SWAP
						if (Mode == 3) begin
							Q_t[7:4] = BusA[3:0];
							Q_t[3:0] = BusA[7:4];
							F_Out[Flag_C] = 1'b0;
						end else begin
							Q_t[7:1] = BusA[6:0];
							Q_t[0] = 1'b1;
							F_Out[Flag_C] = BusA[7];
						end
					end
					3'b101: begin // SRA
						Q_t[6:0] = BusA[7:1];
						Q_t[7] = BusA[7];
						F_Out[Flag_C] = BusA[0];
					end
					default: begin // SRL
						Q_t[6:0] = BusA[7:1];
						Q_t[7] = 1'b0;
						F_Out[Flag_C] = BusA[0];
					end
				endcase
				F_Out[Flag_H] = 1'b0;
				F_Out[Flag_N] = 1'b0;
				F_Out[Flag_X] = Q_t[3];
				F_Out[Flag_Y] = Q_t[5];
				F_Out[Flag_S] = Q_t[7];
				if (Q_t == 8'h00)
					F_Out[Flag_Z] = 1'b1;
				else
					F_Out[Flag_Z] = 1'b0;
				F_Out[Flag_P] = ~(^Q_t);
				if (ISet == 2'b00) begin
					F_Out[Flag_P] = F_In[Flag_P];
					F_Out[Flag_S] = F_In[Flag_S];
					F_Out[Flag_Z] = F_In[Flag_Z];
				end
			end
			default: begin
			end
		endcase
	end

	assign Q = Q_t;

endmodule
