// ZX Spectrum for the EP4CE6E22C8 (OMDAZZ / RZ-EasyFPGA A2.2) dev board
//
// Adapted from spectrum_mist.v (Copyright (c) 2009-2011 Mike Stirling,
// MiST port by the mist-board project).
//
// This board has no ARM IO controller and no SD card slot, unlike the
// MiST board spectrum_mist.v was written for. Everything that depended on
// that controller over SPI has been removed:
//   - user_io.v / osd.v / data_io.v (OSD menu, joystick/status forwarding,
//     ROM & tape upload over SPI)
//   - sd_card.v (a *virtual* SD card that proxies sector reads to the ARM
//     controller's own SD card - meaningless without that controller)
//   - tape.v (tape playback fed from an SPI upload that no longer exists)
//
// Instead:
//   - The 48K/128K ROM is baked into block RAM at synthesis time (rom48.v/
//     rom128.v + 48.hex/128.hex), so no upload step is needed to boot.
//   - The PS/2 keyboard is read directly off the board's PS2 header
//     (keyboard.v / ps2_intf.v already do this - no SPI forwarding needed).
//   - VGA only has one pin per colour (VGA_R/G/B), so the OSD's 6-bit path
//     is gone; the ULA's base R/G/B bit is used directly (8 colours, no
//     bright/flash shading on screen - bright still affects gameplay logic
//     since attr[6] is still decoded, it just isn't visible here).
//   - DivMMC (divmmc.v) is wired straight to 4 free GPIO pins (reused
//     from the unused I2C header) for an SD card breakout module. The
//     ESXDOS DivMMC ROM (esxmmc.rom from esxdos.org, baked into
//     rom_esxdos.v/esxmmc.hex) is copied into SDRAM by a small state
//     machine at power-up (boot_copy_* below), replacing the MiST IO
//     controller's SPI upload of the same image - so DivMMC paging is
//     live unconditionally instead of gated behind an upload flag.
//   - Sound (AY-3-8912 via YM2149 + beeper) is mixed down to mono and fed
//     to the board's piezo buzzer through a 1-bit sigma-delta DAC.
//
// SDRAM on this board is a 64Mbit (4M x16 x4 bank, 12-bit row / 8-bit
// column) part, smaller and organised differently than the 256Mbit part
// the original sdram.v targeted, so sdram_ep4ce.v is used instead.

