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

	// The same picture at twice the line rate
	output reg [3:0] R_OUT,
	output reg [3:0] G_OUT,
	output reg [3:0] B_OUT,
	output reg       HS_OUT_n,
	output reg       VS_OUT_n
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
	reg        resync;
	// Declared before use. Quartus accepts a name used before it is
	// declared and quietly makes an implicit one-bit net of it, which is
	// how wr_line came to be declared twice here without a word said.
	wire [10:0] rd_addr = {~wr_line, out_x};

	// The four bits actually carried: colour per channel plus the one
	// brightness they share. R_IN[3] is the colour and R_IN[0] the
	// brightness, the way video.v assembles {colour, {3{bright}}}.
	// Colour and the SYNC ITSELF, not brightness.
	//
	// Generating a new sync means reproducing what video.v does, and
	// six builds went on failing to. Recording its pulse and playing it
	// back makes the output sync the input's own, only twice as fast -
	// which is what "the same sync" means and cannot be got wrong.
	//
	// The fourth bit was brightness. There is no room for a fifth: 2048
	// words of five bits is 10240 against an M9K's 9216. So BRIGHT is
	// what the doubled mode gives up.
	wire [3:0] pix_in = {R_IN[3], G_IN[3], B_IN[3], HS_IN_n};

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
	always @(posedge CLK or negedge nRESET)
		if (nRESET == 1'b0) hs_in_d <= 1'b1;
		else                hs_in_d <= HS_IN_n;

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
			resync   <= 1'b0;
			R_OUT    <= 4'b0;
			G_OUT    <= 4'b0;
			B_OUT    <= 4'b0;
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

			// Sync: one pulse per output line, the same width in pixels
			// the input used, and the input's vsync passed through.
			HS_OUT_n <= rd_q[0];
			VS_OUT_n <= VS_IN_n;

			R_OUT <= {4{rd_q[3]}};
			G_OUT <= {4{rd_q[2]}};
			B_OUT <= {4{rd_q[1]}};
		end
	end

endmodule
