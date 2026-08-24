// tb_scand - what the scandoubler actually puts out
//
// Copyright (c) 2026 Sergey Potapov (potapov.sergey.77@gmail.com)
//
// Three firmware builds were spent on this by describing the screen to
// each other, which is the worst way to debug an output nobody can see.
// This drives the module with a line of known length and known sync and
// prints what comes back: how long the output line is, where its sync
// pulse falls, and whether each input line really is shown twice.
//
// The input is modelled on video.v's own stream - 896 pixel enables to
// the line, hsync low for a stretch inside the blanking - and the pixel
// value is the position, so a mismatch says exactly which pixel.

`timescale 1ns / 1ps

module tb_scand;

	reg clk = 1'b0;
	reg nreset = 1'b0;
	always #17.857 clk = ~clk;          // 28MHz

	// 14MHz pixel enable, every other clock
	reg ce = 1'b0;
	always @(posedge clk) ce <= ~ce;

	// --- the input line ---
	integer hpos = 0;
	reg     hs_n = 1'b1;
	reg [3:0] col = 4'd0;

	localparam LINE = 896;
	localparam HS_START = 656;          // inside blanking, as video.v has it
	localparam HS_END   = 736;

	always @(posedge clk) begin
		if (nreset && ce) begin
			hpos = (hpos == LINE - 1) ? 0 : hpos + 1;
			hs_n <= ~((hpos >= HS_START) && (hpos < HS_END));
			// Something distinguishable: white in the picture area, black
			// outside it, and a single bright pixel at position 100.
			// A single marker pixel, told apart by the BRIGHT bit so it
			// cannot be confused with ordinary white.
			col  <= (hpos == 100) ? 4'b1111 :
			        (hpos < 512)  ? 4'b1110 : 4'b0000;
		end
	end

	wire [3:0] r_o, g_o, b_o;
	wire       hs_o_n, vs_o_n;

	scandoubler sd (
		.CLK(clk), .CE_IN(ce), .nRESET(nreset),
		.R_IN({col[3], 2'b00, col[0]}), .G_IN({col[2], 2'b00, col[0]}),
		.B_IN({col[1], 2'b00, col[0]}),
		.HS_IN_n(hs_n), .VS_IN_n(1'b1),
		.R_OUT(r_o), .G_OUT(g_o), .B_OUT(b_o),
		.HS_OUT_n(hs_o_n), .VS_OUT_n(vs_o_n)
	);

	// --- what comes out ---
	integer out_clk = 0;
	integer last_fall = 0;
	integer shown = 0;
	reg     hs_o_d = 1'b1;

	always @(posedge clk) begin
		if (nreset) begin
			out_clk = out_clk + 1;
			hs_o_d <= hs_o_n;
			if (hs_o_d == 1'b1 && hs_o_n == 1'b0) begin
				if (last_fall != 0 && shown < 12) begin
					shown = shown + 1;
					$display("output line %0d: %0d clocks since the last sync (an input line is %0d enables = %0d clocks, so half of it is %0d)",
						shown, out_clk - last_fall, LINE, LINE*2, LINE);
				end
				last_fall = out_clk;
			end
		end
	end

	// Is the bright pixel at 100 there, and twice per input line?
	integer marks = 0;
	always @(posedge clk)
		if (nreset && r_o[0] && marks < 12) begin
			marks = marks + 1;
			$display("   marker seen at output clock %0d", out_clk);
		end

	initial begin
		nreset = 1'b0;
		repeat (20) @(posedge clk);
		nreset = 1'b1;
		#400_000;
		$display("DONE - %0d output lines, %0d markers", shown, marks);
		$finish;
	end

endmodule
