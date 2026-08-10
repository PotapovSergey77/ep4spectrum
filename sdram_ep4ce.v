//
// sdram_ep4ce.v
//
// sdram controller adapted from the MiST board sdram.v for the
// EP4CE6E22C8 (OMDAZZ / RZ-EasyFPGA A2.2) development board.
//
// The SDRAM chip fitted to this board is a 64Mbit part organised as
// 4M x 16 x 4 banks (12-bit row address, 8-bit column address) instead
// of the 256Mbit 16M x 16 x 4 banks (13-bit row, 9-bit column) part used
// on the original board this core was written for. The board only routes
// 12 SDRAM address lines (S_A0..S_A11), so the address bus and the
// row/column split below had to shrink accordingly.
//
// Original copyright (c) 2013 Till Harbaum <till@harbaum.org>
// Licensed under the GNU General Public License v3 (or later).
//

module sdram_ep4ce (

	// interface to the SDRAM chip (4M x 16 x 4 banks)
	inout [15:0]  		sd_data,    // 16 bit bidirectional data bus
	output reg [11:0]	sd_addr,    // 12 bit multiplexed address bus
	output reg [1:0] 	sd_dqm,     // two byte masks
	output reg [1:0] 	sd_ba,      // two banks
	output 				sd_cs,      // a single chip select
	output 				sd_we,      // write enable
	output 				sd_ras,     // row address select
	output 				sd_cas,     // columns address select

	// cpu/chipset interface
	input 		 		init,			// init signal after FPGA config to initialize RAM
	input 		 		clk,			// sdram is accessed at up to 128MHz
	input					clkref,		// reference clock to sync to

	input [7:0]  		din,			// data input from chipset/cpu
	output [7:0]  dout,				// data output to chipset/cpu (registered)
	output [7:0]  dout_raw,			// same data, straight off the pins
	input [24:0]   	addr,       // byte address (only addr[21:0] are decoded, giving 4MB usable)
	input 		 		oe,         // cpu/chipset requests read
	input 		 		we          // cpu/chipset requests write
);

// falling edge on oe/we/rfsh starts state machine

// no burst configured
localparam RASCAS_DELAY   = 3'd3;   // tRCD=20ns -> 2 cycles@56MHz
localparam BURST_LENGTH   = 3'b000; // 000=1, 001=2, 010=4, 011=8
localparam ACCESS_TYPE    = 1'b0;   // 0=sequential, 1=interleaved
localparam CAS_LATENCY    = 3'd3;   // 2/3 allowed
localparam OP_MODE        = 2'b00;  // only 00 (standard operation) allowed
localparam NO_WRITE_BURST = 1'b1;   // 0= write burst enabled, 1=only single access write

