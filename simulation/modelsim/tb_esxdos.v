// tb_esxdos.v
//
// Focused simulation testbench: T80 CPU + divmmc.v + address decode
// (replicated from spectrum_top.v's rom_48k generate block) driven
// against a behavioral memory array pre-loaded with the ESXDOS ROM at
// the same offsets boot_copy_* writes them to in the real design.
//
// This intentionally bypasses sdram_ep4ce.v/pll_ep4ce.v (real SDRAM
// timing isn't the question here - we already have hardware evidence the
// write path produces plausible-looking data) so we can get straight to
// watching actual CPU execution and see exactly where/why it gets stuck.

`timescale 1ns/1ps

module tb_esxdos;

	reg clock = 0;
	always #17.857 clock = ~clock; // ~28MHz, matches spectrum_top's "clock"

	reg reset_n = 0;
	initial begin
		repeat (20) @(posedge clock);
		reset_n = 1;
	end

	// ------------------------------------------------------------
	// CPU bus wires declared up front (referenced by clocks below)
	// ------------------------------------------------------------
	wire cpu_m1_n, cpu_mreq_n, cpu_ioreq_n, cpu_rd_n, cpu_wr_n, cpu_rfsh_n, cpu_halt_n, cpu_busack_n;
	wire [15:0] cpu_a;
	wire [7:0] cpu_do;
	reg  [7:0] cpu_di;

	// ------------------------------------------------------------
	// Clock enables (same clocks.v module used by the real design)
	// ------------------------------------------------------------
	wire psg_clken, cpu_clken, mem_clken, dio_clken, vid_clken, clk_ref, vid_mem_sync;
	clocks clken (
		.CLK(clock),
		.nRESET(reset_n),
		.MREQ(~cpu_mreq_n | ~cpu_ioreq_n),
		.CLKEN_PSG(psg_clken),
		.CLKEN_CPU(cpu_clken),
		.CLKEN_MEM(mem_clken),
		.CLKEN_DIO(dio_clken),
		.CLKEN_VID(vid_clken),
		.VID_MEM_SYNC(vid_mem_sync),
		.CLK_REF(clk_ref)
	);

	// ------------------------------------------------------------
	// CPU
	// ------------------------------------------------------------
	wire cpu_wait_n = 1'b1;
	wire cpu_nmi_n = 1'b1;
	wire cpu_busreq_n = 1'b1;

	// ------------------------------------------------------------
	// Maskable interrupt: real Spectrum ULA pulses INT low once per
	// frame (~20ms @ 50Hz), held low for ~32 T-states. Earlier runs of
	// this testbench had NO interrupt source at all (cpu_irq_n tied
	// high forever) - added so the CPU can actually reach code paths
	// that only run from an interrupt-driven main loop, same as real
	// hardware, instead of only ever seeing the cold-boot path.
	// ------------------------------------------------------------
	reg [19:0] irq_cnt = 20'd0;
	reg        cpu_irq_n_r = 1'b1;
	localparam IRQ_PERIOD = 20'd560000; // ~20ms @ 28MHz
	localparam IRQ_WIDTH  = 20'd64;     // ~32 T-states @ 28MHz (2 clocks/T-state)
	always @(posedge clock) begin
		if (irq_cnt == IRQ_PERIOD - 1'd1)
			irq_cnt <= 20'd0;
		else
			irq_cnt <= irq_cnt + 20'd1;
		cpu_irq_n_r <= (irq_cnt < IRQ_WIDTH) ? 1'b0 : 1'b1;
	end
	wire cpu_irq_n = cpu_irq_n_r;

	T80se cpu (
		.RESET_n(reset_n),
		.CLK_n(clock),
		.CLKEN(cpu_clken),
		.WAIT_n(cpu_wait_n),
		.INT_n(cpu_irq_n),
		.NMI_n(cpu_nmi_n),
		.BUSRQ_n(cpu_busreq_n),
		.M1_n(cpu_m1_n),
		.MREQ_n(cpu_mreq_n),
		.IORQ_n(cpu_ioreq_n),
		.RD_n(cpu_rd_n),
		.WR_n(cpu_wr_n),
		.RFSH_n(cpu_rfsh_n),
		.HALT_n(cpu_halt_n),
		.BUSAK_n(cpu_busack_n),
		.A(cpu_a),
		.DI(cpu_di),
		.DO(cpu_do)
	);

	// ------------------------------------------------------------
	// DivMMC (real module) - SD side driven by a minimal behavioral card
	// ------------------------------------------------------------
	wire divmmc_paged_in;
	wire [3:0] divmmc_sram_page;
	wire divmmc_mapram, divmmc_conmem;
	wire [7:0] divmmc_do;
	wire divmmc_sclk, divmmc_mosi, divmmc_cs;
	wire divmmc_miso;

	sd_model sdcard (
		.clk_sys(clock),
		.sd_cs(divmmc_cs),
		.sd_sck(divmmc_sclk),
		.sd_mosi(divmmc_mosi),
		.sd_miso(divmmc_miso)
	);

	// esxdos_downloaded latched true immediately in this testbench - we're
	// testing what happens once paging is allowed, not re-testing the
	// boot_copy gating itself
	reg [1:0] esxdos_downloaded = 2'b11;

	wire divmmc_enable = esxdos_downloaded[1] & (~cpu_ioreq_n) & cpu_m1_n & cpu_a[7] & cpu_a[6] & cpu_a[5] & ~cpu_a[4] & cpu_a[0];

	divmmc dmmc (
		.clk(clock),
		.reset_n(reset_n),
		.clken(psg_clken),
		.enable(divmmc_enable),
		.a(cpu_a),
		.wr_n(cpu_wr_n),
		.rd_n(cpu_rd_n),
		.mreq_n(cpu_mreq_n),
		.m1_n(cpu_m1_n),
		.din(cpu_do),
		.dout(divmmc_do),
		.paged_in(divmmc_paged_in),
		.sram_page(divmmc_sram_page),
		.mapram(divmmc_mapram),
		.conmem(divmmc_conmem),
		.sd_cs(divmmc_cs),
		.sd_sck(divmmc_sclk),
		.sd_mosi(divmmc_mosi),
		.sd_miso(divmmc_miso)
	);

	// ------------------------------------------------------------
	// Address decode (copied from spectrum_top.v's MODEL==0 path)
	// ------------------------------------------------------------
	wire rom_enable = (~cpu_mreq_n) & ~(cpu_a[15] | cpu_a[14]);
	wire ram_enable = (~cpu_mreq_n) & ~rom_enable;
	wire kempston_enable = (~cpu_ioreq_n) & cpu_m1_n & ~cpu_a[7] & ~cpu_a[6] & ~cpu_a[5] & cpu_a[4] & cpu_a[3] & cpu_a[2] & cpu_a[1] & cpu_a[0];
	wire ula_enable = (~cpu_ioreq_n) & cpu_m1_n & ~cpu_a[0];

	wire [18:0] divmmc_lo_addr = ((divmmc_conmem == 1'b1) || (divmmc_mapram == 1'b0)) ?
		{6'b000000, cpu_a[12:0]} : {6'b010011, cpu_a[12:0]};
	wire [18:0] divmmc_hi_addr = {2'b01, divmmc_sram_page, cpu_a[12:0]};
	wire [18:0] divmmc_addr = (cpu_a[13] == 1'b0) ? divmmc_lo_addr : divmmc_hi_addr;

	wire [19:0] rom_addr = ((esxdos_downloaded[1] == 1'b1) && (divmmc_paged_in == 1'b1)) ? {1'b1, divmmc_addr} : {6'b000000, cpu_a[13:0]};
	reg  [19:0] ram_addr;
	wire [2:0]  ram_page = {cpu_a[14], cpu_a[15:14]}; // no 128K paging in this test
	always @(posedge clock) if (mem_clken) ram_addr <= {3'b000, ram_page, cpu_a[13:0]};

	wire [20:0] cpu_addr = (ram_enable == 1'b1) ? {1'b0, ram_addr} : {1'b1, rom_addr};

	wire divmmc_lo_write = 1'b0;
	wire divmmc_hi_write = ~(divmmc_conmem & divmmc_mapram & ~divmmc_sram_page[3] & ~divmmc_sram_page[2] & divmmc_sram_page[1] & divmmc_sram_page[0]);
	wire divmmc_write = (~cpu_a[13] & divmmc_lo_write) | (cpu_a[13] & divmmc_hi_write);
	wire ext_ram_write = (rom_enable & esxdos_downloaded[1] & divmmc_paged_in & divmmc_write) & ~cpu_wr_n;
	wire int_ram_write = ram_enable & ~cpu_wr_n;
	wire ram_write = int_ram_write | ext_ram_write;

	// ------------------------------------------------------------
	// Behavioral memory: byte-addressable, covers the full 21-bit
	// cpu_addr space directly (no SDRAM timing/multiplexing at all -
	// just $readmemh-loaded content read/written combinationally)
	// ------------------------------------------------------------
	reg [7:0] mem [0:(1<<21)-1];

	integer i;
	initial begin
		for (i = 0; i < (1<<21); i = i + 1) mem[i] = 8'h00;
		// fixed ROM location: rom_addr = {1'b1(divmmc), 6'b000000, off[12:0]}
		//   cpu_addr = {1'b1(rom), rom_addr} = 21'h180000 + off
		$readmemh("esxmmc_plain.hex", mem, 21'h180000, 21'h181FFF);
		// mapram location: rom_addr = {1'b1, 6'b010011, off[12:0]}
		//   = 21'h1A6000 + off
		$readmemh("esxmmc_plain.hex", mem, 21'h1A6000, 21'h1A7FFF);
		// standard (non-DivMMC) 48K ROM: rom_addr = {6'b0, cpu_a[13:0]}
		//   cpu_addr = {1'b1(rom), rom_addr} = 21'h100000 + off
		// Earlier runs left this region all-zero (a NOP-slide artifact
		// of the testbench, not real hardware) - loading the real ROM
		// so that paged_in=0 execution is realistic.
		$readmemh("rom48_plain.hex", mem, 21'h100000, 21'h103FFF);
	end

	always @(posedge clock) begin
		if (ram_write)
			mem[cpu_addr] <= cpu_do;
	end

	// I/O reads were NOT modeled at all before (cpu_di fell through to
	// mem[cpu_addr], i.e. whatever memory byte happened to share the
	// same address bits as the port - for keyboard/ULA reads that's
	// mostly the zeroed sram_page area) - real IN A,(n) needs a real
	// response: DivMMC's own register file for its ports, and a fixed
	// "nothing pressed" value for everything else (keyboard/AY/etc,
	// none of which matter for this focused DivMMC test).
	wire io_cycle = (~cpu_ioreq_n) & (~cpu_rd_n);
	always @* begin
		if (io_cycle == 1'b1) begin
			if (divmmc_enable == 1'b1)
				cpu_di = divmmc_do;
			else
				cpu_di = 8'hFF;
		end else begin
			cpu_di = mem[cpu_addr];
		end
	end

	// ------------------------------------------------------------
	// Execution trace: log every M1 (opcode fetch) address + byte
	// ------------------------------------------------------------
	integer logfile;
	initial begin
		logfile = $fopen("trace2.log", "w");
	end
	reg prev_m1_n = 1'b1;
	reg [15:0] prev_pc = 16'hFFFF;
	always @(posedge clock) begin
		if (cpu_m1_n == 1'b0 && prev_m1_n == 1'b1) begin
			// skip logging immediate PC repeats (e.g. LDIR re-fetching its
			// own opcode thousands of times) - keeps the log readable and
			// simulation I/O from dominating runtime
			if (cpu_a !== prev_pc) begin
				$fdisplay(logfile, "PC=%04h OP=%02h paged_in=%b sram_page=%h conmem=%b mapram=%b",
					cpu_a, mem[cpu_addr], divmmc_paged_in, divmmc_sram_page, divmmc_conmem, divmmc_mapram);
			end
			prev_pc <= cpu_a;
		end
		prev_m1_n <= cpu_m1_n;
	end

	// ------------------------------------------------------------
	// Debug: SPI strobe activity + the actual byte value the CPU
	// samples on IN A,(0xEB) - the M1-only trace above can't show this
	// (it only logs opcode fetches, not I/O operand reads), and we
	// need to see whether spi.v's rx_strobe/dout genuinely never
	// produces a real card byte, or whether it does and the CPU just
	// isn't reading it at the right moment.
	// ------------------------------------------------------------
	wire cpu_wr_n_is_write = ~cpu_wr_n;
	integer spi_dbg_file;
	integer spi_dbg_strobes;
	integer spi_dbg_reads;
	initial begin
		spi_dbg_file = $fopen("spi_debug.log", "w");
		spi_dbg_strobes = 0;
		spi_dbg_reads = 0;
	end
	always @(posedge clock) begin
		if ((dmmc.spi_rx_strobe || dmmc.spi_tx_strobe) && spi_dbg_strobes < 400) begin
			$fdisplay(spi_dbg_file, "t=%0t STROBE rx=%b tx=%b counter=%0d io_byte=%02h dout=%02h cpu_a=%04h",
				$time, dmmc.spi_rx_strobe, dmmc.spi_tx_strobe, dmmc.mi_spi.counter, dmmc.mi_spi.io_byte, dmmc.mi_spi.dout, cpu_a);
			spi_dbg_strobes = spi_dbg_strobes + 1;
		end
		if (io_cycle && divmmc_enable && cpu_a[3:0]==4'hb && ~cpu_wr_n_is_write && spi_dbg_reads < 400) begin
			$fdisplay(spi_dbg_file, "t=%0t READ cpu_a=%04h cpu_di=%02h dout=%02h counter=%0d sd_cs=%b",
				$time, cpu_a, cpu_di, dmmc.mi_spi.dout, dmmc.mi_spi.counter, dmmc.sd_cs);
			spi_dbg_reads = spi_dbg_reads + 1;
		end
	end

	initial begin
		#3.5e9; // 3.5 seconds of simulated time - the previous (no SD model)
		        // run showed interesting behavior around ~2.3s in, so give
		        // this run margin past that point
		$fclose(logfile);
		$display("SIMULATION DONE");
		$stop;
	end

endmodule
