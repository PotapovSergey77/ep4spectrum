// spi.v inspired by zxuno project
//
// Modifications copyright (c) 2026 Sergey Potapov (potapov.sergey.77@gmail.com)
//
// Changes:
//   - SCK divided down to ~3.5 MHz, the rate real DivMMC hardware runs
//     at. The engine used to be clocked flat out, which no SD card will
//     answer during its initialisation handshake.
//   - busy output added, so divmmc.v can hold the CPU for exactly one
//     transfer instead of letting a poll land mid-shift and be dropped.
//   - div_cnt given an explicit power-up value: uninitialised it starts
//     as x in simulation and, only ever adding to itself, never
//     recovers - which invalidates any run touching this module.

module spi (
   input clk,              // 7MHz
   input tx_strobe,        // Byte ready to be transmitted
   input rx_strobe,        // request to read one byte
   input [7:0] din,        // del bus de datos de salida de la CPU
   output reg [7:0] dout,  // al bus de datos de entrada de la CPU

   output spi_clk,         // spi itself
   input  spi_di,          //
   output spi_do,          //

   // High from the clock the engine is kicked off until it is idle
   // again, so a caller can hold the CPU for exactly one transfer.
   // See divmmc.v's wait_n for why that is needed.
   output busy,

   // The shift register itself.
   //
   // dout carries the byte from the PREVIOUS transfer: it is loaded when
   // a new one starts, which is the pipelined behaviour a caller that
   // does not wait depends on, and what real Z-Controller hardware does.
   // A caller that DOES hold the CPU to the end of the transfer wants
   // this one instead - by then it is the byte just received, with no
   // lag to account for.
   output [7:0] rxb
);

// SD cards require a slow (<=400kHz) SCK during the CMD0/CMD8/ACMD41
// init handshake - only after leaving idle state can they be clocked
// fast. An earlier attempt at slowing this down (clk/4, ~7-14MHz SCK)
// made things worse, but that was tried before the DivMMC boot
// sequence was understood at all - it wasn't actually slow enough to
// reach SD-safe territory, just slow enough to disturb something else.
// Confirmed via simulation that the ROM correctly sends CMD0 with the
// right CRC and then waits for a response - and on real hardware CS
// gets asserted and then stays stuck exactly there, consistent with
// a card refusing to answer a too-fast SPI clock. div_cnt gates the
// shift/counter advance to roughly clk/128 (56MHz/128/2 =~ 219kHz
// SCK), safely under the 400kHz limit.
// ~219kHz turned out to be far slower than necessary: the card now
// answers, gets detected and the filesystem mounts, so initialisation
// is plainly not the problem any more - but ESXDOS then fails loading
// a file, and at that rate a 4KB read takes ~150ms, which is the sort
// of thing its timeouts are not written for. /8 gives 56MHz/2/8 =
// 3.5MHz, comfortably inside the 25MHz an SD card allows in SPI mode
// and roughly the rate real DivMMC hardware runs at.
// The usable window is narrower than "slower is safer" would suggest.
// 219kHz initialised the card and mounted the filesystem but timed
// ESXDOS out when loading a file; 1.75MHz stopped even initialising, so
// ESXDOS's card-init path has its own timeout that a slow clock misses.
// 3.5MHz is the rate that has actually got through both, and it is what
// real DivMMC hardware runs at.
// Explicit power-up value: Quartus maps this to the DFF's power-up
// state (the same thing `counter`'s own = 5'd16 below relies on), but
// in simulation an uninitialised reg starts 'x' and, since div_cnt only
// ever adds to itself, never recovers - tick stays 'x' forever and the
// x propagates into counter. Sim-only problem, but it invalidates any
// run that touches this module.
reg [2:0] div_cnt = 3'd0;
wire      tick = (div_cnt == 3'd7);
always @(posedge clk) div_cnt <= div_cnt + 3'd1;

reg [4:0] counter = 5'd16; // tx/rx counter is idle
reg [7:0] io_byte;

assign busy = (counter != 5'd16);
assign rxb  = io_byte;

assign spi_clk = counter[0];
assign spi_do = io_byte[7];       // data is shifted up during transfer
wire io_strobe = tx_strobe || rx_strobe;

always @(posedge clk) begin
	// spi engine idle and is supposed to be started?
	if (io_strobe && (counter == 16)) begin
		// kickstart engine
		counter <= 5'd0;
		dout <= io_byte;
		io_byte <= tx_strobe?din:8'hff;
	end else if(counter != 16 && tick) begin
		if(spi_clk) io_byte <= { io_byte[6:0], spi_di };
		counter <= counter + 5'd1;
	end
end

endmodule
