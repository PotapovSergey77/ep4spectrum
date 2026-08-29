// tft - the picture on an ILI9341 over its 8-bit parallel bus
//
// Copyright (c) 2026 Sergey Potapov (potapov.sergey.77@gmail.com)
//
// Fed the finished video stream - colour and syncs, after every delay
// and every mux - exactly like scandoubler.v, and for the same reason:
// the machine's timing must not learn that this exists. Nothing here
// touches video.v.
//
// No frame buffer. Every M9K on the device is spoken for, so a pixel is
// written to the panel's own GRAM the moment the ULA produces it, and
// the panel refreshes from GRAM on its own schedule. That is why the
// picture will tear on the seam between frames; it cannot be helped
// without memory we do not have.
//
// The rate works out exactly. A pixel is four clocks of 28MHz (143ns),
// and 16-bit colour over an 8-bit bus is two byte writes - two clocks
// each, 71ns, which is 14MHz against the ILI9341's specified minimum
// cycle of 66ns. Seven percent of margin and not a clock to spare, and
// no way out of it: this module is strapped for 8-bit on its own PCB,
// so the 16-bit bus that would halve the rate is not available. If the
// picture ever comes apart, that margin is the first thing to suspect,
// and the only remedy left would be a different panel.
//
// The window is 320x240 cut out of a 448x312 raster, so it carries the
// 256x192 picture with 32 pixels of border either side and 24 lines
// above and below. It is positioned by counting from the sync edges -
// H_START and V_START below - because that is what this module can see.
// Those two numbers are a first estimate and are meant to be trimmed
// against the panel.

