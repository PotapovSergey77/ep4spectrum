// spi.v inspired by zxuno project

module spi (
   input clk,              // 7MHz
   input tx_strobe,        // Byte ready to be transmitted
   input rx_strobe,        // request to read one byte
   input [7:0] din,        // del bus de datos de salida de la CPU
   output reg [7:0] dout,  // al bus de datos de entrada de la CPU

   output spi_clk,         // spi itself
   input  spi_di,          //
   output spi_do           //
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
reg [6:0] div_cnt;
wire      tick = (div_cnt == 7'd127);
always @(posedge clk) div_cnt <= div_cnt + 7'd1;

reg [4:0] counter = 5'd16; // tx/rx counter is idle
reg [7:0] io_byte;

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
