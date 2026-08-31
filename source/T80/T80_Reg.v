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
// T80 Registers, technology independent
//
// Version : 0244
//
// Copyright (c) 2002 Daniel Wallner (jesus@opencores.org)
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
//      0242 : Initial release
//
//      0244 : Changed to single register file
//
//      0304 : Converted from the original VHDL to Verilog.
//             Sergey Potapov (potapov.sergey.77@gmail.com), 09.08.2026
//

module T80_Reg (
	Clk,
	CEN,
	WEH,
	WEL,
	AddrA,
	AddrB,
	AddrC,
	DIH,
	DIL,
	DOBC,
	DOHL,
	DOAH,
	DOAL,
	DOBH,
	DOBL,
	DOCH,
	DOCL
);

	input           Clk;
	input           CEN;
	input           WEH;
	input           WEL;
	input   [2:0]   AddrA;
	input   [2:0]   AddrB;
	input   [2:0]   AddrC;
	input   [7:0]   DIH;
	input   [7:0]   DIL;
	output [15:0]  DOBC;
	output [15:0]  DOHL;
	output  [7:0]   DOAH;
	output  [7:0]   DOAL;
	output  [7:0]   DOBH;
	output  [7:0]   DOBL;
	output  [7:0]   DOCH;
	output  [7:0]   DOCL;

	reg     [7:0]   RegsH [0:7];
	reg     [7:0]   RegsL [0:7];

	always @(posedge Clk) begin
		if (CEN) begin
			if (WEH)
				RegsH[AddrA] <= DIH;
			if (WEL)
				RegsL[AddrA] <= DIL;
		end
	end

	// BC and HL, always visible. The block IO flags need C or L and
	// the new B, and the three addressed ports carry whatever the
	// microcode is using at the time. Two more reads of a register
	// array cost nothing.
	assign DOBC = {RegsH[0], RegsL[0]};
	assign DOHL = {RegsH[2], RegsL[2]};
	assign DOAH = RegsH[AddrA];
	assign DOAL = RegsL[AddrA];
	assign DOBH = RegsH[AddrB];
	assign DOBL = RegsL[AddrB];
	assign DOCH = RegsH[AddrC];
	assign DOCL = RegsL[AddrC];

endmodule
