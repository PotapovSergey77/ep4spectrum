// zcontroller - the Pentagon Z-Controller SD interface
//
// Copyright (c) 2026 Sergey Potapov (potapov.sergey.77@gmail.com)
//
// Two ports and nothing else:
//
//   $77  write: bit 0 card power, bit 1 /CS (0 selects the card)
//        read : the last byte written, so a presence check passes
//   $57  read/write: one byte through SPI
//
// This is deliberately the whole of it. Unlike DivMMC it does not touch
// the memory map - no automapper, no traps, no ROM or RAM paged over
// $0000-$3FFF - so the entire class of fault that comes with the
// automapper cannot arise here. Where the file lives and what to do with
// it is the running program's business, which is the point: Proteus
// already knows how to read FAT and we do not have to.
//
// It shares spi.v with DivMMC by instantiating a second copy, 23 logic
// cells, rather than arbitrating one engine between two owners. The SD
// pins themselves are muxed at the top level on which machine is
// running.

module zcontroller (
	input             clk,
	input             reset_n,

	// Bus, already qualified: IORQ without M1
	input             enable,
	input      [7:0]  a,
	input             wr_n,
	input             rd_n,
	input      [7:0]  din,
	output reg [7:0]  dout,

	// SD card
	output reg        sd_cs_n,
	output            sd_sck,
	output            sd_mosi,
	input             sd_miso,

	// High for any access to either port, before anything is decided
	// about the card. Selecting the card is several steps into a
	// conversation, so a lamp driven from /CS cannot tell a program that
	// is looking and failing from one that never looked.
	output            act,

	// Low while a transfer this module started is still shifting. Same
	// shape as divmmc.v's, and for the same reason: SCK runs at 3.5MHz,
	// so a byte takes about 2.3us against an IO cycle of roughly 3.1us
	// at 3.5MHz - close enough that whether it fits would otherwise
	// depend on where the T-states happened to fall.
	output            wait_n
);

	wire sel_dat = (a == 8'h57);
	wire sel_ctl = (a == 8'h77);

	reg  sd_pwr = 1'b0;
	reg  [7:0] ctrl_r = 8'h00;   // last byte written to the control port

	// One transfer per bus cycle, taken on the access starting rather
	// than on its level. IORQ, RD/WR and the port hold for the CPU's
	// whole IN or OUT, and on the level that is several transfers for
	// what the program believes is one byte - the mistake divmmc.v made
	// first and bdi.v made again.
	wire spi_acc = enable & sel_dat & (~rd_n | ~wr_n);
	reg  spi_acc_d = 1'b0;

	reg  spi_tx_strobe;
	reg  spi_rx_strobe;
	wire spi_busy;
	wire [7:0] spi_dout;

	// Latches that this access has actually started a transfer, so
	// wait_n is not fooled by busy still reading low in the clock or two
	// before spi.v reacts to the strobe.
	reg  seen_busy = 1'b0;

	always @(posedge clk) begin
		if (reset_n == 1'b0) begin
			sd_cs_n   <= 1'b1;
			sd_pwr    <= 1'b0;
			ctrl_r    <= 8'h00;
			spi_acc_d <= 1'b0;
			seen_busy <= 1'b0;
		end else begin
			spi_tx_strobe = 1'b0;
			spi_rx_strobe = 1'b0;

			if (enable == 1'b1 && sel_ctl == 1'b1 && wr_n == 1'b0) begin
				sd_pwr  <= din[0];
				sd_cs_n <= din[1];
				ctrl_r  <= din;
			end

			spi_acc_d <= spi_acc;
			if (spi_acc == 1'b1 && spi_acc_d == 1'b0) begin
				if (wr_n == 1'b0) spi_tx_strobe = 1'b1;
				else              spi_rx_strobe = 1'b1;
			end

			if (spi_acc == 1'b0)      seen_busy <= 1'b0;
			else if (spi_busy == 1'b1) seen_busy <= 1'b1;
		end
	end

	// With the card deselected, send $FF rather than the byte the
	// program wrote. Some cards keep taking input after /CS goes high,
	// and the reference hardware does exactly this to stop them.
	wire [7:0] spi_din = sd_cs_n ? 8'hff : din;

	spi zc_spi (
		.clk(clk),
		.tx_strobe(spi_tx_strobe),
		.rx_strobe(spi_rx_strobe),
		.din(spi_din),
		.dout(spi_dout),
		.spi_clk(sd_sck),
		.spi_di(sd_miso),
		.spi_do(sd_mosi),
		.busy(spi_busy)
	);

	// Reading the control port gives back what was written to it.
	//
	// It used to answer $FF, which is what a port with nothing behind it
	// answers - and that is exactly how a program checking whether a
	// controller is fitted would conclude that one is not. Write a value,
	// read it back, compare: $FF fails that whether the comparison is
	// exact or masked. The whole byte is kept rather than just the two
	// defined bits, so an exact compare passes too.
	always @* begin
		if (sel_dat)      dout = spi_dout;
		else if (sel_ctl) dout = ctrl_r;
		else              dout = 8'hff;
	end

	assign act = enable & (sel_dat | sel_ctl);

	assign wait_n = ~spi_acc | (seen_busy & ~spi_busy);

endmodule
