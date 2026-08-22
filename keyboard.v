// ZX Spectrum for Altera DE1
//
// Copyright (c) 2009-2011 Mike Stirling
//
// Modifications copyright (c) 2026 Sergey Potapov (potapov.sergey.77@gmail.com)
//
// Changes:
//   - Every addressed keyboard row is now combined, instead of a
//     priority chain that returned row 0 alone when a program selected
//     all eight rows at once - the usual way software scans the whole
//     keyboard.
//   - Host function keys F1..F12 brought out for CPU speed, machine
//     model, contention mode, NMI and reset.
//   - PC Shift tracked separately, so the number row can send SYMBOL
//     SHIFT combinations when shifted and plain digits when not.
//   - ROW_ANY diagnostic output, one bit per row, for finding a key
//     stuck down.
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

	F11,
	F8,
	F12,
	F5,
	F6,
	F7,
	F1,
	F2,
	F3,
	F4,
	F9,
	F10,
	PGUP,
	PGDN,
	HOME,
	END,
	KPSUB,
	KPADD,
	SPACEKEY,
	ROW_ANY
);

	input           CLK;
	input           nRESET;

	input           PS2_CLK;
	input           PS2_DATA;

	input   [15:0]  A;
	output reg [4:0]   KEYB;

	output reg      F11;
	output reg      F8;
	output reg      F12;
	output reg      F5;
	output reg      F6;
	output reg      F7;
	output reg      F9;
	output reg      F1;
	output reg      F2;
	output reg      F3;
	output reg      F4;
	output reg      F10;
	// Page Up / Page Down: moves the whole frame up or down against the
	// raster, a line a press, so border effects can be lined up by eye.
	output reg      PGUP;
	output reg      PGDN;
	// Home / End: same idea horizontally - moves the interrupt within
	// the line, a CPU T-state (two pixels) a press.
	output reg      HOME;
	output reg      END;
	// Keypad - and +: trims the IO contention window alone, a CPU
	// T-state a press, without touching the memory window.
	output reg      KPSUB;
	output reg      KPADD;
	// Space, brought out so a reset can be told to forget the loaded
	// slots and let DivMMC come back up.
	output reg      SPACEKEY;
	// Per-row 'something is held in this row', for finding a stuck bit
	output  [7:0]   ROW_ANY;

	// Interface to PS/2 block
	wire    [7:0]   keyb_data;
	wire            keyb_valid;
	wire            keyb_error;

	// Internal signals
	reg     [4:0]   keys [0:7];
	reg             release_key;
	reg             extended;
	// Tracks whether a PC Shift key is currently physically held, so the
	// number row can send "!"/"@"/"#"/"+" (SYMBOL SHIFT + digit) when
	// shifted and plain digits when not - independent of keys[0][0],
	// which several other combo keys also drive for their own fixed
	// CAPS SHIFT combos (EDIT is on its own dedicated key, see Esc below).
	reg             pc_shift;

	assign ROW_ANY = {~&keys[7], ~&keys[6], ~&keys[5], ~&keys[4],
	                  ~&keys[3], ~&keys[2], ~&keys[1], ~&keys[0]};

	ps2_intf ps2 (
		.CLK(CLK),
		.nRESET(nRESET),
		.PS2_CLK(PS2_CLK),
		.PS2_DATA(PS2_DATA),
		.DATA(keyb_data),
		.VALID(keyb_valid),
		.ERROR(keyb_error)
	);

	// Output the addressed rows to the ULA.
	//
	// Every row whose address line is low is selected, and all of them
	// are combined - a key held in any selected row pulls its column
	// low. Programs commonly read the whole keyboard at once by putting
	// zero in the address high byte, which selects all eight.
	//
	// This used to be a priority chain of else-ifs, so a read of all
	// rows returned row 0 alone - CAPS SHIFT, Z, X, C, V - and every
	// other key was invisible to that kind of scan. It is why the
	// welcome screen of Test 4.3 would move on for X but not for SPACE,
	// which lives in row 7.
	always @(*) begin
		KEYB = 5'b11111;
		if (A[8]  == 1'b0) KEYB = KEYB & keys[0];
		if (A[9]  == 1'b0) KEYB = KEYB & keys[1];
		if (A[10] == 1'b0) KEYB = KEYB & keys[2];
		if (A[11] == 1'b0) KEYB = KEYB & keys[3];
		if (A[12] == 1'b0) KEYB = KEYB & keys[4];
		if (A[13] == 1'b0) KEYB = KEYB & keys[5];
		if (A[14] == 1'b0) KEYB = KEYB & keys[6];
		if (A[15] == 1'b0) KEYB = KEYB & keys[7];
	end

	always @(posedge CLK or negedge nRESET) begin
		if (nRESET == 1'b0) begin
			release_key <= 1'b0;
			extended <= 1'b0;
			pc_shift <= 1'b0;

			keys[0] <= 5'b11111;
			keys[1] <= 5'b11111;
			keys[2] <= 5'b11111;
			keys[3] <= 5'b11111;
			keys[4] <= 5'b11111;
			keys[5] <= 5'b11111;
			keys[6] <= 5'b11111;
			keys[7] <= 5'b11111;
			F11 <= 1'b0;
			F8 <= 1'b0;
			F12 <= 1'b0;
			F5  <= 1'b0;
			F6  <= 1'b0;
			F7  <= 1'b0;
			F9  <= 1'b0;
			F1  <= 1'b0;
			F2  <= 1'b0;
			F3  <= 1'b0;
			F4  <= 1'b0;
			F10 <= 1'b0;
			PGUP <= 1'b0;
			PGDN <= 1'b0;
			HOME <= 1'b0;
			END  <= 1'b0;
			KPSUB  <= 1'b0;
			KPADD  <= 1'b0;
			SPACEKEY <= 1'b0;
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
						8'h12: begin // Left shift (CAPS SHIFT)
							keys[0][0] <= release_key;
							pc_shift <= ~release_key;
						end
						8'h59: begin // Right shift (CAPS SHIFT)
							keys[0][0] <= release_key;
							pc_shift <= ~release_key;
						end
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

						8'h16: begin // 1, or Shift+1 -> "!"
							if (pc_shift) begin
								keys[0][0] <= 1'b1; // cancel the CAPS SHIFT the Shift key asserted
								keys[7][1] <= release_key; // SYMBOL SHIFT
							end else if (release_key == 1'b1) begin
								// Shift may already be up by the time the digit
								// is released, and then the branch above never
								// runs - leaving SYMBOL SHIFT held for good.
								keys[7][1] <= 1'b1;
							end
							keys[3][0] <= release_key;
						end
						8'h1e: begin // 2, or Shift+2 -> "@"
							if (pc_shift) begin
								keys[0][0] <= 1'b1;
								keys[7][1] <= release_key;
							end else if (release_key == 1'b1) begin
								keys[7][1] <= 1'b1;
							end
							keys[3][1] <= release_key;
						end
						8'h26: begin // 3, or Shift+3 -> "#"
							if (pc_shift) begin
								keys[0][0] <= 1'b1;
								keys[7][1] <= release_key;
							end else if (release_key == 1'b1) begin
								keys[7][1] <= 1'b1;
							end
							keys[3][2] <= release_key;
						end
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

						8'h29: begin // SPACE
							keys[7][0] <= release_key;
							SPACEKEY   <= ~release_key;
						end
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
						8'h58: begin // Caps lock -> Graphics mode, "G" cursor (CAPS SHIFT + 9)
							keys[0][0] <= release_key;
							keys[4][1] <= release_key;
						end
						8'h76: begin // Escape -> EDIT (CAPS SHIFT + 1)
							keys[0][0] <= release_key;
							keys[3][0] <= release_key;
						end
						8'h0d: begin // Tab -> Extended mode, "E" cursor (CAPS SHIFT + SYMBOL SHIFT)
							keys[0][0] <= release_key;
							keys[7][1] <= release_key;
						end

						// PC punctuation keys, unshifted, sent as SYMBOL SHIFT +
						// the letter that carries that symbol on a real Spectrum
						// keyboard - so they type like on a normal PC keyboard
						8'h41: begin // , (comma) -> SYMBOL SHIFT + N
							keys[7][1] <= release_key;
							keys[7][3] <= release_key;
						end
						8'h49: begin // . (period) -> SYMBOL SHIFT + M
							keys[7][1] <= release_key;
							keys[7][2] <= release_key;
						end
						8'h4a: begin // / (slash) -> SYMBOL SHIFT + V
							keys[7][1] <= release_key;
							keys[0][4] <= release_key;
						end
						8'h4c: begin // ; (semicolon) -> SYMBOL SHIFT + O
							keys[7][1] <= release_key;
							keys[5][1] <= release_key;
						end
						8'h52: begin // ' (apostrophe) -> SYMBOL SHIFT + P ("), no separate ' on Spectrum
							keys[7][1] <= release_key;
							keys[5][0] <= release_key;
						end
						8'h4e: begin // - (minus) -> SYMBOL SHIFT + J
							keys[7][1] <= release_key;
							keys[6][3] <= release_key;
						end
						8'h55: begin // = (equals), or Shift+= -> "+" (SYMBOL SHIFT + K)
							keys[7][1] <= release_key;
							if (pc_shift) begin
								keys[0][0] <= 1'b1; // cancel the CAPS SHIFT the Shift key asserted
								keys[6][2] <= release_key; // K -> "+"
							end else
								keys[6][1] <= release_key; // L -> "="
						end

						8'h78: F11 <= ~release_key; // F11 key -> computer reset
						8'h0a: F8  <= ~release_key; // F8 key  -> Pentagon 128K timings
						8'h07: F12 <= ~release_key; // F12 key -> NMI
						8'h05: F1  <= ~release_key; // F1 -> INT position -1 pixel
						8'h06: F2  <= ~release_key; // F2 -> INT position +1 pixel
						8'h04: F3  <= ~release_key; // F3 -> INT line -1
						8'h0c: F4  <= ~release_key; // F4 -> INT line +1
						8'h03: F5  <= ~release_key; // F5 key  -> Sinclair 48K timings
						8'h0b: F6  <= ~release_key; // F6 key  -> Sinclair 128K timings
						8'h83: F7  <= ~release_key; // F7 key  -> Sinclair +2A/+3 timings
						8'h01: F9  <= ~release_key; // F9 key  -> 48K memory
						8'h09: F10 <= ~release_key; // F10 key -> 128K memory
						8'h7d: PGUP <= ~release_key; // Page Up   -> frame up a line
						8'h7a: PGDN <= ~release_key; // Page Down -> frame down a line
						8'h6c: HOME <= ~release_key; // Home -> INT one T-state earlier
						8'h69: END  <= ~release_key; // End  -> INT one T-state later
						8'h7b: KPSUB <= ~release_key; // Keypad -  -> IO window a T-state early
						8'h79: KPADD <= ~release_key; // Keypad +  -> IO window a T-state late

						default: begin
						end
					endcase
				end
			end
		end
	end

endmodule