// 12-bit mode register: A11:A10 reserved(0), A9 wburst, A8:A7 opmode,
// A6:A4 cas latency, A3 access type, A2:A0 burst length
localparam MODE = { 2'b00, NO_WRITE_BURST, OP_MODE, CAS_LATENCY, ACCESS_TYPE, BURST_LENGTH};


// ---------------------------------------------------------------------
// ------------------------ cycle state machine ------------------------
// ---------------------------------------------------------------------

localparam STATE_IDLE      = 3'd0;   // first state in cycle
localparam STATE_CMD_START = 3'd0;   // state in which a new command can be started
localparam STATE_CMD_CONT  = STATE_CMD_START  + RASCAS_DELAY; // 4 command can be continued
localparam STATE_LAST      = 3'd7;   // last state in cycle

// Explicit power-up value. Cyclone IV registers come out of
// configuration at 0 anyway, so this changes nothing on hardware - but
// without it the counter is X in simulation and, because every branch
// of the condition below tests q, it stays X forever and the
// controller never issues a single command.
reg [2:0] q = 3'd0 /* synthesis noprune */;
always @(posedge clk) begin
	// 56Mhz counter synchronous to 7 Mhz clkref
   // force counter to pass state 5->6 exactly after the rising edge of clkref
	// since clkref is two clocks early
   if(((q == 0) && ( clkref == 0)) ||
		((q == 7) && ( clkref == 1)) ||
      ((q != 0) && (q != 7)))
			q <= q + 3'd1;
end

// ---------------------------------------------------------------------
// --------------------------- startup/reset ---------------------------
// ---------------------------------------------------------------------

// wait 1ms (32 8Mhz cycles) after FPGA config is done before going
// into normal operation. Initialize the ram in the last 16 reset cycles (cycles 15-0)
reg [4:0] reset;
always @(posedge clk) begin
	if(init)	reset <= 5'h1f;
	else if((q == STATE_LAST) && (reset != 0))
		reset <= reset - 5'd1;
end

// ---------------------------------------------------------------------
// ------------------ generate ram control signals ---------------------
// ---------------------------------------------------------------------

// all possible commands
localparam CMD_INHIBIT         = 4'b1111;
localparam CMD_NOP             = 4'b0111;
localparam CMD_ACTIVE          = 4'b0011;
localparam CMD_READ            = 4'b0101;
localparam CMD_WRITE           = 4'b0100;
localparam CMD_BURST_TERMINATE = 4'b0110;
localparam CMD_PRECHARGE       = 4'b0010;
localparam CMD_AUTO_REFRESH    = 4'b0001;
localparam CMD_LOAD_MODE       = 4'b0000;

reg [3:0] sd_cmd;   // current command sent to sd ram

// drive control signals according to current command
assign sd_cs  = sd_cmd[3];
assign sd_ras = sd_cmd[2];
assign sd_cas = sd_cmd[1];
assign sd_we  = sd_cmd[0];

// drive ram data lines when writing, set them as inputs otherwise
// the eight bits are sent on both bytes ports. Which one's actually
// written depends on the state of dqm of which only one is active
// at a time when writing
assign sd_data = we?{din, din}:16'bZZZZZZZZZZZZZZZZ;

// Latch the read data here, at the one phase it is actually on the bus
// (q=7, measured in simulation), instead of presenting the raw pins and
// leaving the consumer to sample at exactly the right instant.
//
// spectrum_top.v captures this into mem_do on the falling edge of
// cpu_cycle - a derived signal on ordinary routing, so on real silicon
// its skew decides precisely when the data bus is sampled. Combinational
// dout is only valid for a single ~18ns window, so a small skew samples
// a neighbouring transaction instead - which can only happen when there
// IS a neighbouring transaction, i.e. when video is competing for the
// chip. That matches the board exactly: disabling video's SDRAM reads
// let an otherwise unchanged build boot, while simulation (where a
// derived clock has no skew at all) never reproduced the fault.
// Registered here, dout stays valid for a whole ~143ns q cycle.
reg [6:0] refresh_timer = 7'd0;
reg       refresh_due   = 1'b0;
reg       refresh_cycle = 1'b0;
reg       read_cycle    = 1'b0;

// Registered, at the one phase the data is actually on the bus (q=7,
// measured in simulation). Tried combinational as well: with it the
// board was markedly worse, so the extra hold this gives the consumer
// matters more than the risk of straddling a neighbouring video read.
// Captured one clock after the data is launched, not on the launching
// edge itself. Constraining the interface (see spectrum.sdc) exposed
// this as a real -6.9ns setup violation on SDRAM_DQ -> here: the part
// needs up to ~6ns after its clock edge to drive the data out, and the
// earlier capture edge simply came before that. SDRAM holds read data
// until tOH past the following edge, so sampling one clock later sits
// comfortably inside the valid window and gains a full 17.9ns of setup
// margin. This is invisible in simulation, where the model produces
// data with no delay at all.
//
// read_cycle is assigned at q==0 too, so the value read here is still
// the finishing cycle's - which is the one whose data this is.
reg [7:0] dout_r;
always @(posedge clk) begin
	if (q == 3'd0 && read_cycle)
		dout_r <= sd_data[7:0];
end
assign dout = dout_r;

// Unregistered copy for the video controller, which samples the bus on
// its own schedule and was designed around the combinational output.
// The CPU path needs the registered one for timing margin; giving each
// consumer the form it expects avoids making one work at the cost of
// the other.
assign dout_raw = sd_data[7:0];

// ---------------------------------------------------------------------
// ------------------------- forced refresh ----------------------------
// ---------------------------------------------------------------------
//
// AUTO_REFRESH used to be issued only on cycles where neither oe nor we
// happened to be asserted. That is fine while the bus is mostly idle,
// but the video controller reads SDRAM continuously through the whole
// active display area, so those idle cycles nearly vanish and the chip
// stops being refreshed. Its contents then decay in tens of ms - which
// is exactly the observed board behaviour: with video's SDRAM reads
// disabled the very same build booted ESXDOS through to the 48K ROM,
// and with video enabled it ran off into RAM, while the ROM image was
// verified byte-perfect (16384/16384) by a check that ran with video
// held in reset and therefore refreshing normally.
//
// So take a cycle for refresh on a fixed schedule instead of hoping for
// a gap. The part needs 4096 refreshes per 64ms; one every 32 q cycles
// is one every ~4.6us, covering all 4096 rows in ~19ms, a wide margin
// inside the 64ms requirement, and costs 1/32nd of the bandwidth.
always @(posedge clk) begin
	if (q == STATE_LAST) begin
		if (refresh_timer == 7'd31) begin
			refresh_timer <= 7'd0;
			refresh_due   <= 1'b1;
		end else begin
			refresh_timer <= refresh_timer + 7'd1;
		end
	end
	if (q == STATE_CMD_START && refresh_due && !(we || oe))
		refresh_due <= 1'b0;
end

always @(posedge clk) begin
	sd_cmd <= CMD_INHIBIT;  // default: idle

	if(reset != 0) begin
		// initialization takes place at the end of the reset phase
		if(q == STATE_CMD_START) begin

			if(reset == 13) begin
				sd_cmd <= CMD_PRECHARGE;
				sd_addr[10] <= 1'b1;      // precharge all banks
			end

			if(reset == 2) begin
				sd_cmd <= CMD_LOAD_MODE;
				sd_addr <= MODE;
			end

		end
	end else begin
		// normal operation.
		//
		// The decision for the whole q cycle is taken once, at
		// STATE_CMD_START, and remembered: a refresh must suppress the
		// CAS phase too, otherwise a column access would be issued
		// against a row that was never opened.
		if(q == STATE_CMD_START) begin
			refresh_cycle <= refresh_due && !(we || oe);
			read_cycle    <= oe && !we;

			// Refresh only when the bus is otherwise idle. Preempting a
			// requester silently DROPS that access - the transaction is
			// suppressed but nothing tells the requester, so a write is
			// lost or a read returns stale data. With refresh every 32 q
			// cycles and accesses every 4, that lost roughly one access
			// in eight on each pass, which showed up as ~37% of a 16K
			// RAM write/read-back test failing, on all eight data bits.
			if(refresh_due && !(we || oe)) begin
				sd_cmd <= CMD_AUTO_REFRESH;
			end else if(we || oe) begin
				// RAS phase - 12 bit row address
				sd_cmd <= CMD_ACTIVE;
				sd_addr <= addr[19:8];
				sd_ba <= addr[21:20];
				sd_dqm <= 2'b00;
			end else begin
				// bus idle anyway - may as well refresh
				sd_cmd <= CMD_AUTO_REFRESH;
			end
		end

		// CAS phase - 8 bit column address, A10 forces auto precharge
		if(q == STATE_CMD_CONT && !refresh_cycle && (we || oe)) begin
			sd_cmd <= we?CMD_WRITE:CMD_READ;
			sd_addr <= { 4'b0100, addr[7:0] };  // auto precharge
		end
	end
end

endmodule
