// tb_sdjit - is the doubled line period the same on every line
//
// Copyright (c) 2026 Sergey Potapov (potapov.sergey.77@gmail.com)
//
// A picture that twitches is a line period that is not always the same,
// or a horizontal edge that moves. This walks two whole frames and
// reports every distinct line length it sees, so one odd line out of
// 624 cannot hide in an average.
`timescale 1ns / 1ps

module tb_sdjit;
	reg clk = 1'b0;
	always #17.857 clk = ~clk;              // 28MHz, video.v's own
	reg nreset = 1'b0;
	reg clken = 1'b0;
	always @(posedge clk) if (nreset) clken <= ~clken;

	wire [3:0] vr, vg, vb;  wire vnvs, vnhs;
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
		.BORDER_IN(3'd2), .R(vr), .G(vg), .B(vb),
		.nVSYNC(vnvs), .nHSYNC(vnhs), .nCSYNC(), .nHCSYNC(),
		.SCANLINE(), .nIRQ()
	);

	wire [3:0] sr, sg, sb;  wire shs, svs;
	scandoubler sd (
		.CLK(clk), .CE_IN(clken), .nRESET(nreset),
		.R_IN(vr), .G_IN(vg), .B_IN(vb), .HS_IN_n(vnhs), .VS_IN_n(vnvs),
		.R_OUT(sr), .G_OUT(sg), .B_OUT(sb), .HS_OUT_n(shs), .VS_OUT_n(svs)
	);

	// every distinct output line length, with a count of each
	integer len [0:15];
	integer num [0:15];
	integer kinds = 0;
	integer t = 0, last = 0, lines = 0, i, d, found;
	reg p = 1'b1;

	// the vertical pulse, in output lines
	reg pv = 1'b1;
	integer vs_start = 0, vs_lines = 0, frame_lines = 0, vframe = 0;

	always @(posedge clk) begin
		if (nreset) begin
			t = t + 1;
			if (p == 1'b1 && shs == 1'b0) begin
				if (last != 0) begin
					d = t - last;
					lines = lines + 1;
					found = 0;
					for (i = 0; i < kinds; i = i + 1)
						if (len[i] == d) begin num[i] = num[i] + 1; found = 1; end
					if (found == 0 && kinds < 16) begin
						len[kinds] = d;  num[kinds] = 1;  kinds = kinds + 1;
					end
				end
				last = t;
			end
			p <= shs;

			if (pv == 1'b1 && svs == 1'b0) begin
				if (vframe != 0) frame_lines = lines - vframe;
				vframe = lines;  vs_start = lines;
			end
			if (pv == 1'b0 && svs == 1'b1) vs_lines = lines - vs_start;
			pv <= svs;
		end
	end

	initial begin
		nreset = 1'b0; repeat (20) @(posedge clk); nreset = 1'b1;
		#42_000_000;                       // two frames
		$display("");
		$display("  %0d output lines seen, %0d distinct lengths:", lines, kinds);
		for (i = 0; i < kinds; i = i + 1)
			$display("     %4d clocks  x %0d   (%0d ns, %0d.%02d kHz)",
				len[i], num[i], len[i]*357/10,
				(280000/len[i])/10, (2800000/len[i])%100);
		$display("  vertical pulse %0d output lines, frame %0d output lines",
			vs_lines, frame_lines);
		$display("  (wanted: one length, 896 clocks; 624 lines a frame)");
		$finish;
	end
endmodule
