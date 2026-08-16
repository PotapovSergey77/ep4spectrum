// divmmc

module divmmc (
	input        	reset_n,
	input        	clk,
	input        	clken,

	// Bus interface
	input          enable,
	input  [15:0] 	a,
	input          wr_n,
	input          rd_n,
	input          mreq_n,
	input          m1_n,
	input  [7:0]  	din,
	output [7:0]  	dout,
	
	// memory state
	output         paged_in,
	output [3:0]   sram_page,
	output         mapram,
	output         conmem,
	
	// SD card interface
	output reg     sd_cs,
	output         sd_sck,
	output         sd_mosi,
	input          sd_miso,

	// Low while an SPI transfer this module started is still shifting.
	// See the comment above the assign at the bottom for what it is for
	// and for the two earlier attempts that did not work.
	output         wait_n
);

reg m1_trigger;
reg paged_in_r;

// The 0x3Dxx entry is documented - in this file, below - as activating
// the automapper "immediately", meaning the very fetch that triggers it
// must already come from the DivMMC page. Latching paged_in_r does not
// achieve that: the register only takes effect on the following clock,
// while T80se latches the byte it fetched on the edge that ends TState
// 2. Whether the new mapping wins is then a race decided by how many
// master clocks a T-state lasts:
//
//   3.5 / 7 / 14MHz - T2 spans 8 / 4 / 2 clocks, so the trigger fires
//                     on an earlier one and the CPU latches the byte
//                     with the DivMMC page already mapped. Works.
//   28MHz           - T2 is a single clock. The trigger and the latch
//                     happen on the same edge, the mapping is still the
//                     old one, and the CPU gets the 48K ROM's byte
//                     instead of the DivMMC page's. It then runs on
//                     through 0x3DFE, 0x3DFF, 0x3E00... into the
//                     character set.
//
// Measured: at 28MHz and 14MHz the boot agrees for 609 fetches and
// splits at the 610th - 14MHz takes the jump the DivMMC page holds at
// 0x3DFD and lands on 0x0863, 28MHz falls through to 0x3DFE. That is
// the whole of the 28MHz DivMMC failure: everything entering through a
// trigger breaks, everything already inside the page is fine.
//
// So the 0x3Dxx case is made combinational - it maps the page for the
// cycle that asks, at any speed. The other triggers are deliberately
// left alone: they are specified as taking effect AFTER their cycle,
// and moving them is what broke 14MHz in an earlier attempt.
wire auto_now = (!mreq_n && !rd_n && !m1_n && a[15:8] == 8'h3D);
assign paged_in = paged_in_r | auto_now;

// Declared before use: Quartus accepts use-before-declaration,
// ModelSim rejects it.
reg [7:0] ctrl;

assign sram_page = ctrl[3:0];
assign mapram = ctrl[6];
assign conmem = ctrl[7];

// Control del modulo SPI
reg spi_tx_strobe;
reg spi_rx_strobe;

// One SPI transfer per bus cycle, detected on the access starting
// rather than on its level - see the comment at the strobe below.
wire spi_acc = enable && (a[3:0] == 4'hb) && (!rd_n || !wr_n);
reg  spi_acc_d = 1'b0;

// spi.v starts a transfer only when it is idle, and silently discards
// one that arrives while a previous byte is still shifting - dout is
// left alone and nothing begins. ESXDOS polls this port in a loop; at
// 3.5MHz the polls are far enough apart that each finds the engine
// idle, and above that one can land mid-shift and the driver then
// reads the same stale byte forever.
wire spi_busy;

// Latches that this access has been seen to actually start a transfer.
// Without it, wait_n would be fooled by spi_busy still reading low in
// the clock or two before spi.v reacts to the strobe, and would release
// the CPU before the byte it just asked for had begun.
reg  seen_busy = 1'b0;

// (removed: an acc_cnt access counter clocked by `enable` and never read
// by anything, kept alive only by a noprune attribute. Because `enable`
// is derived from the CPU's IORQ_n, it made TimeQuest treat IORQ_n as a
// clock - "was determined to be a clock but was found without an
// associated clock assignment" - adding a bogus unanalysed clock domain
// for no benefit.)

always @(posedge clk) begin
	if(reset_n == 1'b0) begin
		m1_trigger <= 1'b0;
		paged_in_r <= 1'b0;
		ctrl <= 8'h00;
		sd_cs <= 1'b1;
		seen_busy <= 1'b0;
	end else begin
		spi_rx_strobe = 1'b0;
		spi_tx_strobe = 1'b0;
			
		if (a[3:0]==4'h3 && enable && !wr_n)
			ctrl <= din;
			
		if(a[3:0]==4'h7 && enable && !wr_n)
			sd_cs <= din[0];

		// SPI read/write - exactly one transfer per Z80 IN/OUT.
		//
		// enable/a/wr_n stay stable for the CPU's entire IN/OUT bus
		// cycle, which is many clk edges, so triggering on the level
		// retriggers spi.v every time it goes idle mid-bus-cycle and
		// shifts several real SPI bytes through for what the ROM
		// believes is one byte, desyncing the stream from the card.
		//
		// This used to be gated by clken instead, which only worked by
		// luck of phase: an IO cycle is about 20 clk long and clken
		// fires every 16, so the number of strobes inside one bus
		// cycle depended on where the CPU's T-states happened to sit.
		// Moving CLKEN_CPU one clock (for the SDRAM arbiter) changed
		// that alignment and the card stopped initialising - ESXDOS
		// hung at "Selecting Device". Triggering on the start of the
		// access instead makes it exactly one, whatever the phase.
		spi_acc_d <= spi_acc;
		if(spi_acc && !spi_acc_d) begin
			if(wr_n) spi_rx_strobe = 1'b1;
			else     spi_tx_strobe = 1'b1;
		end

		// Rearms the moment the access ends, ready for the next one.
		if (!spi_acc)
			seen_busy <= 1'b0;
		else if (spi_busy)
			seen_busy <= 1'b1;

		if (!mreq_n && !rd_n && !m1_n && 
			((a==16'h0000) || (a==16'h0008) || (a==16'h0038) ||
			 (a==16'h0066) || (a==16'h04C6) || (a==16'h0562))) begin
			// activate automapper after this cycle
			m1_trigger <= 1'b1;
		end else if (!mreq_n && !rd_n && !m1_n && a[15:8]==8'h3D) begin
			// activate automapper immediately
			paged_in_r <= 1'b1;
			m1_trigger <= 1'b1;
		end else if (!mreq_n && !rd_n && !m1_n && {a[15:3],3'd0} == 16'h1ff8) begin
			// deactivate automapper after this cycle
			m1_trigger <= 1'b0;
		end
	
		if (m1_n==1'b1)
			paged_in_r <= m1_trigger;
	end
end

spi mi_spi (
   .clk(clk),
   .tx_strobe(spi_tx_strobe),
   .rx_strobe(spi_rx_strobe),
   .din(din),
   .dout(dout),
   
   .spi_clk(sd_sck),
   .spi_di(sd_miso),
   .spi_do(sd_mosi),
   .busy(spi_busy)
);

// True once this access's own transfer has both started and finished.
// Gating on spi_busy alone would drop wait_n the instant it read low,
// which includes the clocks right after the strobe before spi.v has
// reacted - releasing the CPU before the byte had begun to shift.
wire spi_xfer_complete = seen_busy && !spi_busy;

// Hold the CPU for exactly one transfer, so a poll can never arrive
// while the engine is still shifting and be discarded. Modelled on
// zx-sizif-512's divmmc.sv, which has no free-running engine to race:
// every access loads the shift counter and holds the CPU until it is
// done, making the drop impossible by construction rather than
// handling it with a queue.
//
// Keyed on spi_acc - a fully qualified access, IORQ and RD/WR and the
// port address together - and released unconditionally the moment the
// access ends. Two earlier shapes are worth not repeating:
//
//  - Keyed on the address alone (plus m1_n/mreq_n), to get the signal
//    earlier. The address bus holds its last value between cycles, so
//    this went true on its own during idle and refresh with nothing
//    able to clear it, and wait_n stuck low forever. That is a machine
//    that will not boot, will not switch speed and will not run BASIC.
//
//  - This same spi_acc shape, before T2Write=1 was set on the T80se
//    instance in spectrum_top.v. It was a complete no-op: T80 samples
//    WAIT at the end of TState 2, and with T2Write=0 an OUT's IORQ did
//    not go low until T3, so the wait was always exactly one T-state
//    too late to be seen. It compiled, closed timing, passed every
//    regression, and changed nothing at all on the board.
//
// While the CPU is held at TState 2, T80se keeps re-asserting IORQ
// (its `TState == 2 && WAIT_n == 0` term), so the access - and this
// signal - stay up until the transfer completes and then release
// together.
assign wait_n = ~spi_acc | spi_xfer_complete;

endmodule
