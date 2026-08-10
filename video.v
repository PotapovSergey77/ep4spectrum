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

module video (
	// Master clock (28 MHz)
	CLK,
	// Video domain clock enable (14 MHz)
	CLKEN,
	//
	MEM_CYC,
	// Master reset
	nRESET,

	// Mode
	VGA,
	// 0 = Sinclair 48K frame timing, 1 = Pentagon 128K
	PENTAGON,

	// Memory interface
	VID_A,
	VID_D_IN,
	nVID_RD,
	nWAIT,

	// IO interface
	BORDER_IN,

	// Video outputs
	R,
	G,
	B,
	nVSYNC,
	nHSYNC,
	nCSYNC,
	nHCSYNC,
	SCANLINE,

	// Interrupt to CPU (asserted for 32 T-states, 64 ticks)
	nIRQ
);

	input           CLK;
	input           CLKEN;
	input           MEM_CYC;
	input           nRESET;

	input           VGA;
	input           PENTAGON;

	output  [12:0]  VID_A;
	input   [7:0]   VID_D_IN;
	output reg      nVID_RD;
	output          nWAIT;

	input   [2:0]   BORDER_IN;

	output reg [3:0]   R;
	output reg [3:0]   G;
	output reg [3:0]   B;
	output          nVSYNC;
	output          nHSYNC;
	output          nCSYNC;
	output          nHCSYNC;
	output          SCANLINE;

	output reg      nIRQ;

	reg     [9:0]   pixels;
	reg     [7:0]   attr;

	// additional buffer used in non-VGA mode (TV) to store the pixels/attr a little
	// bit ahead of time to not interfere with cpu ram access
	reg     [7:0]   pixels_tv;
	reg     [7:0]   attr_tv;

	// Video logic runs at 14 MHz so hcounter has an additonal LSb which is
	// skipped if running in VGA scan-doubled mode.  The value of this
	// extra bit is 1/2 for the purposes of timing calculations bit 1 is
	// assumed to have a value of 1.
	reg     [9:0]   hcounter;
	// vcounter has an extra LSb as well except this is skipped if running
	// in PAL mode.  By not skipping it in VGA mode we get the required
	// double-scanning of each line.  This extra bit has a value 1/2 as well.
	reg     [9:0]   vcounter;
	reg     [4:0]   flashcounter;
	reg             vblanking;
	reg             hblanking;
	reg             hpicture;
	wire            vpicture;
	wire            picture;
	wire            blanking;

	reg             hsync;
	reg             vsync;

	wire            red;
	wire            green;
	wire            blue;
	wire            bright;
	wire            dot;

	// The first 256 pixels of each line are valid picture
	assign picture = hpicture & vpicture;
	assign blanking = hblanking | vblanking;

	// Output syncs
	// drive VSYNC to 1 in PAL mode for Minimig VGA cable
	assign nVSYNC = ~vsync;
	assign nHSYNC = ~hsync;
	assign nCSYNC = ~(vsync ^ hsync);
	// Combined HSYNC/CSYNC.  Feeds HSYNC to VGA HSYNC in VGA mode,
	// or CSYNC to the same pin in PAL mode
	assign nHCSYNC = (VGA == 1'b0) ? ~(vsync ^ hsync) : ~hsync;
	assign SCANLINE = vcounter[0];

	// Determine the pixel colour
	assign dot = pixels[9] ^ (flashcounter[4] & attr[7]); // Combine delayed pixel with FLASH attr and clock state
	assign red = (picture == 1'b1 && dot == 1'b1) ? attr[1] :
		(picture == 1'b1 && dot == 1'b0) ? attr[4] :
		(blanking == 1'b0) ? BORDER_IN[1] :
		1'b0;
	assign green = (picture == 1'b1 && dot == 1'b1) ? attr[2] :
		(picture == 1'b1 && dot == 1'b0) ? attr[5] :
		(blanking == 1'b0) ? BORDER_IN[2] :
		1'b0;
	assign blue = (picture == 1'b1 && dot == 1'b1) ? attr[0] :
		(picture == 1'b1 && dot == 1'b0) ? attr[3] :
		(blanking == 1'b0) ? BORDER_IN[0] :
		1'b0;
	assign bright = (picture == 1'b1) ? attr[6] : 1'b0;

	// Re-register video output to DACs to clean up edges
	always @(posedge CLK or negedge nRESET) begin
		if (nRESET == 1'b0) begin
			// Asynchronous clear
			R <= 4'b0000;
			G <= 4'b0000;
			B <= 4'b0000;
		end else begin
			// Output video to DACs
			R <= {red, {3{bright & red}}};
			G <= {green, {3{bright & green}}};
			B <= {blue, {3{bright & blue}}};
		end
	end


	// This is what the contention model is supposed to look like.
	// We may need to emulate this to ensure proper compatibility.
	//
	// At vcounter = 0 and hcounter = 0 we are at
	// 14336*T since the falling edge of the vsync.
	// This is where we start contending RAM access.
	// The contention pattern repeats every 8 T states, with
	// CPU clock held during the first 6 of every 8 T states
	// (where one T state is two ticks of the horizontal counter).
	// Two screen bytes are fetched consecutively, display first
	// followed by attribute.  The cycle looks like this:
	// hcounter[3..1] = 000 Fetch data 1  nWAIT = 0
	//                  001 Fetch attr 1          0
	//                  010 Fetch data 2          0
	//                  011 Fetch attr 2          0
	//                  100                       1
	//                  101                       1
	//                  110                       0
	//                  111                       0

	// What we actually do is the following, interleaved with CPU RAM access
	// so that we don't need any contention:
	// hcounter[2..0] = 000 Fetch data (LOAD)
	//					001 Fetch data (STORE)
	//					010 Fetch attr (LOAD)
	//					011 Fetch attr (STORE)
	//					100 Idle
	//					101 Idle
	//					110 Idle
	//					111 Idle
	// The load/store pairs take place over two clock enables.  In VGA mode
	// there is one picture/attribute pair fetch per CPU clock enable.  In PAL
	// mode every other tick is ignored, so the picture/attribute fetches occur
	// on alternate CPU clocks.  At no time must a CPU cycle be allowed to split
	// a LOAD/STORE pair, as the bus routing logic will disconnect the memory from
	// the CPU during this time.

	// RAM address is generated continuously from the counter values
	// Pixel fetch takes place when hcounter(2) = 0, attribute when = 1
	assign VID_A = ((VGA == 1'b1 && hcounter[2] == 1'b0) || (VGA == 1'b0 && hcounter[1] == 1'b0)) ?
		// Picture
		{vcounter[8:7], vcounter[3:1], vcounter[6:4], hcounter[8:4]} :
		// Attribute
		{3'b110, vcounter[8:7], vcounter[6:4], hcounter[8:4]};

	// This timing model is completely uncontended.  CPU runs all the time.
	assign nWAIT = 1'b1;

	// First 192 lines are picture
	// Frame geometry, selected by PENTAGON. Sinclair 48K is 224
	// T-states per line and 312 lines per frame; Pentagon 128K is 232
	// per line and 320 lines. hcounter runs at twice the pixel rate, so
	// its limit is doubled (895 vs 911); vcounter[9:1] is the real line
	// number, so its limit is not.
	wire [9:0] hcount_last = PENTAGON ? 10'd911 : 10'd895;
	wire [8:0] vline_last  = PENTAGON ? 9'd319  : 9'd311;
	// Frame interrupt line: 248 on Sinclair, 239 on Pentagon.
	wire [8:0] int_line    = PENTAGON ? 9'd239  : 9'd248;

	assign vpicture = ~(vcounter[9] | (vcounter[8] & vcounter[7]));

	always @(posedge CLK or negedge nRESET) begin
		if (nRESET == 1'b0) begin
			// Asynchronous master reset
			hcounter <= 10'b0;
			vcounter <= 10'b0;
			flashcounter <= 5'b0;

			vblanking <= 1'b0;
			hblanking <= 1'b0;
			hpicture <= 1'b1;
			hsync <= 1'b0;
			vsync <= 1'b0;
			nIRQ <= 1'b1;
			nVID_RD <= 1'b1;

			pixels <= 10'b0;
			attr <= 8'b0;
		end else if (CLKEN == 1'b1) begin

			// activate nVID_RD in advance of pixel and attribute read so data
			// is present in time. This is needed for the SDRAM which is operated at
			// much lower speed than the orignal SRAM in the DE1/DE2
			if (blanking == 1'b0 &&
					(hcounter[3:1] == 3'b111 ||
					 hcounter[3:1] == 3'b000 ||
					 hcounter[3:1] == 3'b001 ||
					 hcounter[3:1] == 3'b010))
				nVID_RD <= 1'b0;
			else
				nVID_RD <= 1'b1;

			// Most functions are only performed when hcounter(0) is clear.
			// This is the 'half' bit inserted to allow for scan-doubled VGA output.
			// In VGA mode the counter will be stepped through the even values only,
			// so the rest of the logic remains the same.
			if (vpicture == 1'b1 && hcounter[0] == 1'b1) begin
				// Pump pixel shift register - this is two pixels longer
				// than a byte to delay the pixels back into alignment with
				// the attribute byte, stored two ticks later
				pixels[9:1] <= pixels[8:0];

				// in TV mode everything happens a little slower. Fetch data ahead of
				// time to have the same memory timing as VGA
				if (hcounter[9] == 1'b0 && hcounter[3] == 1'b0) begin
					if (hcounter[2] == 1'b0) begin
						if (hcounter[1] == 1'b0)
							pixels_tv <= VID_D_IN;
						else
							attr_tv <= VID_D_IN;
					end
				end

				if (hcounter[9] == 1'b0 && hcounter[3] == 1'b0) begin
					// Handle the fetch cycle
					// 3210
					// 0000 PICTURE LOAD
					// 0010 PICTURE STORE
					// 0100 ATTR LOAD
					// 0110 ATTR STORE
					if (hcounter[1] == 1'b1) begin
						// STORE
						if (hcounter[2] == 1'b0) begin
							// PICTURE
							if (VGA == 1'b1)
								pixels[7:0] <= VID_D_IN;
							else
								pixels[7:0] <= pixels_tv;
						end else begin
							// ATTR
							if (VGA == 1'b1)
								attr <= VID_D_IN;
							else
								attr <= attr_tv;
						end
					end
				end

				// Delay horizontal picture enable until the end of the first fetch cycle
				// This also allows for the re-registration of the outputs
				if (hcounter[9] == 1'b0 && hcounter[2:1] == 2'b11)
					hpicture <= 1'b1;
				if (hcounter[9] == 1'b1 && hcounter[2:1] == 2'b11)
					hpicture <= 1'b0;
			end

			// Frame geometry. Sinclair 48K is 224 T-states per line and 312
			// lines; Pentagon 128K is 232 per line and 320 lines. hcounter
			// runs at twice the pixel rate so its limits are doubled.
			// Step the horizontal counter and check for wrap
			if (VGA == 1'b1) begin
				// Counter wraps after 894 in VGA mode
				if (hcounter == hcount_last) begin
					if (MEM_CYC == 1'b1) begin
						hcounter <= 10'b0;
						// Increment vertical counter by ones for VGA so that
						// lines are double-scanned
						vcounter <= vcounter + 1'b1;
					end
				end else begin
					// Increment horizontal counter
					// Even values only for VGA mode
					hcounter <= hcounter + 2'b10;
				end

				hcounter[0] <= 1'b1;
			end else begin
				// Counter wraps after 895 in PAL mode
				if (hcounter == hcount_last) begin
					if (MEM_CYC == 1'b1) begin
						hcounter <= 10'b0;
						// Increment vertical counter by even values for PAL
						vcounter <= vcounter + 2'b10;
						vcounter[0] <= 1'b0;
					end
				end else begin
					// Increment horizontal counter
					// All values for PAL mode
					hcounter <= hcounter + 1'b1;
				end
			end


			//--------------------
			// HORIZONTAL
			//--------------------

			// Each line comprises the following:
			// 256 pixels of active image
			// 48 pixels right border
			// 24 pixels front porch
			// 32 pixels sync
			// 40 pixels back porch
			// 48 pixels left border

			// Generate timing signals during inactive region
			// (when hcounter(9) = 1)
			case (hcounter[9:4])
				// Blanking starts at 304
				6'b100110: hblanking <= 1'b1;
				// Sync starts at 328
				6'b101001: hsync <= 1'b1;
				// Sync ends at 360
				6'b101101: hsync <= 1'b0;
				// Blanking ends at 400
				6'b110010: hblanking <= 1'b0;
				default: begin
				end
			endcase

			// Clear interrupt after 32T
			if (hcounter[7] == 1'b1)
				nIRQ <= 1'b1;

			// Assert the frame interrupt. Kept separate from the vsync
			// case below because the two do not coincide on Pentagon:
			// vsync stays where it is (the picture is still PAL-shaped,
			// the frame is simply longer) while the interrupt moves to
			// line 239. On Sinclair this reproduces the previous
			// behaviour exactly - vcounter[9:3] == 7'b0111110 is lines
			// 248..251, i.e. vcounter[9:1] in 248..251.
			if (PENTAGON == 1'b1) begin
				if (vcounter[9:1] == int_line)
					nIRQ <= 1'b0;
			end else begin
				if (vcounter[9:3] == 7'b0111110)
					nIRQ <= 1'b0;
			end

			//----------------
			// VERTICAL
			//----------------

			case (vcounter[9:3])
				7'b0111110: begin
					// Start of blanking and vsync(line 248)
					vblanking <= 1'b1;
					vsync <= 1'b1;
				end
				7'b0111111: begin
					// End of vsync after 4 lines (line 252)
					vsync <= 1'b0;
				end
				7'b1000000: begin
					// End of blanking and start of top border (line 256)
					// Should be line 264 but this is simpler and doesn't really make
					// any difference
					vblanking <= 1'b0;
				end
				default: begin
				end
			endcase

			// Wrap vertical counter at line 312-1,
			// Top counter value is 623 for VGA, 622 for PAL
			if (vcounter[9:1] == vline_last) begin
				if ((VGA == 1'b1 && vcounter[0] == 1'b1 && hcounter == hcount_last) ||
					 (VGA == 1'b0 && hcounter == hcount_last)) begin
					// Start of picture area
					vcounter <= 10'b0;
					// Increment the flash counter once per frame
					flashcounter <= flashcounter + 1'b1;
				end
			end
		end
	end

endmodule
