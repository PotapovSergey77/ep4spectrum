// divmmc
//
// Modifications copyright (c) 2026 Sergey Potapov (potapov.sergey.77@gmail.com)
//
// Changes:
//   - The 0x3Dxx automapper entry is combinational, so the fetch that
//     triggers it already comes from the DivMMC page. As a latch it
//     worked only while a T-state lasted more than one master clock,
//     which is why DivMMC would not start at 28 MHz.
//   - wait_n added: the CPU is held for exactly one SPI transfer, so a
//     poll can never arrive while the engine is still shifting and be
//     silently discarded. That is what broke DivMMC above 3.5 MHz.
//   - One SPI transfer per bus cycle, detected on the access starting
//     rather than on its level - on the level, one IN/OUT shifted
//     several bytes through and desynchronised the card.
//   - Removed a free-running access counter clocked by `enable`, which
//     made TimeQuest treat IORQ_n as a clock.
//
module divmmc (
	input        	reset_n,
	input        	clk,
	input        	clken,

	// Bus interface
	input          enable,

	// High when a Beta disk interface is fitted and therefore owns the
	// $3Dxx entry. Both devices trap that page, and they are not two
	// spellings of the same mechanism: the Beta swaps a full 16K over
	// $0000-$3FFF, DivMMC swaps 8K of ROM at $0000-$1FFF and 8K of its
	// own RAM at $2000-$3FFF. With TR-DOS present the fetch belongs to
	// the Beta, and DivMMC arming alongside it is not merely redundant -
	// it is a trap it can never get out of. Its exit lives at
	// $1FF8-$1FFF inside a ROM that is no longer mapped, so the stub that
	// would clear the automapper is never executed, and paged_in stays
	// stuck at one for as long as the machine runs.
	input          beta_owns_3d,

	// The machine ROM comes from the SD slots: DivMMC is not part of the
	// memory map at all, so its automapper must not arm either.
	input          stand_down,

	// High when the six ROM entry points below may arm the automapper.
	// They are ESXDOS's, and they are addresses in the 48K BASIC ROM:
	// $0008 is the API and $0038 the interrupt handler. Under a different
	// ROM the same addresses are different code, so the reference DivMMC
	// arms them only while 48 BASIC is the selected half. This is that
	// condition, worked out by the caller because the answer differs by
	// machine - see divmmc_entry_ok in ep4spectrum.v.
	//
	// $3Dxx is deliberately NOT gated by it. That entry is TR-DOS's and
	// the specification arms it whatever ROM is paged; beta_owns_3d is
	// what decides that one.
	input          entry_ok,

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
// The automapper was armed by the $3Dxx entry, which gets the Beta's
// exit rule as well as its entry - see the trap chain below.
reg by_3d;

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
// The $3Dxx entry stays on, because the ESXDOS boot uses it: switching
// it off was tried and the card would not initialise at all. What it
// gets instead is an exit, down in the trap chain - see by_3d there.
localparam TRAP_3D = 1'b1;

wire auto_now = (TRAP_3D && !mreq_n && !rd_n && !m1_n
                 && a[15:8] == 8'h3D && !beta_owns_3d);
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
		by_3d <= 1'b0;
		sd_cs <= 1'b1;
		seen_busy <= 1'b0;
	end else begin
		spi_rx_strobe = 1'b0;
		spi_tx_strobe = 1'b0;
			
		if (a[3:0]==4'h3 && enable && !wr_n)
			// MAPRAM, bit 6, is a set-only bit: once on it stays on until
			// a reset. Writing the whole byte let it be cleared again.
			// Matches divmmc_mcleod.v, which has
			// mapram_mode <= mapram_mode | din[6].
			ctrl <= {din[7], ctrl[6] | din[6], din[5:0]};
			
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

		// Stood down entirely.
		//
		// Gating the $3Dxx trap alone was not enough. Every other entry
		// has the same one-way property: $0038 fires on each interrupt,
		// and the stub that would disarm the automapper lives at
		// $1FF8-$1FFF inside a ROM that is no longer mapped, so it can
		// never be executed. One frame is all it takes, and paged_in is
		// then stuck at one until the power goes off.
		//
		// Two narrow gates rather than one blanket stand-down.
		//
		// Standing the whole automapper down whenever the machine ROM
		// came from the SD slots also took away $0066, and with it the
		// NMI menu - so on a machine running a loaded ROM there was no
		// way to reach ESXDOS at all, and therefore no way to load
		// anything to run on it. That is not a side effect worth having:
		// the two devices have to share the machine, not take turns.
		//
		// $0000 is the one entry that genuinely cannot be shared. It
		// fires on the reset fetch, so leaving it armed means every
		// reset lands in ESXDOS and the loaded ROM's menu is never seen.
		// Suppressing just that one leaves reset to the machine ROM
		// while $0008, $0038 and $0066 still reach ESXDOS. It does mean
		// ESXDOS is not re-initialised by that reset - it does not need
		// to be, since its RAM in SDRAM survives one.
		// Sharing was tried and gives a machine that behaves differently
		// every time, so it is off again.
		//
		// Suppressing only $0000 leaves ESXDOS un-initialised, and the
		// reason that is fatal rather than merely untidy is that ESXDOS
		// keeps its workspace in the SPECTRUM's RAM around $5B00, not
		// in its own. The machine ROM's reset wipes exactly that. Its
		// RAM in SDRAM surviving the reset buys nothing, because the
		// half that matters does not live there - so the NMI menu ran
		// on destroyed state and did something different on every try.
		//
		// Doing it properly means letting ESXDOS take the reset and hand
		// over to the machine ROM afterwards, the way it does on real
		// hardware. That is a separate piece of work and not the way to
		// get a program onto the Pentagon: a TR-DOS machine loads from a
		// disk, and slot 3 already carries an image.
		if (stand_down) begin
			m1_trigger <= 1'b0;
			paged_in_r <= 1'b0;
		end else if (!mreq_n && !rd_n && !m1_n &&
			// Five entries gated by entry_ok, the NMI one not. They were
			// unconditional, and that was the right condition applied
			// to the wrong machines: unconditional is right for a 48K,
			// which has no ROM select, and wrong for a 128K running its
			// own ROM, where $0038 is the interrupt handler and $0000
			// fires on the reset fetch - which brought the machine up
			// in 48 BASIC instead of the 128 menu.
			//
			// The reference DivMMC gates six of them on "the 48K BASIC
			// ROM is currently selected", and copying that here broke
			// ESXDOS outright. That condition is bit 4 of $7FFD, which
			// is clear out of reset, so on a 48K only the $0000 entry
			// ever armed the automapper - and $0008 is the ESXDOS API,
			// the way every dot command is called. .browse answered with
			// an error and the machine could not be brought back up.
			//
			// $0066 is outside the gate. It is the NMI entry, and on
			// this board an NMI comes from F12 and nothing else, so it
			// cannot fire by accident - holding it under the ROM
			// condition only made the way in longer. From the 128 menu
			// bit 4 is clear, so the first F12 was not seen here at
			// all: it went to the ROM own handler, which drops into 48
			// BASIC, and only a SECOND F12 reached ESXDOS. Ungated, it
			// is what the NMI button on a real DivMMC is for - one
			// press, from whatever ROM happens to be paged.
			// $0000 stays UNDER the gate here, unlike divmmc_mcleod.v: there
			// ESXDOS is the boot ROM, while this board boots machine ROMs
			// loaded from the card. Ungated, ESXDOS wins the reset fetch and
			// the machine's own menu never runs.
			((a==16'h0066) ||
			 (entry_ok &&
			  ((a==16'h0000) || (a==16'h0008) || (a==16'h0038) ||
			   (a==16'h04C6) || (a==16'h0562))))) begin
			// activate automapper after this cycle
			m1_trigger <= 1'b1;
			by_3d      <= 1'b0;
		end else if (TRAP_3D && !mreq_n && !rd_n && !m1_n && a[15:8]==8'h3D
		             && !beta_owns_3d) begin
			// Activate the automapper immediately, before the byte is
			// fetched.
			//
			// The specification gives this entry a second action - set
			// MAPRAM - and doing it here breaks the card completely: it
			// never initialises. MAPRAM turns $0000-$1FFF into bank 3, the
			// copy ESXDOS makes of itself, and OUR BOOT COMES THROUGH THIS
			// ENTRY - so the EPROM was being taken away from the loader
			// before there was any copy to take its place. On real hardware
			// the firmware has made that copy and set MAPRAM through the
			// control port long before any program probes $3Dxx, so the
			// entry's own action never has to do it from cold.
			//
			// Which says something about the probe fault: at the moment a
			// program probes, bank 3 here is not a valid copy of ESXDOS.
			// That is the thing to fix, not this line.
			paged_in_r <= 1'b1;
			m1_trigger <= 1'b1;
			by_3d      <= 1'b1;
		end else if (!mreq_n && !rd_n && !m1_n && {a[15:3],3'd0} == 16'h1ff8) begin
			// deactivate automapper after this cycle
			m1_trigger <= 1'b0;
			by_3d      <= 1'b0;
		// Back on. It was switched off with a 1'b0 to find out whether it
		// was what took the automapper away underneath the NMI handler.
		// That turned out to be something else - F12 was fixed with a
		// 64-T one-shot in ep4spectrum and works - but the 1'b0 stayed,
		// and with it the fault described below.
		// Switched off again with the 1'b0 it spent a long time behind.
		// Turning it on was speculative, fixed nothing, and lives in the
		// DivMMC path that only the Spectrum machines use for the card.
		end else if (1'b0 && by_3d && !mreq_n && !rd_n && !m1_n
		             && (a[15] | a[14])) begin
			// Armed through $3Dxx, and now fetching outside the ROM
			// area: let go.
			//
			// The documented exit is $1FF8-$1FFF and nothing else, which
			// is fine for a caller that goes in and comes back out
			// through the stub. It is not fine for a program that only
			// PROBES the page - reads what is there, finds it is not
			// TR-DOS, and returns to its own code. Nothing disarms the
			// automapper then, DivMMC's RAM covers $2000-$3FFF for the
			// rest of the run, and the next call into the top half of
			// the 48K ROM runs ESXDOS's data as code. That is what
			// killed Test 4.3 a screen after the probe.
			//
			// Removing the entry instead was tried and stopped ESXDOS
			// booting: the boot uses it. So keep the entry and give it
			// the Beta's exit rule, which is the paging this entry
			// exists to emulate in the first place. It costs the boot
			// nothing - that runs inside $0000-$3FFF throughout.
			m1_trigger <= 1'b0;
			paged_in_r <= 1'b0;
			by_3d      <= 1'b0;
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
   .busy(spi_busy),
   .rxb()          // ESXDOS is written for the pipelined dout above
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
//    instance in ep4spectrum.v. It was a complete no-op: T80 samples
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
