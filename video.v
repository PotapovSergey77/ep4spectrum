// ZX Spectrum for Altera DE1
//
// Copyright (c) 2009-2011 Mike Stirling
//
// Modifications copyright (c) 2026 Sergey Potapov (potapov.sergey.77@gmail.com)
//
// Changes:
//   - Per-machine raster geometry: line and frame lengths, and the
//     interrupt's line, position and length, for 48K, 128K/+2, +2A/+3
//     and Pentagon.
//   - ULA contention window brought out on CONTENTION, with the
//     published 6,5,4,3,2,1,0,0 pattern over 128 of the 224 T-states of
//     each display line, and a runtime trim on CONT_ADJ.
//   - Border output delayed by three pixel-rate stages so a write to
//     port 0xFE takes effect where the ULA puts it.
//   - Port 0xFF (floating bus) value exported on PORT_FF_ACTIVE/DATA.
//   - Display fetches turned into a request/acknowledge handshake with
//     the SDRAM arbiter in spectrum_top.v, replacing direct reads.
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
	CONTENTION,
	CONTENTION_IO,
	INT_ADJ,
	INT_VADJ,
	CONT_ADJ,
	IO_ADJ,
	BORD_PHASE,
	PORT_FF_ACTIVE,
	PORT_FF_DATA,

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
	VID_REQ_GEN,
	VID_STALE,
	VID_REQ_ACK,
	VID_DATA_VALID,
	VID_DATA_STEP,
	VID_DATA_GEN,

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
	output          CONTENTION;
	// Same window a T-state earlier, for IO - see the assign below.
	output          CONTENTION_IO;
	input   [7:0]   INT_ADJ;
	input   [7:0]   INT_VADJ;
	input   [4:0]   CONT_ADJ;
	// Shifts the IO window alone, a CPU T-state a step and signed, on
	// top of the fixed one-T-state lead below. Memory contention is
	// measured exact now - Tact Meter agrees with a real machine - so
	// what is left has to be trimmed without touching it.
	input   [4:0]   IO_ADJ;
	// Which sixteenth of a group the border boundary sits on.
	input   [3:0]   BORD_PHASE;
	output          PORT_FF_ACTIVE;
	output  [7:0]   PORT_FF_DATA;

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
	output          VID_REQ_GEN;
	output          VID_STALE;
	input           VID_REQ_ACK;
	input           VID_DATA_VALID;
	input           VID_DATA_STEP;
	input           VID_DATA_GEN;

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
	// Interrupt pulse, counted out from its start position
	reg     [9:0]   int_cnt = 10'd0;
	reg             int_armed = 1'b1;

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

	// ULA contention, from zx-sizif-512's video.sv:
	//
	//   contention = (vc < V_AREA) && (hc < H_AREA) && (hc[2] || hc[3])
	//
	// which holds the CPU for six T-states out of every eight while the
	// ULA is fetching, over the 192 display lines and 256 columns. That
	// is the pattern the comment further down this file describes and
	// which this design has never actually had - the CPU ran at full
	// speed on every machine, which is right for Pentagon and wrong for
	// the Sinclairs.
	//
	// hcounter runs at twice the pixel rate here, so Sizif's hc[2] and
	// hc[3] are hcounter[3] and hcounter[4], and hc < 256 is
	// hcounter[9] == 0.
	// CONT_ADJ shifts the whole window - both its edges and the pattern
	// inside it - one CPU T-state a step, signed.
	//
	// It used to move only the pattern, leaving the edges pinned to
	// hcounter: the window ran counts 0..511 while the picture runs
	// 7..518, an offset of seven counts that nothing had ever checked.
	// On the board a demo's border stripes break at the same place on
	// every line, at the right-hand edge of the picture, which is where
	// this window ends - and with only the pattern movable there was no
	// way to test that. The amount of delay and its shape do not change;
	// only where the window sits in the line.
	// Written from the published delay table rather than copied.
	//
	// A contended access beginning at T-state offset 0..7 of the window
	// is delayed 6,5,4,3,2,1,0,0 - so the free pair is at the end of the
	// eight, and an access is held until the window's sixth T-state.
	// Holding while the offset is below 6 gives exactly that: an access
	// at offset k waits 6-k, and offsets 6 and 7 pass straight through.
	//
	// zx-sizif-512's `hc[2] || hc[3]` put the free pair at the start
	// instead, which is the same shape rotated by two T-states. Measured
	// here before the change, the table came out 0,0,6,5,4,3,2,1.
	//
	// A T-state is four hcounter counts and the window is thirty-two, so
	// hcounter[4:2] is the offset.
	// Declared here rather than beside the frame geometry further down,
	// where these used to be: they are needed above that point now, and
	// a name used before its declaration becomes an implicit one-bit net
	// instead. ModelSim rejects that outright; Quartus built it without
	// a word, and the board ran with this window computed from a single
	// bit - which is why moving the window there changed nothing.
	wire lines228 = (MACHINE == MACHINE_S128) | (MACHINE == MACHINE_S3);
	wire [9:0] hcount_last = lines228 ? 10'd911 : 10'd895;
	wire [8:0] vline_last  =
		(MACHINE == MACHINE_PENT) ? 9'd319 :
		lines228                  ? 9'd310 :
		                            9'd311;
	wire signed [12:0] hline = {3'b000, hcount_last} + 13'sd1;

	// Wrapped into the line, so a negative trim near the start of a line
	// lands at its end rather than turning into a huge unsigned count -
	// the same trap the interrupt position fell into.
	//
	// The -4 (one T-state, four hcounter counts) is structural, not a
	// trim, and is why CONT_ADJ can stay centred on zero. The CPU side
	// charges contention when it sees MREQ_n or IORQ_n go low, and both
	// of those are first visible in T2 here - MREQ because T80se raises
	// it on the edge that ends TState 1 where a real Z80 has it in T1,
	// IORQ because T2 is where it genuinely belongs. So the charge lands
	// one T-state after the machine cycle it belongs to started, for
	// every access alike, and winding the window back one T-state makes
	// the delay come out against the cycle's own T1 - which is what the
	// published table is written in terms of and what a program can time
	// against.
	//
	// One window covers memory and IO both. Giving them separate windows
	// a T-state apart was tried, on the theory that MREQ-in-T1 and
	// IORQ-in-T2 need different corrections; measurement says they do
	// not, because T80se's MREQ is late by exactly the amount that makes
	// the two agree. (Requires T2Write=1 on the T80se instance so a
	// write's MREQ is on the same edge as a read's.)
	wire signed [12:0] hc_sum =
		{3'b000, hcounter} + {{6{CONT_ADJ[4]}}, CONT_ADJ, 2'b00} - 13'sd4;
	wire signed [12:0] hc_wrap =
		(hc_sum < 0)      ? (hc_sum + hline) :
		(hc_sum >= hline) ? (hc_sum - hline) : hc_sum;
	wire [9:0] hc_cont = hc_wrap[9:0];
	// The Amstrad gate array has its own pattern: 7,6,5,4,3,2,1,0 rather
	// than the Ferranti ULA's 6,5,4,3,2,1,0,0 - eight delays where the
	// ULA has six, so every phase of the group is charged something.
	// (sinclair.wiki.zxnet.co.uk; its window also starts later and
	// repeats every 228 T-states, which the 228-count line already gives
	// on this machine.) One pattern was used for all four machines.
	wire [2:0] cont_span = (MACHINE == MACHINE_S3) ? 3'd7 : 3'd6;
	assign CONTENTION = vpicture & ~hc_cont[9]
	                    & (hc_cont[4:2] < cont_span);

	// The IO window, kept as a separate signal only so IO_ADJ can trim it.
	//
	// It was genuinely a second window for a while, offset from memory,
	// because memory is charged against T1 of the machine cycle while IO
	// was charged off IORQ, which T80se does not show until T2. Against a
	// shared window every IO delay then came out a T-state short of the
	// published table - measured, a program writing the border at a fixed
	// instruction spacing was charged 3 where the table gives 4, at every
	// phase with real statistics behind it. The window was moved to +8 on
	// the board to make up for it.
	//
	// That was treating the symptom. The walk now starts at the IO cycle's
	// real T1 (spectrum_top.v, io_cyc off the microcode's IO_CYC), so the
	// missing T-state is gone at its source and the offset below is zero.
	//
	// The pattern was never the problem. ioscan.hex sweeps an OUT to
	// $02FE - high byte outside the contended page, the case ula48 uses -
	// across every phase, and the delays come out 4,3,2,1 on phases 1..4
	// and 0 on phase 6, the published N:1,C:3 row exactly. A right pattern
	// in the wrong place is what displaces a stream of OUTs progressively
	// along the line, which is the shape the squares demo showed: one edge
	// out by four pixels, the next by eight.
	//
	// FUSE, where both of these demos render right, has no second window
	// at all: machines/spec48.c gives contend_delay and contend_delay_no_
	// mreq as the same function, machine.c fills both tables from it, and
	// memory and IO index that one table with the same absolute T-state.
	// IO_ADJ stays because the board is the only thing that can answer a
	// question, but it is a trim now and not a correction: if the model is
	// right it reads zero.
	wire signed [12:0] hi_sum  = hc_sum
	                             + {{6{IO_ADJ[4]}}, IO_ADJ, 2'b00};
	wire signed [12:0] hi_wrap =
		(hi_sum < 0)      ? (hi_sum + hline) :
		(hi_sum >= hline) ? (hi_sum - hline) : hi_sum;
	wire [9:0] hc_io = hi_wrap[9:0];
	assign CONTENTION_IO = vpicture & ~hc_io[9]
	                       & (hc_io[4:2] < cont_span);


	// The border colour is latched rather than taken straight off the
	// port. zx-sizif-512's video.sv has:
	//
	//   border_update = (hc0[4:0] == 5'b10011) || (machine == PENT && ck7)
	//
	// - once per 8-pixel group on the Sinclair machines, every pixel
	// tick on Pentagon. The group is the part not kept here; see below.
	// Latching at all matters though. Using it combinationally, as this did, looks
	// finer but is not what a ULA does: the edge then lands wherever
	// inside a pixel the CPU happened to write, and where that is
	// depends on the CPU's phase. That is a border edge that will not
	// hold still to within a pixel or two.
	//
	// hcounter runs at twice the pixel rate here, so a pixel tick is
	// hcounter[0].
	//
	// Every machine samples at the pixel rate. The Sinclair machines
	// used to sample once per 8-pixel group instead, on the assumption
	// that the border follows the character grid the way the screen
	// fetch does. It does not: a ULA drives the border straight from the
	// port latch, with no character-cell boundary in the way, which is
	// why the pixel rate is what came out right for Pentagon on the
	// board. The group cost every border change up to eight pixels, and
	// on the board a demo drawing text in the border sat exactly that
	// far right of where it belongs.
	// The group is back, and with a phase this time.
	//
	// It was removed because putting it in moved a border-drawn text
	// demo eight pixels right - which is what a group does when its
	// boundary is in the wrong place, and is a reason to set the phase
	// rather than to drop the quantisation.
	//
	// Dropping it left the border able to change on any pixel, and a
	// real 48K cannot do that: its ULA takes the border once per
	// 8-pixel group, so a border edge can only ever land on a group
	// boundary. That is the whole of the four-pixel residual - half a
	// group, a position the machine being copied cannot produce - and
	// it is why no amount of delay or interrupt trimming would take it:
	// every knob moved the edge by whole pixels within a grid that
	// should not have existed.
	//
	// hcounter runs at twice the pixel rate, so a group is sixteen
	// counts. The phase is set to the display's own character grid: the
	// picture turns on at hcounter[2:1] == 2'b11, which puts cell
	// boundaries at count 7 of every sixteen.
	// The phase is a runtime trim now, on keypad - and +, so sixteen
	// values can be tried in half a minute instead of one per rebuild.
	reg     [2:0]   border_latched = 3'b000;
	wire            border_update = (MACHINE == MACHINE_PENT)
	                                ? (hcounter[0] == 1'b1)
	                                : (hcounter[3:0] == BORD_PHASE);
	// One further pixel of delay before it reaches the screen.
	//
	// With the interrupt at its authentic position the picture drawn in
	// the border still sat one pixel left of where a real Pentagon puts
	// it. That last pixel belongs to the border path rather than to the
	// interrupt - it is the same place the real machine's own
	// adjustment acts - so it is corrected here instead of by moving
	// the interrupt off the position that is otherwise right.
	//
	// It has to be clocked at the pixel rate to cost a pixel. Both
	// stages used to share border_update, which was the pixel rate only
	// on Pentagon - where this was measured. On the Sinclair machines
	// that enable arrived once every eight pixels, so the stage meant to
	// cost one pixel cost a whole character cell.
	//
	// Two further pixels on top of that, which are a correction for
	// something outside this file. T2Write=1 on the T80se instance in
	// spectrum_top.v moves an OUT's IORQ and WR from T3 into T2, so the
	// ULA port latches a border write one T-state earlier than it used
	// to - and a T-state at 3.5MHz is two pixels, which is exactly how
	// far left the border moved when that went in. The write has to stay
	// early: it is what makes the write visible to T80 when it samples
	// WAIT at the end of T2, and contention, the turbo modes and DivMMC
	// all depend on that. So only its visible consequence is taken back,
	// here, where the machine's own border adjustment already acts.
	//
	// The cause is machine-independent, so this delay is too - it is not
	// a Pentagon-only trim, even though Pentagon is where it shows up
	// cleanest, having no contention to smear the OUT across a slot.
	// The chain is longer than the three stages the picture needs, so
	// the border OUTSIDE the display lines can be tapped at a different
	// point from the border beside them. BORD_ADJ picks that tap.
	//
	// This exists because the fault is confined to the border above and
	// below the raster: there the stripes sit right of where they
	// belong, while beside the raster they are correct. Moving the whole
	// frame cannot express that - it shifts all three areas alike, which
	// is why the interrupt trim did nothing useful. This knob moves only
	// the two areas that are wrong.
	//
	// Range: BORD_ADJ 0 keeps the present three stages, positive values
	// delay further (stripes move right), and it can be wound back to
	// zero stages for three pixels of left shift - no more, because
	// moving left further would mean tapping the chain before the value
	// exists. If the answer turns out to need more left than that, the
	// displacement is not in the output path and this knob will say so
	// by running out.
	// A whole line of history, written as a circular buffer rather than
	// a shift register so it costs one memory block instead of hundreds
	// of registers.
	//
	// The length is what makes a LEFT shift possible at all. Tapping the
	// chain can only ever delay, and the stripes above the raster need
	// to move left - which cannot be done by delaying, because the value
	// has not happened yet. But the border repeats line to line here
	// (the stripes are aligned vertically, no stagger), so delaying by
	// nearly a whole line is indistinguishable from advancing by the
	// remainder. Winding BORD_ADJ back past zero wraps to the far end of
	// the buffer and shows the same stripe one line older, which reads
	// on screen as a shift to the left.
	// A line-long buffer was tried here, so the border outside the
	// display lines could be shifted either way independently of the
	// border beside them. **It settled the question and was removed.**
	// No setting of it lined the stripes up, and on a text demo the
	// displacement turned out to vary ALONG the line - which no output
	// delay can produce, since a delay shifts a whole line equally. The
	// displacement is in how many T-states the CPU spends getting to
	// each OUT, not in when the border reaches the screen. It also cost
	// 94% of the device's logic, being 448 registers wide.
	reg     [2:0]   border_d1  = 3'b000;
	reg     [2:0]   border_d2  = 3'b000;
	reg     [2:0]   border_d3  = 3'b000;
	reg     [2:0]   border_d4  = 3'b000;
	reg     [2:0]   border_d5  = 3'b000;
	reg     [2:0]   border_d6  = 3'b000;
	reg     [2:0]   border_d7  = 3'b000;
	reg     [2:0]   border_out = 3'b000;
	always @(posedge CLK or negedge nRESET) begin
		if (nRESET == 1'b0) begin
			border_latched <= 3'b000;
			border_d1      <= 3'b000;
			border_d2      <= 3'b000;
			border_d3      <= 3'b000;
			border_d4      <= 3'b000;
			border_d5      <= 3'b000;
			border_d6      <= 3'b000;
			border_d7      <= 3'b000;
			border_out     <= 3'b000;
		end else if (CLKEN == 1'b1) begin
			if (border_update == 1'b1)
				border_latched <= BORDER_IN;
			if (hcounter[0] == 1'b1) begin
				border_d1  <= border_latched;
				border_d2  <= border_d1;
				border_d3  <= border_d2;
				border_d4  <= border_d3;
				border_d5  <= border_d4;
				border_d6  <= border_d5;
				border_d7  <= border_d6;
				// 48K taps four pixels further down the chain, and its
				// interrupt sits two T-states earlier to match.
				//
				// The pair cancels for anything that takes the interrupt
				// as it comes: two T-states earlier is four pixels left,
				// four pixels of delay puts them back. It does not
				// cancel for a program that waits in HALT. There the
				// CPU polls the interrupt line every four T-states, so
				// acceptance cannot move by two - it either stays where
				// it was or jumps a whole step of eight pixels. Measured
				// on the board: ula48 did not move at all when the
				// interrupt went from 8 to 0, and the birds demo jumped
				// eight pixels.
				//
				// So the interrupt buys the birds eight pixels left and
				// the delay gives four of them back, leaving the four
				// that were wrong. Nothing else on the machine moves,
				// and Pentagon is not touched at all.
				// Every machine taps the same place again. The 48K used
				// to tap two pixels earlier, which was an attempt to
				// take the four-pixel residual out of the delay - the
				// chain measured two pixels of range in simulation and
				// the residual was four, so it could not reach. The
				// quantisation above is where that belongs.
				border_out <= border_d2;
			end
		end
	end

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
		(blanking == 1'b0) ? border_out[1] :
		1'b0;
	assign green = (picture == 1'b1 && dot == 1'b1) ? attr[2] :
		(picture == 1'b1 && dot == 1'b0) ? attr[5] :
		(blanking == 1'b0) ? border_out[2] :
		1'b0;
	assign blue = (picture == 1'b1 && dot == 1'b1) ? attr[0] :
		(picture == 1'b1 && dot == 1'b0) ? attr[3] :
		(blanking == 1'b0) ? border_out[0] :
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
	// The line and frame lengths are declared with the contention window
	// near the top of the file, since it needs them.

	// Getting the horizontal position wrong shifts everything a demo
	// draws relative to the interrupt - fired at the start of the line
	// instead, raster bars come out visibly too high.
	// INT_VADJ trims the line, one sixteenth of a line a step. Which line
	// the interrupt falls on sets where in the frame everything a program
	// draws from it lands, so an entry that is out shows as border
	// effects sitting above or below where they belong.
	//
	// 48K's 247 is 245 with the board's trim of 0x21 - thirty-three
	// sixteenths, two lines and a sixteenth - folded in, the sixteenth
	// going to the position below. Set with a demo drawing border
	// stripes: 0x21 placed them best, and moving off it either way put
	// misplaced stripes somewhere else in the raster.
	//
	// 245 was Sizif's 248 less three lines, also measured here. 128K and
	// +2A/+3 keep it: the trim above was set on 48K, and folding it into
	// an entry those two share would move machines nobody has checked.
	// 48K's 248 and the position of 8 below are not eyeballed - they are
	// the only pair that gives the published figure. A 48K puts exactly
	// 14336 T-states between the interrupt and the first pixel of the
	// screen, and 64 whole lines at the picture's own horizontal start
	// is 64 * 896 counts = 57344 = 14336 T on the nose.
	//
	// The board-trimmed 247 and 880 that stood here came to 14342, six
	// T-states early - twelve pixels, which is about what setting it by
	// eye against a demo can resolve.
	// 128K and +2A/+3 use 248 as well, checked on the board 2026-08-17
	// with the Page Up / Page Down trim: both wanted the frame three
	// lines lower than 245 put it, which is exactly 248. So the "less
	// three lines" that came in with Sizif's table was wrong for them
	// too, and 48K was simply the machine where it got corrected first.
	// Pentagon keeps its own 239, set on the board against a demo that
	// draws in the border.
	// 48K is 247 rather than 248 because its position below is eight
	// counts - two T-states - into the tail of the previous line. See
	// int_hpos_base.
	// 48K sits one line earlier at position 888, which is eight steps -
	// two T-states - before position 0 of line 248. Written that way
	// because the counter cannot go below zero: a negative position
	// wraps to a huge number and no interrupt is generated at all, which
	// is a machine that will not start.
	wire [8:0] int_line_base =
		(MACHINE == MACHINE_PENT) ? 9'd239 : 9'd248;
	// Interrupt position. The table entry is zx-sizif-512's converted;
	// Pentagon's was then set on the board, where the picture drawn in
	// the border shows it directly.
	// INT_ADJ trims the position, two counts - one pixel - a step. Only
	// Pentagon's entry has been set against a real machine; the others
	// are zx-sizif-512's converted and have never been checked on the
	// board, which is what the trim is back for.
	// Pentagon's 622 was set the same way.
	// 128K and +2A/+3 are still Sizif's untouched.
	//
	// 48K was 8, and that is two CPU T-states too late. The testbench
	// measures the frame directly - `INT -> first paper pixel` - and it
	// came out 14335 where a 48K publishes 14336. On top of that the CPU
	// does not see nIRQ when the video asserts it: cpu_irq_n_sync
	// resamples on the CPU's own enable, and since the enables sit on
	// counter 7 and 15 while hcounter steps on the even counts, the
	// register holds the edge for exactly one whole T-state before the
	// CPU can sample it. So what a program actually gets is 14334.
	//
	// Four hcounter counts are one T-state, so 8 -> 0 hands both back:
	// the video's own figure becomes 14337 and the CPU's - the one that
	// decides where a program's border writes land - becomes 14336.
	//
	// This is not the one-T-state trim the note above `int_adj` in
	// spectrum_top.v warns off. That one cancelled the resampler alone
	// and left the geometry a T-state short; this is both, and it is the
	// interrupt-to-raster phase ula48's top border draws against.
	//
	// Then two more, for T80's own interrupt path. The testbench times
	// the gap from the edge to the start of the acknowledge with the CPU
	// halted, and across eight phases it comes out 2,2,3,3,4,4,5,5 - a
	// clean span of four, so the 4-T-state M1 cycles T80 runs in HALT
	// are right, but the whole span sits two T-states above the 0..3 a
	// Z80 gives. That is `INT_s`, which latches ~INT_n on CEN while the
	// decision reads it at T_Res, one T-state later, plus the pipelining
	// of IntCycle itself. It is a flat latency, not a missed boundary,
	// so handing the interrupt over two T-states early cancels it exactly
	// - on every phase, and against any instruction's boundary grid.
	//
	// 0 - 8 counts is the tail of the previous line: hence 888 here and
	// 247 rather than 248 above. What the CPU is shown is now 14338
	// before the first pixel, and it acknowledges where a Z80 handed the
	// interrupt at 14336 would.
	// 48K is back at the value b1e517e DERIVED rather than tuned: a 48K
	// puts exactly 14336 T-states between the interrupt and the first
	// pixel, and 64 whole lines at the picture's own horizontal start is
	// 64 * 896 = 57344 counts = 14336 T. Line 248, position 8.
	//
	// It had since been walked back four T-states in two steps - 8 -> 0
	// (4fac427) and then 0 -> 888 with the line at 247 (219544b) - each
	// time to cancel the CPU-side latency before the interrupt. That
	// reasoning does not hold for a demo that synchronises on HALT.
	// Moving the interrupt and removing latency enter the acceptance as
	// the same sum, so they are interchangeable; but the acceptance lands
	// on the CPU's 4-T-state poll grid either way, so neither can move it
	// by less than four. Measured on the board with the phase brought out
	// on keypad 0 and . : four consecutive trim values change nothing at
	// all, then it jumps eight pixels. Compensating here bought a jump
	// between grid points and was read as progress.
	//
	// So the compensation comes out and the derived figure goes back in.
	// What is left over after it - four pixels on the birds demo - is not
	// in the acceptance at all, and no value here will reach it.
	// Pentagon moves 622 -> 630: four pixels right, measured on the board.
	//
	// The counter runs at four steps per T-state - 896 of them across a
	// 224-T line - so a step is half a pixel and eight of them are the
	// four asked for. Which is also two T-states, and that is not a
	// coincidence: 622 was set while the CPU still lost two T-states
	// before taking an interrupt. Removing that latency moved every
	// machine, and this entry was never brought back in step. The figure
	// was predicted at the time and left unverified for want of a working
	// Pentagon to check it on; there is one now, and it reads as four
	// pixels, which is what two T-states look like.
	wire [9:0] int_hpos_base =
		(MACHINE == MACHINE_PENT) ? 10'd630 :
		// 48K moves 8 -> 0: four pixels LEFT, the mirror of Pentagon.
		//
		// ula48 draws its border with timed OUTs and its raster from
		// screen memory, so a border sitting four pixels right of the
		// raster is the phase between the interrupt and the sweep, not
		// where the picture starts - moving the display origin would
		// carry both and change nothing between them. Eight steps is two
		// T-states, and two T-states is what the CPU used to lose before
		// taking an interrupt.
		//
		// Worth saying plainly: 8 was put here as the figure derived
		// from 14336 and checked against libspectrum, so zero is two
		// T-states away from the reference. Either the derivation has an
		// end-point off by that much or our sweep starts two T-states
		// early - the board says the border is four pixels out, and
		// that is the measurement in hand.
		(MACHINE == MACHINE_S48)  ? 10'd0   :
		lines228                  ? 10'd8   :
		                            10'd0;
	// Wrapped into the line rather than added raw.
	//
	// The 48K entry is 0, so any negative trim took the position below
	// zero, where a ten-bit counter turns it into a huge number: the
	// window then matched nothing, no interrupt was generated at all
	// and the machine stopped dead. That is what trimming left did on
	// the board - and left is exactly where the right position appears
	// to be, so it could not be reached.
	// One sixteenth of a line. Both line lengths here divide by sixteen
	// exactly - 896 counts for 224 T-states gives 56, and 912 for 228
	// gives 57 - so sixteen steps come to precisely one line. Thirty-two
	// would not: 912 does not divide by it.
	wire signed [12:0] heighth = hline >>> 4;

	// The vertical trim is in sixteenths, so it splits into whole lines
	// and a part of a line that has to be carried into the position.
	// A whole line a step could not place the interrupt on the board -
	// two was short, three too far - and an eighth still could not:
	// eleven eighths left an artefact at the right edge and twelve moved
	// it to the left.
	//
	// Shifting right rounds towards minus infinity, which is what makes
	// the low four bits the remainder for negative values too - -1 is
	// -1 line plus fifteen sixteenths.
	wire signed [8:0] vadj_lines = $signed(INT_VADJ) >>> 4;
	wire       [3:0]  vadj_frac  = INT_VADJ[3:0];

	wire signed [12:0] int_hpos_raw =
		{3'b000, int_hpos_base} + {{5{INT_ADJ[7]}}, INT_ADJ}
		+ $signed({1'b0, vadj_frac}) * heighth;

	// The fraction can push the position past the end of the line, and
	// then the interrupt belongs on the next line - so the wrap counts
	// how many lines it carried rather than just folding the position.
	wire cy1 = (int_hpos_raw >= hline);
	wire signed [12:0] hp1 = cy1 ? (int_hpos_raw - hline) : int_hpos_raw;
	wire cy2 = (hp1 >= hline);
	wire signed [12:0] hp2 = cy2 ? (hp1 - hline) : hp1;
	wire bw1 = (hp2 < 0);
	wire signed [12:0] hp3 = bw1 ? (hp2 + hline) : hp2;
	wire [9:0] int_hpos = hp3[9:0];

	wire signed [9:0] int_line_s = $signed({1'b0, int_line_base})
		+ {{1{vadj_lines[8]}}, vadj_lines}
		+ (cy1 ? 10'sd1 : 10'sd0) + (cy2 ? 10'sd1 : 10'sd0)
		- (bw1 ? 10'sd1 : 10'sd0);
	wire [8:0] int_line = int_line_s[8:0];
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
	reg             fetch_gen = 1'b0;
	reg     [7:0]   pixels_next;
	reg     [7:0]   attr_next;
	// The floating bus on port 0xFF, from zx-sizif-512's video.sv:
	//
	//   port_ff_attr   = (machine == PENT) || hc[3:1] == 6 || hc[3:1] == 0
	//   port_ff_bitmap = hc[3] && hc[1]
	//   port_ff_active = screen_read && (attr || bitmap)
	//   port_ff_data   = attr ? attr_next : bitmap ? bitmap_next : FF
	//
	// Reading an unattached port on a real machine picks up whatever
	// the ULA is fetching at that moment, and programs use it to find
	// where the raster is. Pentagon always gives the attribute; the
	// Sinclairs give the attribute or the bitmap depending on where in
	// the fetch they are caught, and 0xFF elsewhere.
	//
	// Sizif's hc runs at the pixel rate, so its hc[3:1] is hcounter[4:2]
	// here and hc[3], hc[1] are hcounter[4], hcounter[2].
	wire port_ff_attr   = (MACHINE == MACHINE_PENT)
	                      | (hcounter[4:2] == 3'd6)
	                      | (hcounter[4:2] == 3'd0);
	wire port_ff_bitmap = hcounter[4] & hcounter[2];
	assign PORT_FF_ACTIVE = vpicture & ~hcounter[9]
	                        & (port_ff_attr | port_ff_bitmap);
	assign PORT_FF_DATA = port_ff_attr   ? attr_next   :
	                      port_ff_bitmap ? pixels_next :
	                                       8'hFF;

	assign VID_REQ_STEP = read_step[0];
	// Flips once per group. A fetch that is held up long enough to
	// come back after the next group has already been set up would
	// otherwise be filed under the new group - the step tag alone only
	// says pixels or attribute, not which group it belongs to. That
	// only happens when the CPU is busy enough to delay video, and the
	// position of the damage drifts from frame to frame, which is what
	// the moving artefacts on the board look like.
	assign VID_REQ_GEN = fetch_gen;
	// One pulse per discarded late byte, counted in spectrum_top.v and
	// shown on the display so the board can say whether this ever fires.
	assign VID_STALE = VID_DATA_VALID & (VID_DATA_GEN != fetch_gen);

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

	// The line whose group 0 is being set up. Plain +1 is wrong at the
	// end of the frame: the last line is 319 (or 311), and adding one to
	// the low bits of that does not give line 0, so the very first group
	// of the very first line was always fetched from the wrong address.
	// That is the top-left character cell coming out wrong on every
	// demo - and the single mismatch the video check had been reporting
	// all along, at line 0 group 0, which I had put down to a startup
	// artefact.
	wire [8:0] next_line = (vcounter[9:1] == vline_last) ? 9'd0 :
	                       (vcounter[9:1] + 1'b1);
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
			fetch_gen   <= 1'b0;
			pixels_next <= 8'b0;
			attr_next   <= 8'b0;
		end else begin
			if (CLKEN == 1'b1 && fetch_start == 1'b1) begin
				vaddr_r   <= line_wrap ? next_line[7:0] : vcounter[8:1];
				haddr_r   <= line_wrap ? 5'b0 : (hcounter[8:4] + 1'b1);
				read_step <= fetch_wanted ? 2'd0 : 2'd2;
				fetch_gen <= ~fetch_gen;
			end else if (VID_REQ_ACK == 1'b1 && read_step != 2'd2) begin
				read_step <= read_step + 1'b1;
			end

			// The step tag arrives with the data instead of being read
			// from read_step, which by now has usually moved on to the
			// next request.
			if (VID_DATA_VALID == 1'b1 && VID_DATA_GEN == fetch_gen) begin
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
			int_cnt <= 10'd0;
			int_armed <= 1'b1;

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
				// No longer waits for MEM_CYC. That made the line end
				// only when the memory window came round, tying the
				// video timebase to the memory schedule - which mattered
				// when video had fixed slots to hit and is pointless now
				// that it asks for cycles on demand. It also meant the
				// line was not exactly hcount_last+1 counts long.
				if (hcounter == hcount_last) begin
					hcounter <= 10'b0;
					// Increment vertical counter by even values for PAL
					vcounter <= vcounter + 2'b10;
					vcounter[0] <= 1'b0;
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
			// Started at the position and then counted out, rather than
			// matched as a window inside the line.
			//
			// As a window it could not outlive the line it began on. The
			// 48K position is 824 counts and a line is 896, so trimming
			// the position right clipped the interrupt against the end
			// of the line: at 824+58 what was meant to be 128 counts -
			// the 32 T-states a real machine holds - came out as 14, and
			// two counts further as 12. The CPU then caught it or missed
			// it by luck, which showed on the board as one press of the
			// trim leaving an artefact and the next hanging the demo.
			// Counting it out lets it run past the end of the line, and
			// past the end of the frame, which is what it must do.
			if (hcounter == 10'd0)
				int_armed <= 1'b1;

			if (int_cnt != 10'd0) begin
				int_cnt <= int_cnt - 10'd1;
				nIRQ <= 1'b0;
			end else
				nIRQ <= 1'b1;

			// Fires on the first count at or past the position, so it
			// does not depend on hitting it exactly - the counter steps
			// by two in VGA mode.
			if (int_armed == 1'b1 && vcounter[9:1] == int_line &&
			    hcounter >= int_hpos) begin
				int_armed <= 1'b0;
				int_cnt   <= int_len - 10'd1;
				nIRQ      <= 1'b0;
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
