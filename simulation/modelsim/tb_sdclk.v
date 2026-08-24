// tb_sdclk - the scandoubler on the board's clock against the bench's
//
// Copyright (c) 2026 Sergey Potapov (potapov.sergey.77@gmail.com)
//
// Every earlier bench drove the doubler at 28MHz with a 14MHz enable -
// the ratio it is built for - and every one of them passed while the
// monitor refused to lock. On the board it hangs on clk56 while CE_IN
// is a clk28-domain enable, so each enable is seen for two clocks and
// each pixel is written twice. This runs both wirings and prints the
// line each produces.
`timescale 1ns / 1ps

module tb_sdclk;
	reg clk56 = 1'b0;
	always #8.928 clk56 = ~clk56;         // 56MHz
	reg clk28 = 1'b0;
	always @(posedge clk56) clk28 <= ~clk28;   // 28MHz, phase-related
	reg nreset = 1'b0;

	// The 14MHz enable, one clk28 cycle wide - clocks.v's CLKEN_VID
	reg clken = 1'b0;
	always @(posedge clk28) if (nreset) clken <= ~clken;

	wire [3:0] vr, vg, vb;  wire vnvs, vnhs;
	video vid (
		.CLK(clk28), .CLKEN(clken), .MEM_CYC(1'b0), .nRESET(nreset),
		.VGA(1'b0), .MACHINE(2'd0),
		.CONTENTION(), .CONTENTION_IO(),
		.INT_ADJ(12'd0), .INT_VADJ(8'd0), .CONT_ADJ(5'd0), .IO_ADJ(8'd0),
		.BORD_PHASE(4'd9), .BORD_DELAY(2'd0),
		.OSD_SPEED(2'd0), .OSD_EXT(1'b0), .OSD_POKE(1'b0), .OSD_ACTIVE(),
		.PORT_FF_ACTIVE(), .PORT_FF_DATA(),
		.VID_A(), .VID_D_IN(8'hFF), .nVID_RD(), .nWAIT(),
		.VID_REQ_STEP(), .VID_REQ_GEN(), .VID_STALE(),
		.VID_REQ_ACK(1'b1), .VID_DATA_VALID(1'b1),
		.VID_DATA_STEP(1'b0), .VID_DATA_GEN(1'b0),
		.BORDER_IN(3'd2), .R(vr), .G(vg), .B(vb),
		.nVSYNC(vnvs), .nHSYNC(vnhs), .nCSYNC(), .nHCSYNC(),
		.SCANLINE(), .nIRQ()
	);

	// as wired on the board today
	wire [3:0] hr, hg, hb;  wire hhs, hvs;
	scandoubler sd_board (
		.CLK(clk56), .CE_IN(clken), .nRESET(nreset),
		.R_IN(vr), .G_IN(vg), .B_IN(vb), .HS_IN_n(vnhs), .VS_IN_n(vnvs),
		.R_OUT(hr), .G_OUT(hg), .B_OUT(hb), .HS_OUT_n(hhs), .VS_OUT_n(hvs)
	);

	// on the clock video.v itself uses
	wire [3:0] gr, gg, gb;  wire ghs, gvs;
	scandoubler sd_fixed (
		.CLK(clk28), .CE_IN(clken), .nRESET(nreset),
		.R_IN(vr), .G_IN(vg), .B_IN(vb), .HS_IN_n(vnhs), .VS_IN_n(vnvs),
		.R_OUT(gr), .G_OUT(gg), .B_OUT(gb), .HS_OUT_n(ghs), .VS_OUT_n(gvs)
	);

	// Each is measured on its own clock, in nanoseconds, so the two are
	// comparable despite running at different rates.
	real bt = 0, blast = 0, bper = 0;  reg bp = 1'b1;  integer bn = 0;
	always @(posedge clk56) if (nreset) begin
		if (bp == 1'b1 && hhs == 1'b0) begin
			if (blast != 0) begin bper = $realtime - blast; bn = bn + 1; end
			blast = $realtime;
		end
		bp <= hhs;
	end
	real glast = 0, gper = 0;  reg gp = 1'b1;  integer gn = 0;
	always @(posedge clk28) if (nreset) begin
		if (gp == 1'b1 && ghs == 1'b0) begin
			if (glast != 0) begin gper = $realtime - glast; gn = gn + 1; end
			glast = $realtime;
		end
		gp <= ghs;
	end

	initial begin
		nreset = 1'b0; repeat (20) @(posedge clk56); nreset = 1'b1;
		#2_000_000;
		$display("");
		$display("  wiring                 pulses   line(ns)    kHz");
		$display("  CLK=clk56 (the board)  %5d   %8.1f   %6.2f",
			bn, bper, (bper == 0) ? 0.0 : 1000000.0/bper);
		$display("  CLK=clk28 (video's)    %5d   %8.1f   %6.2f",
			gn, gper, (gper == 0) ? 0.0 : 1000000.0/gper);
		$display("  wanted                          32000.0    31.25");
		$finish;
	end
endmodule
