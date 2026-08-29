// tftid - read the identification register out of a parallel TFT panel
//
// Copyright (c) 2026 Sergey Potapov (potapov.sergey.77@gmail.com)
//
// The 2.4" module carries no markings, and the two controllers it is
// likely to be answer to DIFFERENT protocols - so this asks both and
// shows both answers rather than guessing which to trust.
//
//   ILI9341  command/parameter. Write $D3 with RS low, then read four
//            bytes with RS high: a dummy, then $00 $93 $41.
//   ILI9325  index/data. Write the 16-bit index $0000 as two bytes with
//            RS low, then read two bytes with RS high: $93 $25.
//
// Both sequences are harmless to the other part: a controller that does
// not know the command returns whatever its bus floats to, and neither
// writes anything that changes the display.
//
// Speed is irrelevant here, so every strobe is a microsecond wide -
// far inside what even the slowest of these parts specifies, and well
// clear of any doubt about wiring capacitance on a hand-made harness.

module tftid (
	input             CLK,          // 28MHz
	input             nRESET,

	// The panel's 8-bit bus. The data lines turn around for the reads,
	// which is the whole reason /RD had to be wired.
	output reg  [7:0] DB_O,
	output reg        DB_OE,        // 1 = we drive the bus
	input       [7:0] DB_I,
	output reg        RS,           // 0 = command/index, 1 = data
	output reg        WR_n,
	output reg        RD_n,
	output reg        RST_n,

	// What came back. ID_9341 is the third and fourth bytes of $D3,
	// ID_9325 the two bytes of index $0000.
	output reg [15:0] ID_9341,
	output reg [15:0] ID_9325,
	output reg        DONE
);

	// A microsecond a phase at 28MHz.
	localparam TICK = 9'd28;

	// The panel wants milliseconds after reset before it will answer.
	// 2ms of reset and 150ms of settling, counted in ticks so there is
	// only one time base in the module.
	localparam RST_TICKS  = 17'd2000;
	localparam WAIT_TICKS = 17'd150000;

	reg  [8:0]  div;
	reg         tick;
	always @(posedge CLK or negedge nRESET)
		if (nRESET == 1'b0) begin
			div  <= 9'd0;
			tick <= 1'b0;
		end else if (div == TICK - 9'd1) begin
			div  <= 9'd0;
			tick <= 1'b1;
		end else begin
			div  <= div + 9'd1;
			tick <= 1'b0;
		end

	reg [16:0] delay;
	reg  [5:0] step;
	reg  [7:0] shifted;

	// One step of the sequence is: set up, strobe low, strobe high. The
	// phase counter runs on ticks, so each phase is a microsecond.
	reg  [1:0] phase;

	always @(posedge CLK or negedge nRESET) begin
		if (nRESET == 1'b0) begin
			step    <= 6'd0;
			phase   <= 2'd0;
			delay   <= RST_TICKS;
			DB_O    <= 8'h00;
			DB_OE   <= 1'b0;
			RS      <= 1'b0;
			WR_n    <= 1'b1;
			RD_n    <= 1'b1;
			RST_n   <= 1'b0;
			ID_9341 <= 16'h0000;
			ID_9325 <= 16'h0000;
			DONE    <= 1'b0;
			shifted <= 8'h00;
		end else if (tick == 1'b1) begin
			case (step)
			// --- reset, then let it settle -----------------------------
			6'd0: begin
				RST_n <= 1'b0;
				if (delay == 17'd0) begin
					RST_n <= 1'b1;
					delay <= WAIT_TICKS;
					step  <= 6'd1;
				end else
					delay <= delay - 17'd1;
			end
			6'd1: begin
				if (delay == 17'd0)
					step <= 6'd2;
				else
					delay <= delay - 17'd1;
			end

			// --- ILI9341: write $D3, read four -------------------------
			6'd2:  begin RS <= 1'b0; DB_O <= 8'hD3; DB_OE <= 1'b1;
			             step <= 6'd3; phase <= 2'd0; end
			6'd3:  begin WR_n <= 1'b0; step <= 6'd4; end
			6'd4:  begin WR_n <= 1'b1; step <= 6'd5; end

			// The bus turns around here and stays turned for the reads.
			6'd5:  begin DB_OE <= 1'b0; RS <= 1'b1; step <= 6'd6; end

			6'd6:  begin RD_n <= 1'b0; step <= 6'd7; end
			6'd7:  begin shifted <= DB_I; RD_n <= 1'b1; step <= 6'd8; end   // dummy
			6'd8:  begin RD_n <= 1'b0; step <= 6'd9; end
			6'd9:  begin shifted <= DB_I; RD_n <= 1'b1; step <= 6'd10; end  // $00
			6'd10: begin RD_n <= 1'b0; step <= 6'd11; end
			6'd11: begin ID_9341[15:8] <= DB_I; RD_n <= 1'b1; step <= 6'd12; end
			6'd12: begin RD_n <= 1'b0; step <= 6'd13; end
			6'd13: begin ID_9341[7:0] <= DB_I; RD_n <= 1'b1; step <= 6'd14; end

			// --- ILI9325: write index $0000, read two ------------------
			6'd14: begin RS <= 1'b0; DB_O <= 8'h00; DB_OE <= 1'b1; step <= 6'd15; end
			6'd15: begin WR_n <= 1'b0; step <= 6'd16; end
			6'd16: begin WR_n <= 1'b1; step <= 6'd17; end
			6'd17: begin WR_n <= 1'b0; step <= 6'd18; end
			6'd18: begin WR_n <= 1'b1; step <= 6'd19; end

			6'd19: begin DB_OE <= 1'b0; RS <= 1'b1; step <= 6'd20; end
			6'd20: begin RD_n <= 1'b0; step <= 6'd21; end
			6'd21: begin ID_9325[15:8] <= DB_I; RD_n <= 1'b1; step <= 6'd22; end
			6'd22: begin RD_n <= 1'b0; step <= 6'd23; end
			6'd23: begin ID_9325[7:0] <= DB_I; RD_n <= 1'b1; step <= 6'd24; end

			6'd24: begin DONE <= 1'b1; step <= 6'd24; end
			default: step <= 6'd24;
			endcase
		end
	end

endmodule
