// tb_sdpwm - how bright is a pixel actually driven, in each mode
//
// Copyright (c) 2026 Sergey Potapov (potapov.sergey.77@gmail.com)
//
// One PWM period has to fall inside one pixel. At 15kHz a pixel is
// eight steps of the 56MHz counter, in the doubled mode four, and the
// duty is meant to be the same 3/4 either way. Rather than argue about
// it, this drives both paths from one video.v and counts the clocks the
// pin would be high in each.
`timescale 1ns / 1ps

module tb_sdpwm;
	reg clk56 = 1'b0;
	always #8.928 clk56 = ~clk56;
	reg clk28 = 1'b0;
	always @(posedge clk56) clk28 <= ~clk28;
	reg nreset = 1'b0;
	reg ce = 1'b0;
	always @(posedge clk28) if (nreset) ce <= ~ce;

	wire [3:0] vr, vg, vb;  wire vnvs, vnhs, vosd;
	video vid (
		.CLK(clk28), .CLKEN(ce), .MEM_CYC(1'b0), .nRESET(nreset),
		.VGA(1'b0), .MACHINE(2'd0),
		.CONTENTION(), .CONTENTION_IO(),
		.INT_ADJ(12'd0), .INT_VADJ(8'd0), .CONT_ADJ(5'd0), .IO_ADJ(8'd0),
		.BORD_PHASE(4'd9), .BORD_DELAY(2'd0),
		.OSD_SPEED(2'd0), .OSD_EXT(1'b0), .OSD_POKE(1'b0),
		.OSD_ACTIVE(vosd),
		.PORT_FF_ACTIVE(), .PORT_FF_DATA(),
		.VID_A(), .VID_D_IN(8'hFF), .nVID_RD(), .nWAIT(),
		.VID_REQ_STEP(), .VID_REQ_GEN(), .VID_STALE(),
		.VID_REQ_ACK(1'b1), .VID_DATA_VALID(1'b1),
		.VID_DATA_STEP(1'b0), .VID_DATA_GEN(1'b0),
		.BORDER_IN(3'd7),                     // white border, not bright
		.R(vr), .G(vg), .B(vb),
		.nVSYNC(vnvs), .nHSYNC(vnhs), .nCSYNC(), .nHCSYNC(),
		.SCANLINE(), .nIRQ()
	);

	wire [3:0] sr, sg, sb;  wire shs, svs, sosd;
	scandoubler sd (
		.CLK(clk28), .CE_IN(ce), .nRESET(nreset),
		.R_IN(vr), .G_IN(vg), .B_IN(vb),
		.HS_IN_n(vnhs), .VS_IN_n(vnvs), .OSD_IN(vosd),
		.R_OUT(sr), .G_OUT(sg), .B_OUT(sb),
		.HS_OUT_n(shs), .VS_OUT_n(svs), .OSD_OUT(sosd)
	);

	// spectrum_top's own output stage, both settings of it
	reg [2:0] pwm_cnt = 3'd0;
	always @(posedge clk56) pwm_cnt <= pwm_cnt + 3'd1;
	wire dim15 = (pwm_cnt      < 3'd6);
	wire dim31 = (pwm_cnt[1:0] < 2'd3);

	wire pin15 = vr[3] & (vr[0] | dim15);
	wire pin31 = sr[3] & (sr[0] | dim31);

	integer on15 = 0, all15 = 0, on31 = 0, all31 = 0;
	always @(posedge clk56) if (nreset) begin
		// count only where the colour is actually lit, so blanking does
		// not dilute the figure
		if (vr[3]) begin all15 = all15 + 1;  if (pin15) on15 = on15 + 1; end
		if (sr[3]) begin all31 = all31 + 1;  if (pin31) on31 = on31 + 1; end
	end

	// the waveform itself, 48 clocks of it once both are lit
	integer shown = 0;
	reg [47:0] w15, w31, p15, p31;
	always @(posedge clk56) if (nreset && vr[3] && sr[3] && shown < 48) begin
		w15 = {w15[46:0], pin15};  w31 = {w31[46:0], pin31};
		p15 = {p15[46:0], vr[3]};  p31 = {p31[46:0], sr[3]};
		shown = shown + 1;
	end

	initial begin
		nreset = 1'b0; repeat (20) @(posedge clk56); nreset = 1'b1;
		#20_000_000;
		$display("");
		$display("  15kHz : %0d of %0d clocks high  = %0d.%0d%%",
			on15, all15, (on15*1000/all15)/10, (on15*1000/all15)%10);
		$display("  31kHz : %0d of %0d clocks high  = %0d.%0d%%",
			on31, all31, (on31*1000/all31)/10, (on31*1000/all31)%10);
		$display("");
		$display("  48 clocks of 56MHz, one character per clock:");
		$display("    15kHz pin : %b", w15);
		$display("    31kHz pin : %b", w31);
		$display("  (both should be 75%% - a normal colour, six steps of");
		$display("   eight at 15kHz and three of four doubled)");
		$finish;
	end
endmodule
