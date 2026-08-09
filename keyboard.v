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

// PS/2 scancode to Spectrum matrix conversion
module keyboard (
	CLK,
	nRESET,

	// PS/2 interface
	PS2_CLK,
	PS2_DATA,

	// CPU address bus (row)
	A,
	// Column outputs to ULA
	KEYB,

	F11
);

	input           CLK;
	input           nRESET;

	input           PS2_CLK;
	input           PS2_DATA;

	input   [15:0]  A;
	output reg [4:0]   KEYB;

	output reg      F11;

	// Interface to PS/2 block
	wire    [7:0]   keyb_data;
	wire            keyb_valid;
	wire            keyb_error;

	// Internal signals
	reg     [4:0]   keys [0:7];
	reg             release_key;
	reg             extended;

	ps2_intf ps2 (
		.CLK(CLK),
		.nRESET(nRESET),
		.PS2_CLK(PS2_CLK),
		.PS2_DATA(PS2_DATA),
		.DATA(keyb_data),
		.VALID(keyb_valid),
		.ERROR(keyb_error)
	);

	// Output addressed row to ULA
	always @(*) begin
		if (A[8] == 1'b0)
			KEYB = keys[0];
		else if (A[9] == 1'b0)
			KEYB = keys[1];
		else if (A[10] == 1'b0)
			KEYB = keys[2];
		else if (A[11] == 1'b0)
			KEYB = keys[3];
		else if (A[12] == 1'b0)
			KEYB = keys[4];
		else if (A[13] == 1'b0)
			KEYB = keys[5];
		else if (A[14] == 1'b0)
			KEYB = keys[6];
		else if (A[15] == 1'b0)
			KEYB = keys[7];
		else
			KEYB = 5'b11111;
	end

	always @(posedge CLK or negedge nRESET) begin
		if (nRESET == 1'b0) begin
			release_key <= 1'b0;
			extended <= 1'b0;

			keys[0] <= 5'b11111;
			keys[1] <= 5'b11111;
			keys[2] <= 5'b11111;
			keys[3] <= 5'b11111;
			keys[4] <= 5'b11111;
			keys[5] <= 5'b11111;
			keys[6] <= 5'b11111;
			keys[7] <= 5'b11111;
			F11 <= 1'b0;
		end else begin
			if (keyb_valid == 1'b1) begin
				if (keyb_data == 8'he0) begin
					// Extended key code follows
					extended <= 1'b1;
				end else if (keyb_data == 8'hf0) begin
					// Release code follows
					release_key <= 1'b1;
				end else begin
					// Cancel extended/release flags for next time
					release_key <= 1'b0;
					extended <= 1'b0;

					case (keyb_data)
						8'h12: keys[0][0] <= release_key; // Left shift (CAPS SHIFT)
						8'h59: keys[0][0] <= release_key; // Right shift (CAPS SHIFT)
						8'h1a: keys[0][1] <= release_key; // Z
						8'h22: keys[0][2] <= release_key; // X
						8'h21: keys[0][3] <= release_key; // C
						8'h2a: keys[0][4] <= release_key; // V

						8'h1c: keys[1][0] <= release_key; // A
						8'h1b: keys[1][1] <= release_key; // S
						8'h23: keys[1][2] <= release_key; // D
						8'h2b: keys[1][3] <= release_key; // F
						8'h34: keys[1][4] <= release_key; // G

						8'h15: keys[2][0] <= release_key; // Q
						8'h1d: keys[2][1] <= release_key; // W
						8'h24: keys[2][2] <= release_key; // E
						8'h2d: keys[2][3] <= release_key; // R
						8'h2c: keys[2][4] <= release_key; // T

						8'h16: keys[3][0] <= release_key; // 1
						8'h1e: keys[3][1] <= release_key; // 2
						8'h26: keys[3][2] <= release_key; // 3
						8'h25: keys[3][3] <= release_key; // 4
						8'h2e: keys[3][4] <= release_key; // 5

						8'h45: keys[4][0] <= release_key; // 0
						8'h46: keys[4][1] <= release_key; // 9
						8'h3e: keys[4][2] <= release_key; // 8
						8'h3d: keys[4][3] <= release_key; // 7
						8'h36: keys[4][4] <= release_key; // 6

						8'h4d: keys[5][0] <= release_key; // P
						8'h44: keys[5][1] <= release_key; // O
						8'h43: keys[5][2] <= release_key; // I
						8'h3c: keys[5][3] <= release_key; // U
						8'h35: keys[5][4] <= release_key; // Y

						8'h5a: keys[6][0] <= release_key; // ENTER
						8'h4b: keys[6][1] <= release_key; // L
						8'h42: keys[6][2] <= release_key; // K
						8'h3b: keys[6][3] <= release_key; // J
						8'h33: keys[6][4] <= release_key; // H

						8'h29: keys[7][0] <= release_key; // SPACE
						8'h14: keys[7][1] <= release_key; // CTRL (Symbol Shift)
						8'h3a: keys[7][2] <= release_key; // M
						8'h31: keys[7][3] <= release_key; // N
						8'h32: keys[7][4] <= release_key; // B

						// Cursor keys - these are actually extended (E0 xx), but
						// the scancodes for the numeric keypad cursor keys are
						// are the same but without the extension, so we'll accept
						// the codes whether they are extended or not
						8'h6b: begin // Left (CAPS 5)
							keys[0][0] <= release_key;
							keys[3][4] <= release_key;
						end
						8'h72: begin // Down (CAPS 6)
							keys[0][0] <= release_key;
							keys[4][4] <= release_key;
						end
						8'h75: begin // Up (CAPS 7)
							keys[0][0] <= release_key;
							keys[4][3] <= release_key;
						end
						8'h74: begin // Right (CAPS 8)
							keys[0][0] <= release_key;
							keys[4][2] <= release_key;
						end

						// Other special keys sent to the ULA as key combinations
						8'h66: begin // Backspace (CAPS 0)
							keys[0][0] <= release_key;
							keys[4][0] <= release_key;
						end
						8'h58: begin // Caps lock (CAPS 2)
							keys[0][0] <= release_key;
							keys[3][1] <= release_key;
						end
						8'h76: begin // Escape (CAPS SPACE)
							keys[0][0] <= release_key;
							keys[7][0] <= release_key;
						end

						8'h78: F11 <= ~release_key; // F11 key

						default: begin
						end
					endcase
				end
			end
		end
	end

endmodule
