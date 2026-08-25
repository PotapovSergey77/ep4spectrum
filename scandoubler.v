// scandoubler - 15.625kHz in, 31.25kHz out
//
// Copyright (c) 2026 Sergey Potapov (potapov.sergey.77@gmail.com)
//
// Takes the finished video stream - colour and syncs, after every delay
// and every mux - and shows each line twice at double the rate. The
// machine's own timing never learns that this exists.
//
// That is the whole reason it is a separate stage. video.v has a VGA
// input which steps its counters twice as fast, and with the original
// MiST code that was harmless because, as its own comment says, "this
// timing model is completely uncontended". Ours is not: the contention
// window, the interrupt position and the border group grid are all
// counted off the same hcounter, so doubling it halves them against a
// CPU that still runs at 3.5MHz. The raster came out fine and every
// border drawn by timed OUTs came apart. Doubling after the fact cannot
// do that: there is nothing left to get wrong by then.
//
// One line of storage, written at the input rate and read back twice at
// double it. Two lines are held rather than one so the read of a line
// never catches up with the write of the next.

module scandoubler (
	// 28MHz, and the input pixel enable at 14MHz
	input            CLK,
	input            CE_IN,
	input            nRESET,

	// The 15kHz stream, as it goes to the pins today
	input      [3:0] R_IN,
	input      [3:0] G_IN,
	input      [3:0] B_IN,
	input            HS_IN_n,
	input            VS_IN_n,
	// The on-screen line, which needs a dimmer duty than any colour and
	// so cannot travel as one.
	input            OSD_IN,

	// The same picture at twice the line rate
	output reg [3:0] R_OUT,
	output reg [3:0] G_OUT,
	output reg [3:0] B_OUT,
	output reg       HS_OUT_n,
	output reg       VS_OUT_n,
	output reg       OSD_OUT
);

	// A line is 896 input pixel-enables at most - Pentagon's is the
	// longest at 912 - so ten bits of address and one of line parity.
	// Four bits a channel would be twelve per pixel; the machine only
	// ever drives one bit and a brightness per channel, so three bits of
	// colour and one of brightness is the whole of it and the buffer
	// stays inside a single M9K.
	reg  [3:0] buf_a [0:2047];
	reg [10:0] wr_addr;
	reg        wr_line;
	reg [9:0]  out_x;
	reg        out_half;      // which of the two passes over the line
	reg [9:0]  line_len;
	// The width of the input sync pulse, in input pixels. wr_addr is
	// rewound by the falling edge and counts input pixels from it, so at
	// the rising edge it IS the width - measured every line rather than
	// written down here, which keeps this free of any machine's numbers.
	reg [9:0]  sync_len;
	// Declared before use. Quartus accepts a name used before it is
	// declared and quietly makes an implicit one-bit net of it, which is
	// how wr_line came to be declared twice here without a word said.
	wire [10:0] rd_addr = {~wr_line, out_x};

	// The four bits carried: one colour per channel and the brightness
	// they share. R_IN[3] is the colour and R_IN[0] the brightness, the
	// way video.v assembles {colour, {3{bright}}}.
	//
	// There is no room for a fifth bit - 2048 words of five is 10240
	// against an M9K's 9216 - and for a while the sync was stored here
	// instead, with brightness given up to make room. It does not have to
	// be: the buffer is rewound by the falling edge of the input hsync,
	// so the pulse always occupies the START of the line, from zero to
	// its own width. That is a position the output counter already knows,
	// and sync_len below measures the width rather than assuming it. So
	// the sync costs no storage and brightness keeps its bit.
	// The brightness stored is the RAW one, recovered by OR-ing the three
	// channels. video.v gates it with each channel's own colour -
	// {red, {3{bright & red}}} - so R_IN[0] alone is bright AND red, and
	// taking it for the brightness of all three loses it on every bright
	// colour without red in it: bright green, bright blue, bright cyan
	// all came out as ordinary ones and the picture looked dark. A pixel
	// with no colour at all is black whatever the brightness says, so the
	// OR cannot invent one.
	wire [3:0] pix_in = {R_IN[3], G_IN[3], B_IN[3],
	                    R_IN[0] | G_IN[0] | B_IN[0]};

	// The falling edge of the input hsync, found on the 28MHz clock and
	// held until it is used.
	//
	// It used to be looked for inside "if (CE_IN)", while the delayed
	// copy was updated outside it - so by the time an enable arrived the
	// two were already equal and the edge was gone. It was caught every
	// other line at best and, on the wrong phase, never: nothing reset
	// the write address or the output counter, and the screen showed a
	// stream with no line structure at all.
	reg  hs_in_d;
	wire hs_fall = (hs_in_d == 1'b1) && (HS_IN_n == 1'b0);
	wire hs_rise = (hs_in_d == 1'b0) && (HS_IN_n == 1'b1);
	always @(posedge CLK or negedge nRESET)
		if (nRESET == 1'b0) hs_in_d <= 1'b1;
		else                hs_in_d <= HS_IN_n;

	// One bit per buffer half: did the line written into it carry any of
	// the on-screen line. Every M9K on the device is spoken for, so the
	// per-pixel flag has nowhere to live - but it does not need to. The
	// line is drawn over the border, where video.v never sets brightness
	// on anything else, so on a line that carried it a bright green pixel
	// IS it. Two flip-flops scope that test to the right lines and keep a
	// bright green in an ordinary picture from being taken for text.
	reg [1:0] osd_line;
	always @(posedge CLK or negedge nRESET)
		if (nRESET == 1'b0)                     osd_line <= 2'b00;
		// The half about to be written - wr_line has not flipped yet here.
		else if (hs_fall == 1'b1)               osd_line[~wr_line] <= 1'b0;
		else if (OSD_IN == 1'b1 && CE_IN == 1'b1) osd_line[wr_line] <= 1'b1;

	// The pulse width, latched where it ends. Kept out of the write
	// chain below: sharing an else-if with the write would drop the one
	// input pixel that lands on this clock.
	always @(posedge CLK or negedge nRESET)
		if (nRESET == 1'b0)          sync_len <= 10'd64;
		else if (hs_rise == 1'b1)   sync_len <= wr_addr[10] ? 10'd1023
		                                                     : wr_addr[9:0];

	// --- input side, at the machine's own pixel rate ---
	always @(posedge CLK or negedge nRESET) begin
		if (nRESET == 1'b0) begin
			wr_addr <= 11'd0;
			wr_line <= 1'b0;
		end else if (hs_fall == 1'b1) begin
			// Start of a line: swap buffers and rewind.
			wr_line <= ~wr_line;
			wr_addr <= 11'd0;
		end else if (CE_IN == 1'b1 && wr_addr[10] == 1'b0) begin
			// Stopped at 1024 rather than allowed to wrap. A line is 896
			// enables and Pentagon's 912, so this never fires while CLK is
			// twice the input pixel rate. When it was not - the doubler on
			// clk56 while CE_IN came from the 28MHz domain - every pixel
			// was written twice, wr_addr[9:0] rolled over and quietly
			// overwrote the start of the same line. Clipping instead of
			// wrapping leaves a wrong ratio visible as a short line rather
			// than as a picture with no structure at all.
			buf_a[{wr_line, wr_addr[9:0]}] <= pix_in;
			wr_addr <= wr_addr + 11'd1;
		end
	end

	// Read port. One registered read of one array is the only shape
	// Quartus turns into an M9K; reading the array inside the output
	// expressions instead built it out of logic and asked for 340% of
	// the device.
	reg [3:0] rd_q;
	// The sync, one stage early, so it reaches the pins on the same clock
	// as the colour that was read alongside it. rd_q is out_x delayed by
	// one; hs_q is too, and both are registered once more on the way out.
	reg       hs_q;
	always @(posedge CLK) rd_q <= buf_a[rd_addr];

	// --- output side, at twice the rate ---
	//
	// Every 28MHz clock is an output pixel, so a line that took 896
	// input enables takes 896 output clocks - half the time - and is

	always @(posedge CLK or negedge nRESET) begin
		if (nRESET == 1'b0) begin
			out_x    <= 10'd0;
			out_half <= 1'b0;
			line_len <= 10'd896;
			R_OUT    <= 4'b0;
			G_OUT    <= 4'b0;
			B_OUT    <= 4'b0;
			OSD_OUT  <= 1'b0;
			hs_q     <= 1'b1;
			HS_OUT_n <= 1'b1;
			VS_OUT_n <= 1'b1;
		end else begin
			// The output counter is tied to the input hsync, because the
			// sync it generates has to stay in step with the buffer the
			// picture comes out of. Those are two counters, and the moment
			// the second is left to free-run they drift: the measured line
			// length is one short - the write counter misses an increment on
			// the hsync clock - and the error accumulates line after line.
			// The sync stays evenly spaced while walking away from the
			// content, which a bench measuring sync-to-sync cannot see and a
			// monitor shows as a small unstable window.
			//
			// So: the input hsync puts it at zero and starts the first pass,
			// and the wrap only switches to the second. Nothing can drift.
			if (hs_fall == 1'b1) begin
				// The write counter's own total, nothing added. With one
				// added the passes came out 895 and 897, with two 894 and
				// 898 - the first figure is the SECOND pass, so adding to
				// the length shortens it. The raw value halves the line.
				line_len <= wr_addr[10] ? 10'd1023 : wr_addr[9:0];
				out_x    <= 10'd0;
				out_half <= 1'b0;
			end else if (out_x == line_len - 10'd1) begin
				out_x    <= 10'd0;
				out_half <= ~out_half;
			end else
				out_x <= out_x + 10'd1;

			// Sync: one pulse per output line, at the start of it, as wide
			// as the input's own - the buffer is rewound by the falling
			// edge, so the pulse is exactly counts 0 to sync_len. The
			// input's vsync is passed straight through.
			hs_q     <= (out_x >= sync_len);
			HS_OUT_n <= hs_q;
			VS_OUT_n <= VS_IN_n;

			// Rebuilt the way video.v assembles them, {colour, {3{bright}}},
			// because ep4spectrum reads the colour off bit 3 and the
			// brightness off bit 0. Four bits of storage carry three
			// colours and the brightness they share.
			// Gated with each channel's colour on the way out, exactly as
			// video.v gates it on the way in.
			// Green and bright together, on a line that carried the text.
			OSD_OUT <= osd_line[~wr_line] & rd_q[2] & rd_q[0];
			R_OUT <= {rd_q[3], {3{rd_q[0] & rd_q[3]}}};
			G_OUT <= {rd_q[2], {3{rd_q[0] & rd_q[2]}}};
			B_OUT <= {rd_q[1], {3{rd_q[0] & rd_q[1]}}};
		end
	end

endmodule
