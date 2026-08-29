// tb_iowin - the shape of the contention window, printed out
//
// Copyright (c) 2026 Sergey Potapov (potapov.sergey.77@gmail.com)
//
// The board says the border beside and below the raster does not just
// sit in the wrong place, it SPREADS - the first edge out by a little
// and the next by more. A window in the wrong place cannot do that: it
// would move every write by the same amount. A window of the wrong
// shape can, because each write in a run meets the pattern at a
// different point and is charged a different number of T-states.
//
// So the thing to look at is the pattern itself, per CPU T-state,
// across one display line. A 48K charges 6,5,4,3,2,1,0,0 repeating over
// 128 of the 224 T-states, and nothing outside that.
//
// Printed rather than checked: the published figure is the delay in
// T-states per slot, while what this module carries is a per-T-state
// hold, so the two are the same fact in different units and the
// comparison is better made by eye than by an assertion that bakes in
// one reading of it.

`timescale 1ns / 1ps

module tb_iowin;

	reg         clk = 1'b0;
	reg         clken = 1'b0;
	reg         nreset = 1'b0;
	reg  [1:0]  machine = 2'd0;
	integer     mval;
	initial if ($value$plusargs("MACHINE=%d", mval)) machine = mval[1:0];

	// The raster is not the same on every machine, and this bench used to
	// assume it was: it scanned lines 0..311 and read 224 T-states of a
	// line, both of which are the 48K's. On a 128K there are only 311
	// lines, so waiting for line 311 waited for ever - the run did not
	// fail, it hung, and printed TIMED OUT forty simulated milliseconds
	// later. Which is a poor way to learn that the machine you wanted to
	// measure is the one the bench cannot reach.
	wire [9:0] nlines = (machine == 2'd3) ? 10'd320 :   // Pentagon
	                    (machine == 2'd0) ? 10'd312 :   // 48K
	                                        10'd311;    // 128K, +2A/+3
	wire [9:0] tline  = (machine == 2'd1 || machine == 2'd2) ? 10'd228
	                                                        : 10'd224;
	// Eight bits, not five: IO_ADJ is an eight-bit port, and driving it
	// five bits wide left the top three unconnected - Z, which becomes X
	// through the sign extension and took the whole IO window with it.
	// That is why this bench has always printed "held for x" and a row of
	// quotes: not a formatting slip but an undefined signal, and the one
	// window a border demo actually depends on.
	reg  [7:0]  io_adj = 8'd0;

	integer     adjval;
	initial if ($value$plusargs("IOADJ=%d", adjval)) io_adj = adjval[7:0];

	always #17.857 clk = ~clk;
	always @(posedge clk) clken <= ~clken;

	wire cont_mem, cont_io;

	video vid (
		.CLK(clk), .CLKEN(clken), .MEM_CYC(1'b0), .nRESET(nreset),
		.VGA(1'b0), .MACHINE(machine),
		.CONTENTION(cont_mem), .CONTENTION_IO(cont_io),
		.INT_ADJ(8'd0), .INT_VADJ(8'd0), .CONT_ADJ(5'd0), .IO_ADJ(io_adj),
		.BORD_PHASE(4'd9), .BORD_DELAY(2'd0),
		.PORT_FF_ACTIVE(), .PORT_FF_DATA(),
		.VID_A(), .VID_D_IN(8'h00), .nVID_RD(), .nWAIT(),
		.VID_REQ_STEP(), .VID_REQ_GEN(), .VID_STALE(),
		.VID_REQ_ACK(1'b0), .VID_DATA_VALID(1'b0),
		.VID_DATA_STEP(1'b0), .VID_DATA_GEN(1'b0),
		.BORDER_IN(3'd0),
		.R(), .G(), .B(),
		.nVSYNC(), .nHSYNC(), .nCSYNC(), .nHCSYNC(), .SCANLINE(), .nIRQ()
	);

	// One CPU T-state is four hcounter counts. Sample each window once a
	// T-state, on the same count every time, so the string below is one
	// character per T-state of the line.
	reg [8:0] memrow [0:255];
	reg [8:0] iorow  [0:255];
	integer   t;
	integer   i;
	integer   memtot, iotot;

	initial begin
		nreset = 1'b0;
		repeat (40) @(posedge clk);
		nreset = 1'b1;

		// First: which lines have any contention at all - the vertical
		// edge is where a one-time loss at the top border would live.
		if ($test$plusargs("VSCAN")) begin : vscan
			integer ln, seen, firstln, lastln;
			firstln = -1; lastln = -1;
			for (ln = 0; ln < nlines; ln = ln + 1) begin
				wait (vid.vcounter[9:1] == ln[8:0]);
				seen = 0;
				while (vid.vcounter[9:1] == ln[8:0]) begin
					@(posedge clk);
					if (cont_mem) seen = seen + 1;
				end
				if (seen != 0) begin
					if (firstln < 0) firstln = ln;
					lastln = ln;
				end
			end
			$display("contention on lines %0d..%0d", firstln, lastln);
		end

		// Somewhere well inside the display area.
		wait (vid.vcounter[9:1] == 9'd100);
		wait (vid.hcounter == 10'd0);

		for (t = 0; t < tline; t = t + 1) begin
			// One T-state is four CLKEN ticks, eight posedges of the
			// 28MHz clock. Sample once per T-state, exactly.
			repeat (8) @(posedge clk);
			memrow[t] = cont_mem;
			iorow[t]  = cont_io;
		end

		memtot = 0; iotot = 0;
		for (i = 0; i < tline; i = i + 1) begin
			memtot = memtot + memrow[i];
			iotot  = iotot  + iorow[i];
		end

		$write("MEM window, one char per T-state of a display line:\n  ");
		for (i = 0; i < tline; i = i + 1) $write("%s", memrow[i] ? "#" : ".");
		$write("\n  held for %0d of %0d T-states\n", memtot, tline);

		$write("IO  window:\n  ");
		for (i = 0; i < tline; i = i + 1) $write("%s", iorow[i] ? "#" : ".");
		$write("\n  held for %0d of %0d T-states\n", iotot, tline);

		memtot = -1; iotot = -1;
		for (i = tline - 1; i >= 0; i = i - 1) begin
			if (memrow[i]) memtot = i;
			if (iorow[i])  iotot  = i;
		end
		$display("first MEM T-state %0d, first IO T-state %0d, IO leads by %0d",
			memtot, iotot, memtot - iotot);

		// Where each run of held T-states begins, and its phase on the
		// eight-T-state grid the pattern repeats on. Counting by eye does
		// not settle this: the question is whether the run that wraps
		// round the end of the line lands on the same grid as the rest,
		// and on a 228 T-state line it cannot, because 228 is not a
		// multiple of 8.
		$write("MEM runs start at:");
		for (i = 0; i < tline; i = i + 1)
			if (memrow[i] && (i == 0 || !memrow[i-1]))
				$write(" %0d(%0d)", i, i % 8);
		$write("\nIO  runs start at:");
		for (i = 0; i < tline; i = i + 1)
			if (iorow[i] && (i == 0 || !iorow[i-1]))
				$write(" %0d(%0d)", i, i % 8);
		$write("\n");
		// Every display line should carry the same window. The board says
		// the border beside the raster is shifted in some places and not
		// in others going down, which is a line-to-line story, and one
		// line sampled in the middle cannot tell it. So walk them all and
		// print only the ones that differ from the first - and the first
		// and last few regardless, because the edges of the display are
		// where a window is most likely to be a T-state short.
		begin : lscan
			integer ln, k, mt, it, mf, iff, refm, refi, refmf, refif, bad;
			refm = -1; bad = 0;
			for (ln = 0; ln < 192; ln = ln + 1) begin
				wait (vid.vcounter[9:1] == ln[8:0]);
				wait (vid.hcounter == 10'd0);
				mt = 0; it = 0; mf = -1; iff = -1;
				for (k = 0; k < tline; k = k + 1) begin
					repeat (8) @(posedge clk);
					if (cont_mem) begin mt = mt + 1; if (mf < 0) mf = k; end
					if (cont_io)  begin it = it + 1; if (iff < 0) iff = k; end
				end
				if (refm < 0) begin
					refm = mt; refi = it; refmf = mf; refif = iff;
					$display("line %0d reference: MEM %0d from %0d, IO %0d from %0d",
						ln, mt, mf, it, iff);
				end else if (mt != refm || it != refi ||
				             mf != refmf || iff != refif) begin
					$display("line %0d DIFFERS: MEM %0d from %0d, IO %0d from %0d",
						ln, mt, mf, it, iff);
					bad = bad + 1;
				end
			end
			$display("lines differing from the first: %0d of 192", bad);
		end

		$display("DONE");
		$finish;
	end


	initial begin
		#400_000_000;
		$display("TIMED OUT");
		$finish;
	end

endmodule
