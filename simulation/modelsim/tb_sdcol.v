// tb_sdcol - does a colour survive the line buffer unchanged
//
// Copyright (c) 2026 Sergey Potapov (potapov.sergey.77@gmail.com)
//
// The buffer keeps four bits for what video.v sends as twelve, so it
// has to put them back together the same way video.v took them apart:
// {colour, {3{bright & colour}}}, the brightness gated by each
// channel's own colour. Storing R_IN[0] and handing it to all three
// lost the brightness of every bright colour without red in it - bright
// green, bright blue, bright cyan - and the picture looked dark. This
// walks all sixteen colour-and-brightness combinations and compares
// what comes out against what went in.
`timescale 1ns / 1ps

module tb_sdcol;
	reg clk = 1'b0;
	always #17.857 clk = ~clk;
	reg nreset = 1'b0;
	reg ce = 1'b0;
	always @(posedge clk) if (nreset) ce <= ~ce;

	localparam LINE = 896, HS_W = 64;

	integer hpos = 0, lineno = 0;
	reg hs_n = 1'b1;

	// colour index: bit 3 bright, bits 2:0 the three channels
	wire [3:0] c_now = lineno[3:0];
	wire       br    = c_now[3];
	wire       rd    = c_now[2], gr = c_now[1], bl = c_now[0];
	// exactly video.v's assembly
	wire [3:0] r_in = {rd, {3{br & rd}}};
	wire [3:0] g_in = {gr, {3{br & gr}}};
	wire [3:0] b_in = {bl, {3{br & bl}}};

	always @(posedge clk) if (nreset && ce) begin
		if (hpos == LINE - 1) begin hpos = 0; lineno = lineno + 1; end
		else hpos = hpos + 1;
		hs_n <= ~(hpos < HS_W);
	end

	wire [3:0] r_o, g_o, b_o;  wire hs_o, vs_o, osd_o;
	scandoubler sd (
		.CLK(clk), .CE_IN(ce), .nRESET(nreset),
		.R_IN(r_in), .G_IN(g_in), .B_IN(b_in),
		.HS_IN_n(hs_n), .VS_IN_n(1'b1), .OSD_IN(1'b0),
		.R_OUT(r_o), .G_OUT(g_o), .B_OUT(b_o),
		.HS_OUT_n(hs_o), .VS_OUT_n(vs_o), .OSD_OUT(osd_o)
	);

	// The buffer replays the line before this one.
	wire [3:0] p    = (lineno - 1) & 4'hF;
	wire       ebr  = p[3];
	wire [3:0] er   = {p[2], {3{ebr & p[2]}}};
	wire [3:0] eg   = {p[1], {3{ebr & p[1]}}};
	wire [3:0] eb   = {p[0], {3{ebr & p[0]}}};

	integer checks = 0, bad = 0, i;
	reg [15:0] seen = 16'd0;
	always @(posedge clk)
		if (nreset && lineno > 2 && sd.out_x > 300 && sd.out_x < 600) begin
			checks = checks + 1;
			if (r_o !== er || g_o !== eg || b_o !== eb) begin
				bad = bad + 1;
				if (bad < 6)
					$display("   colour %0d (bright=%0d rgb=%0d%0d%0d): in %b/%b/%b out %b/%b/%b",
						p, ebr, p[2], p[1], p[0], er, eg, eb, r_o, g_o, b_o);
			end else
				seen[p] = 1'b1;
		end

	initial begin
		nreset = 1'b0; repeat (20) @(posedge clk); nreset = 1'b1;
		#5_000_000;
		$display("");
		$display("  %0d samples compared, %0d wrong", checks, bad);
		$write("  combinations verified:");
		for (i = 0; i < 16; i = i + 1) if (seen[i]) $write(" %0d", i);
		$display("");
		$display("  %s", (bad == 0 && seen == 16'hFFFF) ?
			"all sixteen survive the buffer unchanged" : "MISMATCH");
		$finish;
	end
endmodule