module tft (
	input            CLK,          // 28MHz
	input            CE,           // 14MHz pixel enable, CLKEN_VID
	input            nRESET,

	// the 15kHz stream, as it goes to the pins
	input      [3:0] R_IN,
	input      [3:0] G_IN,
	input      [3:0] B_IN,
	input            HS_IN_n,
	input            VS_IN_n,
	input            PENTAGON,     // its raster is 320 lines, not 312

	// the panel's 8-bit bus
	output reg [7:0] DB_O,
	output reg       DB_OE,
	output reg       RS,
	output reg       WR_n,
	output           RD_n,
	output reg       RST_n
);

	assign RD_n = 1'b1;           // nothing is read back once it is running

	// Pixels from the hsync edge to the left edge of the window, and
	// lines from the vsync edge to its top. Trim these two against the
	// panel; everything else is fixed by the format.
	localparam [9:0] H_START = 10'd88;
	localparam [9:0] V_START = 10'd40;
	localparam [9:0] H_SIZE  = 10'd320;
	localparam [9:0] V_SIZE  = 10'd240;

	// Pentagon's frame is 320 lines against everyone else's 312, and the
	// window is measured from the vsync edge, so its picture arrives one
	// character cell lower than the rest. Starting the window that much
	// further down the raster puts it back where the others sit. Nothing
	// outside this one machine is touched.
	localparam [9:0] V_PENT = 10'd8;

	wire [9:0] v_start = V_START + (PENTAGON ? V_PENT : 10'd0);

	// --- where we are in the incoming raster -------------------------
	reg hs_d, vs_d;
	wire hs_fall = (hs_d == 1'b1) && (HS_IN_n == 1'b0);
	wire vs_fall = (vs_d == 1'b1) && (VS_IN_n == 1'b0);
	always @(posedge CLK or negedge nRESET)
		if (nRESET == 1'b0) begin hs_d <= 1'b1; vs_d <= 1'b1; end
		else begin hs_d <= HS_IN_n; vs_d <= VS_IN_n; end

	// CE is the 14MHz video enable and a pixel is 7MHz, so a pixel is two
	// enables: `half` says which one we are on, and it is cleared at the
	// hsync edge so the pairing cannot drift away from the raster.
	reg [9:0] hpix;      // pixels since the hsync edge
	reg [9:0] vline;     // lines since the vsync edge
	reg       ce_d;
	reg       half;

	always @(posedge CLK or negedge nRESET) begin
		if (nRESET == 1'b0) begin
			hpix <= 10'd0; vline <= 10'd0; ce_d <= 1'b0; half <= 1'b0;
		end else begin
			ce_d <= CE;
			if (hs_fall) begin
				hpix <= 10'd0;
				half <= 1'b0;
				if (vs_fall == 1'b0) vline <= vline + 10'd1;
			end else if (CE && !ce_d) begin
				// two enables to a pixel
				half <= ~half;
				if (half) hpix <= hpix + 10'd1;
			end
			if (vs_fall) vline <= 10'd0;
		end
	end

	wire in_win = (hpix >= H_START) && (hpix < H_START + H_SIZE)
	            && (vline >= v_start) && (vline < v_start + V_SIZE);

	// --- colour ------------------------------------------------------
	//
	// Rebuilt the way video.v assembles its own outputs: bit 3 is the
	// colour, bit 0 the brightness gated by that colour. Normal sits at
	// three quarters of full, which is the ratio the PWM gives the VGA
	// side, so the two outputs match.
	wire [4:0] r5 = R_IN[3] ? (R_IN[0] ? 5'd31 : 5'd23) : 5'd0;
	wire [5:0] g6 = G_IN[3] ? (G_IN[0] ? 6'd63 : 6'd47) : 6'd0;
	wire [4:0] b5 = B_IN[3] ? (B_IN[0] ? 5'd31 : 5'd23) : 5'd0;
	wire [15:0] rgb565 = {r5, g6, b5};

	// --- the sequencer -----------------------------------------------
	localparam S_RESET  = 3'd0,
	           S_WAIT   = 3'd1,
	           S_INIT   = 3'd2,
	           S_SLEEP  = 3'd3,
	           S_FRAME  = 3'd4,
	           S_STREAM = 3'd5;

	reg  [2:0] state;
	reg [22:0] delay;
	reg  [4:0] idx;
	reg        strobe;      // low half of the write pulse

	// Init and per-frame command tables. {RS, byte}: RS low is a
	// command, high is its parameter.
	//
	// $11 sleep out, $3A pixel format 16-bit, $36 orientation with the
	// row/column exchange that turns the native 240x320 portrait into
	// 320x240, $B1 frame rate, $29 display on.
	//
	// The frame rate is set as high as the part goes, and the reasoning
	// behind that is worth keeping, because the obvious setting is the
	// wrong one.
	//
	// The panel scans its own memory on its own oscillator while we write
	// into that memory from the ULA's raster. Where the two pointers
	// cross, the screen shows half of one frame above half of another,
	// and the crossings happen |panel - ours| times a second.
	//
	// So matching the panel to our own 50Hz looks like the answer, and it
	// was tried: $B1 with DIVA=01 and the $B5 porches, per machine, 48.83
	// for Pentagon and 50.03 for the rest, straight out of the datasheet's
	//
	//     rate = fOSC / (RTNA * DIVA_ratio * (320 + VFP + VBP))
	//
	// It failed on the panel for a reason no arithmetic would show: at
	// 50Hz the display visibly flickers. That is the LCD itself, not our
	// signal - the rate that removes the tearing is below what the glass
	// will hold steady.
	//
	// It could not have been made to work anyway. Matching the nominal
	// rate does not lock anything: the panel's oscillator is free and
	// specified to about ten percent, so a beat of a few Hz survives, and
	// a seam that creeps is worse to look at than one that races. A real
	// lock needs the panel's TE output steering these porches frame by
	// frame, and on THIS module TE is not brought out to the connector,
	// so that door is shut.
	//
	// Hence the opposite direction entirely: run it fast, so the flicker
	// goes and the crossings come so often that the seam stops being a
	// line the eye can follow.
	//
	// The controller's fastest is RTNA=16, 118Hz, and that was tried too.
	// It costs contrast, visibly: the faster the scan, the less time each
	// pixel has to charge, and the greyer the picture looks. RTNA=19 -
	// 615k/(19*1*324) = 100Hz, the datasheet's own figure for that entry
	// - keeps the flicker away and gives the glass back the charging time.
	//
	// So the setting is a compromise between three things the panel will
	// not give at once: 50Hz flickers, 118Hz washes out, 100Hz is where
	// they balance.
	//
	// One more idea was tried and is worth recording as closed, because
	// it is a good idea and it will occur to anyone reading this. Put the
	// panel at exactly twice a machine's own frame rate - 97.66Hz for
	// Pentagon's 48.83 - and every frame is scanned exactly twice, so the
	// crossings should stand still instead of walking. Built, per machine,
	// with the porches opened from 2 to 5. On the panel: no visible
	// difference at all.
	//
	// The arithmetic says why, and it condemns the whole approach rather
	// than that one setting. fOSC is 615kHz typical over 570 to 660 - about
	// seven percent - so at 100Hz the rate is uncertain by some 7Hz. The
	// correction being made was the 1.8Hz between 99.5 and 97.66: five
	// times smaller than the tolerance it was swimming in. No open-loop
	// choice of nominal frequency can survive that, which is the same
	// reason the 50Hz match would not have locked either.
	//
	// The tearing is not gone, and no frequency setting will remove it.
	// That needs a closed loop on TE, which this module does not bring
	// out, or a frame buffer, which the device has no memory for.
	reg [8:0] initrom;
	always @* begin
		case (idx)
		5'd0:  initrom = 9'h011;   // sleep out
		5'd1:  initrom = 9'h03A;   // pixel format
		5'd2:  initrom = 9'h155;   //   16 bits
		5'd3:  initrom = 9'h036;   // memory access control
		5'd4:  initrom = 9'h128;   //   MV | BGR
		5'd5:  initrom = 9'h0B1;   // frame rate control
		5'd6:  initrom = 9'h100;   //   DIVA = fosc, undivided
		5'd7:  initrom = 9'h113;   //   RTNA = 19 -> 100Hz
		5'd8:  initrom = 9'h029;   // display on
		default: initrom = 9'h000;
		endcase
	end

	// Column 0..319, page 0..239, then "write to memory".
	reg [8:0] winrom;
	always @* begin
		case (idx)
		5'd0:  winrom = 9'h02A;
		5'd1:  winrom = 9'h100;
		5'd2:  winrom = 9'h100;
		5'd3:  winrom = 9'h101;
		5'd4:  winrom = 9'h13F;   // 319
		5'd5:  winrom = 9'h02B;
		5'd6:  winrom = 9'h100;
		5'd7:  winrom = 9'h100;
		5'd8:  winrom = 9'h100;
		5'd9:  winrom = 9'h1EF;   // 239
		5'd10: winrom = 9'h02C;   // memory write
		default: winrom = 9'h000;
		endcase
	end

	always @(posedge CLK or negedge nRESET) begin
		if (nRESET == 1'b0) begin
			state  <= S_RESET;
			delay  <= 23'd56000;         // 2ms of reset
			idx    <= 5'd0;
			strobe <= 1'b0;
			DB_O   <= 8'h00;
			DB_OE  <= 1'b0;
			RS     <= 1'b0;
			WR_n   <= 1'b1;
			RST_n  <= 1'b0;
		end else begin
			case (state)
			S_RESET: begin
				RST_n <= 1'b0;
				if (delay == 23'd0) begin
					RST_n <= 1'b1;
					delay <= 23'd4200000;   // 150ms to settle
					state <= S_WAIT;
				end else
					delay <= delay - 23'd1;
			end

			S_WAIT: begin
				if (delay == 23'd0) begin
					state  <= S_INIT;
					idx    <= 5'd0;
					strobe <= 1'b0;
				end else
					delay <= delay - 23'd1;
			end

			// One byte every two clocks, the same shape everywhere:
			// strobe low with the byte on the bus, then strobe high.
			S_INIT: begin
				DB_OE <= 1'b1;
				if (strobe == 1'b0) begin
					RS     <= initrom[8];
					DB_O   <= initrom[7:0];
					WR_n   <= 1'b0;
					strobe <= 1'b1;
				end else begin
					WR_n   <= 1'b1;
					strobe <= 1'b0;
					idx    <= idx + 5'd1;
					// Sleep out is the one command with a wait of its own:
					// the controller ignores everything for 120ms after it,
					// so without this the whole rest of the table lands in
					// the bin and the panel stays dark whatever else is
					// right.
					if (idx == 5'd0) begin
						delay <= 23'd3360000;
						state <= S_SLEEP;
					end else if (idx == 5'd8) begin
						idx   <= 5'd0;
						state <= S_FRAME;
					end
				end
			end

			S_SLEEP: begin
				if (delay == 23'd0)
					state <= S_INIT;
				else
					delay <= delay - 23'd1;
			end

			// At the top of every frame: set the window again and start
			// a new memory write, so a lost byte cannot walk the picture
			// sideways for the rest of the session.
			S_FRAME: begin
				DB_OE <= 1'b1;
				if (vs_fall == 1'b1) begin
					idx    <= 5'd0;
					strobe <= 1'b0;
				end else if (idx <= 5'd10) begin
					if (strobe == 1'b0) begin
						RS     <= winrom[8];
						DB_O   <= winrom[7:0];
						WR_n   <= 1'b0;
						strobe <= 1'b1;
					end else begin
						WR_n   <= 1'b1;
						strobe <= 1'b0;
						idx    <= idx + 5'd1;
						if (idx == 5'd10) state <= S_STREAM;
					end
				end
			end

			// Two bytes a pixel, four clocks a pixel: high byte on the
			// first two, low byte on the second two. Outside the window
			// nothing is written at all.
			S_STREAM: begin
				DB_OE <= 1'b1;
				RS    <= 1'b1;
				if (vs_fall == 1'b1) begin
					state  <= S_FRAME;
					idx    <= 5'd0;
					strobe <= 1'b0;
					WR_n   <= 1'b1;
				end else if (in_win && CE && !ce_d) begin
					DB_O <= half ? rgb565[7:0] : rgb565[15:8];
					WR_n <= 1'b0;
				end else
					WR_n <= 1'b1;
			end

			default: state <= S_RESET;
			endcase
		end
	end

endmodule
