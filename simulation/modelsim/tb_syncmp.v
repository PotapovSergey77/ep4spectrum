// tb_syncmp - the two 31kHz signals, side by side
//
// Copyright (c) 2026 Sergey Potapov (potapov.sergey.77@gmail.com)
//
// One video.v running with VGA=1 - the internal doubling, the signal
// monitors accepted - and another at VGA=0 feeding the scandoubler,
// which they did not. Both are 31kHz by construction, so whatever the
// monitor objects to is a difference between them, and six builds were
// spent guessing at it. This prints both.

`timescale 1ns / 1ps

module tb_syncmp;
	reg clk = 1'b0, clken = 1'b0, nreset = 1'b0;
	always #17.857 clk = ~clk;
	always @(posedge clk) clken <= ~clken;

	// --- the reference: video.v doubling itself ---
	wire [3:0] ar, ag, ab;  wire anvs, anhs, ancs, anhcs;
	video vid_a (
		.CLK(clk), .CLKEN(clken), .MEM_CYC(1'b0), .nRESET(nreset),
		.VGA(1'b1), .MACHINE(2'd0),
		.CONTENTION(), .CONTENTION_IO(),
		.INT_ADJ(12'd0), .INT_VADJ(8'd0), .CONT_ADJ(5'd0), .IO_ADJ(8'd0),
		.BORD_PHASE(4'd9), .BORD_DELAY(2'd0),
		.OSD_SPEED(2'd0), .OSD_EXT(1'b0), .OSD_POKE(1'b0), .OSD_ACTIVE(),
		.PORT_FF_ACTIVE(), .PORT_FF_DATA(),
		.VID_A(), .VID_D_IN(8'hFF), .nVID_RD(), .nWAIT(),
		.VID_REQ_STEP(), .VID_REQ_GEN(), .VID_STALE(),
		.VID_REQ_ACK(1'b1), .VID_DATA_VALID(1'b1),
		.VID_DATA_STEP(1'b0), .VID_DATA_GEN(1'b0),
		.BORDER_IN(3'd2), .R(ar), .G(ag), .B(ab),
		.nVSYNC(anvs), .nHSYNC(anhs), .nCSYNC(ancs), .nHCSYNC(anhcs),
		.SCANLINE(), .nIRQ()
	);

	// --- ours: video.v at 15kHz into the scandoubler ---
	wire [3:0] br, bg, bb;  wire bnvs, bnhs, bncs, bnhcs;
	video vid_b (
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
		.BORDER_IN(3'd2), .R(br), .G(bg), .B(bb),
		.nVSYNC(bnvs), .nHSYNC(bnhs), .nCSYNC(bncs), .nHCSYNC(bnhcs),
		.SCANLINE(), .nIRQ()
	);
	wire [3:0] sr, sg, sb;  wire shs, svs;
	scandoubler sd (
		.CLK(clk), .CE_IN(clken), .nRESET(nreset),
		.R_IN(br), .G_IN(bg), .B_IN(bb), .HS_IN_n(bnhs), .VS_IN_n(bnvs),
		.R_OUT(sr), .G_OUT(sg), .B_OUT(sb), .HS_OUT_n(shs), .VS_OUT_n(svs)
	);

	// --- measure both the same way ---
	task report;
		input [8*8:1] name;
		input         hs;
		inout integer t, last, lowc, shown;
		begin end
	endtask

`include "syncprobe.vh"

	initial begin
		nreset = 1'b0; repeat (20) @(posedge clk); nreset = 1'b1;
		#2_000_000; $display("DONE"); $finish;
	end
endmodule
