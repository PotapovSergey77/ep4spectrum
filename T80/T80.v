// ****
// T80(b) core. In an effort to merge and maintain bug fixes ....
//
//
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
//      0208 : First complete release
//
//      0210 : Fixed wait and halt
//
//      0211 : Fixed Refresh addition and IM 1
//
//      0214 : Fixed mostly flags, only the block instructions now fail the zex regression test
//
//      0232 : Removed refresh address output for Mode > 1 and added DJNZ M1_n fix by Mike Johnson
//
//      0235 : Added clock enable and IM 2 fix by Mike Johnson
//
//      0237 : Changed 8080 I/O address output, added IntE output
//
//      0238 : Fixed (IX/IY+d) timing and 16 bit ADC and SBC zero flag
//
//      0240 : Added interrupt ack fix by Mike Johnson, changed (IX/IY+d) timing and changed flags in GB mode
//
//      0242 : Added I/O wait, fixed refresh address, moved some registers to RAM
//
//      0247 : Fixed bus req/ack cycle
//

module T80 (
	RESET_n,
	CLK_n,
	CEN,
	WAIT_n,
	INT_n,
	NMI_n,
	BUSRQ_n,
	M1_n,
	IORQ,
	NoRead,
	Write,
	RFSH_n,
	HALT_n,
	BUSAK_n,
	A,
	DInst,
	DI,
	DO,
	MC,
	TS,
	IntCycle_n,
	IntE,
	Stop
);

	parameter Mode = 0;  // 0 => Z80, 1 => Fast Z80, 2 => 8080, 3 => GB
	parameter IOWait = 0;  // 1 => Single cycle I/O, 1 => Std I/O cycle
	parameter Flag_C = 0;
	parameter Flag_N = 1;
	parameter Flag_P = 2;
	parameter Flag_X = 3;
	parameter Flag_H = 4;
	parameter Flag_Y = 5;
	parameter Flag_Z = 6;
	parameter Flag_S = 7;

	input           RESET_n;
	input           CLK_n;
	input           CEN;
	input           WAIT_n;
	input           INT_n;
	input           NMI_n;
	input           BUSRQ_n;
	output reg      M1_n;
	output          IORQ;
	output          NoRead;
	output          Write;
	output reg      RFSH_n;
	output          HALT_n;
	output          BUSAK_n;
	output reg [15:0]  A;
	input   [7:0]   DInst;
	input   [7:0]   DI;
	output reg [7:0]   DO;
	output  [2:0]   MC;
	output  [2:0]   TS;
	output          IntCycle_n;
	output          IntE;
	output          Stop;

	localparam [2:0] aNone = 3'b111;
	localparam [2:0] aBC   = 3'b000;
	localparam [2:0] aDE   = 3'b001;
	localparam [2:0] aXY   = 3'b010;
	localparam [2:0] aIOA  = 3'b100;
	localparam [2:0] aSP   = 3'b101;
	localparam [2:0] aZI   = 3'b110;

	// Registers
	reg     [7:0]   ACC, F;
	reg     [7:0]   Ap, Fp;
	reg     [7:0]   I;
	reg     [7:0]   R;
	reg     [15:0]  SP, PC;

	reg     [7:0]   RegDIH;
	reg     [7:0]   RegDIL;
	wire    [15:0]  RegBusA;
	wire    [15:0]  RegBusB;
	wire    [15:0]  RegBusC;
	reg     [2:0]   RegAddrA_r;
	wire    [2:0]   RegAddrA;
	reg     [2:0]   RegAddrB_r;
	wire    [2:0]   RegAddrB;
	reg     [2:0]   RegAddrC;
	reg             RegWEH;
	reg             RegWEL;
	reg             Alternate;

	// Help Registers
	reg     [15:0]  TmpAddr;        // Temporary address register
	reg     [7:0]   IR;             // Instruction register
	reg     [1:0]   ISet;           // Instruction set selector
	reg     [15:0]  RegBusA_r;

	wire    [15:0]  ID16;
	wire    [7:0]   Save_Mux;

	reg     [2:0]   TState;
	reg     [2:0]   MCycle;
	reg             IntE_FF1;
	reg             IntE_FF2;
	reg             Halt_FF;
	reg             BusReq_s;
	reg             BusAck;
	wire            ClkEn;
	reg             NMI_s;
	reg             INT_s;
	reg     [1:0]   IStatus;

	wire    [7:0]   DI_Reg;
	wire            T_Res;
	reg     [1:0]   XY_State;
	reg     [2:0]   Pre_XY_F_M;
	wire            NextIs_XY_Fetch;
	reg             XY_Ind;
	reg             No_BTR;
	reg             BTR_r;
	wire            Auto_Wait;
	reg             Auto_Wait_t1;
	reg             Auto_Wait_t2;
	reg             IncDecZ;

	// ALU signals
	reg     [7:0]   BusB;
	reg     [7:0]   BusA;
	wire    [7:0]   ALU_Q;
	wire    [7:0]   F_Out;

	// Registered micro code outputs
	reg     [4:0]   Read_To_Reg_r;
	reg             Arith16_r;
	reg             Z16_r;
	reg     [3:0]   ALU_Op_r;
	reg             Save_ALU_r;
	reg             PreserveC_r;
	reg     [2:0]   MCycles;

	// Micro code outputs
	wire    [2:0]   MCycles_d;
	wire    [2:0]   TStates;
	reg             IntCycle;
	reg             NMICycle;
	wire            Inc_PC;
	wire            Inc_WZ;
	wire    [3:0]   IncDec_16;
	wire    [1:0]   Prefix;
	wire            Read_To_Acc;
	wire            Read_To_Reg;
	wire    [3:0]   Set_BusB_To;
	wire    [3:0]   Set_BusA_To;
	wire    [3:0]   ALU_Op;
	wire            Save_ALU;
	wire            PreserveC;
	wire            Arith16;
	wire    [2:0]   Set_Addr_To;
	wire            Jump;
	wire            JumpE;
	wire            JumpXY;
	wire            Call;
	wire            RstP;
	wire            LDZ;
	wire            LDW;
	wire            LDSPHL;
	wire            IORQ_i;
	wire    [2:0]   Special_LD;
	wire            ExchangeDH;
	wire            ExchangeRp;
	wire            ExchangeAF;
	wire            ExchangeRS;
	wire            I_DJNZ;
	wire            I_CPL;
	wire            I_CCF;
	wire            I_SCF;
	wire            I_RETN;
	wire            I_BT;
	wire            I_BC;
	wire            I_BTR;
	wire            I_RLD;
	wire            I_RRD;
	wire            I_INRC;
	wire            SetDI;
	wire            SetEI;
	wire    [1:0]   IMode;
	wire            Halt;
	wire            XYbit_undoc;

	T80_MCode #(
		.Mode(Mode),
		.Flag_C(Flag_C),
		.Flag_N(Flag_N),
		.Flag_P(Flag_P),
		.Flag_X(Flag_X),
		.Flag_H(Flag_H),
		.Flag_Y(Flag_Y),
		.Flag_Z(Flag_Z),
		.Flag_S(Flag_S)
	) mcode (
		.IR(IR),
		.ISet(ISet),
		.MCycle(MCycle),
		.F(F),
		.NMICycle(NMICycle),
		.IntCycle(IntCycle),
		.XY_State(XY_State),
		.MCycles(MCycles_d),
		.TStates(TStates),
		.Prefix(Prefix),
		.Inc_PC(Inc_PC),
		.Inc_WZ(Inc_WZ),
		.IncDec_16(IncDec_16),
		.Read_To_Acc(Read_To_Acc),
		.Read_To_Reg(Read_To_Reg),
		.Set_BusB_To(Set_BusB_To),
		.Set_BusA_To(Set_BusA_To),
		.ALU_Op(ALU_Op),
		.Save_ALU(Save_ALU),
		.PreserveC(PreserveC),
		.Arith16(Arith16),
		.Set_Addr_To(Set_Addr_To),
		.IORQ(IORQ_i),
		.Jump(Jump),
		.JumpE(JumpE),
		.JumpXY(JumpXY),
		.Call(Call),
		.RstP(RstP),
		.LDZ(LDZ),
		.LDW(LDW),
		.LDSPHL(LDSPHL),
		.Special_LD(Special_LD),
		.ExchangeDH(ExchangeDH),
		.ExchangeRp(ExchangeRp),
		.ExchangeAF(ExchangeAF),
		.ExchangeRS(ExchangeRS),
		.I_DJNZ(I_DJNZ),
		.I_CPL(I_CPL),
		.I_CCF(I_CCF),
		.I_SCF(I_SCF),
		.I_RETN(I_RETN),
		.I_BT(I_BT),
		.I_BC(I_BC),
		.I_BTR(I_BTR),
		.I_RLD(I_RLD),
		.I_RRD(I_RRD),
		.I_INRC(I_INRC),
		.SetDI(SetDI),
		.SetEI(SetEI),
		.IMode(IMode),
		.Halt(Halt),
		.NoRead(NoRead),
		.Write(Write),
		.XYbit_undoc(XYbit_undoc)
	);

	T80_ALU #(
		.Mode(Mode),
		.Flag_C(Flag_C),
		.Flag_N(Flag_N),
		.Flag_P(Flag_P),
		.Flag_X(Flag_X),
		.Flag_H(Flag_H),
		.Flag_Y(Flag_Y),
		.Flag_Z(Flag_Z),
		.Flag_S(Flag_S)
	) alu (
		.Arith16(Arith16_r),
		.Z16(Z16_r),
		.ALU_Op(ALU_Op_r),
		.IR(IR[5:0]),
		.ISet(ISet),
		.BusA(BusA),
		.BusB(BusB),
		.F_In(F),
		.Q(ALU_Q),
		.F_Out(F_Out)
	);

	assign ClkEn = CEN & ~BusAck;

	assign T_Res = (TState == TStates) ? 1'b1 : 1'b0;

	assign NextIs_XY_Fetch = (XY_State != 2'b00 && XY_Ind == 1'b0 &&
			((Set_Addr_To == aXY) ||
			(MCycle == 3'b001 && IR == 8'b11001011) ||
			(MCycle == 3'b001 && IR == 8'b00110110))) ? 1'b1 : 1'b0;

	assign Save_Mux = (ExchangeRp == 1'b1) ? BusB :
		(Save_ALU_r == 1'b0) ? DI_Reg :
		ALU_Q;

	always @(posedge CLK_n or negedge RESET_n) begin
		if (RESET_n == 1'b0) begin
			PC <= 16'b0;  // Program Counter
			A <= 16'b0;
			TmpAddr <= 16'b0;
			IR <= 8'b00000000;
			ISet <= 2'b00;
			XY_State <= 2'b00;
			IStatus <= 2'b00;
			MCycles <= 3'b000;
			DO <= 8'b00000000;

			ACC <= 8'b11111111;
			F <= 8'b11111111;
			Ap <= 8'b11111111;
			Fp <= 8'b11111111;
			I <= 8'b00000000;
			R <= 8'b00000000;
			SP <= 16'hFFFF;
			Alternate <= 1'b0;

			Read_To_Reg_r <= 5'b00000;
			Arith16_r <= 1'b0;
			BTR_r <= 1'b0;
			Z16_r <= 1'b0;
			ALU_Op_r <= 4'b0000;
			Save_ALU_r <= 1'b0;
			PreserveC_r <= 1'b0;
			XY_Ind <= 1'b0;

		end else begin

			if (ClkEn == 1'b1) begin

				ALU_Op_r <= 4'b0000;
				Save_ALU_r <= 1'b0;
				Read_To_Reg_r <= 5'b00000;

				MCycles <= MCycles_d;

				if (IMode != 2'b11)
					IStatus <= IMode;

				Arith16_r <= Arith16;
				PreserveC_r <= PreserveC;
				if (ISet == 2'b10 && ALU_Op[2] == 1'b0 && ALU_Op[0] == 1'b1 && MCycle == 3'b011)
					Z16_r <= 1'b1;
				else
					Z16_r <= 1'b0;

				if (MCycle == 3'b001 && TState[2] == 1'b0) begin
					// MCycle = 1 and TState = 1, 2, or 3

					if (TState == 3'd2 && WAIT_n == 1'b1) begin
						if (Mode < 2) begin
							A[7:0] <= R;
							A[15:8] <= I;
							R[6:0] <= R[6:0] + 7'b1;
						end

						if (Jump == 1'b0 && Call == 1'b0 && NMICycle == 1'b0 && IntCycle == 1'b0 && !(Halt_FF == 1'b1 || Halt == 1'b1))
							PC <= PC + 16'b1;

						if (IntCycle == 1'b1 && IStatus == 2'b01)
							IR <= 8'b11111111;
						else if (Halt_FF == 1'b1 || (IntCycle == 1'b1 && IStatus == 2'b10) || NMICycle == 1'b1)
							IR <= 8'b00000000;
						else
							IR <= DInst;

						ISet <= 2'b00;
						if (Prefix != 2'b00) begin
							if (Prefix == 2'b11) begin
								if (IR[5] == 1'b1)
									XY_State <= 2'b10;
								else
									XY_State <= 2'b01;
							end else begin
								if (Prefix == 2'b10) begin
									XY_State <= 2'b00;
									XY_Ind <= 1'b0;
								end
								ISet <= Prefix;
							end
						end else begin
							XY_State <= 2'b00;
							XY_Ind <= 1'b0;
						end
					end

				end else begin
					// either (MCycle > 1) OR (MCycle = 1 AND TState > 3)

					if (MCycle == 3'b110) begin
						XY_Ind <= 1'b1;
						if (Prefix == 2'b01)
							ISet <= 2'b01;
					end

					if (T_Res == 1'b1) begin
						BTR_r <= (I_BT | I_BC | I_BTR) & ~No_BTR;
						if (Jump == 1'b1) begin
							A[15:8] <= DI_Reg;
							A[7:0] <= TmpAddr[7:0];
							PC[15:8] <= DI_Reg;
							PC[7:0] <= TmpAddr[7:0];
						end else if (JumpXY == 1'b1) begin
							A <= RegBusC;
							PC <= RegBusC;
						end else if (Call == 1'b1 || RstP == 1'b1) begin
							A <= TmpAddr;
							PC <= TmpAddr;
						end else if (MCycle == MCycles && NMICycle == 1'b1) begin
							A <= 16'b0000000001100110;
							PC <= 16'b0000000001100110;
						end else if (MCycle == 3'b011 && IntCycle == 1'b1 && IStatus == 2'b10) begin
							A[15:8] <= I;
							A[7:0] <= TmpAddr[7:0];
							PC[15:8] <= I;
							PC[7:0] <= TmpAddr[7:0];
						end else begin
							case (Set_Addr_To)
								aXY: begin
									if (XY_State == 2'b00) begin
										A <= RegBusC;
									end else begin
										if (NextIs_XY_Fetch == 1'b1)
											A <= PC;
										else
											A <= TmpAddr;
									end
								end
								aIOA: begin
									if (Mode == 3) begin
										// Memory map I/O on GBZ80
										A[15:8] <= 8'b11111111;
									end else if (Mode == 2) begin
										// Duplicate I/O address on 8080
										A[15:8] <= DI_Reg;
									end else begin
										A[15:8] <= ACC;
									end
									A[7:0] <= DI_Reg;
								end
								aSP: begin
									A <= SP;
								end
								aBC: begin
									if (Mode == 3 && IORQ_i == 1'b1) begin
										// Memory map I/O on GBZ80
										A[15:8] <= 8'b11111111;
										A[7:0] <= RegBusC[7:0];
									end else begin
										A <= RegBusC;
									end
								end
								aDE: begin
									A <= RegBusC;
								end
								aZI: begin
									if (Inc_WZ == 1'b1) begin
										A <= TmpAddr + 16'b1;
									end else begin
										A[15:8] <= DI_Reg;
										A[7:0] <= TmpAddr[7:0];
									end
								end
								default: begin
									A <= PC;
								end
							endcase
						end

						Save_ALU_r <= Save_ALU;
						ALU_Op_r <= ALU_Op;

						if (I_CPL == 1'b1) begin
							// CPL
							ACC <= ~ACC;
							F[Flag_Y] <= ~ACC[5];
							F[Flag_H] <= 1'b1;
							F[Flag_X] <= ~ACC[3];
							F[Flag_N] <= 1'b1;
						end
						if (I_CCF == 1'b1) begin
							// CCF
							F[Flag_C] <= ~F[Flag_C];
							F[Flag_Y] <= ACC[5];
							F[Flag_H] <= F[Flag_C];
							F[Flag_X] <= ACC[3];
							F[Flag_N] <= 1'b0;
						end
						if (I_SCF == 1'b1) begin
							// SCF
							F[Flag_C] <= 1'b1;
							F[Flag_Y] <= ACC[5];
							F[Flag_H] <= 1'b0;
							F[Flag_X] <= ACC[3];
							F[Flag_N] <= 1'b0;
						end
					end

					if (TState == 3'd2 && WAIT_n == 1'b1) begin
						if (ISet == 2'b01 && MCycle == 3'b111)
							IR <= DInst;
						if (JumpE == 1'b1)
							PC <= PC + {{8{DI_Reg[7]}}, DI_Reg};
						else if (Inc_PC == 1'b1)
							PC <= PC + 16'b1;
						if (BTR_r == 1'b1)
							PC <= PC - 16'd2;
						if (RstP == 1'b1) begin
							TmpAddr <= 16'b0;
							TmpAddr[5:3] <= IR[5:3];
						end
					end
					if (TState == 3'd3 && MCycle == 3'b110) begin
						TmpAddr <= RegBusC + {{8{DI_Reg[7]}}, DI_Reg};
					end

					if ((TState == 3'd2 && WAIT_n == 1'b1) || (TState == 3'd4 && MCycle == 3'b001)) begin
						if (IncDec_16[2:0] == 3'b111) begin
							if (IncDec_16[3] == 1'b1)
								SP <= SP - 16'b1;
							else
								SP <= SP + 16'b1;
						end
					end

					if (LDSPHL == 1'b1)
						SP <= RegBusC;
					if (ExchangeAF == 1'b1) begin
						Ap <= ACC;
						ACC <= Ap;
						Fp <= F;
						F <= Fp;
					end
					if (ExchangeRS == 1'b1)
						Alternate <= ~Alternate;
				end

				if (TState == 3'd3) begin
					if (LDZ == 1'b1)
						TmpAddr[7:0] <= DI_Reg;
					if (LDW == 1'b1)
						TmpAddr[15:8] <= DI_Reg;

					if (Special_LD[2] == 1'b1) begin
						case (Special_LD[1:0])
							2'b00: begin
								ACC <= I;
								F[Flag_P] <= IntE_FF2;
							end
							2'b01: begin
								ACC <= R;
								F[Flag_P] <= IntE_FF2;
							end
							2'b10: begin
								I <= ACC;
							end
							default: begin
								R <= ACC;
							end
						endcase
					end
				end

				if ((I_DJNZ == 1'b0 && Save_ALU_r == 1'b1) || ALU_Op_r == 4'b1001) begin
					if (Mode == 3) begin
						F[6] <= F_Out[6];
						F[5] <= F_Out[5];
						F[7] <= F_Out[7];
						if (PreserveC_r == 1'b0)
							F[4] <= F_Out[4];
					end else begin
						F[7:1] <= F_Out[7:1];
						if (PreserveC_r == 1'b0)
							F[Flag_C] <= F_Out[0];
					end
				end
				if (T_Res == 1'b1 && I_INRC == 1'b1) begin
					F[Flag_H] <= 1'b0;
					F[Flag_N] <= 1'b0;
					if (DI_Reg[7:0] == 8'b00000000)
						F[Flag_Z] <= 1'b1;
					else
						F[Flag_Z] <= 1'b0;
					F[Flag_S] <= DI_Reg[7];
					F[Flag_P] <= ~(^DI_Reg);
				end

				if (TState == 3'd1) begin
					DO <= BusB;
					if (I_RLD == 1'b1) begin
						DO[3:0] <= BusA[3:0];
						DO[7:4] <= BusB[3:0];
					end
					if (I_RRD == 1'b1) begin
						DO[3:0] <= BusB[7:4];
						DO[7:4] <= BusA[3:0];
					end
				end

				if (T_Res == 1'b1) begin
					Read_To_Reg_r[3:0] <= Set_BusA_To;
					Read_To_Reg_r[4] <= Read_To_Reg;
					if (Read_To_Acc == 1'b1) begin
						Read_To_Reg_r[3:0] <= 4'b0111;
						Read_To_Reg_r[4] <= 1'b1;
					end
				end

				if (TState == 3'd1 && I_BT == 1'b1) begin
					F[Flag_X] <= ALU_Q[3];
					F[Flag_Y] <= ALU_Q[1];
					F[Flag_H] <= 1'b0;
					F[Flag_N] <= 1'b0;
				end
				if (I_BC == 1'b1 || I_BT == 1'b1)
					F[Flag_P] <= IncDecZ;

				if ((TState == 3'd1 && Save_ALU_r == 1'b0) ||
					(Save_ALU_r == 1'b1 && ALU_Op_r != 4'b0111)) begin
					case (Read_To_Reg_r)
						5'b10111: ACC <= Save_Mux;
						5'b10110: DO <= Save_Mux;
						5'b11000: SP[7:0] <= Save_Mux;
						5'b11001: SP[15:8] <= Save_Mux;
						5'b11011: F <= Save_Mux;
						default: ;
					endcase
					if (XYbit_undoc == 1'b1)
						DO <= ALU_Q;
				end

			end

		end
	end

	//---------------------------------------------------------------------------
	//
	// BC('), DE('), HL('), IX and IY
	//
	//---------------------------------------------------------------------------
	always @(posedge CLK_n) begin
		if (ClkEn == 1'b1) begin
			// Bus A / Write
			RegAddrA_r <= {Alternate, Set_BusA_To[2:1]};
			if (XY_Ind == 1'b0 && XY_State != 2'b00 && Set_BusA_To[2:1] == 2'b10)
				RegAddrA_r <= {XY_State[1], 2'b11};

			// Bus B
			RegAddrB_r <= {Alternate, Set_BusB_To[2:1]};
			if (XY_Ind == 1'b0 && XY_State != 2'b00 && Set_BusB_To[2:1] == 2'b10)
				RegAddrB_r <= {XY_State[1], 2'b11};

			// Address from register
			RegAddrC <= {Alternate, Set_Addr_To[1:0]};
			// Jump (HL), LD SP,HL
			if (JumpXY == 1'b1 || LDSPHL == 1'b1)
				RegAddrC <= {Alternate, 2'b10};
			if (((JumpXY == 1'b1 || LDSPHL == 1'b1) && XY_State != 2'b00) || (MCycle == 3'b110))
				RegAddrC <= {XY_State[1], 2'b11};

			if (I_DJNZ == 1'b1 && Save_ALU_r == 1'b1 && Mode < 2)
				IncDecZ <= F_Out[Flag_Z];
			if ((TState == 3'd2 || (TState == 3'd3 && MCycle == 3'b001)) && IncDec_16[2:0] == 3'b100) begin
				if (ID16 == 16'b0)
					IncDecZ <= 1'b0;
				else
					IncDecZ <= 1'b1;
			end

			RegBusA_r <= RegBusA;
		end
	end

	assign RegAddrA =
			// 16 bit increment/decrement
			((TState == 3'd2 || (TState == 3'd3 && MCycle == 3'b001 && IncDec_16[2] == 1'b1)) && XY_State == 2'b00) ? {Alternate, IncDec_16[1:0]} :
			((TState == 3'd2 || (TState == 3'd3 && MCycle == 3'b001 && IncDec_16[2] == 1'b1)) && IncDec_16[1:0] == 2'b10) ? {XY_State[1], 2'b11} :
			// EX HL,DL
			(ExchangeDH == 1'b1 && TState == 3'd3) ? {Alternate, 2'b10} :
			(ExchangeDH == 1'b1 && TState == 3'd4) ? {Alternate, 2'b01} :
			// Bus A / Write
			RegAddrA_r;

	assign RegAddrB =
			// EX HL,DL
			(ExchangeDH == 1'b1 && TState == 3'd3) ? {Alternate, 2'b01} :
			// Bus B
			RegAddrB_r;

	assign ID16 = (IncDec_16[3] == 1'b1) ? (RegBusA - 16'b1) : (RegBusA + 16'b1);

	always @(*) begin
		RegWEH = 1'b0;
		RegWEL = 1'b0;
		if ((TState == 3'd1 && Save_ALU_r == 1'b0) ||
			(Save_ALU_r == 1'b1 && ALU_Op_r != 4'b0111)) begin
			case (Read_To_Reg_r)
				5'b10000, 5'b10001, 5'b10010, 5'b10011, 5'b10100, 5'b10101: begin
					RegWEH = ~Read_To_Reg_r[0];
					RegWEL = Read_To_Reg_r[0];
				end
				default: ;
			endcase
		end

		if (ExchangeDH == 1'b1 && (TState == 3'd3 || TState == 3'd4)) begin
			RegWEH = 1'b1;
			RegWEL = 1'b1;
		end

		if (IncDec_16[2] == 1'b1 && ((TState == 3'd2 && WAIT_n == 1'b1 && MCycle != 3'b001) || (TState == 3'd3 && MCycle == 3'b001))) begin
			case (IncDec_16[1:0])
				2'b00, 2'b01, 2'b10: begin
					RegWEH = 1'b1;
					RegWEL = 1'b1;
				end
				default: ;
			endcase
		end
	end

	always @(*) begin
		RegDIH = Save_Mux;
		RegDIL = Save_Mux;

		if (ExchangeDH == 1'b1 && TState == 3'd3) begin
			RegDIH = RegBusB[15:8];
			RegDIL = RegBusB[7:0];
		end
		if (ExchangeDH == 1'b1 && TState == 3'd4) begin
			RegDIH = RegBusA_r[15:8];
			RegDIL = RegBusA_r[7:0];
		end

		if (IncDec_16[2] == 1'b1 && ((TState == 3'd2 && MCycle != 3'b001) || (TState == 3'd3 && MCycle == 3'b001))) begin
			RegDIH = ID16[15:8];
			RegDIL = ID16[7:0];
		end
	end

	T80_Reg Regs (
		.Clk(CLK_n),
		.CEN(ClkEn),
		.WEH(RegWEH),
		.WEL(RegWEL),
		.AddrA(RegAddrA),
		.AddrB(RegAddrB),
		.AddrC(RegAddrC),
		.DIH(RegDIH),
		.DIL(RegDIL),
		.DOAH(RegBusA[15:8]),
		.DOAL(RegBusA[7:0]),
		.DOBH(RegBusB[15:8]),
		.DOBL(RegBusB[7:0]),
		.DOCH(RegBusC[15:8]),
		.DOCL(RegBusC[7:0])
	);

	//---------------------------------------------------------------------------
	//
	// Buses
	//
	//---------------------------------------------------------------------------
	always @(posedge CLK_n) begin
		if (ClkEn == 1'b1) begin
			case (Set_BusB_To)
				4'b0111: begin
					BusB <= ACC;
				end
				4'b0000, 4'b0001, 4'b0010, 4'b0011, 4'b0100, 4'b0101: begin
					if (Set_BusB_To[0] == 1'b1)
						BusB <= RegBusB[7:0];
					else
						BusB <= RegBusB[15:8];
				end
				4'b0110: begin
					BusB <= DI_Reg;
				end
				4'b1000: begin
					BusB <= SP[7:0];
				end
				4'b1001: begin
					BusB <= SP[15:8];
				end
				4'b1010: begin
					BusB <= 8'b00000001;
				end
				4'b1011: begin
					BusB <= F;
				end
				4'b1100: begin
					BusB <= PC[7:0];
				end
				4'b1101: begin
					BusB <= PC[15:8];
				end
				4'b1110: begin
					BusB <= 8'b00000000;
				end
				default: begin
					BusB <= 8'bxxxxxxxx;
				end
			endcase

			case (Set_BusA_To)
				4'b0111: begin
					BusA <= ACC;
				end
				4'b0000, 4'b0001, 4'b0010, 4'b0011, 4'b0100, 4'b0101: begin
					if (Set_BusA_To[0] == 1'b1)
						BusA <= RegBusA[7:0];
					else
						BusA <= RegBusA[15:8];
				end
				4'b0110: begin
					BusA <= DI_Reg;
				end
				4'b1000: begin
					BusA <= SP[7:0];
				end
				4'b1001: begin
					BusA <= SP[15:8];
				end
				4'b1010: begin
					BusA <= 8'b00000000;
				end
				default: begin
					BusA <= 8'bxxxxxxxx;
				end
			endcase
			if (XYbit_undoc == 1'b1) begin
				BusA <= DI_Reg;
				BusB <= DI_Reg;
			end
		end
	end

	//---------------------------------------------------------------------------
	//
	// Generate external control signals
	//
	//---------------------------------------------------------------------------
	always @(posedge CLK_n or negedge RESET_n) begin
		if (RESET_n == 1'b0) begin
			RFSH_n <= 1'b1;
		end else begin
			if (CEN == 1'b1) begin
				if (MCycle == 3'b001 && ((TState == 3'd2 && WAIT_n == 1'b1) || TState == 3'd3))
					RFSH_n <= 1'b0;
				else
					RFSH_n <= 1'b1;
			end
		end
	end

	assign MC = MCycle;
	assign TS = TState;
	assign DI_Reg = DI;
	assign HALT_n = ~Halt_FF;
	assign BUSAK_n = ~BusAck;
	assign IntCycle_n = ~IntCycle;
	assign IntE = IntE_FF1;
	assign IORQ = IORQ_i;
	assign Stop = I_DJNZ;

	//-------------------------------------------------------------------------
	//
	// Syncronise inputs
	//
	//-------------------------------------------------------------------------
	reg             OldNMI_n;
	always @(posedge CLK_n or negedge RESET_n) begin
		if (RESET_n == 1'b0) begin
			BusReq_s <= 1'b0;
			INT_s <= 1'b0;
			NMI_s <= 1'b0;
			OldNMI_n = 1'b0;
		end else begin
			if (CEN == 1'b1) begin
				BusReq_s <= ~BUSRQ_n;
				INT_s <= ~INT_n;
				if (NMICycle == 1'b1)
					NMI_s <= 1'b0;
				else if (NMI_n == 1'b0 && OldNMI_n == 1'b1)
					NMI_s <= 1'b1;
				OldNMI_n = NMI_n;
			end
		end
	end

	//-------------------------------------------------------------------------
	//
	// Main state machine
	//
	//-------------------------------------------------------------------------
	always @(posedge CLK_n or negedge RESET_n) begin
		if (RESET_n == 1'b0) begin
			MCycle <= 3'b001;
			TState <= 3'b000;
			Pre_XY_F_M <= 3'b000;
			Halt_FF <= 1'b0;
			BusAck <= 1'b0;
			NMICycle <= 1'b0;
			IntCycle <= 1'b0;
			IntE_FF1 <= 1'b0;
			IntE_FF2 <= 1'b0;
			No_BTR <= 1'b0;
			Auto_Wait_t1 <= 1'b0;
			Auto_Wait_t2 <= 1'b0;
			M1_n <= 1'b1;
		end else begin
			if (CEN == 1'b1) begin
				Auto_Wait_t1 <= Auto_Wait;
				Auto_Wait_t2 <= Auto_Wait_t1;
				No_BTR <= (I_BT & (~IR[4] | ~F[Flag_P])) |
						(I_BC & (~IR[4] | F[Flag_Z] | ~F[Flag_P])) |
						(I_BTR & (~IR[4] | F[Flag_Z]));
				if (TState == 3'd2) begin
					if (SetEI == 1'b1) begin
						IntE_FF1 <= 1'b1;
						IntE_FF2 <= 1'b1;
					end
					if (I_RETN == 1'b1)
						IntE_FF1 <= IntE_FF2;
				end
				if (TState == 3'd3) begin
					if (SetDI == 1'b1) begin
						IntE_FF1 <= 1'b0;
						IntE_FF2 <= 1'b0;
					end
				end
				if (IntCycle == 1'b1 || NMICycle == 1'b1)
					Halt_FF <= 1'b0;
				if (MCycle == 3'b001 && TState == 3'd2 && WAIT_n == 1'b1)
					M1_n <= 1'b1;
				if (BusReq_s == 1'b1 && BusAck == 1'b1) begin
					// hold
				end else begin
					BusAck <= 1'b0;
					if (TState == 3'd2 && WAIT_n == 1'b0) begin
						// stall
					end else if (T_Res == 1'b1) begin
						if (Halt == 1'b1)
							Halt_FF <= 1'b1;
						if (BusReq_s == 1'b1) begin
							BusAck <= 1'b1;
						end else begin
							TState <= 3'b001;
							if (NextIs_XY_Fetch == 1'b1) begin
								MCycle <= 3'b110;
								Pre_XY_F_M <= MCycle;
								if (IR == 8'b00110110 && Mode == 0)
									Pre_XY_F_M <= 3'b010;
							end else if ((MCycle == 3'b111) ||
								(MCycle == 3'b110 && Mode == 1 && ISet != 2'b01)) begin
								MCycle <= Pre_XY_F_M + 3'b1;
							end else if ((MCycle == MCycles) ||
								No_BTR == 1'b1 ||
								(MCycle == 3'b010 && I_DJNZ == 1'b1 && IncDecZ == 1'b1)) begin
								M1_n <= 1'b0;
								MCycle <= 3'b001;
								IntCycle <= 1'b0;
								NMICycle <= 1'b0;
								if (NMI_s == 1'b1 && Prefix == 2'b00) begin
									NMICycle <= 1'b1;
									IntE_FF1 <= 1'b0;
								end else if ((IntE_FF1 == 1'b1 && INT_s == 1'b1) && Prefix == 2'b00 && SetEI == 1'b0) begin
									IntCycle <= 1'b1;
									IntE_FF1 <= 1'b0;
									IntE_FF2 <= 1'b0;
								end
							end else begin
								MCycle <= MCycle + 3'b1;
							end
						end
					end else begin
						if (!(Auto_Wait == 1'b1 && Auto_Wait_t2 == 1'b0)) begin
							TState <= TState + 3'b1;
						end
					end
				end
				if (TState == 3'b000)
					M1_n <= 1'b0;
			end
		end
	end

	assign Auto_Wait = ((IntCycle == 1'b1 || NMICycle == 1'b1) && MCycle == 3'b001) ? 1'b1 : 1'b0;

endmodule
