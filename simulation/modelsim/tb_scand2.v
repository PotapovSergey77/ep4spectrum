// tb_scand2 - the scandoubler fed by the real video.v
//
// Copyright (c) 2026 Sergey Potapov (potapov.sergey.77@gmail.com)
//
// tb_scand.v drives the doubler with a synthetic line and says it is
// correct: one marker per 896 output clocks, every line shown twice.
// The board disagrees, so the thing left to test is the join - the real
// stream's sync polarity, its pulse width and its pixel rate against
// what the doubler assumes.

`timescale 1ns / 1ps

module tb_scand2;

	reg clk = 1'b0;
	reg clken = 1'b0;
	reg nreset = 1'b0;
	always #17.857 clk = ~clk;
	always @(posedge clk) clken <= ~clken;

	wire [3:0] r, g, b;
	wire nvs, nhs, ncs, nhcs;

	video vid (
		.CLK(clk), .CLKEN(clken), .MEM_CYC(1'b0), .nRESET(nreset),
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
		.BORDER_IN(3'd2),
		.R(r), .G(g), .B(b),
		.nVSYNC(nvs), .nHSYNC(nhs), .nCSYNC(ncs), .nHCSYNC(nhcs),
		.SCANLINE(), .nIRQ()
	);

	wire [3:0] sr, sg, sb;
	wire shs, svs;
	scandoubler sd (
		.CLK(clk), .CE_IN(clken), .nRESET(nreset),
		.R_IN(r), .G_IN(g), .B_IN(b),
		.HS_IN_n(nhs), .VS_IN_n(nvs),
		.R_OUT(sr), .G_OUT(sg), .B_OUT(sb),
		.HS_OUT_n(shs), .VS_OUT_n(svs)
	);

	// The input line, measured the same way the doubler measures it.
	integer t = 0, in_last = 0, out_last = 0, ni = 0, no = 0;
	reg pnhs = 1'b1, pshs = 1'b1;
	always @(posedge clk) begin
		if (nreset) begin
			t = t + 1;
			pnhs <= nhs;  pshs <= shs;
			if (pnhs == 1'b1 && nhs == 1'b0) begin
				if (in_last != 0 && ni < 6) begin
					ni = ni + 1;
					$display("input  line: %0d clocks", t - in_last);
				end
				in_last = t;
			end
			if (pshs == 1'b1 && shs == 1'b0) begin
				if (out_last != 0 && no < 10) begin
					no = no + 1;
					$display("output line: %0d clocks", t - out_last);
				end
				out_last = t;
			end
		end
	end

	// Vertical: how many output lines to a frame, and how wide the
	// vertical pulse is in them. A monitor centres on these, and they
	// have never been measured here.
	integer vlines = 0, vseen = 0, vwide = 0;
	reg pnvs = 1'b1;
	always @(posedge clk) begin
		if (nreset) begin
			pnvs <= nvs;
			if (pshs == 1'b1 && shs == 1'b0) vlines = vlines + 1;
			if (svs == 1'b0) vwide = vwide + 1;
			if (pnvs == 1'b1 && nvs == 1'b0) begin
				if (vseen > 0 && vseen < 4)
					$display("frame: %0d output lines, vsync low for %0d clocks", vlines, vwide);
				vseen = vseen + 1; vlines = 0; vwide = 0;
			end
		end
	end

	// Draw the output frame into a file. Six attempts were made by
	// describing the screen to each other; this puts the actual output
	// where it can be looked at.
	integer ppm, px, py, started;
	initial begin ppm = 0; px = 0; py = 0; started = 0; end
	always @(posedge clk) begin
		if (nreset && ppm != 0) begin
			if (pshs == 1'b1 && shs == 1'b0) begin px = 0; py = py + 1; end
			if (py > 0 && py <= 300 && px < 896) begin
				$fwrite(ppm, "%c%c%c", {sr,4'd0}, {sg,4'd0}, {sb,4'd0});
				px = px + 1;
			end
		end
	end

	initial begin
		nreset = 1'b0;
		repeat (20) @(posedge clk);
		nreset = 1'b1;
		@(negedge nvs);
		ppm = $fopen("out.ppm", "wb");
		$fwrite(ppm, "P6
896 300
255
");
		#45_000_000;
		$fclose(ppm);
		$display("DONE");
		$finish;
	end
endmodule
