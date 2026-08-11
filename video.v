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
	// Frame timing: which machine to be. See the geometry table below.
	MACHINE,

	// Memory interface
	VID_A,
	VID_D_IN,
	nVID_RD,
	nWAIT,
	// Arbiter handshake: which byte is being asked for, and the strobe
	// that hands one back. Video no longer reads the bus at a fixed
	// moment - the CPU has priority now, so a fetch can land in any
	// cycle and only the strobe says when it has.
	VID_REQ_STEP,
	VID_REQ_ACK,
	VID_DATA_VALID,
	VID_DATA_STEP,

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
	input   [1:0]   MACHINE;

	// Machine codes, shared with spectrum_top.v
	localparam MACHINE_S48  = 2'd0;   // Sinclair 48K
	localparam MACHINE_S128 = 2'd1;   // Sinclair 128K
	localparam MACHINE_S3   = 2'd2;   // Sinclair +2A/+3
	localparam MACHINE_PENT = 2'd3;   // Pentagon 128K

	output  [12:0]  VID_A;
	input   [7:0]   VID_D_IN;
	output          nVID_RD;
	output          nWAIT;

	output          VID_REQ_STEP;
	input           VID_REQ_ACK;
	input           VID_DATA_VALID;
	input           VID_DATA_STEP;

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

	// First 192 lines are picture
	//
	// Frame geometry, taken from zx-sizif-512 (cpld/rtl/video.sv for the
	// line and frame totals, cpld/rtl/cpu.sv for the interrupt). One
	// T-state is four hcounter counts here - hcounter runs at 14MHz and
	// the CPU at 3.5MHz - so a 224 T-state line is 896 counts and a 228
	// T-state line is 912. Sizif counts horizontally in pixels (7MHz),
	// which is half our rate, hence the doubling of its interrupt
	// positions.
	//
	//   machine    T/line  lines   T/frame   INT line  INT pos  INT len
	//   48K          224     312    69888      248        0       32 T
	//   128K         228     311    70908      248        2 T     36 T
	//   +2A/+3       228     311    70908      248        2 T     36 T
	//   Pentagon     224     320    71680      239      161 T     32 T
	//
	// vcounter[9:1] is the real line number, so its limit is not doubled.
	wire lines228 = (MACHINE == MACHINE_S128) | (MACHINE == MACHINE_S3);

	wire [9:0] hcount_last = lines228 ? 10'd911 : 10'd895;
	wire [8:0] vline_last  =
		(MACHINE == MACHINE_PENT) ? 9'd319 :
		lines228                  ? 9'd310 :
		                            9'd311;

	// Getting the horizontal position wrong shifts everything a demo
	// draws relative to the interrupt - fired at the start of the line
	// instead, raster bars come out visibly too high.
	wire [8:0] int_line =
		(MACHINE == MACHINE_PENT) ? 9'd239 : 9'd248;
	wire [9:0] int_hpos =
		(MACHINE == MACHINE_PENT) ? 10'd644 :
		lines228                  ? 10'd8   :
		                            10'd0;
	wire [9:0] int_len =
		lines228 ? 10'd144 : 10'd128;

	// Fetch address registers, after zx-sizif-512's video.sv.
	//
	// The address used to be generated combinationally from the live
	// counters, which only works while the fetch is nailed to a fixed
	// memory cycle. Now that the CPU has priority and video takes
	// whatever cycle is free, a request can be served a cycle or two
	// later than it was made - by which time the live counters have
	// moved on and point somewhere else entirely. Capturing the group's
	// address once, up front, makes a displaced read still fetch the
	// right byte.
	reg     [8:1]   vaddr_r;
	reg     [8:4]   haddr_r;
	// 0 = pixels, 1 = attribute, 2 = both done for this group
	reg     [1:0]   read_step;
	reg     [7:0]   pixels_next;
	reg     [7:0]   attr_next;

	assign VID_REQ_STEP = read_step[0];

	assign VID_A = (read_step == 2'd0) ?
		// Picture
		{vaddr_r[8:7], vaddr_r[3:1], vaddr_r[6:4], haddr_r} :
		// Attribute
		{3'b110, vaddr_r[8:7], vaddr_r[6:4], haddr_r};

	// Start the group's fetch half a group early - 8 hcounter ticks, so
	// four SDRAM cycles of slack before the first byte is needed at
	// hcounter[3:0]==0011. Fetching inside the group, as the fixed
	// schedule did, leaves under two cycles: fine when the slot was
	// pre-aligned, not enough once a CPU access can get in front.
	wire fetch_start = (hcounter[3:0] == 4'b1000);
	// The group being set up is the one after the current one. In the
	// last group of a line that is group 0 of the next line, so the
	// line number has to be stepped as well - vcounter[0] is the
	// half-line bit, so the line number is vcounter[8:1].
	//
	// Compared against hcount_last rather than a fixed 6'b111111: the
	// counter only runs to 895 (or 911 on the 228 T-state machines), so
	// it never reaches group 63 and the wrap case never fired at all.
	// Group 0 of every line then kept whatever address the previous
	// line's last fetch left behind, which is visible as artefacts down
	// the left edge of the picture.
	wire line_wrap = (hcounter[9:4] == hcount_last[9:4]);
	// Only groups that are actually displayed need fetching. Vertical
	// position is deliberately not checked: a wasted read in the top or
	// bottom border costs nothing now that the CPU is served first.
	wire fetch_wanted = line_wrap |
		((hcounter[9] == 1'b0) & (hcounter[8:4] != 5'b11111));

	// A request stands until the arbiter acknowledges it.
	assign nVID_RD = (read_step == 2'd2);

	// Runs on the full 28MHz clock rather than under CLKEN: the ack and
	// data-valid strobes are one 28MHz clock wide, and a block gated by
	// the 14MHz enable would sample straight past them.
	always @(posedge CLK or negedge nRESET) begin
		if (nRESET == 1'b0) begin
			vaddr_r     <= 8'b0;
			haddr_r     <= 5'b0;
			read_step   <= 2'd2;
			pixels_next <= 8'b0;
			attr_next   <= 8'b0;
		end else begin
			if (CLKEN == 1'b1 && fetch_start == 1'b1) begin
				vaddr_r   <= line_wrap ? (vcounter[8:1] + 1'b1) : vcounter[8:1];
				haddr_r   <= line_wrap ? 5'b0 : (hcounter[8:4] + 1'b1);
				read_step <= fetch_wanted ? 2'd0 : 2'd2;
			end else if (VID_REQ_ACK == 1'b1 && read_step != 2'd2) begin
				read_step <= read_step + 1'b1;
			end

			// The step tag arrives with the data instead of being read
			// from read_step, which by now has usually moved on to the
			// next request.
			if (VID_DATA_VALID == 1'b1) begin
				if (VID_DATA_STEP == 1'b0)
					pixels_next <= VID_D_IN;
				else
					attr_next <= VID_D_IN;
			end
		end
	end

	// This timing model is completely uncontended.  CPU runs all the time.
	assign nWAIT = 1'b1;

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

			pixels <= 10'b0;
			attr <= 8'b0;
		end else if (CLKEN == 1'b1) begin

			// Most functions are only performed when hcounter(0) is clear.
			// This is the 'half' bit inserted to allow for scan-doubled VGA output.
			// In VGA mode the counter will be stepped through the even values only,
			// so the rest of the logic remains the same.
			if (vpicture == 1'b1 && hcounter[0] == 1'b1) begin
				// Pump pixel shift register - this is two pixels longer
				// than a byte to delay the pixels back into alignment with
				// the attribute byte, stored two ticks later
				pixels[9:1] <= pixels[8:0];

				// Move the prefetched bytes into the live registers at
				// the same instants the old fixed-slot code did, so the
				// picture keeps its horizontal alignment. Both bytes
				// were fetched during the previous group and are only
				// overwritten from hcounter[3:0]==1000 onwards, well
				// after they have been consumed here.
				if (hcounter[9] == 1'b0 && hcounter[3] == 1'b0) begin
					// 3210
					// 0011 PICTURE STORE
					// 0111 ATTR STORE
					if (hcounter[1] == 1'b1) begin
						if (hcounter[2] == 1'b0)
							pixels[7:0] <= pixels_next;
						else
							attr <= attr_next;
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

			// Frame interrupt: one window on one line, the same shape
			// for every machine. Kept separate from the vsync case
			// below because the two do not coincide on Pentagon - vsync
			// stays where it is (the picture is still PAL-shaped, the
			// frame is simply longer) while the interrupt moves to line
			// 239, most of a line in.
			//
			// This replaces a cruder pair of rules that asserted for
			// four whole lines and cleared on hcounter[7], which held
			// the interrupt for the wrong length on every machine.
			if (vcounter[9:1] == int_line &&
			    hcounter >= int_hpos && hcounter < (int_hpos + int_len))
				nIRQ <= 1'b0;
			else
				nIRQ <= 1'b1;

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
