// tb_contpat - the delay our contention window actually charges, per phase
//
// Copyright (c) 2026 Sergey Potapov (potapov.sergey.77@gmail.com)
//
// FUSE's tables, worked through contend_delay_common, say both machines
// contend exactly T-states 14361..14488 of the frame and differ only in
// what they charge inside that window:
//
//   128K     contention_pattern_65432100  { 5,4,3,2,1,0,0,6 }
//   +2A/+3   contention_pattern_76543210  { 5,4,3,2,1,0,7,6 }
//
// The 128K row is confirmed against hardware, so it doubles as the
// control: whatever phase this bench samples from, that row must read
// back as FUSE.s array, and the +2A/+3 row must then read as its own on
// the same reference. Reading one row alone says nothing about phase -
// reasoning about the phase instead of measuring it got the rotation
// wrong once already.
//
// Our delay is not a table: the CPU is held while CONTENTION is high, so
// what an access at a given phase pays is the number of contended
// T-states in front of it. This reads that straight off the module for
// the first display line and prints it beside FUSE's row, so the two can
// be compared without a demo in the way.

`timescale 1ns / 1ps

module tb_contpat;

	reg clk = 1'b0;
	always #10 clk = ~clk;          // 50 MHz here; only ratios matter
	reg clken = 1'b0;
	always @(posedge clk) clken <= ~clken;

	reg nreset = 1'b0;
	reg [1:0] machine = 2'd1;

	wire contention;

	video dut (
		.CLK(clk), .CLKEN(clken), .MEM_CYC(1'b1), .nRESET(nreset),
		.VGA(1'b0), .MACHINE(machine),
		.CONTENTION(contention), .CONTENTION_IO(),
		.INT_ADJ(12'd0), .INT_VADJ(8'd0), .CONT_ADJ(5'd0), .IO_ADJ(8'd0),
		.BORD_PHASE(4'd5), .BORD_DELAY(2'd2),
		.OSD_SPEED(2'd0), .OSD_EXT(1'b0), .OSD_POKE(1'b0), .OSD_ACTIVE(),
		.PORT_FF_ACTIVE(), .PORT_FF_DATA(),
		.VID_A(), .VID_D_IN(8'h00), .nVID_RD(), .nWAIT(),
		.VID_REQ_STEP(), .VID_REQ_GEN(), .VID_STALE(),
		.VID_REQ_ACK(1'b1), .VID_DATA_VALID(1'b1),
		.VID_DATA_STEP(1'b0), .VID_DATA_GEN(1'b0),
		.BORDER_IN(3'd0), .SCR_WR(1'b0), .SCR_A(13'd0), .SCR_D(8'h00),
		.FWD_HIT(),
		.R(), .G(), .B(),
		.nVSYNC(), .nHSYNC(), .nCSYNC(), .nHCSYNC(), .SCANLINE(),
		.nIRQ()
	);

	// Sample CONTENTION once per CPU T-state - four hcounter counts -
	// on the first line of the display area.
	reg [0:31] map;
	integer got = 0;
	integer i, j, d;
	reg armed = 1'b0;
	reg seen  = 1'b0;

	always @(posedge clk) if (nreset && clken) begin
		// Arm on the first display line, then start at the line's own
		// beginning so phase 0 of the printout is the window's first
		// T-state.
		if (dut.vpicture && dut.hc_cont == 10'd0) armed <= 1'b1;
		if (armed && !seen && dut.hc_cont[1:0] == 2'b00 && got < 32) begin
			map[got] = contention;
			got = got + 1;
			if (got == 32) seen <= 1'b1;
		end
	end

	task show;
		begin
			$write("  window: ");
			for (i = 0; i < 32; i = i + 1) $write("%s", map[i] ? "#" : ".");
			$write("\n  charged:");
			for (i = 0; i < 8; i = i + 1) begin
				d = 0;
				j = i;
				while (j < 32 && map[j]) begin d = d + 1; j = j + 1; end
				$write(" %0d", d);
			end
			$write("\n");
		end
	endtask

	initial begin
		nreset = 1'b0;
		repeat (10) @(posedge clk);
		nreset = 1'b1;

		machine = 2'd1;
		wait (seen == 1'b1);
		$display("128K   FUSE contention_pattern_65432100: 5 4 3 2 1 0 0 6");
		show;

		// Second pass for the +2A/+3.
		nreset = 1'b0; armed = 1'b0; seen = 1'b0; got = 0;
		machine = 2'd2;
		repeat (10) @(posedge clk);
		nreset = 1'b1;
		wait (seen == 1'b1);
		$display("+2A/+3 FUSE contention_pattern_76543210: 5 4 3 2 1 0 7 6");
		show;

		$display("DONE");
		$finish;
	end

	initial begin
		#40000000;
		$display("TIMED OUT (got=%0d)", got);
		$finish;
	end

endmodule
