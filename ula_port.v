// ZX Spectrum for Altera DE1
//
// Copyright (c) 2009-2011 Mike Stirling
//
// All rights reserved
//
// Redistribution and use in source and synthezised forms, with or without
// modification, are permitted provided that the following conditions are met:
//
// * Redistributions of source code must retain the above copyright notice,
//   this list of conditions and the following disclaimer.
//
// * Redistributions in synthesized form must reproduce the above copyright
//   notice, this list of conditions and the following disclaimer in the
//   documentation and/or other materials provided with the distribution.
//
// * Neither the name of the author nor the names of other contributors may
//   be used to endorse or promote products derived from this software without
//   specific prior written agreement from the author.
//
// * License is granted for non-commercial use only.  A fee may not be charged
//   for redistributions as source code or in synthesized/hardware form without
//   specific prior written agreement from the author.
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

module ula_port (
	CLK,
	nRESET,

	// CPU interface with separate read/write buses
	D_IN,
	D_OUT,
	ENABLE,
	nWR,

	BORDER_OUT,
	EAR_OUT,
	MIC_OUT,

	KEYB_IN,
	EAR_IN
);

	input           CLK;
	input           nRESET;

	input   [7:0]   D_IN;
	output reg [7:0]   D_OUT;
	input           ENABLE;
	input           nWR;

	output reg [2:0]   BORDER_OUT;
	output reg      EAR_OUT;
	output reg      MIC_OUT;

	input   [4:0]   KEYB_IN;
	input           EAR_IN;

	always @(posedge CLK or negedge nRESET) begin
		if (!nRESET) begin
			// Output register
			// 7,6,5 = N/C
			// 4 = EAR
			// 3 = MIC
			// 2,1,0 = BORDER (G, R, B)
			EAR_OUT <= 1'b0;
			MIC_OUT <= 1'b0;
			BORDER_OUT <= 3'b000;

			// Input register
			D_OUT <= 8'h00;
		end else begin
			// Register inputs
			// 7 = N/C
			// 6 = EAR
			// 5 = N/C
			// 4-0 = Keyboard
			D_OUT <= {1'b0, EAR_IN, 1'b0, KEYB_IN};

			if (ENABLE == 1'b1 && nWR == 1'b0) begin
				// Latch input data to output register
				EAR_OUT <= D_IN[4];
				MIC_OUT <= D_IN[3];
				BORDER_OUT <= D_IN[2:0];
			end
		end
	end

endmodule
