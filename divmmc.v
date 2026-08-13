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
	output reg     paged_in,
	output [3:0]   sram_page,
	output         mapram,
	output         conmem,
	
	// SD card interface
	output reg     sd_cs,
	output         sd_sck,
	output         sd_mosi,
	input          sd_miso,
	// High while an SPI byte is in flight and the CPU is on the port.
	output         cpu_hold
);

reg m1_trigger;

// Declared before use: Quartus accepts use-before-declaration,
// ModelSim rejects it.
reg [7:0] ctrl;

assign sram_page = ctrl[3:0];
assign mapram = ctrl[6];
assign conmem = ctrl[7];

// Control del modulo SPI
reg spi_tx_strobe;
wire spi_busy_i;
reg spi_rx_strobe;

// One SPI transfer per bus cycle, detected on the access starting
// rather than on its level - see the comment at the strobe below.
wire spi_acc = enable && (a[3:0] == 4'hb) && (!rd_n || !wr_n);
reg  spi_acc_d = 1'b0;

// Hold the CPU on the SPI port while a byte is in flight, so the
// exchange stops depending on how fast the CPU polls it. Declared here
// rather than above, where spi_acc has not been declared yet and would
// become an implicit one-bit net - ModelSim rejects that and Quartus
// builds it silently, which cost a board flash earlier in this project.
assign cpu_hold = spi_acc & spi_busy_i;

// (removed: an acc_cnt access counter clocked by `enable` and never read
// by anything, kept alive only by a noprune attribute. Because `enable`
// is derived from the CPU's IORQ_n, it made TimeQuest treat IORQ_n as a
// clock - "was determined to be a clock but was found without an
// associated clock assignment" - adding a bogus unanalysed clock domain
// for no benefit.)

always @(posedge clk) begin
	if(reset_n == 1'b0) begin
		m1_trigger <= 1'b0;
		paged_in <= 1'b0;
		ctrl <= 8'h00;
		sd_cs <= 1'b1;
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

		if (!mreq_n && !rd_n && !m1_n && 
			((a==16'h0000) || (a==16'h0008) || (a==16'h0038) ||
			 (a==16'h0066) || (a==16'h04C6) || (a==16'h0562))) begin
			// activate automapper after this cycle
			m1_trigger <= 1'b1;
		end else if (!mreq_n && !rd_n && !m1_n && a[15:8]==8'h3D) begin
			// activate automapper immediately
			paged_in <= 1'b1;
			m1_trigger <= 1'b1;
		end else if (!mreq_n && !rd_n && !m1_n && {a[15:3],3'd0} == 16'h1ff8) begin
			// deactivate automapper after this cycle
			m1_trigger <= 1'b0;
		end
	
		if (m1_n==1'b1)
			paged_in <= m1_trigger;
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
   .spi_busy(spi_busy_i)
);

endmodule