module spectrum_top (
	// 50MHz crystal
	CLOCK_50,

	// board reset button (active low) and 4 general purpose buttons (active low)
	RESET_BTN,
	KEY,

	// LEDs
	LED,

	// 7-segment "digital tube" display
	SEG,
	DIG,

	// VGA - single bit per colour on this board
	VGA_R,
	VGA_G,
	VGA_B,
	VGA_HS,
	VGA_VS,

	// SDRAM (64Mbit, 12 address lines)
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

	// PS/2 keyboard
	PS2_CLK,
	PS2_DATA,

	// mono audio out to the onboard piezo buzzer
	BEEP,

	// SPI to an (optional, not yet populated) SD card module for DivMMC/ESXDOS
	SD_CS,
	SD_SCK,
	SD_MOSI,
	SD_MISO
);

	// Model to generate
	// 0 = 48 K (only option that fits EP4CE6's 30 M9K blocks alongside the
	//     AY volume table - a full 128K ROM alone needs 32 blocks)
	// 1 = 128 K
	// 2 = +2A/+3
	parameter MODEL = 0;

	// The AY-3-8912 (via YM2149) is wired in unconditionally below, even
	// though real 48K Spectrums didn't have one - same "48K + AY" hybrid
	// used by Pentagon and other clones, chosen because a real 128K ROM
	// doesn't fit in this device's block RAM (see MODEL comment above).

	input           CLOCK_50;

	input           RESET_BTN;
	input   [3:0]   KEY;

	output  [3:0]   LED;

	output  [7:0]   SEG;
	output  [3:0]   DIG;

	output          VGA_R;
	output          VGA_G;
	output          VGA_B;
	output          VGA_HS;
	output          VGA_VS;

	output  [11:0]  SDRAM_A;
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

	input           PS2_CLK;
	input           PS2_DATA;

	output          BEEP;

	output          SD_CS;
	output          SD_SCK;
	output          SD_MOSI;
	input           SD_MISO;

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

	// ZX spectrum video signals (single bit per component on this board)
	wire            zx_red;
	wire            zx_green;
	wire            zx_blue;

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
	// The ESXDOS ROM is baked in (rom_esxdos.v) and copied into SDRAM at
	// boot (see boot_copy_* below) instead of being uploaded on request.
	// esxdos_downloaded only latches true once that copy has actually
	// finished (boot_copy_active drops back to 0) - NOT unconditionally:
	// address 0x0000 is a DivMMC trap address hit on every single reset,
	// so if this were hardwired true from power-on, DivMMC would page in
	// on the very first boot before the copy had written anything there,
	// running whatever garbage SDRAM happened to power up with.
	reg     [1:0]   esxdos_downloaded;
	wire            divmmc_paged_in;
	wire    [3:0]   divmmc_sram_page;
	wire            divmmc_mapram;
	wire            divmmc_conmem;
	wire            key_f11;
	wire            key_f8;
	wire            key_f12;

	// Master clock - 28 MHz
	wire            clk56;
	wire            pll_locked;
	reg             clock;
	reg             reset_n;

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

	//--------------------------------
	// PLL
	// 50 MHz input (board crystal)
	// 56 MHz sdram controller clock
	// 56 MHz sdram clock (-2.5 ns phase shifted)
	//--------------------------------

	pll_ep4ce pll (
		.areset(1'b0),
		.inclk0(CLOCK_50),
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
	sdram_ep4ce sdr (
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

	//--------------------------------------------------------------
	// One-time copy of the embedded ESXDOS ROM (rom_esxdos.v) into the
	// SDRAM location DivMMC's low ROM mapping reads from (conmem=0,
	// mapram=0: {6'b000000, addr[12:0]} within the ROM half of the
	// address space). Replaces the MiST IO controller's SPI upload of
	// this same image. Runs while the CPU is still held in reset (see
	// reset_cond) so it never contends with the CPU for the bus. A short
	// settle delay after pll_locked lets sdram_ep4ce.v finish its own
	// internal init sequence first, so the first few bytes aren't
	// silently dropped.
	//--------------------------------------------------------------
	reg  [9:0]  boot_settle_cnt;
	reg         boot_settle_done;
	always @(posedge clock) begin
		if (pll_locked == 1'b0) begin
			boot_settle_cnt <= 10'd0;
			boot_settle_done <= 1'b0;
		end else if (boot_settle_done == 1'b0) begin
			if (boot_settle_cnt == 10'd1023)
				boot_settle_done <= 1'b1;
			else
				boot_settle_cnt <= boot_settle_cnt + 10'd1;
		end
	end

	// boot_copy_addr[12:0] = byte offset into the ESXDOS ROM image.
	// boot_copy_addr[13]   = pass select: 0 = write to the fixed ROM
	//   location divmmc_lo_addr uses with conmem=0/mapram=0, 1 = write the
	//   SAME bytes again to the mapram location (conmem=0/mapram=1,
	//   {6'b010011,...}). Real ESXDOS copies its own ROM into mapram and
	//   switches there as part of normal init (so it can self-patch at
	//   runtime) - without this second pass it would find that area empty
	//   and run garbage the moment it switches, regardless of whether an
	//   SD card is even present.
	// boot_copy_addr == 16384/16385: DIAGNOSTIC extra phase - see the
	// address mux below.
	reg         boot_copy_active;
	reg  [14:0] boot_copy_addr;
	reg  [14:0] boot_copy_waddr;
	reg         boot_copy_wr;
	wire [7:0]  boot_copy_rom_do;

	rom_esxdos rom_esx (
		.address(boot_copy_addr[12:0]),
		.clock(clock),
		.q(boot_copy_rom_do)
	);

	always @(posedge clock) begin
		if (pll_locked == 1'b0) begin
			boot_copy_active <= 1'b1;
			boot_copy_addr <= 15'd0;
			boot_copy_wr <= 1'b0;
		end else if (mem_clken == 1'b1) begin
			// paced by mem_clken (the same, much slower, tick the CPU's own
			// SDRAM accesses use) rather than vid_clken - vid_clken is fast
			// enough that the address/data here would change again before
			// sdram_ep4ce.v's multi-tick RAS/CAS state machine finished the
			// previous write, corrupting transactions.
			// one tick behind boot_copy_addr, to match rom_esxdos's
			// one-cycle read latency
			boot_copy_wr <= boot_copy_active & boot_settle_done;
			boot_copy_waddr <= boot_copy_addr;
			if (boot_copy_active == 1'b1 && boot_settle_done == 1'b1) begin
				if (boot_copy_addr == 15'd16385)
					boot_copy_active <= 1'b0;
				else
					boot_copy_addr <= boot_copy_addr + 15'd1;
			end
		end
	end

	// esxdos_downloaded only turns (and stays) on once the copy above has
	// actually finished - see the comment by its declaration for why this
	// can't just be a permanent constant.
	always @(posedge clock) begin
		if (pll_locked == 1'b0)
			esxdos_downloaded <= 2'b00;
		else if (boot_copy_active == 1'b0)
			esxdos_downloaded <= 2'b11;
	end

	// embedded rom
	generate
	if (MODEL == 0) begin : rom_inst_48k
		rom48 rom (
			.address(rom_addr[13:0]),
			.clock(psg_clken),    // psg_clken is in the middle of a cpu cycle
			.q(rom_do)
		);
	end else begin : rom_inst_128k
		rom128 rom (
			.address(rom_addr[14:0]),
			.clock(psg_clken),    // psg_clken is in the middle of a cpu cycle
			.q(rom_do)
		);
	end
	endgenerate

	// LEDs on this board are active-low (confirmed on hardware: tying a
	// pin to constant 0 lit it, not 1 as previously assumed).
	// Board silkscreen numbers these in reverse of the LED[] index (its
	// "LED1" is this code's LED[3], pin 84) - user wants the CS
	// indicator specifically on silkscreen LED1, i.e. LED[3] here.
	assign LED[0] = 1'b1;
	assign LED[1] = 1'b1;
	assign LED[2] = 1'b1;
	assign LED[3] = divmmc_cs;

	// ULA "ear" input (tape in) - no tape hardware on this board, keep idle
	assign ula_ear_in = 1'b1;

	// KEY[0] = board button S1 -> computer reset (also see reset_cond)
	// KEY[1] = board button S2 -> NMI (also see nmi_trigger)
	wire nmi_trigger = key_f12 | ~KEY[1];

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
	// (tested disabling this entirely as a diagnostic - made no
	// difference on real hardware, ruled out)
	assign cpu_irq_n = vid_irq_n;
	// Unused CPU input signals
	assign cpu_wait_n = 1'b1;
	// F12 (PS/2 keyboard) or board button S2 triggers a plain NMI directly -
	// the T80 core only latches this on the falling edge internally
	// (see T80.v's NMI_s/OldNMI_n), so holding it doesn't re-trigger
	assign cpu_nmi_n = nmi_trigger ? 1'b0 : 1'b1;
	assign cpu_busreq_n = 1'b1;

	// Keyboard
	keyboard kb (
		.CLK(clock),
		.nRESET(reset_n),
		.PS2_CLK(PS2_CLK),
		.PS2_DATA(PS2_DATA),
		.A(cpu_a),
		.KEYB(keyb),
		.F11(key_f11),
		.F8(key_f8),
		.F12(key_f12)
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

	// ULA video - native 15.625kHz (non scan-doubled) mode. Sync is
	// combined composite sync on VGA_HS (vid_hcsync_n); VGA_VS is held
	// high and unused, matching the classic RGB/SCART 15kHz convention
	// this timing was designed for. (The monitor sync theory was wrong -
	// the real bug was DivMMC paging into never-written SDRAM, see
	// esxdos_downloaded above.)
	video vid (
		.CLK(clock),
		.CLKEN(vid_clken),
		.MEM_CYC(vid_mem_sync),
		.nRESET(reset_n),
		.VGA(1'b0),
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

	// Sound - AY-3-8912 (via YM2149) wired in unconditionally, see MODEL
	// comment above for why this isn't gated on MODEL != 0 like upstream.
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

	// mix AY output with the beeper (average the two 8-bit sources) and
	// drive the board's piezo buzzer through a single 1-bit sigma-delta DAC
	wire [7:0] beeper_aout = {ula_ear_out, ula_mic_out, ula_ear_in, 5'b00000};
	wire [8:0] mono_sum = psg_aout + beeper_aout;
	sigma_delta_dac dac_mono (
		.CLK(clock),
		.RESET(~reset_n),
		.DACin(mono_sum[8:1]),
		.DACout(BEEP)
	);

	// DIVMMC interface - wired straight to the SD card module pins. See
	// file header comment: the ESXDOS ROM is copied into SDRAM at boot,
	// so this is live as soon as an SD card is present.
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
	assign SD_CS = divmmc_cs;
	assign SD_SCK = divmmc_sclk;
	assign SD_MOSI = divmmc_mosi;
	assign divmmc_miso = SD_MISO;

	// Asynchronous reset
	// System is reset by the board's reset button or PLL being out of lock

	// delay reset so sdram can be initialized etc. especially clearing the
	// divmmc ram after esxdos upload needs some time (9.3ms)
	// F8 (PS/2 keyboard) or board button S1 resets the computer, in
	// addition to the board's own RESET_BTN. Also held while the ESXDOS
	// ROM is still being copied into SDRAM (boot_copy_active below) so the
	// CPU can never page DivMMC in before that content is valid - the very
	// first instruction fetch after reset (address 0x0000) is one of
	// divmmc.v's auto-page-in trap addresses.
	wire reset_cond = (pll_locked == 1'b0) || (RESET_BTN == 1'b0) || (key_f8 == 1'b1) || (KEY[0] == 1'b0) || (boot_copy_active == 1'b1);
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
		// map kempston joystick port - no joystick hardware on this board, idle
		(kempston_enable == 1'b1) ? 8'b00000000 :
		// Idle bus
		8'b11111111;

	generate
	if (MODEL == 0) begin : rom_48k
		// DivMMC low mapping (0x0000 - 0x1fff)
		assign divmmc_lo_addr = ((divmmc_conmem == 1'b1) || (divmmc_mapram == 1'b0)) ?
			{6'b000000, cpu_a[12:0]} : {6'b010011, cpu_a[12:0]};

		// DivMMC hi mapping (0x2000 - 0x3fff)
		assign divmmc_hi_addr = {2'b01, divmmc_sram_page, cpu_a[12:0]};

		// DivMMC mapping
		assign divmmc_addr = (cpu_a[13] == 1'b0) ? divmmc_lo_addr : divmmc_hi_addr;

		// 48K, with DivMMC paged in over the ROM address space (0x0000-0x3fff)
		// when active - unlike stock 48K hardware, the trap logic in
		// divmmc.v works from the raw address bus regardless of ROM content.
		// Gated on esxdos_downloaded so this can't page into SDRAM before
		// the ESXDOS ROM copy (see boot_copy_* above) has actually finished.
		assign rom_addr =
			((esxdos_downloaded[1] == 1'b1) && (divmmc_paged_in == 1'b1)) ? {1'b1, divmmc_addr} :
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
	assign cpu_addr = (ram_enable == 1'b1) ? {1'b0, ram_addr} : {1'b1, rom_addr};

	// Video from bank 7 (128K/+3)
	// Video from bank 5
	// 16-bit address, LSb selects high/low byte
	assign vid_addr = (page_shadow_scr == 1'b1) ? {6'b001110, vid_a[12:0]} :
		{6'b001010, vid_a[12:0]};

	// 128K-style paging register (port 0x7FFD), kept live even in the 48K
	// build: it doesn't cost any block RAM (just address decode + 3 FFs),
	// and page_ram_sel[2:0] still genuinely selects which of the 8 SDRAM
	// RAM banks is mapped at 0xC000-0xFFFF (see ram_page above) - software
	// that OUTs to 0x7FFD can bank-switch RAM even without the paged 128K
	// ROM. page_rom_sel has no effect in the 48K rom_48k address generate.
	// Shown live on the 7-segment display below.
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

	// 7-segment "digital tube" - digit 1 normally shows page_ram_sel (0-7).
	// Polarity is a guess (common-anode: segment/digit driven low = lit) -
	// not yet confirmed on hardware. If the digit stays blank or shows
	// inverted, flip these two constants.
	localparam SEG_ACTIVE_LOW = 1'b1;
	// confirmed correct: a single clean digit displayed before this was
	// (wrongly) flipped based on an LED polarity analogy that didn't apply
	// here - digit-select is active-low, independent of the LED drivers
	localparam DIG_ACTIVE_LOW = 1'b1;

	// DIAGNOSTIC: all 4 digits show the CPU's last M1 (opcode fetch)
	// address in hex, live - direct proof of whether the CPU is actually
	// executing sane code in the DivMMC ROM region or has run off into
	// the weeds, instead of inferring it indirectly from paged_in state.
	// TODO revert to page_ram_sel on digit 1 once DivMMC bring-up is confirmed
	// Edge-triggered (only the cycle M1 first goes low) rather than
	// level-triggered: M1 stays low for several clock cycles per real
	// opcode fetch, and if cpu_a isn't perfectly stable for that whole
	// window, a level-triggered latch can catch a mid-instruction
	// address instead of the actual opcode-fetch address - confirmed
	// via simulation (which used edge-triggered capture and never saw
	// this) that PC=0x0088, read live off hardware, is not a valid
	// instruction boundary at all - it's the middle of a 3-byte
	// instruction that starts at 0x0086, meaning the display itself
	// was likely showing bogus mid-instruction snapshots rather than
	// real execution being stuck there.
	reg [15:0] last_pc;
	reg        prev_cpu_m1_n = 1'b1;
	always @(posedge clock) begin
		if ((cpu_m1_n == 1'b0) && (prev_cpu_m1_n == 1'b1))
			last_pc <= cpu_a;
		prev_cpu_m1_n <= cpu_m1_n;
	end

	// slow, visually-persistent round-robin scan across the 4 digits
	reg [11:0] digit_scan_cnt;
	reg [1:0]  digit_scan;
	always @(posedge clock) begin
		digit_scan_cnt <= digit_scan_cnt + 12'd1;
		if (digit_scan_cnt == 12'd0)
			digit_scan <= digit_scan + 2'd1;
	end

	wire [3:0] nibble = (digit_scan == 2'd0) ? last_pc[3:0]   :
	                    (digit_scan == 2'd1) ? last_pc[7:4]   :
	                    (digit_scan == 2'd2) ? last_pc[11:8]  :
	                                           last_pc[15:12];

	reg [6:0] seg_gfedcba;
	always @* begin
		// classic hex-to-7seg table, bit order {g,f,e,d,c,b,a}
		case (nibble)
			4'h0: seg_gfedcba = 7'h3F;
			4'h1: seg_gfedcba = 7'h06;
			4'h2: seg_gfedcba = 7'h5B;
			4'h3: seg_gfedcba = 7'h4F;
			4'h4: seg_gfedcba = 7'h66;
			4'h5: seg_gfedcba = 7'h6D;
			4'h6: seg_gfedcba = 7'h7D;
			4'h7: seg_gfedcba = 7'h07;
			4'h8: seg_gfedcba = 7'h7F;
			4'h9: seg_gfedcba = 7'h6F;
			4'ha: seg_gfedcba = 7'h77;
			4'hb: seg_gfedcba = 7'h7C;
			4'hc: seg_gfedcba = 7'h39;
			4'hd: seg_gfedcba = 7'h5E;
			4'he: seg_gfedcba = 7'h79;
			4'hf: seg_gfedcba = 7'h71;
		endcase
	end
	// Board wiring swaps segments b and f relative to the {g,f,e,d,c,b,a}
	// bit order assumed above (confirmed on hardware: "3" displayed as
	// a mirrored "6", the exact symptom of a b/f swap) - compensate here
	// by swapping bits 1 (b) and 5 (f) when driving the physical pins,
	// keeping the logical hex table above standard/untouched.
	wire [6:0] seg_gfedcba_pins = {seg_gfedcba[6], seg_gfedcba[1], seg_gfedcba[4:2], seg_gfedcba[5], seg_gfedcba[0]};
	assign SEG[6:0] = SEG_ACTIVE_LOW ? ~seg_gfedcba_pins : seg_gfedcba_pins;
	// Decimal point repurposed as a live divmmc_paged_in indicator (lit
	// while DivMMC's ROM is actually mapped in) - answers "does
	// automap ever actually engage on this hardware at all" without
	// adding another LED.
	assign SEG[7] = SEG_ACTIVE_LOW ? ~divmmc_paged_in : divmmc_paged_in;

	wire [3:0] dig_onehot = 4'b0001 << digit_scan; // digit0=last_pc[3:0] (rightmost, matches earlier confirmed digit position) ... digit3=last_pc[15:12]
	assign DIG = DIG_ACTIVE_LOW ? ~dig_onehot : dig_onehot;

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

	// Connect ULA to video output - only the base colour bit survives on
	// this board's single-pin-per-channel VGA connector (8 colours, no
	// bright/scanline shading)
	assign zx_red = vid_r_out[3];
	assign zx_green = vid_g_out[3];
	assign zx_blue = vid_b_out[3];
	assign VGA_R = zx_red;
	assign VGA_G = zx_green;
	assign VGA_B = zx_blue;
	// 15kHz mode: composite (H^V) sync on VGA_HS, VGA_VS unused/high
	assign VGA_HS = vid_hcsync_n;
	assign VGA_VS = 1'b1;

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
		end

		// Register SRAM signals to outputs (clock must be at least 2x CPU clock)
		if (vid_clken == 1'b1) begin
			// Fetch data from previous CPU cycle
			// Normal RAM access at 0x4000-0xffff
			// 16-bit address
			ram_addr <= {3'b000, ram_page, cpu_a[13:0]};
		end
	end

	// share SDRAM between CPU and Video. This must stay combinational (not
	// clocked): sdram_ep4ce.v's internal ACTIVE->CAS state machine runs on
	// clk56 with only a 3-cycle RAS-to-CAS latency, and registering this mux
	// on posedge clock adds up to a full clock-cycle of extra latency
	// between cpu_cycle changing and sdram_we/addr/di reflecting it --
	// enough to shift the row-select (ACTIVE) and column/data-select (CAS)
	// phases of one transaction onto two different requesters, silently
	// corrupting the target address.
	always @* begin
		if (boot_copy_wr == 1'b1) begin
			// one-time ESXDOS ROM seeding, see boot_copy_* above. The CPU
			// is held in reset for all of this, so it's safe to just
			// override the normal cpu/video arbitration outright.
			sdram_oe = 1'b0;
			sdram_we = 1'b1;
			if (boot_copy_waddr < 15'd16384) begin
				sdram_di = boot_copy_rom_do;
				// pass 0 (boot_copy_waddr[13]=0): fixed ROM location, same
				// address layout as rom_addr's DivMMC {1'b1, divmmc_addr}
				// mapping with conmem=1 or mapram=0: {6'b000000, addr[12:0]}.
				// pass 1: the mapram location (conmem=0, mapram=1):
				// {6'b010011, addr[12:0]} - see boot_copy_addr comment above
				sdram_addr = boot_copy_waddr[13] ?
					{4'b0000, 2'b11, 6'b010011, boot_copy_waddr[12:0]} :
					{4'b0000, 2'b11, 6'b000000, boot_copy_waddr[12:0]};
			end else begin
				// DIAGNOSTIC EXPERIMENT: zero out the RST 28h indirect-jump
				// vector at 0x3DEE/0x3DEF (divmmc "hi" mapping, sram_page=0,
				// which is what's live right after reset before any CPU
				// code changes it) so RST 28h jumps to 0x0000 instead of
				// whatever was in that never-initialized SDRAM before. This
				// tests the theory that PC getting stuck at 0x0028 (and
				// bouncing to 0x0038 on the interrupt vector) is caused by
				// that vector table never being set up, rather than being
				// the "real" fix - see conversation notes.
				sdram_di = 8'h00;
				sdram_addr = (boot_copy_waddr == 15'd16384) ?
					{4'b0000, 2'b11, 2'b01, 4'b0000, 13'h1DEE} :
					{4'b0000, 2'b11, 2'b01, 4'b0000, 13'h1DEF};
			end
		end else if (cpu_cycle == 1'b1) begin
			sdram_oe = ~cpu_mreq_n & ~cpu_rd_n;  // any cpu read enables ram
			sdram_we = ram_write;                // write only for memory used as ram
			sdram_di = cpu_do;
			sdram_addr = {4'b0000, cpu_addr};
		end else begin
			// no cpu access. Thus do video access
			sdram_oe = ~vid_rd_n;
			sdram_we = 1'b0;    // video never writes
			sdram_di = 8'b00000000;
			sdram_addr = {6'b000000, vid_addr};
		end
	end

endmodule
