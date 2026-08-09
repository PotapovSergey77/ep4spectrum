// ZX Spectrum for MiST board
//
// Copyright (c) 2009-2011 Mike Stirling
//
// All rights reserved
//
// Redistribution and use in source and synthezised forms, with or without
// modification, are permitted provided that the following conditions are met:
//
// * Redistributions of source code must retain the above copyright notice,
//   this list of condition and the following disclaimer.
//
// * Redistributions in synthesized form must reproduce the above copyright
//   notice, this list of conditions and the following disclaimer in the
//   documentation and/or other materials provided with the distribution.
//
// * Neither the name of the author nor the names of other contributors may
//   be used to endorse or promote products derived from this software without
//   specific prior written agreement from the author.
//
// * License is granted for non-commercial use only.  A fee may not be charged
//   for redistributions as source code or in synthesized/hardware form without
//   specific prior written agreement from the author.
//
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
// AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
// THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
// PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE AUTHOR OR CONTRIBUTORS BE
// LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
// CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
// SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
// INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
// CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
// ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
// POSSIBILITY OF SUCH DAMAGE.
//
// Sinclair ZX Spectrum
//
// Terasic DE1 top-level
//
// (C) 2011 Mike Stirling

// Generic top-level entity for Altera DE1 board
module spectrum_mist (
	// Clocks
	CLOCK_27,

	// LED
	LED,

	// VGA
	VGA_R,
	VGA_G,
	VGA_B,
	VGA_HS,
	VGA_VS,

	// SDRAM
	SDRAM_A,
	SDRAM_DQ,
	SDRAM_DQML,
	SDRAM_DQMH,
	SDRAM_nWE,
	SDRAM_nCAS,
	SDRAM_nRAS,
	SDRAM_nCS,
	SDRAM_BA,
	SDRAM_CLK,
	SDRAM_CKE,

	// AUDIO
	AUDIO_L,
	AUDIO_R,

	// SPI interface to io controller
	SPI_SCK,
	SPI_DO,
	SPI_DI,
	SPI_SS2,
	SPI_SS3,
	SPI_SS4,
	CONF_DATA0
);

	// Model to generate
	// 0 = 48 K
	// 1 = 128 K
	// 2 = +2A/+3
	parameter MODEL = 1;

	input   [1:0]   CLOCK_27;

	output          LED;

	output  [5:0]   VGA_R;
	output  [5:0]   VGA_G;
	output  [5:0]   VGA_B;
	output          VGA_HS;
	output          VGA_VS;

	output  [12:0]  SDRAM_A;
	inout   [15:0]  SDRAM_DQ;
	output          SDRAM_DQML;
	output          SDRAM_DQMH;
	output          SDRAM_nWE;
	output          SDRAM_nCAS;
	output          SDRAM_nRAS;
	output          SDRAM_nCS;
	output  [1:0]   SDRAM_BA;
	output          SDRAM_CLK;
	output          SDRAM_CKE;

	output          AUDIO_L;
	output          AUDIO_R;

	input           SPI_SCK;
	inout           SPI_DO;
	input           SPI_DI;
	input           SPI_SS2;
	input           SPI_SS3;
	input           SPI_SS4;
	input           CONF_DATA0;

	// config string used by the io controller to fill the OSD
	localparam STRLEN = 56;
	localparam [8*STRLEN-1:0] CONF_STR = "SPECTRUM;CSW;T1,Reset;T2,Trigger NMI;O3,Scanlines,Off,On";

	//-------------
	// Signals
	//-------------

	// SDRAM interface
	wire    [1:0]   sdram_dqm;
	reg     [7:0]   sdram_di;
	wire    [7:0]   sdram_do;
	reg     [24:0]  sdram_addr;
	reg             sdram_we;
	reg             sdram_oe;

	// ZX spectrum video signals
	wire    [5:0]   zx_red;
	wire    [5:0]   zx_green;
	wire    [5:0]   zx_blue;

	// signals from user_io
	wire    [1:0]   switches;
	wire    [1:0]   buttons;
	wire    [7:0]   joystickA;
	wire    [7:0]   joystickB;
	wire    [7:0]   status;

	// TH extra
	wire    [18:0]  divmmc_lo_addr;
	wire    [18:0]  divmmc_hi_addr;
	wire    [18:0]  divmmc_addr;
	wire    [19:0]  rom_addr;
	reg     [19:0]  ram_addr;
	wire    [20:0]  cpu_addr;
	wire    [18:0]  vid_addr;
	reg             cpu_cycle;
	wire    [7:0]   rom_do;
	reg     [7:0]   mem_do;
	wire            ps2_clk;
	wire            ps2_data;
	wire            ioctl_wr;
	wire    [24:0]  ioctl_addr;
	wire    [7:0]   ioctl_data;
	reg             ioctl_ram_wr;
	reg             ioctl_cycle;
	reg             ioctl_used;
	reg     [24:0]  ioctl_ram_addr;
	reg     [7:0]   ioctl_ram_data;
	wire    [24:0]  ioctl_size;
	wire    [4:0]   ioctl_index;
	wire            ioctl_download;
	wire            tape_rd;
	wire    [24:0]  tape_addr;
	wire            tape_download;
	wire    [24:0]  io_addr;
	wire            scandoubler_disable;
	reg     [1:0]   esxdos_downloaded = 2'b00;
	wire    [31:0]  sd_lba;
	wire            sd_rd;
	wire            sd_wr;
	wire            sd_ack;
	wire            sd_conf;
	wire            sd_sdhc;
	wire    [7:0]   sd_dout;
	wire            sd_dout_strobe;
	wire    [7:0]   sd_din;
	wire            sd_din_strobe;
	wire            divmmc_paged_in;
	wire    [3:0]   divmmc_sram_page;
	wire            divmmc_mapram;
	wire            divmmc_conmem;
	wire            key_f11;

	// Master clock - 28 MHz
	wire            clk56;
	wire            pll_locked;
	reg             clock;
	reg             reset_n;
	reg     [10:0]  clk14k_div;
	wire            clk14k;

	// Clock control
	wire            psg_clken;
	wire            cpu_clken;
	wire            mem_clken;
	wire            dio_clken;
	wire            vid_clken;
	wire            clk_ref;
	wire            vid_mem_sync;

	// Address decoding
	wire            ula_enable; // all even IO addresses
	wire            rom_enable; // 0x0000-0x3FFF
	wire            ram_enable; // 0x4000-0xFFFF
	// 128K extensions
	wire            page_enable; // all odd IO addresses with A15 and A1 clear (and A14 set in +3 mode)
	wire            psg_enable; // all odd IO addresses with A15 set and A1 clear
	// +3 extensions
	wire            plus3_enable; // A15, A14, A13, A1 clear, A12 set.
	// MMC
	wire            divmmc_enable; // A7-A4 = "1110"
	wire            kempston_enable; // A7-A0 = "00011111"

	// 128K paging register (with default values for systems that don't have it)
	wire            page_reg_disable; // bit 5
	wire            page_rom_sel; // bit 4
	wire            page_shadow_scr; // bit 3
	wire    [2:0]   page_ram_sel; // bits 2:0

	// +3 extensions (with default values for systems that don't have it)
	reg             plus3_printer_strobe = 1'b0; // bit 4
	reg             plus3_disk_motor = 1'b0; // bit 3
	reg     [1:0]   plus3_page = 2'b00; // bits 2:1
	reg             plus3_special = 1'b0; // bit 0

	// RAM bank actually being accessed
	wire    [2:0]   ram_page;

	// CPU signals
	wire            cpu_wait_n;
	wire            cpu_irq_n;
	wire            cpu_nmi_n;
	wire            cpu_busreq_n;
	wire            cpu_m1_n;
	wire            cpu_mreq_n;
	wire            cpu_ioreq_n;
	wire            cpu_rd_n;
	wire            cpu_wr_n;
	wire            cpu_rfsh_n;
	wire            cpu_halt_n;
	wire            cpu_busack_n;
	wire    [15:0]  cpu_a;
	wire    [7:0]   cpu_di;
	wire    [7:0]   cpu_do;

	// ULA port signals
	wire    [7:0]   ula_do;
	wire    [2:0]   ula_border;
	wire            ula_ear_out;
	wire            ula_mic_out;
	wire            ula_ear_in;

	// ULA video signals
	wire    [12:0]  vid_a;
	wire            vid_rd_n;
	wire            vid_wait_n;
	wire    [3:0]   vid_r_out;
	wire    [3:0]   vid_g_out;
	wire    [3:0]   vid_b_out;
	wire            vid_vsync_n;
	wire            vid_hsync_n;
	wire            vid_csync_n;
	wire            vid_hcsync_n;
	wire            vid_irq_n;
	wire            vid_scanline;

	// Keyboard
	wire    [4:0]   keyb;

	// Sound (PSG default values for systems that don't have it)
	wire    [7:0]   psg_do;
	wire            psg_bdir;
	wire            psg_bc1;

	// DIVMMC interface
	wire    [7:0]   divmmc_do;

	wire            divmmc_sclk;
	wire            divmmc_mosi;
	wire            divmmc_miso;
	wire            divmmc_cs;

	wire            esx_request;

	//--------------------------------
	// PLL
	// 27 MHz input
	// 56 MHz sdram controller clock
	// 56 MHz sdram clock (-2.5 ns phase shifted)
	//--------------------------------

	// 28 MHz master clock
	pll_main pll (
		.areset(1'b0),
		.inclk0(CLOCK_27[0]),
		.c0(clk56),
		.c1(SDRAM_CLK),
		.locked(pll_locked)
	);

	// generate 28Mhz system clock from 56MHz main clock by dividing it by 2
	always @(posedge clk56) begin
		clock <= ~clock;
	end

	// Clock enable logic
	clocks clken (
		.CLK(clock),
		.nRESET(pll_locked),
		.MREQ(~cpu_mreq_n | ~cpu_ioreq_n),
		.CLKEN_PSG(psg_clken),
		.CLKEN_CPU(cpu_clken),
		.CLKEN_MEM(mem_clken),
		.CLKEN_DIO(dio_clken),
		.CLKEN_VID(vid_clken),
		.VID_MEM_SYNC(vid_mem_sync),
		.CLK_REF(clk_ref)
	);

	// SDRAM
	sdram sdr (
		// RAM chip
		.sd_data(SDRAM_DQ),
		.sd_addr(SDRAM_A),
		.sd_dqm(sdram_dqm),
		.sd_cs(SDRAM_nCS),
		.sd_ba(SDRAM_BA),
		.sd_we(SDRAM_nWE),
		.sd_ras(SDRAM_nRAS),
		.sd_cas(SDRAM_nCAS),

		// System
		.clk(clk56),
		.clkref(clk_ref),
		.init(~pll_locked),

		// cpu interface
		.din(sdram_di),
		.dout(sdram_do),
		.addr(sdram_addr),
		.we(sdram_we),
		.oe(sdram_oe)
	);
	assign SDRAM_DQMH = sdram_dqm[1];
	assign SDRAM_DQML = sdram_dqm[0];
	// SDRAM clock always enabled
	assign SDRAM_CKE = 1'b1;

	// embedded rom
	rom128 rom (
		.address(rom_addr[14:0]),
		.clock(psg_clken),    // psg_clken is in the middle of a cpu cycle
		.q(rom_do)
	);

	// include the io controller. This controller differs from the one
	// in the zx01 because it does not come with its own embedded dual port ram.
	// Instead it provides signals to connect to an external ram
	data_io data_io_I (
		.sck(SPI_SCK),
		.ss(SPI_SS2),
		.sdi(SPI_DI),

		.downloading(ioctl_download),
		.size(ioctl_size),
		.index(ioctl_index),

		// ram interface
		.clk(clock),
		.wr(ioctl_wr),
		.a(ioctl_addr),
		.d(ioctl_data)
	);

	always @(posedge ioctl_download) begin
		if (ioctl_index == 5'b00000)
			esxdos_downloaded[0] <= 1'b1;
	end

	// tape download comes from OSD entry 1
	assign tape_download = ((ioctl_index == 5'b00001) && (ioctl_download == 1'b1)) ? 1'b1 : 1'b0;
	tape #(.ADDR_WIDTH(25)) tape_I (
		.clk(clock),
		.reset(~reset_n),
		.iocycle(ioctl_cycle),

		.audio_out(ula_ear_in),

		.downloading(tape_download),
		.size(ioctl_size),

		// ram interface
		.rd(tape_rd),
		.a(tape_addr),
		.d(sdram_do)
	);

	// use led as the sd card access led
	assign LED = divmmc_cs;

	always @(posedge clock) begin
		if (dio_clken == 1'b1 && ioctl_cycle == 1'b0) begin
			if (ioctl_ram_wr == 1'b1) begin
				ioctl_ram_wr <= 1'b0;
				ioctl_used <= 1'b1;
				ioctl_ram_addr <= ioctl_addr;
				ioctl_ram_data <= ioctl_data;
			end else begin
				ioctl_used <= 1'b0;
			end
		end

		if (ioctl_wr == 1'b1) begin
			// io controller sent a new byte. Store it until it can be
			// saved in RAM
			ioctl_ram_wr <= 1'b1;
		end
	end

	// generate ~14Khz ps2 clock from 28MHz
	always @(posedge clock) begin
		clk14k_div <= clk14k_div + 1'b1;
	end
	assign clk14k = clk14k_div[10];

	// User io
	user_io #(.STRLEN(STRLEN)) user_io_d (
		.SPI_CLK(SPI_SCK),
		.SPI_SS_IO(CONF_DATA0),
		.SPI_MISO(SPI_DO),
		.SPI_MOSI(SPI_DI),

		.conf_str(CONF_STR),

		.status(status),
		.joystick_0(joystickA),
		.joystick_1(joystickB),
		.switches(switches),
		.buttons(buttons),
		.scandoubler_disable(scandoubler_disable),

		.sd_lba(sd_lba),
		.sd_rd(sd_rd),
		.sd_wr(sd_wr),
		.sd_ack(sd_ack),
		.sd_conf(sd_conf),
		.sd_sdhc(sd_sdhc),
		.sd_dout(sd_dout),
		.sd_dout_strobe(sd_dout_strobe),
		.sd_din(sd_din),
		.sd_din_strobe(sd_din_strobe),

		.ps2_clk(clk14k),
		.ps2_kbd_clk(ps2_clk),
		.ps2_kbd_data(ps2_data),

		.serial_data(8'h00),
		.serial_strobe(1'b0)
	);

	sd_card sd_card_d (
		// connection to io controller
		.io_lba(sd_lba),
		.io_rd(sd_rd),
		.io_wr(sd_wr),
		.io_ack(sd_ack),
		.io_conf(sd_conf),
		.io_sdhc(sd_sdhc),
		.io_din(sd_dout),
		.io_din_strobe(sd_dout_strobe),
		.io_dout(sd_din),
		.io_dout_strobe(sd_din_strobe),

		.allow_sdhc(1'b1),   // esxdos supports SDHC

		// connection to host
		.sd_cs(divmmc_cs),
		.sd_sck(divmmc_sclk),
		.sd_sdi(divmmc_mosi),
		.sd_sdo(divmmc_miso)
	);

	assign esx_request = key_f11 | status[2] | joystickA[7] | joystickB[7];

	// CPU
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
	// VSYNC interrupt routed to CPU
	assign cpu_irq_n = vid_irq_n;
	// Unused CPU input signals
	assign cpu_wait_n = 1'b1;
	// trigger nmi either with F11, the OSD or with the joystick
	assign cpu_nmi_n = ((esx_request == 1'b1) && (esxdos_downloaded[1] == 1'b1)) ? 1'b0 : 1'b1;
	assign cpu_busreq_n = 1'b1;

	// Keyboard
	keyboard kb (
		.CLK(clock),
		.nRESET(reset_n),
		.PS2_CLK(ps2_clk),
		.PS2_DATA(ps2_data),
		.A(cpu_a),
		.KEYB(keyb),
		.F11(key_f11)
	);

	// ULA port
	ula_port ula (
		.CLK(clock),
		.nRESET(reset_n),
		.D_IN(cpu_do),
		.D_OUT(ula_do),
		.ENABLE(ula_enable & psg_clken),
		.nWR(cpu_wr_n),
		.BORDER_OUT(ula_border),
		.EAR_OUT(ula_ear_out),
		.MIC_OUT(ula_mic_out),
		.KEYB_IN(keyb),
		.EAR_IN(ula_ear_in)
	);

	// ULA video
	video vid (
		// use pll_locked to make the hcounter run synchronous to the
		// clocks counter
		.CLK(clock),
		.CLKEN(vid_clken),
		.MEM_CYC(vid_mem_sync),
		.nRESET(reset_n),
		.VGA(~scandoubler_disable),
		.VID_A(vid_a),
		.VID_D_IN(sdram_do),
		.nVID_RD(vid_rd_n),
		.nWAIT(vid_wait_n),
		.BORDER_IN(ula_border),
		.R(vid_r_out),
		.G(vid_g_out),
		.B(vid_b_out),
		.nVSYNC(vid_vsync_n),
		.nHSYNC(vid_hsync_n),
		.nCSYNC(vid_csync_n),
		.nHCSYNC(vid_hcsync_n),
		.SCANLINE(vid_scanline),
		.nIRQ(vid_irq_n)
	);

	// Sound
	generate
	if (MODEL != 0) begin : sound_128k
		// PSG only on 128K and above
		wire [7:0] psg_aout;
		YM2149 psg (
			.I_DA(cpu_do),
			.O_DA(psg_do),
			.O_DA_OE_L(),
			.I_A9_L(1'b0), // /A9 pulled down internally
			.I_A8(1'b1), // A8 pulled up on Spectrum
			.I_BDIR(psg_bdir),
			.I_BC2(1'b1), // BC2 pulled up on Spectrum
			.I_BC1(psg_bc1),
			.I_SEL_L(1'b1), // /SEL is high for AY-3-8912 compatibility
			.O_AUDIO(psg_aout),
			.I_IOA(8'b0),
			.O_IOA(),
			.O_IOA_OE_L(), // port A unused (keypad and serial on Spectrum 128K)
			.I_IOB(8'b0),
			.O_IOB(),
			.O_IOB_OE_L(), // port B unused (non-existent on AY-3-8912)
			.ENA(psg_clken),
			.RESET_L(reset_n),
			.CLK(clock)
		);
		assign psg_bdir = psg_enable & cpu_rd_n;
		assign psg_bc1 = psg_enable & cpu_a[14];

		// map AY sound on left channel
		sigma_delta_dac dac_l (
			.CLK(clock),
			.RESET(~reset_n),
			.DACin(psg_aout),
			.DACout(AUDIO_L)
		);

		// and beeper on right channel
		sigma_delta_dac dac_r (
			.CLK(clock),
			.RESET(~reset_n),
			.DACin({ula_ear_out, ula_mic_out, ula_ear_in, 5'b00000}),
			.DACout(AUDIO_R)
		);
	end else begin : sound_128k_else
		assign psg_do = 8'b11111111;
	end
	endgenerate

	// DIVMMC interface
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

	// Asynchronous reset
	// System is reset by external reset switch or PLL being out of lock

	// delay reset so sdram can be initialized etc. especially clearing the
	// divmmc ram after esxdos upload needs some time (9.3ms)
	//
	// The esx_request/esxdos_downloaded clause below only clears once
	// esx_request's rising edge is processed *after* esxdos_downloaded
	// becomes 2'b01 (see "always @(posedge esx_request)" further down). If
	// esx_request is already high (e.g. a stuck/held status[2] "Trigger
	// NMI" bit from the IO controller) before that ioctl download happens,
	// that edge never arrives and esxdos_downloaded gets stuck at 2'b01
	// forever, holding the whole design in permanent reset. DivMMC/ESXDOS
	// isn't used here, so drop this clause rather than depend on esx_request
	// behaving as a clean momentary pulse.
	wire reset_cond = ((pll_locked == 1'b0) || (status[0] == 1'b1) || (status[1] == 1'b1) || (buttons[1] == 1'b1));
	reg [24:0] reset_cnt = 25'd32000000;
	always @(posedge clock) begin
		if (reset_cond) begin
			if (reset_cnt < 25'd280000)
				reset_cnt <= 25'd280000;
		end else begin
			if (reset_cnt != 25'd0)
				reset_cnt <= reset_cnt - 25'd1;
		end
	end

	// make sure cpu runs synchronous to bus state machine
	always @(posedge clock) begin
		if (cpu_clken == 1'b1) begin
			if (reset_cnt == 25'd0)
				reset_n <= 1'b1;
			else
				reset_n <= 1'b0;
		end
	end

	always @(posedge esx_request) begin
		esxdos_downloaded <= {esxdos_downloaded[0], esxdos_downloaded[0]};
	end

	// Address decoding.  Z80 has separate IO and memory address space
	// IO ports (nominal addresses - incompletely decoded):
	// 0xXXFE R/W = ULA
	// 0x7FFD W   = 128K paging register
	// 0xFFFD W   = 128K AY-3-8912 register select
	// 0xFFFD R   = 128K AY-3-8912 register read
	// 0xBFFD W   = 128K AY-3-8912 register write
	// 0x1FFD W   = +3 paging and control register
	// 0x2FFD R   = +3 FDC status register
	// 0x3FFD R/W = +3 FDC data register
	// 0xXXEX R/W = DIVMMC interface
	// FIXME: Revisit this - could be neater
	assign ula_enable = (~cpu_ioreq_n) & cpu_m1_n & ~cpu_a[0]; // all even IO addresses
	assign psg_enable = (~cpu_ioreq_n) & cpu_m1_n & cpu_a[0] & cpu_a[15] & ~cpu_a[1];
	assign kempston_enable = (~cpu_ioreq_n) & cpu_m1_n & ~cpu_a[7] & ~cpu_a[6] & ~cpu_a[5] & cpu_a[4] & cpu_a[3] & cpu_a[2] & cpu_a[1] & cpu_a[0];
	assign divmmc_enable = esxdos_downloaded[1] & (~cpu_ioreq_n) & cpu_m1_n & cpu_a[7] & cpu_a[6] & cpu_a[5] & ~cpu_a[4] & cpu_a[0];

	generate
	if (MODEL != 2) begin : addr_decode_128k
		assign page_enable = (~cpu_ioreq_n) & cpu_m1_n & cpu_a[0] & ~(cpu_a[15] | cpu_a[1]);
	end
	endgenerate
	generate
	if (MODEL == 2) begin : addr_decode_plus3
		// Paging register address decoding is slightly stricter on the +3
		assign page_enable = (~cpu_ioreq_n) & cpu_a[0] & cpu_a[14] & ~(cpu_a[15] | cpu_a[1]);
		assign plus3_enable = (~cpu_ioreq_n) & cpu_a[0] & cpu_a[12] & ~(cpu_a[15] | cpu_a[14] | cpu_a[13] | cpu_a[1]);
	end
	endgenerate

	// ROM is enabled between 0x0000 and 0x3fff except in +3 special mode
	assign rom_enable = (~cpu_mreq_n) & ~(plus3_special | cpu_a[15] | cpu_a[14]);
	// RAM is enabled for any memory request when ROM isn't enabled
	assign ram_enable = (~cpu_mreq_n) & ~rom_enable;

	generate
	if (MODEL != 2) begin : ram_page_128k
		// 128K has pageable RAM at 0xc000
		assign ram_page =
			(cpu_a[15:14] == 2'b11) ? page_ram_sel : // Selectable bank at 0xc000
			{cpu_a[14], cpu_a[15:14]}; // A=bank: 00=XXX, 01=101, 10=010, 11=XXX
	end
	endgenerate
	generate
	if (MODEL == 2) begin : ram_page_plus3
		// +3 has various additional modes in addition to "normal" mode, which is
		// the same as the 128K
		// Extra modes assign RAM banks as follows:
		// plus3_page    0000    4000    8000    C000
		// 00            0       1       2       3
		// 01            4       5       6       7
		// 10            4       5       6       3
		// 11            4       7       6       3
		// NORMAL        ROM     5       2       PAGED
		assign ram_page =
			(plus3_special == 1'b0 && cpu_a[15:14] == 2'b11) ? page_ram_sel :
			(plus3_special == 1'b0) ? {cpu_a[14], cpu_a[15:14]} :
			(plus3_special == 1'b1 && plus3_page == 2'b00) ? {1'b0, cpu_a[15:14]} :
			(plus3_special == 1'b1 && plus3_page == 2'b01) ? {1'b1, cpu_a[15:14]} :
			(plus3_special == 1'b1 && plus3_page == 2'b10) ? {~(cpu_a[15] & cpu_a[14]), cpu_a[15:14]} :
			{~(cpu_a[15] & cpu_a[14]), (cpu_a[15] | cpu_a[14]), cpu_a[14]};
	end
	endgenerate

	always @(negedge cpu_cycle) begin
		// latch sdram data at the end of cpus memory cycle
		mem_do <= sdram_do;
	end

	// CPU data bus mux
	assign cpu_di =
		// System RAM
		(ram_enable == 1'b1) ? mem_do :
		// DIVMMC memory mapped into ROM area
		((rom_enable == 1'b1) && (divmmc_paged_in == 1'b1) && (esxdos_downloaded[1] == 1'b1)) ? mem_do :
		// Internal ROM
		(rom_enable == 1'b1) ? rom_do :
		// IO ports
		(ula_enable == 1'b1) ? ula_do :
		(psg_enable == 1'b1) ? psg_do :
		(divmmc_enable == 1'b1) ? divmmc_do :
		// map both joysticks onto the one supported by kempston
		(kempston_enable == 1'b1) ? {2'b00, (joystickA[5:0] | joystickB[5:0])} :
		// Idle bus
		8'b11111111;

	generate
	if (MODEL == 0) begin : rom_48k
		// 48K
		assign rom_addr =
			// Otherwise access the internal ROM
			{6'b000000, cpu_a[13:0]};
	end
	endgenerate

	generate
	if (MODEL == 1) begin : rom_128k
		// DIVMMC low mapping (0x0000 - 0x1fff)
		assign divmmc_lo_addr = ((divmmc_conmem == 1'b1) || (divmmc_mapram == 1'b0)) ?
			{6'b000000, cpu_a[12:0]} : {6'b010011, cpu_a[12:0]};

		// DIVMMC hi mapping (0x2000 - 0x3fff)
		assign divmmc_hi_addr = {2'b01, divmmc_sram_page, cpu_a[12:0]};

		// DIVMMC mapping
		assign divmmc_addr = (cpu_a[13] == 1'b0) ? divmmc_lo_addr : divmmc_hi_addr;

		// 128K
		assign rom_addr =
			// all DIVMMC mapping (even ram) happens in the ROM
			// address space (0x0000-0x3fff)
			((esxdos_downloaded[1] == 1'b1) && (divmmc_paged_in == 1'b1)) ? {1'b1, divmmc_addr} :
			// Otherwise access the internal ROMs
			{5'b00000, page_rom_sel, cpu_a[13:0]};
	end
	endgenerate

	generate
	if (MODEL == 2) begin : rom_plus3
		// DIVMMC low mapping (0x0000 - 0x1fff)
		assign divmmc_lo_addr = ((divmmc_conmem == 1'b1) || (divmmc_mapram == 1'b0)) ?
			{6'b000000, cpu_a[12:0]} : {6'b010011, cpu_a[12:0]};

		// DIVMMC hi mapping (0x2000 - 0x3fff)
		assign divmmc_hi_addr = {2'b01, divmmc_sram_page, cpu_a[12:0]};

		// DIVMMC mapping
		assign divmmc_addr = (cpu_a[13] == 1'b0) ? divmmc_lo_addr : divmmc_hi_addr;

		// +3
		assign rom_addr =
			// all DIVMMC mapping (even ram) happens in the ROM
			// address space (0x0000-0x3fff)
			((esxdos_downloaded[1] == 1'b1) && (divmmc_paged_in == 1'b1)) ? {1'b1, divmmc_addr} :

			// Otherwise access the internal ROMs
			{4'b0000, plus3_page[1], page_rom_sel, cpu_a[13:0]};
	end
	endgenerate

	// first 1MB of sdram are used as ram, second 1MB sdram are used as rom
	// and after that starts tape buffer
	assign cpu_addr = (ram_enable == 1'b1) ? {1'b0, ram_addr} : {1'b1, rom_addr};

	// Video from bank 7 (128K/+3)
	// Video from bank 5
	// 16-bit address, LSb selects high/low byte
	assign vid_addr = (page_shadow_scr == 1'b1) ? {6'b001110, vid_a[12:0]} :
		{6'b001010, vid_a[12:0]};

	// io address is driven by io controller on upload or by tape during replay
	assign io_addr = (ioctl_used == 1'b1) ? ioctl_ram_addr : tape_addr;

	// Synchronous outputs to SRAM
	wire divmmc_lo_write = 1'b0;
	wire divmmc_hi_write = ~(divmmc_conmem & divmmc_mapram &
		~divmmc_sram_page[3] & ~divmmc_sram_page[2] &
		divmmc_sram_page[1] & divmmc_sram_page[0]);
	wire divmmc_write = (~cpu_a[13] & divmmc_lo_write) |
		(cpu_a[13] & divmmc_hi_write);
	wire ext_ram_write = (rom_enable & esxdos_downloaded[1] & divmmc_paged_in & divmmc_write) & ~cpu_wr_n;
	wire int_ram_write = ram_enable & ~cpu_wr_n;
	wire ram_write = int_ram_write | ext_ram_write;

	always @(posedge clock) begin
		// synchonize cpu memory access to video memory access
		if (vid_clken == 1'b1) begin
			cpu_cycle <= mem_clken;
			ioctl_cycle <= dio_clken;
		end

		// Register SRAM signals to outputs (clock must be at least 2x CPU clock)
		if (vid_clken == 1'b1) begin
			// Fetch data from previous CPU cycle
			// Normal RAM access at 0x4000-0xffff
			// 16-bit address
			ram_addr <= {3'b000, ram_page, cpu_a[13:0]};
		end
	end

	// share SDRAM between CPU, Video and the io controller (ROM and tape
	// upload). This must stay combinational (not clocked): sdram.v's
	// internal ACTIVE->CAS state machine runs on clk56 with only a 3-cycle
	// RAS-to-CAS latency, and registering this mux on posedge clock adds up
	// to a full clock-cycle of extra latency between cpu_cycle changing and
	// sdram_we/addr/di reflecting it -- enough to shift the row-select
	// (ACTIVE) and column/data-select (CAS) phases of one transaction onto
	// two different requesters (e.g. video's row with the CPU's column),
	// silently corrupting the target address. The original VHDL had this
	// mux textually inside a clocked process but outside its
	// rising_edge(clock) guard, so Quartus synthesized it as a plain
	// (zero-latency) mux -- match that here with always @*.
	always @* begin
		if (cpu_cycle == 1'b1) begin
			sdram_oe = ~cpu_mreq_n & ~cpu_rd_n;  // any cpu read enables ram
			sdram_we = ram_write;                // write only for memory used as ram
			sdram_di = cpu_do;
			sdram_addr = {4'b0000, cpu_addr};
		end else if (ioctl_cycle == 1'b1) begin
			sdram_oe = tape_rd;
			sdram_we = ioctl_used;
			sdram_di = ioctl_ram_data;
			sdram_addr = io_addr;
		end else begin
			// no cpu sccess. Thus do video access
			sdram_oe = ~vid_rd_n;
			sdram_we = 1'b0;    // video never writes
			sdram_di = 8'b00000000;
			sdram_addr = {6'b000000, vid_addr};
		end
	end

	generate
	if (MODEL != 0) begin : page_reg_128k
		// 128K paging register
		reg     preg_disable;
		reg     prom_sel;
		reg     pshadow_scr;
		reg     [2:0] pram_sel;
		always @(posedge clock or negedge reset_n) begin
			if (reset_n == 1'b0) begin
				preg_disable <= 1'b0;
				prom_sel <= 1'b0;
				pshadow_scr <= 1'b0;
				pram_sel <= 3'b000;
			end else if (psg_clken == 1'b1) begin
				if (page_enable == 1'b1 && preg_disable == 1'b0 && cpu_wr_n == 1'b0) begin
					preg_disable <= cpu_do[5];
					prom_sel <= cpu_do[4];
					pshadow_scr <= cpu_do[3];
					pram_sel <= cpu_do[2:0];
				end
			end
		end
		assign page_reg_disable = preg_disable;
		assign page_rom_sel = prom_sel;
		assign page_shadow_scr = pshadow_scr;
		assign page_ram_sel = pram_sel;
	end else begin : page_reg_128k_else
		assign page_reg_disable = 1'b1;
		assign page_rom_sel = 1'b0;
		assign page_shadow_scr = 1'b0;
		assign page_ram_sel = 3'b000;
	end
	endgenerate

	generate
	if (MODEL == 2) begin : plus3_reg
		// +3 paging and control register
		always @(posedge clock or negedge reset_n) begin
			if (reset_n == 1'b0) begin
				plus3_printer_strobe <= 1'b0;
				plus3_disk_motor <= 1'b0;
				plus3_page <= 2'b00;
				plus3_special <= 1'b0;
			end else begin
				// FIXME: Does this get disabled by the page_reg_disable bit?
				if (plus3_enable == 1'b1 && cpu_wr_n == 1'b0) begin
					plus3_printer_strobe <= cpu_do[4];
					plus3_disk_motor <= cpu_do[3];
					plus3_page <= cpu_do[2:1];
					plus3_special <= cpu_do[0];
				end
			end
		end
	end
	endgenerate

	// Connect ULA to video output
	assign zx_red = (vid_scanline == 1'b1 && status[3] == 1'b1) ? {1'b0, vid_r_out, 1'b0} : {vid_r_out, 2'b00};
	assign zx_green = (vid_scanline == 1'b1 && status[3] == 1'b1) ? {1'b0, vid_g_out, 1'b0} : {vid_g_out, 2'b00};
	assign zx_blue = (vid_scanline == 1'b1 && status[3] == 1'b1) ? {1'b0, vid_b_out, 1'b0} : {vid_b_out, 2'b00};
	assign VGA_HS = vid_hcsync_n;
	// when scandoubler is disabled a csync is fed into hsync and
	// vsync is used as a rgb switch signal
	assign VGA_VS = (scandoubler_disable == 1'b1) ? 1'b1 : vid_vsync_n;

	// route video through osd
	osd #(.OSD_COLOR(6)) osd_d (
		.pclk(vid_clken),
		.sck(SPI_SCK),
		.ss(SPI_SS3),
		.sdi(SPI_DI),

		.red_in(zx_red),
		.green_in(zx_green),
		.blue_in(zx_blue),
		.hs_in(vid_hsync_n),
		.vs_in(vid_vsync_n),

		.red_out(VGA_R),
		.green_out(VGA_G),
		.blue_out(VGA_B),
		.hs_out(),
		.vs_out()
	);

endmodule
