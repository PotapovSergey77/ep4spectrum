// ****
// T80(b) core. In an effort to merge and maintain bug fixes ....
//
//
// Ver 304 converted from VHDL to Verilog by Sergey Potapov (potapov.sergey.77@gmail.com) 09.08.2026
// Ver 300 started tidyup
// MikeJ March 2005
// Latest version from www.fpgaarcade.com (original www.opencores.org)
//
// ****
//
// Z80 compatible microprocessor core, synchronous top level with clock enable
// Different timing than the original z80
// Inputs needs to be synchronous and outputs may glitch
//
// Version : 0240
//
// Copyright (c) 2001-2002 Daniel Wallner (jesus@opencores.org)
//
// Modifications copyright (c) 2026 Sergey Potapov (potapov.sergey.77@gmail.com)
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
//      0235 : First release
//
//      0236 : Added T2Write generic
//
//      0237 : Fixed T2Write with wait state
//
//      0238 : Updated for T80 interface change
//
//      0240 : Updated for T80 interface change
//
//      0242 : Updated for T80 interface change
//
//      0304 : Converted from the original VHDL to Verilog.
//             Sergey Potapov (potapov.sergey.77@gmail.com), 09.08.2026
//

module T80se (
	RESET_n,
	CLK_n,
	CLKEN,
	WAIT_n,
	INT_n,
	NMI_n,
	BUSRQ_n,
	M1_n,
	MREQ_n,
	IORQ_n,
	RD_n,
	WR_n,
	RFSH_n,
	HALT_n,
	BUSAK_n,
	A,
	DI,
	DO
);

	parameter Mode = 0;    // 0 => Z80, 1 => Fast Z80, 2 => 8080, 3 => GB
	parameter T2Write = 0; // 0 => WR_n active in T3, /=0 => WR_n active in T2
	parameter IOWait = 1;  // 0 => Single cycle I/O, 1 => Std I/O cycle

	input           RESET_n;
	input           CLK_n;
	input           CLKEN;
	input           WAIT_n;
	input           INT_n;
	input           NMI_n;
	input           BUSRQ_n;
	output          M1_n;
	output reg      MREQ_n;
	output reg      IORQ_n;
	output reg      RD_n;
	output reg      WR_n;
	output          RFSH_n;
	output          HALT_n;
	output          BUSAK_n;
	output  [15:0]  A;
	input   [7:0]   DI;
	output  [7:0]   DO;

	wire            IntCycle_n;
	wire            NoRead;
	wire            Write;
	wire            IORQ;
	reg     [7:0]   DI_Reg;
	wire    [2:0]   MCycle;
	wire    [2:0]   TState;

	T80 #(
		.Mode(Mode),
		.IOWait(IOWait)
	) u0 (
		.CEN(CLKEN),
		.M1_n(M1_n),
		.IORQ(IORQ),
		.NoRead(NoRead),
		.Write(Write),
		.RFSH_n(RFSH_n),
		.HALT_n(HALT_n),
		.WAIT_n(WAIT_n),
		.INT_n(INT_n),
		.NMI_n(NMI_n),
		.RESET_n(RESET_n),
		.BUSRQ_n(BUSRQ_n),
		.BUSAK_n(BUSAK_n),
		.CLK_n(CLK_n),
		.A(A),
		.DInst(DI),
		.DI(DI_Reg),
		.DO(DO),
		.MC(MCycle),
		.TS(TState),
		.IntCycle_n(IntCycle_n)
	);

	always @(posedge CLK_n or negedge RESET_n) begin
		if (RESET_n == 1'b0) begin
			RD_n <= 1'b1;
			WR_n <= 1'b1;
			IORQ_n <= 1'b1;
			MREQ_n <= 1'b1;
			DI_Reg <= 8'b00000000;
		end else begin
			if (CLKEN == 1'b1) begin
				RD_n <= 1'b1;
				WR_n <= 1'b1;
				IORQ_n <= 1'b1;
				MREQ_n <= 1'b1;
				if (MCycle == 3'b001) begin
					if (TState == 3'b001 || (TState == 3'b010 && WAIT_n == 1'b0)) begin
						RD_n <= ~IntCycle_n;
						MREQ_n <= ~IntCycle_n;
						IORQ_n <= IntCycle_n;
					end
					if (TState == 3'b011) begin
						MREQ_n <= 1'b0;
					end
				end else begin
					if ((TState == 3'b001 || (TState == 3'b010 && WAIT_n == 1'b0)) && NoRead == 1'b0 && Write == 1'b0) begin
						RD_n <= 1'b0;
						IORQ_n <= ~IORQ;
						MREQ_n <= IORQ;
					end
					if (T2Write == 0) begin
						if (TState == 3'b010 && Write == 1'b1) begin
							WR_n <= 1'b0;
							IORQ_n <= ~IORQ;
							MREQ_n <= IORQ;
						end
					end else begin
						if ((TState == 3'b001 || (TState == 3'b010 && WAIT_n == 1'b0)) && Write == 1'b1) begin
							WR_n <= 1'b0;
							IORQ_n <= ~IORQ;
							MREQ_n <= IORQ;
						end
					end
				end
				if (TState == 3'b010 && WAIT_n == 1'b1) begin
					DI_Reg <= DI;
				end
			end
		end
	end

endmodule
