// ZX Spectrum for the EP4CE6E22C8 (OMDAZZ / RZ-EasyFPGA A2.2) dev board
//
// Adapted from spectrum_mist.v (Copyright (c) 2009-2011 Mike Stirling,
// MiST port by the mist-board project).
//
// Copyright (c) 2026 Sergey Potapov (potapov.sergey.77@gmail.com)
//
// Written for this board on the basis of spectrum_mist.v. Beyond the
// port itself, the parts that are new here: the SDRAM arbiter that
// shares one chip between the CPU and video, the boot-copy state
// machine that seeds SDRAM from block ROM at power-up, turbo at
// 3.5/7/14/28 MHz with the speed change landing on a safe boundary,
// the ULA contention model, machine selection between 48K, 128K/+2,
// +2A/+3 and Pentagon, and the DivMMC wiring to the SD card breakout.
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

	// Simulation only. The boot zeroes 131072 SDRAM locations one per
	// slot, which is 75ms of modelled time and about five minutes of
	// waiting per run - all of it before anything interesting happens.
	// Hardware needs every one of them; a simulator starts its memory
	// from a known value anyway.
	parameter SIM = 0;

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
	wire   [15:0]   sdram_word;   // the whole word a read came from
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
	// Combinational, so it always reflects the address the CPU is
	// presenting right now.
	//
	// It used to be registered on vid_clken, i.e. re-sampled only every
	// second clock, which left it lagging cpu_a by up to two clocks.
	// That was harmless while the CPU had a fixed memory slot and the
	// mux read the address live, part way through the slot - the value
	// had caught up by then. The arbiter captures the address at the
	// start of the cycle instead, so it captured the stale one whenever
	// cpu_a had just moved. Stack traffic moves it every few T-states:
	// simulation of a program that fills RAM showed exactly half of all
	// writes landing at the previous address, which is the kind of
	// sparse damage that lets small files load and large ones fail.
	wire    [19:0]  ram_addr;   // assigned below, after ram_page/cpu_a
	wire    [20:0]  cpu_addr;
	wire    [18:0]  vid_addr;
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
	reg     [1:0]   esxdos_downloaded = 2'b00;
	wire            divmmc_paged_in;
	wire    [3:0]   divmmc_sram_page;
	wire            divmmc_mapram;
	wire            divmmc_conmem;
	wire    [15:0]  divmmc_trap_addr;
	// Declared here rather than where it is driven, a thousand lines
	// down: the DivMMC instance needs it to know who owns $3Dxx, and
	// Quartus tolerates using a net before its declaration where
	// ModelSim does not.
	wire            trdos_avail;
	wire            trdos_active;
	wire            disk_loaded;
	reg     [1:0]   romld_slot = 2'd0;
	// Same reason: the DivMMC instance above needs to know whether the
	// machine ROM is coming from the slots, and that is decided a
	// thousand lines below.
	reg             rom_from_sd = 1'b0;
	wire            key_f11;
	wire            key_f8;
	wire            key_f12;
	wire            key_f5;
	wire            key_f6;
	wire            key_f7;
	wire            key_f9;
	wire            key_f10;
	wire            key_pgup;
	wire            key_pgdn;
	wire            key_home;
	wire            key_end;
	wire            key_kpsub;
	wire            key_kpadd;
	wire            key_space;
	reg             key_kpsub_d = 1'b0;
	reg             key_kpadd_d = 1'b0;
	reg             key_pgup_d = 1'b0;
	reg             key_pgdn_d = 1'b0;
	reg             key_home_d = 1'b0;
	reg             key_end_d  = 1'b0;
	// CPU speed, set by F1..F4: 0 = 3.5 MHz, 1 = 7, 2 = 14, 3 = 28.
	//
	// The key only asks; the change lands further down, on a slot
	// boundary with no access in flight. Switching the moment the key
	// is pressed corrupted a running BASIC, and it would: the enable
	// pattern changes instantly, but the arbiter is built on the CPU
	// putting MREQ exactly on a slot boundary - which is why the 3.5 MHz
	// enables sit on counts 6 and 14. Change it under an open SDRAM
	// cycle and the address moves out from under it, splitting one
	// transaction across two locations. One byte of BASIC's system
	// variables is enough to break it.
	reg     [1:0]   cpu_speed_req = 2'd0;
	reg     [1:0]   cpu_speed     = 2'd0;
	// The interrupt sits where the published 14336 T-states put it and is
	// not adjustable. The keypad trim that was here proved the point it
	// was built for - every value moves the top border in jumps of eight
	// pixels, never the four that are missing - and then only got in the
	// way. See the memory note on the HALT poll grid.
	wire signed [7:0] int_adj = 8'sd0;
	// Which trim the four-digit display is showing, set by whichever trim
	// key was pressed last. A fixed priority used to decide it, and setting
	// a trim the display was not on looked exactly like the keys being
	// dead - see the note by any_trim.
	//   0 = contention window   1 = IO window   2 = interrupt phase
	reg [1:0] trim_show = 2'd0;
	// Vertical trim: where the frame sits against the raster, stepped by
	// Page Up / Page Down. video.v takes this in sixteenths of a line
	// (INT_VADJ >>> 4), so a step of 16 is exactly one line.
	//
	// Unlike CONT_ADJ this does not touch the contention window - it
	// moves the interrupt, and so the whole frame, up or down. The two
	// are independent knobs: one for where the frame sits, one for where
	// the contention window sits inside it.
	reg  signed [7:0] int_vadj = 8'sd0;
	// F10 cycles the ULA contention model
	// 0 = no contention, 1 = memory only, 2 = memory and IO.
	//
	// Full on at power-up, which is what a real machine does. Judged on
	// the board with a demo that draws border stripes: with memory and
	// IO both contended the stripes line up and run at the right speed.
	// The lamps read the mode inverted, so mode 2 is the state with all
	// of them dark.
	reg     [1:0]   cont_mode = 2'd2;
	// Which lengthened T-states count as internal ones - see cycle_extra
	// below. Declared here, with the other trims, because the block that
	// steps it on Home/End runs long before that point in the file and
	// Quartus was accepting the forward reference without wiring it.
	reg     [1:0]   cont_model = 2'd1;
	// Position of the whole contention window in the line, edges and
	// pattern together, one CPU T-state a step and signed - so 1F is one
	// T-state early, not thirty-one late. Stepped by the board's spare
	// buttons KEY3 and KEY4, sampled slowly so contact bounce does not
	// run it on.
	reg     [4:0]   cont_adj = 5'd0;
	// The same again for the IO window on its own, keypad - and +.
	//
	// Memory contention is exact now - Tact Meter reads what a real
	// machine reads - so anything still displaced cannot be trimmed with
	// cont_adj without breaking what already agrees. And what is still
	// displaced grows along the line: in the squares demo the first edge
	// is out by four pixels and the next by eight. A phase error does
	// not do that; an IO window in the wrong place does, because every
	// port write meets it at a different point in the pattern.
	reg     [4:0]   io_adj = 5'd0;
	reg     [16:0]  btn_div = 17'd0;
	reg     [1:0]   btn_prev = 2'b11;
	reg             key_f10_d = 1'b0;
	wire            key_f3;
	wire            key_f4;
	reg             key_f3_d = 1'b0;
	reg             key_f4_d = 1'b0;
	wire            key_f1;
	wire            key_f2;
	reg             key_f1_d = 1'b0;
	reg             key_f2_d = 1'b0;
	// Per-row 'a key is held here', for spotting a stuck bit
	wire    [7:0]   kb_row_any;

	// Memory size select: F9 gives 48K, F10 gives 128K. 128K is the
	// default. This only gates the paging register's effect - the 0x7FFD
	// register and the banked RAM at 0xC000 are present either way, and
	// with page_ram_sel forced to 0 the mapping is exactly a 48K
	// machine's. There is no 128K ROM: it needs 32 of this device's 30
	// M9K blocks on its own, which is why the build is 48K-ROM based.
	// ESXDOS reads TRD images with its own driver rather than through
	// TR-DOS, so what those need is the RAM banks, not the 128K ROM.

	// Frame timing select:
	//   F5 Sinclair 48K   F6 Sinclair 128K
	//   F7 Sinclair +2A/+3   F8 Pentagon 128K
	// Geometry and interrupt positions per machine are in video.v,
	// taken from zx-sizif-512. Pentagon 128K is the power-up default.
	//
	// This picks timing only. The ROM is the 48K one in every mode - a
	// 128K ROM needs 32 of this device's 30 M9K blocks on its own - and
	// memory size follows from it. The +2A/+3 differs from
	// 128K in its contention pattern rather than its frame, and
	// contention is not modelled here at all, so F6 and F7 currently
	// produce the same frame; the distinction is wired through so it is
	// there when contention is.
	localparam MACHINE_S48  = 2'd0;
	localparam MACHINE_S128 = 2'd1;
	localparam MACHINE_S3   = 2'd2;
	localparam MACHINE_PENT = 2'd3;
	// Pentagon 128K at power-up.
	reg     [1:0]   machine = MACHINE_PENT;
	// Memory size follows the machine: 48K has none of it, the other
	// three have 128K. Pentagon can additionally be given 1024K on F9.
	wire            mem128 = (machine != MACHINE_S48);
	reg             ext1024 = 1'b0;

	// Master clock - 28 MHz
	wire            clk56;
	wire            pll_locked;
	// Explicit power-up value. Cyclone IV registers come out of
	// configuration at 0 regardless, so this changes nothing on hardware
	// - but this register is derived from itself (clock <= ~clock), so
	// without it the whole 28MHz domain is stuck at X in simulation and
	// the design does absolutely nothing.
	wire            clock;
	wire            clk28;
	reg             reset_n;

	// Clock control
	wire            psg_clken;
	wire            cpu_clken;
	wire            mem_clken;
	wire            dio_clken;
	wire            vid_clken;
	wire            clk_ref;
	wire            vid_mem_sync;
	wire            vid_contention;
	wire            vid_contention_io;
	wire            vid_port_ff_active;
	wire    [7:0]   vid_port_ff_data;
	// The CPU's enable after the ULA has had its say - see the contention
	// block further down. Declared here because the CPU instance is above
	// it.
	wire            cpu_clken_gated;
	// one tick per SDRAM cycle boundary - the arbiter's decision point
	wire            slot_tick;
	// which byte video is asking for right now: 0 = pixels, 1 = attribute
	wire            vid_req_step;
	wire            vid_req_gen;
	wire            vid_stale;
	// arbiter -> video handshake (driven in the arbiter block below,
	// declared here because the video instance reads them first)
	reg     [7:0]   vid_do = 8'd0;
	reg             vid_data_valid = 1'b0;
	reg             vid_data_step = 1'b0;
	reg             vid_data_gen = 1'b0;
	reg             vid_req_ack = 1'b0;

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
	// Six bits: three from the 128K paging register, three more from the
	// Pentagon 1024 extension in bits 7:5 of the same port.
	wire    [5:0]   page_ram_sel;

	// +3 extensions (with default values for systems that don't have it)
	reg             plus3_printer_strobe = 1'b0; // bit 4
	reg             plus3_disk_motor = 1'b0; // bit 3
	reg     [1:0]   plus3_page = 2'b00; // bits 2:1
	reg             plus3_special = 1'b0; // bit 0

	// RAM bank actually being accessed
	wire    [5:0]   ram_page;

	// CPU signals
	wire            cpu_wait_n;
	// Held low for the span of one DivMMC SPI transfer - see divmmc.v's
	// wait_n. ANDed with the arbiter's own wait below to make the signal
	// T80 actually sees; cpu_wait_n itself keeps its name and meaning
	// (the SDRAM arbiter alone) everywhere else in this file. Declared
	// here, ahead of the T80 instance that reads it: Quartus accepts
	// use-before-declaration, ModelSim does not.
	wire            divmmc_wait_n;
	wire    [2:0]   cpu_mc;
	wire    [2:0]   cpu_ts;
	wire            cpu_io_cyc;
	wire            cpu_wait_all_n;
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
		.c2(clk28),
		.locked(pll_locked)
	);

	// The system clock comes from its own PLL output rather than from
	// dividing the SDRAM clock.
	//
	// Dividing tied the two together: the memory could only run at a
	// whole multiple of 28MHz - 84, 112, 140 and nothing between. It
	// also fixed the PLL's VCO configuration, and that configuration is
	// what made the phase grid too coarse to close 112MHz, where the
	// output path finished 76ps short with no shift left to give it.
	//
	// Both outputs come from the same PLL, so they stay phase-related
	// and the crossing between them is as safe as it was.
	assign clock = clk28;

	// Clock enable logic
	clocks clken (
		.CLK(clock),
		.nRESET(pll_locked),
		.MREQ(~cpu_mreq_n | ~cpu_ioreq_n),
		.SPEED(cpu_speed),
		.CLKEN_PSG(psg_clken),
		.CLKEN_CPU(cpu_clken),
		.CLKEN_MEM(mem_clken),
		.CLKEN_DIO(dio_clken),
		.CLKEN_VID(vid_clken),
		.VID_MEM_SYNC(vid_mem_sync),
		.CLK_REF(clk_ref),
		.CLKEN_SLOT(slot_tick)
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
		.dout16(sdram_word),
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
	reg  [9:0]  boot_settle_cnt = 10'd0;
	reg         boot_settle_done = 1'b0;
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
	reg         boot_copy_active = 1'b1;
	reg  [14:0] boot_copy_addr = 15'd0;
	wire [7:0]  boot_copy_rom_do;

	// The write request is presented for a whole CPU slot rather than
	// pulsed, so address and data stay put for the entire SDRAM
	// transaction (see the pacing comment on the state machine below).
	// ZERO FIRST, THEN COPY. It used to be the other way round, and the
	// two passes overlapped: the zeroing covers DivMMC RAM pages 0 to 15
	// as {2'b11, 2'b01, page, offset}, and the mapram copy writes
	// {2'b11, 6'b010011, offset} - which for page 3 is the same eight
	// leading bits, 11010011. So the copy carefully seeded bank 3 with
	// the ESXDOS image and the zeroing then wiped it, every boot, and the
	// mapram pass was doing nothing at all.
	//
	// Nothing noticed because nothing used bank 3: MAPRAM was never set.
	// The moment it was, $0000-$1FFF became eight kilobytes of zeros and
	// the machine came up with a black screen.
	//
	// Simulation could not have caught it either - tb_top.v pokes the
	// image into both locations itself and then forces the copy counter
	// to the end, so bank 3 is populated there whatever the hardware
	// does.
	wire        boot_copy_wr = boot_copy_active & ~boot_zero_active
	                           & boot_settle_done;

	// Second boot phase: zero the DivMMC sram pages (see the state
	// machine below for why).
	reg         boot_zero_active = 1'b1;
	reg  [16:0] boot_zero_addr   = 17'd0;
	wire        boot_zero_wr = boot_zero_active & boot_settle_done;

	// During the boot copy the ROM follows the copy counter; afterwards
	// it follows the CPU, so the DivMMC fixed 8K can be served straight
	// from block RAM (see the cpu_di mux).
	rom_esxdos rom_esx (
		.address(boot_copy_addr[12:0]),
		.clock(clock),
		.q(boot_copy_rom_do)
	);

	// Advance exactly one byte per CPU slot, at the end of the slot.
	//
	// This was previously gated on `mem_clken`, which looks like a slow
	// per-slot tick but is not: clocks.v holds CLKEN_MEM high for three
	// consecutive 56MHz clocks (counter 7, 8 and 9), so a
	// `posedge clock, if (mem_clken)` block fires three times back to
	// back and the address ran three bytes ahead inside a single slot.
	// sdram_ep4ce.v needs the address stable across its whole 8-clock
	// RAS->CAS sequence, so the row it opened and the column it wrote
	// belonged to different addresses. Together with the write address
	// being delayed a tick while the ROM data behind it was not, every
	// byte landed several bytes away from where it belonged - confirmed
	// on hardware, where reading the image back gave 0x01 at offset 0
	// (the value from offset 5/6) instead of 0xF3.
	//
	// Keying off cpu_cycle instead gives the same address/data stability
	// discipline the CPU's own SDRAM accesses get.
	always @(posedge clock) begin
		if (pll_locked == 1'b0) begin
			boot_copy_active    <= 1'b1;
			boot_copy_addr      <= 15'd0;
			boot_zero_active    <= 1'b1;
			boot_zero_addr      <= 17'd0;
		end else begin
			if (slot_tick == 1'b1
			    && boot_zero_active == 1'b1
			    && boot_settle_done == 1'b1) begin
				// Clear the 16 DivMMC sram pages BEFORE the ROM copy runs.
				//
				// ESXDOS keeps tables in this window and expects to find
				// zeroed entries in them. Launching a TRD hangs without
				// this: the ROM scans a table at 0x2C00 in steps of 40
				// bytes looking for a zero byte, and since only the low
				// address byte is incremented the search wraps inside one
				// 256-byte page and never terminates if no zero is there.
				// Observed directly on hardware - the CPU sat in the loop
				// at 0x034C-0x0354 with the DivMMC ROM paged in. Real
				// DivMMC SRAM powers up arbitrarily too, so this is the
				// sort of thing that works by luck rather than by design.
				if (boot_zero_addr == (SIM ? 17'd1023 : 17'd131071))
					boot_zero_active <= 1'b0;
				else
					boot_zero_addr <= boot_zero_addr + 17'd1;
			end
			if (slot_tick == 1'b1
			    && boot_copy_active == 1'b1 && boot_zero_active == 1'b0
			    && boot_settle_done == 1'b1) begin
				if (boot_copy_addr == 15'd16383)
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
		else if (boot_copy_active == 1'b0 && boot_zero_active == 1'b0)
			esxdos_downloaded <= 2'b11;
	end

	// embedded rom
	generate
	if (MODEL == 0) begin : rom_inst_48k
		rom48 rom (
			.address(rom_addr[13:0]),
			.clock(clock),        // see note below on why not psg_clken
			.q(rom_do)
		);
	end else begin : rom_inst_128k
		rom128 rom (
			.address(rom_addr[14:0]),
			.clock(clock),        // see note below on why not psg_clken
			.q(rom_do)
		);
	end
	endgenerate

	// LEDs on this board are active-low (confirmed on hardware: tying a
	// pin to constant 0 lit it, not 1 as previously assumed).
	// Board silkscreen numbers these in reverse of the LED[] index (its
	// "LED1" is this code's LED[3], pin 84) - user wants the CS
	// indicator specifically on silkscreen LED1, i.e. LED[3] here.
	// DIAGNOSTIC: silkscreen LED1 (= LED[3]) lights when the readback
	// verify has COMPLETED. Without this the displayed mismatch count is
	// ambiguous - a count of 0000 reads the same whether every byte
	// matched or the verify never ran at all (in which case the CPU is
	// also still held in reset, which is exactly what happened).

	// Tracks the M1 edge for the PC display sampler further down.
	reg        prev_cpu_m1_n = 1'b1;

	// Silkscreen numbering runs opposite to the LED[] index, so LED[3]
	// is the leftmost lamp (silkscreen LED1) and LED[0] the rightmost
	// (silkscreen LED4). Active low.
	//
	//   LED1, leftmost  - SD card access
	//   LED4, rightmost - Pentagon 1024K extension on
	//   LED2, LED3      - unused
	// The lamps are driven from the diagnostic block down beside the
	// seven-segment display, where every signal they report on has
	// already been declared. Driving them from here meant reaching
	// forward to regs declared a thousand lines further down - Quartus
	// allows that, ModelSim does not.

	// ULA "ear" input (tape in) - no tape hardware on this board, keep idle
	assign ula_ear_in = 1'b1;

	// KEY[0] = board button S1 -> computer reset (also see reset_cond)
	// KEY[1] = board button S2 -> NMI (also see nmi_trigger)
	// Keys that step or toggle something have to act on the press, not
	// on the level.
	//
	// The key signals stay high for as long as the key is held, and
	// these blocks run at 28MHz, so a level test fires millions of times
	// per press: the trim jumped to a value set by how long the key was
	// held, and the 1024K toggle below settled wherever it happened to
	// stop. Every position picked with the trim before this was
	// measured with an instrument that did not work.
	reg key_f9_d = 1'b0;
	wire key_f9_press = key_f9 & ~key_f9_d;
	always @(posedge clock) begin
		key_f9_d <= key_f9;
	end

	// F1..F4 pick the CPU speed: 3.5, 7, 14, 28 MHz. They used to trim
	// the interrupt position and line, which was set aside once no trim
	// could satisfy two demos at once - the interrupt now sits at the
	// value the published 14336 T-states give and is not adjustable.
	// The contention window on KEY2/KEY3 is still there.
	always @(posedge clock) begin
		key_f1_d <= key_f1;
		key_f2_d <= key_f2;
		if (key_f1 == 1'b1 && key_f1_d == 1'b0)
			cpu_speed_req <= 2'd0;
		else if (key_f2 == 1'b1 && key_f2_d == 1'b0)
			cpu_speed_req <= 2'd1;
		else if (key_f3 == 1'b1 && key_f3_d == 1'b0)
			cpu_speed_req <= 2'd2;
		else if (key_f4 == 1'b1 && key_f4_d == 1'b0)
			cpu_speed_req <= 2'd3;
		btn_div <= btn_div + 17'd1;
		if (btn_div == 17'd0) begin
			btn_prev <= KEY[3:2];
			if (btn_prev[0] == 1'b1 && KEY[2] == 1'b0) begin
				cont_adj <= cont_adj - 5'd1; trim_show <= 2'd0;
			end else if (btn_prev[1] == 1'b1 && KEY[3] == 1'b0) begin
				cont_adj <= cont_adj + 5'd1; trim_show <= 2'd0;
			end
		end
		key_f10_d <= key_f10;
		if (key_f10 == 1'b1 && key_f10_d == 1'b0)
			cont_mode <= (cont_mode == 2'd2) ? 2'd0 : (cont_mode + 2'd1);
		// Page Up / Page Down move the frame a line at a time. Acted on
		// the press, not the level - these blocks run at 28MHz and a
		// level test would run the trim away in a single keystroke.
		// Keypad - and + move the IO window alone, a T-state a press.
		// Not the cursor keys: 6b and 74 are already the Spectrum's
		// CAPS+5 and CAPS+8, so trimming with them typed into whatever
		// was running.
		key_kpsub_d <= key_kpsub;
		key_kpadd_d <= key_kpadd;
		if (key_kpsub == 1'b1 && key_kpsub_d == 1'b0) begin
			io_adj <= io_adj - 5'd1; trim_show <= 2'd1;
		end else if (key_kpadd == 1'b1 && key_kpadd_d == 1'b0) begin
			io_adj <= io_adj + 5'd1; trim_show <= 2'd1;
		end
		key_pgup_d <= key_pgup;
		key_pgdn_d <= key_pgdn;
		if (key_pgup == 1'b1 && key_pgup_d == 1'b0)
			int_vadj <= int_vadj - 8'sd16;
		else if (key_pgdn == 1'b1 && key_pgdn_d == 1'b0)
			int_vadj <= int_vadj + 8'sd16;
		// Home / End move the border ABOVE AND BELOW the raster only, a
		// pixel a press, leaving the border beside the raster alone.
		// Home winds the tap back (stripes move left) and stops at zero;
		// End delays it further.
		key_home_d <= key_home;
		key_end_d  <= key_end;
		if (key_home == 1'b1 && key_home_d == 1'b0) begin
			cont_model <= cont_model - 2'd1;
		end else if (key_end == 1'b1 && key_end_d == 1'b0) begin
			cont_model <= cont_model + 2'd1;
		end
		key_f3_d <= key_f3;
		key_f4_d <= key_f4;
	end

	// F5..F8 pick the machine. Switching deliberately does NOT reset,
	// so the effect can be watched on a running program.
	always @(posedge clock) begin
		if (key_f5 == 1'b1)
			machine <= MACHINE_S48;
		else if (key_f6 == 1'b1)
			machine <= MACHINE_S128;
		else if (key_f7 == 1'b1)
			machine <= MACHINE_S3;
		else if (key_f8 == 1'b1)
			machine <= MACHINE_PENT;
	end

	// Switching memory size under a running program leaves it with its
	// banks moved out from under it, so it will usually crash - but the
	// switch deliberately does NOT reset the machine, to leave room to
	// experiment. Press F11 to reset when needed.
	// F9 turns the 1024K extension on and off, and only means anything
	// on Pentagon. Leaving Pentagon drops it: the extra pages do not
	// exist on the other machines and leaving them selected would strand
	// whatever is running on a bank it cannot reach.
	reg mem128_d = 1'b1;
	always @(posedge clock) begin
		mem128_d <= mem128;
		if (machine != MACHINE_PENT)
			ext1024 <= 1'b0;
		else if (key_f9_press == 1'b1)
			ext1024 <= ~ext1024;
	end
	wire mem128_changed = (mem128 != mem128_d);

	wire nmi_trigger = key_f12 | ~KEY[1];

	// CPU
	//
	// T2Write=1 puts a write's WR_n/MREQ_n on the TState==1 edge, the
	// same edge a read or an opcode fetch uses (T80se.v:157/166 against
	// :170). With the core's default T2Write=0 a write asserts MREQ a
	// T-state later than a read does, and since ULA contention here is
	// charged off MREQ going low (cont_mem, below), the delay a program
	// was charged depended on whether it was reading or writing.
	//
	// Measured, by phase of the machine cycle's own T1, against the
	// 6,5,4,3,2,1,0,0 a real 48K charges:
	//     reads   5,4,3,2,1,0,0,6   - one T-state late
	//     writes  4,3,2,1,0,0,6,5   - two T-states late
	//
	// One T-state apart, so no single CONT_ADJ trim can straighten both
	// at once - which is exactly why no trim ever satisfied two demos
	// together. This makes them agree; video.v then takes out the
	// one-T-state lateness they now share.
	T80se #(.T2Write(1)) cpu (
		.RESET_n(reset_n),
		.CLK_n(clock),
		.CLKEN(cpu_clken_gated),
		.WAIT_n(cpu_wait_all_n),
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
		.DO(cpu_do),
		.MC(cpu_mc),
		.TS(cpu_ts),
		.IO_CYC(cpu_io_cyc)
	);
	// VSYNC interrupt routed to CPU
	// (tested disabling this entirely as a diagnostic - made no
	// difference on real hardware, ruled out)
	//
	// Fed straight to the core. There used to be a resampler here, a
	// register clocking vid_irq_n on the CPU's own enable, on the
	// argument that nIRQ is made in the video domain and its edges land
	// wherever they land inside a T-state.
	//
	// T80 already does exactly that. Its own input stage is
	// `INT_s <= ~INT_n` on CEN, which is this CPU enable, so the edge was
	// being sampled onto the CPU's grid twice and cost a T-state for it.
	// Measured: from this signal to the acknowledge came out 2, 3 and 5
	// T-states over the phases, where a Z80 out of HALT can only ever
	// give 0..3.
	//
	// The shimmer that put the resampler here was really 840ab94's bug:
	// the pulse was a window compared against hcounter, so trimming right
	// clipped it against the end of the line and 128 counts came out as
	// 14. The CPU caught it or missed it by luck. The pulse is counted
	// out by length now and holds its full 32 T-states, which is what
	// that register was covering for.
	//
	// Those two T-states are what 4fac427 and 219544b were cancelling by
	// moving the interrupt in video.v. That worked - it took the birds
	// demo from twelve pixels to four - but it paid for a CPU fault out
	// of the raster geometry, which then no longer matched the published
	// 14336. Fixed here, the geometry can stay at the reference value.
	assign cpu_irq_n = vid_irq_n;
	// ULA contention, after zx-sizif-512's cpu.sv.
	//
	// The ULA holds the CPU while it is fetching, but only when the CPU
	// is touching something the ULA is also using: the contended RAM
	// bank, or an even IO port. Pentagon has no contention at all, which
	// is why its demos can count T-states in the first place.
	//
	// Contended RAM is 0x4000-0x7FFF on every machine, plus the banked
	// window at 0xC000 when the bank paged there is a contended one -
	// odd banks on a 128K, banks 4..7 on a +2A/+3.
	wire cont_page = (machine == MACHINE_S3) ? page_ram_sel[2] : page_ram_sel[0];
	wire cont_addr = cpu_a[14] & (~cpu_a[15] | cont_page);
	// The +2A/+3 does not contend IO at all. On the others an IO cycle
	// is charged from the published four-case table, which keys on the
	// port's high byte and on A0:
	//
	//   high byte 0x40..0x7F, A0=0 : C:1, C:3       - two delays
	//   high byte 0x40..0x7F, A0=1 : C:1 four times - four delays
	//   any other high byte,  A0=0 : N:1, C:3       - one delay
	//   any other high byte,  A0=1 : N:4            - none
	//
	// What stood here charged one delay for every even port and nothing
	// for odd ones, which is right for 0xFE - other high byte, A0 zero,
	// one delay - and wrong everywhere else. 0x7FFD is the case it got
	// most wrong: high byte 0x7F is contended and A0 is one, so it is
	// due four delays and was given none, and a 128K demo writes it
	// every frame.
	//
	// Keyed on the microcode's IO_CYC, true from T1, and not on IORQ_n,
	// which T80se registers at the edge ending T1 and so cannot be seen
	// until T2. FUSE settles what the right reference is: it keeps one
	// contention table indexed by the absolute T-state and charges IO at
	// T1 and T2 of the IO cycle (peripherals/ula.c, ula_contend_port_early
	// and _late) out of that same table, on the same phase reference
	// memory uses. The published "IO is a T-state different" is not a
	// second window - it is only where in the cycle the two checks fall.
	//
	// Starting at T1 also stops a second charge nothing had noticed. The
	// walk used to begin in T2, so at T1 of an IO cycle io_cyc was still
	// low and cont_mem below saw an ordinary machine cycle beginning with
	// the port address on the bus. For OUT ($40FE),A - high byte inside
	// the contended page - that charged a memory delay on top of the two
	// the IO table already gives. That is the C:1,C:3 row, the one row
	// this design had never measured.
	wire io_cyc     = cpu_io_cyc & cpu_m1_n & (machine != MACHINE_S3);
	// The port's high byte is contended on the same rule as memory: 0x40-
	// 0x7F always, and 0xC0-0xFF when the bank paged at 0xC000 is a
	// contended one. Only the first half was here, so on a 128K a port
	// in the 0xC000-0xFFFF range was charged nothing where a real
	// machine charges it. No effect on a 48K, where cont_page is 0.
	wire io_hi_cont = cpu_a[14] & (~cpu_a[15] | cont_page);

	// A machine cycle is charged the delay once, at its start, and then
	// runs to its end untouched. These flags remember that this cycle
	// has already paid: they set on the tick the access is finally let
	// through, and clear when the cycle ends and the strobe goes high.
	//
	// The one-tick delay line that used to stand here was not enough.
	// A memory cycle is three T-states and an opcode fetch four, so the
	// mask expired inside the cycle and the CPU was charged again, and
	// again, for the same access. Measured with a loop running out of
	// contended RAM, that cost 98% of every clock enable inside the
	// contention window - the CPU very nearly stopped there, where the
	// published table says it should lose about 44%. That is what made
	// the music drag and the border stripes come out dim.
	//
	// Nothing updates while the CPU is held, since these are clocked by
	// the gated enable, so a hold stays a hold until the window frees.
	// What marks the cycle the ULA charges against.
	//
	// sinclair.wiki.zxnet.co.uk, on the Amstrad gate array: "it applies
	// memory contention only if the MREQ line is active, whereas the
	// 16K/48K ULA applies it under all circumstances". Keying on MREQ is
	// therefore the +2A/+3 rule, and this design applied it to every
	// machine - so 48K and 128K were running a gate array's contention.
	//
	// The early ULA watches the address bus, and the delay lands once
	// per machine cycle because a Z80 only samples WAIT at the end of
	// T2. Here the CPU is held by withholding its clock enable rather
	// than through WAIT_n, and a withheld enable freezes it in any
	// T-state, not just T2 - so the T2 test has to be made explicitly.
	// Without it the CPU is charged again on every T-state of the cycle,
	// which is the old defect that cost 98% of the enables in the window
	// where the table says 44%.
	// The published instruction timings are written as a list of
	// sub-cycles - "pc:4, hl:3, hl:1, hl:3" for INC (HL) - and EVERY one
	// of them is charged, the internal `:1` entries included. That is
	// what "the 16K/48K ULA applies it under all circumstances" means in
	// practice, and it is why the error depends on what the program is
	// executing rather than being a fixed offset: two programs with
	// different instruction mixes have different numbers of internal
	// T-states, so no single window trim can suit both.
	//
	// T80 folds an internal T-state into the machine cycle it follows,
	// making that cycle longer instead of starting a new one. So a
	// sub-cycle boundary is T1, plus any T-state beyond the normal
	// length - beyond 4 for an opcode fetch (MCycle 1), beyond 3 for
	// everything else. INC (HL)'s read comes through as a 4-T-state
	// cycle and is charged twice, PUSH's 5-T-state fetch likewise, while
	// a plain fetch or read is charged once.
	// Charged at T1. Moving this to T2 was tried on the theory that T80
	// might still be showing the previous cycle's address during T1, so
	// that cont_addr would sometimes be tested against the wrong bus
	// value - a per-instruction-sequence error, which is the shape of
	// the remaining fault. **Disproven on hardware**: the only effect was
	// a clean one-T-state shift of everything (a border stripe moved two
	// pixels, exactly one T-state), the striped demo went from perfect to
	// broken, and nothing improved. A pure phase shift with no change in
	// distribution means the address IS valid at T1 and no charge was
	// landing on the wrong address. Do not repeat this.
	wire cycle_first = (cpu_ts == 3'd1);

	// Which lengthened T-states count as internal ones, selectable from
	// the keyboard because the answer has to come off the board and a
	// simulation run costs half an hour.
	//
	// Every variant charges T1 of each machine cycle. They differ only
	// in the extra charge for T-states beyond a cycle's normal length,
	// and T80 produces those for two unrelated reasons: a genuine
	// internal T-state folded onto the cycle - what the published
	// timings write as hl:1 and a real ULA charges - and its own
	// lengthening of interrupt acknowledge and the like, which nothing
	// should charge. The two are indistinguishable from a length test
	// alone, so each combination is offered:
	//
	//   0  none          - one charge per machine cycle
	//   1  all           - every T-state past the normal length
	//   2  non-fetch     - only on cycles other than the opcode fetch
	//   3  fetch only    - only on the opcode fetch
	wire extra_nonm1 = (cpu_mc != 3'd1) && (cpu_ts > 3'd3);
	wire extra_m1    = (cpu_mc == 3'd1) && (cpu_ts > 3'd4);
	wire cycle_extra = (cont_model == 2'd0) ? 1'b0 :
	                   (cont_model == 2'd1) ? (extra_m1 | extra_nonm1) :
	                   (cont_model == 2'd2) ? extra_nonm1 : extra_m1;
	wire cont_trigger = (machine == MACHINE_S3) ? ~cpu_mreq_n
	                                            : (cycle_first | cycle_extra);

	// No "already paid" flag on the ULA path, deliberately. It existed
	// because MREQ stays low for two or three T-states, so the level
	// alone re-charged the same access; a T-state test is true for one
	// T-state and clears itself. Worse, the flag would break the case
	// this change is for: two internal T-states in a row must be charged
	// twice, and a paid flag suppresses the second. The hold still ends
	// on its own, because it lasts only while the window is in a delay
	// phase. The +2A/+3 path keeps the flag - it is still keyed on MREQ.
	reg mreq_paid = 1'b0;
	always @(posedge clock) begin
		if (cpu_clken_gated == 1'b1) begin
			if (cpu_mreq_n == 1'b1) mreq_paid <= 1'b0;
			else                    mreq_paid <= 1'b1;
		end
	end

	// An IO cycle walks its delays one T-state at a time rather than
	// taking one hold like a memory access, because the table gives it
	// as many as four of them and they are separate: each waits for the
	// window afresh, so two delays cost more than one twice as long.
	//
	// The walk starts at T1 of the IO machine cycle, off the microcode's
	// IO_CYC rather than off IORQ_n - see io_cyc above. It used to start
	// at IORQ, a T-state later, and every delay sat a T-state later than
	// the table puts it. There were exactly as many, which is why the
	// cost of an OUT looked right while its phase was not.
	//
	// The port is latched at the start: A0 and the high byte have to
	// keep their values through a walk that outlives IORQ itself in the
	// four-delay case.
	reg [2:0] io_seq  = 3'd0;       // 0 = idle, else the delay's index
	reg       io_done = 1'b0;       // this cycle's walk is finished
	reg       io_a0   = 1'b0;
	reg       io_hic  = 1'b0;
	wire      io_start = io_cyc & ~io_done & (io_seq == 3'd0);

	always @(posedge clock) begin
		if (cpu_clken_gated == 1'b1) begin
			if (io_start == 1'b1) begin
				io_seq <= 3'd1;
				io_a0  <= cpu_a[0];
				io_hic <= io_hi_cont;
			end else if (io_seq == 3'd3) begin
				io_seq  <= 3'd0;
				io_done <= 1'b1;
			end else if (io_seq != 3'd0)
				io_seq <= io_seq + 3'd1;

			if (io_cyc == 1'b0)
				io_done <= 1'b0;
		end
	end

	wire [2:0] io_idx = io_start ? 3'd0 : io_seq;
	wire       io_ha0 = io_start ? cpu_a[0]   : io_a0;
	wire       io_hh  = io_start ? io_hi_cont : io_hic;
	// WHICH T-state each delay falls on, not just how many there are.
	// Taken straight off FUSE's periph.c:writeport(), which is
	//
	//   ula_contend_port_early:  if page contended, check;  then +1
	//   ula_contend_port_late:   if A0==0, check, +2
	//                            else if page contended, check,+1,
	//                                 check,+1, check
	//                            else +2
	//   then +1
	//
	// so the four rows fall out as:
	//
	//   page contended, A0=0 : T1, T2                 - C:1, C:3
	//   page contended, A0=1 : T1, T2, T3, T4         - C:1 four times
	//   page plain,     A0=0 : T2 only                - N:1, C:3
	//   page plain,     A0=1 : none                   - N:4
	//
	// The ULA-port check is the LATE one and belongs on T2. It used to
	// sit on T1 here, which is right for nothing and wrong for the one
	// case that matters most: OUT ($xxFE),A with the high byte outside
	// the contended page is the N:1,C:3 row, and it is what every demo
	// drawing the border does. A T-state early on that check draws the
	// delay from the wrong step of the 6,5,4,3,2,1,0,0 group.
	wire       io_point = (io_idx == 3'd0) ? io_hh :
	                      (io_idx == 3'd1) ? (io_hh | ~io_ha0) :
	                                         (io_hh & io_ha0);

	// The MREQ term is not optional either. Without it the address bus
	// alone asks for contention, and a Z80 leaves the last address on
	// the bus through the internal T-states that follow an access.
	wire cont_mem = ~io_cyc & cont_trigger & cont_addr
	                & ((machine == MACHINE_S3) ? ~mreq_paid : 1'b1);
	wire cont_io  = (io_start | (io_seq != 3'd0)) & io_point;
	// One window for both memory and IO. It is worth recording why,
	// because the opposite looks plausible: a real Z80 puts MREQ in T1
	// and IORQ in T2, so it seems as though the two would need windows a
	// T-state apart. They do not, because T80se raises MREQ a T-state
	// late (on the edge ending T1, so first visible in T2) and IORQ on
	// time - which lands both of them in T2 here, once T2Write=1 has
	// moved a write's onto the same edge as a read's.
	//
	// Measured, on this build, with a loop containing both a contended
	// read and a contended OUT so the two share a phase reference: both
	// follow the same rule on every sample with real statistics behind
	// it - read 5.8 where 6 is due and 0.0 where 0 is, IO 4.9 where 5 is
	// due and 4.0 where 4 is. Splitting the window was tried and put a
	// T-state of difference between them that the hardware does not
	// have.
	//
	// F10 turns contention off, to tell whether the model is what makes
	// border stripes spread out from the middle of the screen: a demo's
	// loop taking longer than it should stretches everything it draws.
	// Memory and IO take their delay from windows a T-state apart now:
	// memory is charged against the machine cycle's own T1, IO against
	// IORQ, which a Z80 puts in T2. See the comment by CONTENTION_IO in
	// video.v - measured, IO was coming out a T-state short of the
	// published table at every phase, and that is the ONLY contention
	// path a border-drawing OUT goes through.
	wire contention = (machine != MACHINE_PENT)
	                  & ((cont_mode == 2'd2) ?
	                        ((vid_contention & cont_mem) |
	                         (vid_contention_io & cont_io)) :
	                     (cont_mode == 2'd1) ?
	                        (vid_contention & cont_mem) : 1'b0);

	// Holding the CPU means withholding its clock enable here, which is
	// what Sizif does by holding clkcpu.
	assign cpu_clken_gated = cpu_clken & ~contention;

	// The speed change lands here rather than where the key is read: on
	// a slot boundary, with no memory or IO cycle open and nothing
	// waiting on the arbiter. Everything downstream assumes the CPU's
	// MREQ arrives on a boundary, so the enable pattern must only ever
	// change while there is nothing in flight to disturb.
	always @(posedge clock) begin
		if (slot_tick == 1'b1 && cpu_mreq_n == 1'b1 && cpu_ioreq_n == 1'b1 &&
		    cpu_wait_n == 1'b1)
			cpu_speed <= cpu_speed_req;
	end

	// cpu_wait_n is driven by the arbiter further down.
	// F12 (PS/2 keyboard) or board button S2 triggers a plain NMI directly -
	// the T80 core only latches this on the falling edge internally
	// (see T80.v's NMI_s/OldNMI_n), so holding it doesn't re-trigger
	assign cpu_nmi_n = nmi_trigger ? 1'b0 : 1'b1;
	assign cpu_busreq_n = 1'b1;

	// Keyboard
	// The keyboard is deliberately NOT reset by reset_n. F11 is the reset
	// key, and resetting the keyboard along with the machine cleared the
	// very register holding F11 down - so the reset tore itself down
	// again instead of staying asserted, and holding F11 could not work
	// the way holding the board's button does. It only resets with the
	// PLL now, which is also closer to how a real keyboard behaves: it
	// does not forget which keys are held just because the computer was
	// reset.
	keyboard kb (
		.CLK(clock),
		.nRESET(pll_locked),
		.PS2_CLK(PS2_CLK),
		.PS2_DATA(PS2_DATA),
		.A(cpu_a),
		.KEYB(keyb),
		.F11(key_f11),
		.F8(key_f8),
		.F12(key_f12),
		.F5(key_f5),
		.F6(key_f6),
		.F7(key_f7),
		.F9(key_f9),
		.F1(key_f1),
		.F2(key_f2),
		.F3(key_f3),
		.F4(key_f4),
		.F10(key_f10),
		.PGUP(key_pgup),
		.PGDN(key_pgdn),
		.HOME(key_home),
		.END(key_end),
		.SPACEKEY(key_space),
		.KPSUB(key_kpsub),
		.KPADD(key_kpadd),
		.ROW_ANY(kb_row_any)
	);

	// ULA port
	ula_port ula (
		.CLK(clock),
		.nRESET(reset_n),
		.D_IN(cpu_do),
		.D_OUT(ula_do),
		// Not gated by psg_clken. That enable passes once every 16
		// clocks - once every two T-states - so a border write landed
		// on a two-T-state grid at best, and at worst was missed
		// entirely depending on where the CPU's T-states fell. Border
		// effects are written to this port at exact T-state positions,
		// which is why they came out wrong while everything else in the
		// frame was right. It is also the likely reason a reset
		// sometimes left the border black: the ROM's OUT setting it
		// white was simply dropped.
		//
		// The write is an idempotent register load, so letting it run
		// for the whole bus cycle is harmless - the first load happens
		// the moment IORQ and WR are both low, which is the exact
		// T-state the program intended.
		.ENABLE(ula_enable),
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
		.MACHINE(machine),
		.CONTENTION(vid_contention),
		.CONTENTION_IO(vid_contention_io),
		.INT_ADJ(int_adj),
		.INT_VADJ(int_vadj),
		.CONT_ADJ(cont_adj),
		.IO_ADJ(io_adj),
		.PORT_FF_ACTIVE(vid_port_ff_active),
		.PORT_FF_DATA(vid_port_ff_data),
		.VID_A(vid_a),
		// The registered byte the arbiter hands back, not the raw bus:
		// video's cycle is no longer at a predictable moment, so there
		// is no fixed instant at which the bus could be sampled.
		.VID_D_IN(vid_do),
		.nVID_RD(vid_rd_n),
		.nWAIT(vid_wait_n),
		.VID_REQ_STEP(vid_req_step),
		.VID_REQ_ACK(vid_req_ack),
		.VID_DATA_VALID(vid_data_valid),
		.VID_DATA_STEP(vid_data_step),
		.VID_REQ_GEN(vid_req_gen),
		.VID_DATA_GEN(vid_data_gen),
		.VID_STALE(vid_stale),
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
	// Turbo Sound: a second AY, selected by writing 1111111N to the
	// register-select port, after sorgelig/ZX_Spectrum-128K_MIST's
	// turbosound.sv. 0xFF picks the first chip, 0xFE the second; the
	// value is not a valid register number either way, so it does no
	// harm if it also reaches a chip.
	//
	// Both the direction and the select strobe are gated per chip, not
	// just the select strobe as the reference does: with only the
	// select gated, a data write still reaches the chip that is not
	// selected and lands in whatever register it had latched.
	//
	// The write is edge-triggered, like every other port in this design
	// - gating it on the psg_clken level is what silently dropped
	// writes to the DivMMC SPI port, the paging register and the ULA.
	reg  ay_select = 1'b0;
	reg  ay_sel_wr_d = 1'b0;
	wire ay_sel_wr = psg_bdir & psg_bc1;
	always @(posedge clock or negedge reset_n) begin
		if (reset_n == 1'b0) begin
			ay_select   <= 1'b0;
			ay_sel_wr_d <= 1'b0;
		end else begin
			ay_sel_wr_d <= ay_sel_wr;
			if (ay_sel_wr == 1'b1 && ay_sel_wr_d == 1'b0
			    && cpu_do[7:1] == 7'b1111111)
				ay_select <= cpu_do[0];
		end
	end

	wire psg_bdir_0 = psg_bdir & ~ay_select;
	wire psg_bc1_0  = psg_bc1  & ~ay_select;
	wire psg_bdir_1 = psg_bdir &  ay_select;
	wire psg_bc1_1  = psg_bc1  &  ay_select;
	wire [7:0] psg_do_0;
	wire [7:0] psg_do_1;
	wire [7:0] psg_aout_0;
	wire [7:0] psg_aout_1;
	// One volume table, two read ports - see YM2149/vol_table_array.v.
	wire [11:0] vol_addr_0;
	wire [11:0] vol_addr_1;
	wire [9:0]  vol_data_0;
	wire [9:0]  vol_data_1;
	vol_table u_vol_table (
		.CLK(clock),
		.ADDR(vol_addr_0),
		.DATA(vol_data_0),
		.ADDR_B(vol_addr_1),
		.DATA_B(vol_data_1)
	);
	assign psg_do   = ay_select ? psg_do_1 : psg_do_0;
	// Summed and halved so two chips playing cannot clip the mixer.
	assign psg_aout = ({1'b0, psg_aout_0} + {1'b0, psg_aout_1}) >> 1;

	YM2149 psg (
		.I_DA(cpu_do),
		.O_DA(psg_do_0),
		.O_DA_OE_L(),
		.I_A9_L(1'b0), // /A9 pulled down internally
		.I_A8(1'b1), // A8 pulled up on Spectrum
		.I_BDIR(psg_bdir_0),
		.I_BC2(1'b1), // BC2 pulled up on Spectrum
		.I_BC1(psg_bc1_0),
		.I_SEL_L(1'b1), // /SEL is high for AY-3-8912 compatibility
		.O_AUDIO(psg_aout_0),
		.VOL_ADDR(vol_addr_0),
		.VOL_DATA(vol_data_0),
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
	YM2149 psg2 (
		.I_DA(cpu_do),
		.O_DA(psg_do_1),
		.O_DA_OE_L(),
		.I_A9_L(1'b0),
		.I_A8(1'b1),
		.I_BDIR(psg_bdir_1),
		.I_BC2(1'b1),
		.I_BC1(psg_bc1_1),
		.I_SEL_L(1'b1),
		.O_AUDIO(psg_aout_1),
		.VOL_ADDR(vol_addr_1),
		.VOL_DATA(vol_data_1),
		.I_IOA(8'b0),
		.O_IOA(),
		.O_IOA_OE_L(),
		.I_IOB(8'b0),
		.O_IOB(),
		.O_IOB_OE_L(),
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
		.beta_owns_3d(trdos_avail),
		.stand_down(rom_from_sd),
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
		.sd_miso(divmmc_miso),
		.wait_n(divmmc_wait_n),
		.trap_addr(divmmc_trap_addr)
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
	wire reset_cond = (pll_locked == 1'b0) || (RESET_BTN == 1'b0) || (key_f11 == 1'b1) || (KEY[0] == 1'b0) || (boot_copy_active == 1'b1) || (boot_zero_active == 1'b1);
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

	// Beta Disk ports, live only while the TR-DOS ROM is paged in - that
	// is how a real interface behaves, and it keeps $1F, $3F, $5F, $7F
	// and $FF out of everyone else's way the rest of the time. All of
	// them are odd, so the ULA's even-port decode never collides.
	wire       bdi_enable = trdos_active & (~cpu_ioreq_n) & cpu_m1_n & cpu_a[0];
	wire [7:0]  bdi_do;
	wire [19:0] bdi_img_addr;
	wire        bdi_img_busy;
	// A read of the data register while a sector is in progress is an
	// SDRAM read of the image, served by the arbiter exactly like any
	// other CPU access - the CPU waits on WAIT until the byte is there.
	// Same path the ROM slots are read back through.
	wire        bdi_img_rd = bdi_enable & ~cpu_rd_n & cpu_m1_n
	                         & ~cpu_a[7] & (cpu_a[6:5] == 2'b11) & bdi_img_busy;
	bdi u_bdi (
		.clk(clock),
		.clken(cpu_clken_gated),
		.reset_n(reset_n),
		.enable(bdi_enable),
		.a(cpu_a[7:0]),
		.wr_n(cpu_wr_n),
		.rd_n(cpu_rd_n),
		.din(cpu_do),
		.dout(bdi_do),
		// No image yet: the controller answers, and says there is no
		// disk in the drive. That is enough for software to find TR-DOS,
		// which it cannot do at all while the ports are dead.
		.disk_present(disk_loaded),
		.img_addr(bdi_img_addr),
		.img_busy(bdi_img_busy)
	);

	// --- ROM loader channel ------------------------------------------
	//
	// 128K and Pentagon ROM images come off the SD card, read by ESXDOS,
	// which already has the FAT drivers - none of that belongs in logic.
	// What the hardware provides is a way in, and it is deliberately NOT
	// a writable ROM window: 0x0000-0x3FFF stays unwritable from the
	// memory map at all times, with no enable bit, so a program cannot
	// overwrite the ROM it is executing from. Bytes arrive through a port
	// instead.
	//
	//   0x9B write : [1:0] slot, [2] reset counter, [3] mark filled,
	//                [4] clear filled
	//   0x9B read  : [3:0] the filled flags
	//   0x9F write : one byte, the counter steps on its own
	//
	// Ports chosen clear of everything already decoded: A0=1 keeps them
	// off the ULA, A1=1 off the AY and the paging register, A4=1 off
	// DivMMC's 1110 group, and neither is 0x1F.
	wire romld_ctl_enable = (~cpu_ioreq_n) & cpu_m1_n & (cpu_a[7:0] == 8'h9b);
	wire romld_dat_enable = (~cpu_ioreq_n) & cpu_m1_n & (cpu_a[7:0] == 8'h9f);
	wire romld_write      = romld_dat_enable & ~cpu_wr_n;
	// Slot 3 is a disk image, not a ROM, and it goes in the RAM half of
	// SDRAM rather than the ROM half: a .trd is 640K and the ROM half has
	// only the gap between the slots and DivMMC. Based at $40000 so a
	// 768K image still fits inside twenty bits of address.
	wire disk_slot        = (romld_slot == 2'd3);
	// Reading the data port hands back the byte the counter is pointing
	// at, and steps it, so software can read a slot back and compare it
	// with the file it came from. Everything up to here was verified in
	// simulation and the board still would not boot from a slot, which
	// left one thing nobody could see: what 32768 writes actually put
	// there. Now it can be measured on the board instead of guessed at.
	wire       romld_read       = romld_dat_enable & ~cpu_rd_n;

	// Where each slot sits, in units of 32K of rom_addr space. Bit 19 of
	// rom_addr is DivMMC's; every base here leaves it clear, so the two
	// cannot overlap by construction rather than by arithmetic.
	//
	//   slot 0  128K      rom_addr 0x00000  32K
	//   slot 1  Pentagon  rom_addr 0x08000  32K
	//   slot 2  TR-DOS    rom_addr 0x10000  16K
	function [4:0] slot_base(input [1:0] s);
		slot_base = (s == 2'd0) ? 5'd0 :
		            (s == 2'd1) ? 5'd1 : 5'd2;
	endfunction

	reg [19:0] romld_cnt       = 20'd0;
	reg [3:0]  rom_slot_filled = 4'b0000;
	reg        romld_wr_d      = 1'b0;
	always @(posedge clock or negedge reset_n) begin
		if (reset_n == 1'b0) begin
			romld_slot      <= 2'd0;
			romld_cnt       <= 20'd0;
			romld_wr_d      <= 1'b0;
		end else begin
			// Not gated by the CPU clock enable, for the same reason as
			// the filled flags: the port, the data and WR hold for the
			// whole OUT, so acting on every clock of it is idempotent,
			// while waiting for an enable pulse made it depend on where
			// a contention stall happened to fall. A ROM survived that
			// because a miscount only shifts one image; a disk image is
			// hundreds of blocks and a single miscounted byte moves
			// every sector after it.
			if (romld_ctl_enable == 1'b1 && cpu_wr_n == 1'b0) begin
				romld_slot <= cpu_do[1:0];
				if (cpu_do[2] == 1'b1) romld_cnt <= 20'd0;
			end
			// Stepped when the write ENDS, not while it is asserted: the
			// CPU is held through the arbiter's grant and the level would
			// otherwise count the same byte several times over.
			romld_wr_d <= romld_write | romld_read;
			if (romld_wr_d == 1'b1 && (romld_write | romld_read) == 1'b0)
				romld_cnt <= romld_cnt + 20'd1;
		end
	end

	// A machine reads its ROM out of SDRAM only once its slot says it has
	// been filled. Unfilled, it falls back to the 48K image in block RAM -
	// which is the behaviour before any of this existed, so a card with no
	// ROM files on it still boots and can print the error saying so.
	wire [1:0] mach_slot   = (machine == MACHINE_PENT) ? 2'd1 : 2'd0;
	// The filled flags get a block of their own, with NO reset in it.
	//
	// They have to survive a reset: switching machine and pressing reset
	// is how a loaded ROM is brought up, and a slot that forgot it was
	// loaded would send the CPU into an empty window at the very moment
	// it starts. They used to live in the block above with the async
	// reset, simply left out of its reset branch - which means "hold" to
	// a simulator but leaves synthesis free to clear them with everything
	// else in the block. That is exactly what split the board from the
	// model: in simulation the flags were forced and stayed set, so the
	// machine booted its slot; on the board they cleared on the reset that
	// was supposed to bring the new ROM up, rom_sd_ready went to zero with
	// them, and the 48K image came back instead.
	//
	// Cleared only by reconfiguring the FPGA - a power cycle - which is
	// the documented way back to ESXDOS.
	// Reset with SPACE held forgets the loaded slots, which lets DivMMC
	// come back up. Without it, loading the images was a one-way door:
	// the flags survive a reset by design, so every reset afterwards came
	// up on the slot ROM with the automapper stood down, and only a power
	// cycle got ESXDOS back.
	//
	// The write is NOT gated by the CPU clock enable. IORQ, WR, the port
	// address and the data all stay put for the whole of the OUT's bus
	// cycle, so setting the same bit on every clock of it is idempotent -
	// while gating on the clock enable made the one bit that decides
	// which ROM the machine boots depend on where a contention stall
	// happened to fall. That is a coin toss, not a decode.
	always @(posedge clock) begin
		if (key_f11 == 1'b1 && key_space == 1'b1)
			rom_slot_filled <= 4'b0000;
		else if (romld_ctl_enable == 1'b1 && cpu_wr_n == 1'b0) begin
			if (cpu_do[3] == 1'b1) rom_slot_filled[cpu_do[1:0]] <= 1'b1;
			if (cpu_do[4] == 1'b1) rom_slot_filled[cpu_do[1:0]] <= 1'b0;
		end
	end

	// Whether a loaded slot is used at all, on keypad 5.
	//
	// Without it, loading the images was a one-way door: the flags
	// survive a reset by design, so every reset afterwards came up on the
	// slot ROM with DivMMC stood down, and the only way back to ESXDOS
	// was a power cycle. Now the choice is a keypress and a reset, in
	// either direction, and the slots keep their contents either way.
	assign     disk_loaded  = rom_slot_filled[3];
	wire       rom_sd_ready = ((machine == MACHINE_S128) & rom_slot_filled[0])
	                        | ((machine == MACHINE_PENT) & rom_slot_filled[1]);

	// Which ROM the machine runs can only change across a reset.
	//
	// It used to follow rom_sd_ready directly, and that swapped the ROM
	// out from under whatever was executing. The loader marks the Pentagon
	// slot filled while it is still running, and Pentagon is the power-up
	// machine, so the swap happened mid-command - and since the interrupt
	// handler lives in the ROM at $0038, the very next frame vectored into
	// a different ROM's handler. The screen filled with rubbish there and
	// then. The dot command itself survived because it executes at $2000
	// in DivMMC RAM, which is why it could still finish printing.
	//
	// Held in the reset branch, so it tracks while reset is asserted and
	// freezes when it lifts: load the images, pick the machine, press
	// reset, and the new ROM is what comes up.
	// Clocked, not asynchronous. Written the obvious way -
	//
	//   always @(posedge clock or negedge reset_n)
	//       if (reset_n == 1'b0) rom_from_sd <= rom_sd_ready;
	//
	// it assigns a SIGNAL in the asynchronous reset branch rather than a
	// constant, which is outside the pattern synthesis recognises.
	// ModelSim runs it exactly as intended and Quartus inferred a latch
	// from it (Warning 10240), on combinational feedback with no timing
	// closed - and the board went back to filling the screen with rubbish
	// while simulation stayed clean. The clock does not stop during
	// reset, so a plain clocked register does the same job properly.
	always @(posedge clock) begin
		if (reset_n == 1'b0)
			rom_from_sd <= rom_sd_ready;
	end
	wire [4:0] mach_base   = slot_base(mach_slot);

	// TR-DOS paging, the Beta Disk rule: the ROM comes in on an opcode
	// fetch at $3Dxx while 48 BASIC is the selected half, and goes out
	// on the first fetch outside the ROM area.
	//
	// Gated on rom_from_sd, which is what makes it safe. TR-DOS and
	// DivMMC both trap $3Dxx, and an earlier attempt armed this whenever
	// slot 2 was filled - so it fired while ESXDOS was still running, ate
	// its own entry and the card would not initialise. But rom_from_sd is
	// exactly the state in which divmmc_maps has already stood the
	// automapper down, so in here there is nobody to conflict with.
	reg  trdos_paged = 1'b0;
	assign trdos_avail = rom_from_sd & (machine == MACHINE_PENT)
	                     & rom_slot_filled[2];

	// The fetch that triggers the entry has to come from the TR-DOS ROM
	// ALREADY. $3D00 is the address programs CALL to reach TR-DOS, and
	// if that first byte still comes from the BASIC ROM the caller gets
	// the character set - $3D00 there is the blank for "space", eight
	// zero bytes, which decode as NOPs and run on into $3D08 without
	// complaining. Everything downstream then happens one byte out of
	// step, and a program that enters TR-DOS to ask whether it is there
	// gets an answer built from the wrong first byte.
	//
	// A latch cannot deliver that byte. It takes effect on the following
	// clock, and this one was gated by the CPU clock enable on top, so
	// it landed a whole T-state after T80 had already latched what it
	// read. Same defect, and the same fix, as the DivMMC $3Dxx entry in
	// divmmc.v - which had to become combinational for exactly this
	// reason and for exactly this address.
	//
	// The exit keeps its register: it fires on a fetch at $4000 or above,
	// and that fetch reads RAM whichever way the ROM is switched, so
	// nothing depends on it being immediate.
	wire trdos_now = trdos_avail & (~cpu_m1_n) & (~cpu_mreq_n) & (~cpu_rd_n)
	                 & (cpu_a[15:8] == 8'h3d) & page_rom_sel;
	assign trdos_active = trdos_paged | trdos_now;

	always @(posedge clock) begin
		if (reset_n == 1'b0)
			trdos_paged <= 1'b0;
		else if (cpu_m1_n == 1'b0 && cpu_mreq_n == 1'b0 && cpu_rd_n == 1'b0) begin
			if (trdos_now == 1'b1)
				trdos_paged <= 1'b1;
			else if (cpu_a[15] == 1'b1 || cpu_a[14] == 1'b1)
				trdos_paged <= 1'b0;
		end
	end


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
			{3'b000, cpu_a[14], cpu_a[15:14]}; // A=bank: 01=101, 10=010
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
			(plus3_special == 1'b0) ? {3'b000, cpu_a[14], cpu_a[15:14]} :
			(plus3_special == 1'b1 && plus3_page == 2'b00) ? {4'b0000, cpu_a[15:14]} :
			(plus3_special == 1'b1 && plus3_page == 2'b01) ? {3'b000, 1'b1, cpu_a[15:14]} :
			(plus3_special == 1'b1 && plus3_page == 2'b10) ? {3'b000, ~(cpu_a[15] & cpu_a[14]), cpu_a[15:14]} :
			{3'b000, ~(cpu_a[15] & cpu_a[14]), (cpu_a[15] | cpu_a[14]), cpu_a[14]};
	end
	endgenerate

	// Latch SDRAM data at the end of the CPU's memory cycle.
	//
	// This used to be `always @(negedge cpu_cycle)`, i.e. clocked by a
	// logic-generated signal on ordinary routing. TimeQuest does not
	// recognise cpu_cycle as a clock at all (the design's clock list holds
	// only CLOCK_50 and the two PLL outputs), so that register's timing
	// was never analysed and its skew came out differently on every
	// build - which is exactly the behaviour seen on the board, where two
	// builds differing only in which signal drove an LED behaved
	// completely differently. Clocking it from the real 28MHz clock and
	assign ram_addr = {ram_page, cpu_a[13:0]};
	// instant while putting the path under proper timing analysis.
	// Captured one clock after the end of the CPU's slot, not on the edge
	// itself: sdram_ep4ce.v now latches read data internally at its q==0,
	// which lands just after cpu_cycle has already fallen. Sampling on
	// the falling edge therefore picked up the *previous* transaction's
	// byte - on the board that showed as the CPU fetching a constant
	// wrong value and spinning on address 0000 forever, with opcode
	// fetches still happening (so not a reset).
	assign ram_addr = {3'b000, ram_page, cpu_a[13:0]};

	// Moved above the arbiter, which reads ram_write: Quartus
	// accepts use-before-declaration, ModelSim does not.
	wire divmmc_lo_write = 1'b0;
	wire divmmc_hi_write = ~(divmmc_conmem & divmmc_mapram &
		~divmmc_sram_page[3] & ~divmmc_sram_page[2] &
		divmmc_sram_page[1] & divmmc_sram_page[0]);
	wire divmmc_write = (~cpu_a[13] & divmmc_lo_write) |
		(cpu_a[13] & divmmc_hi_write);
	// DivMMC's automapper stands down while the machine is running a ROM
	// out of a slot.
	//
	// It traps the reset fetch at $0000, and the trace says it wins it
	// outright: the first fetch after reset reads $0000 with paged_in
	// clear, and by the second the DivMMC page is in and the CPU is off
	// into ESXDOS. A loaded Pentagon or 128K image therefore never got
	// control at all, which is why every attempt on the board ended up in
	// the 48K BASIC no matter what had been loaded.
	//
	// The two cannot both own the reset vector, and once an image has
	// been loaded and the machine deliberately switched to it, that image
	// is what the user asked to run - ESXDOS has already done its job of
	// fetching it off the card. It comes back on a power cycle, which
	// clears the slot flags; a plain reset does not, so switching machine
	// and resetting brings the loaded ROM up rather than ESXDOS again.
	// A machine running a ROM out of the slots does not have DivMMC in
	// its map at all. Letting the two share was tried: see divmmc.v,
	// where the reason it produced a differently-behaved machine on
	// every attempt is written down. Getting a program onto a TR-DOS
	// machine is a job for a disk image in slot 3, not for ESXDOS.
	wire divmmc_maps = divmmc_paged_in & ~rom_from_sd;

	wire ext_ram_write = (rom_enable & esxdos_downloaded[1] & divmmc_maps & divmmc_write) & ~cpu_wr_n;
	wire int_ram_write = ram_enable & ~cpu_wr_n;
	wire ram_write = int_ram_write | ext_ram_write | romld_write;

	// ---------------------------------------------------------------
	// CPU/video SDRAM arbiter, after zx-sizif-512's ram_arbiter
	// (cpld/rtl/mem.sv).
	//
	// The old scheme nailed the CPU to one fixed SDRAM cycle per
	// 16-count window (counters 9-12) and gave video everything else.
	// That is not a bandwidth problem - a group of 8 pixels spans 8
	// SDRAM cycles and video only needs 2 of them - it is a rigidity
	// problem: an access that becomes ready just after counter 12 has
	// to sit out a whole window, and clocks.v papered over it with a
	// blanket wait state on every memory access. That cost ~0.15% of
	// the CPU's T-states, which is exactly what stops Pentagon demos
	// keeping time.
	//
	// Sizif inverts the priority: the CPU is served first and video
	// yields, because video asks far enough ahead that being pushed
	// back a cycle still leaves its data in time. Video therefore can
	// no longer read the bus at a fixed moment - it is handed its byte
	// with a data-valid strobe whenever the cycle happens to land.
	//
	// The step tag travels with the transaction rather than being read
	// from video's current state at capture time. Video has usually
	// moved on to its next request by then, and reading its live state
	// is what corrupted several earlier attempts at this.
	localparam OWN_NONE = 2'd0;
	localparam OWN_CPU  = 2'd1;
	localparam OWN_VID  = 2'd2;

	reg  [1:0]  cur_own  = OWN_NONE;   // owner of the cycle in flight
	reg  [1:0]  prev_own = OWN_NONE;   // owner of the cycle just finished
	reg  [20:0] cpu_addr_held = 21'd0;
	reg  [18:0] vid_addr_held = 19'd0;
	reg         cur_vid_step = 1'b0;
	reg         prev_vid_step = 1'b0;
	reg         cur_vid_gen = 1'b0;
	reg         prev_vid_gen = 1'b0;
	reg         cpu_served = 1'b0;
	reg         cpu_oe_held = 1'b0;
	reg         cpu_we_held = 1'b0;
	reg  [7:0]  cpu_di_held = 8'd0;
	reg         slot_tick_d = 1'b0;
	reg         slot_tick_d2 = 1'b0;

	// A request the CPU has made and that has not been answered yet.
	// esxdos_downloaded gates the DivMMC ROM because before the boot
	// copy has run there is nothing in SDRAM to fetch.
	wire cpu_needs_sdram = ram_enable |
		(rom_enable & divmmc_maps & esxdos_downloaded[1]) |
		(rom_enable & (rom_from_sd | trdos_active));
	// The loader's port write is served by the same arbiter as a memory
	// cycle - it is a write to SDRAM like any other, and the CPU is held
	// on WAIT until it is granted, exactly as it would be for a store.
	wire cpu_mem_active  = ((~cpu_mreq_n) & ((~cpu_rd_n) | (~cpu_wr_n)) & cpu_needs_sdram)
	                       | romld_write | romld_read | bdi_img_rd;
	// A CPU cycle is in flight while either the cycle running now or
	// the one that just ended belongs to the CPU - its answer only
	// lands two clocks after that cycle finishes.
	//
	// This was a separate flag, set at the grant and cleared when
	// prev_own said CPU. prev_own is the previous cycle's owner, so two
	// CPU cycles back to back cleared the flag two clocks after it was
	// set, while its own cycle was still running: the CPU could then be
	// granted again on top of an unfinished cycle, overwriting the held
	// address, and the answer was never credited. The request stayed up
	// with WAIT_n low and the CPU stopped for good - which is what the
	// board showed, 2511: waiting, with a request active and nothing
	// else holding it.
	wire cpu_inflight = (cur_own == OWN_CPU) | (prev_own == OWN_CPU);
	// A watchdog on top of that.
	//
	// The board still shows a request left outstanding with WAIT_n low
	// and the CPU stopped for good, so a way to deadlock remains that I
	// have not found by reading, and simulation does not reach it - the
	// workload there is far too thin. Rather than keep guessing on
	// hardware, a request that has waited more than sixteen cycle
	// boundaries is granted regardless.
	//
	// This is a backstop, not an explanation: it costs nothing when
	// things are healthy - a request is normally served within two
	// boundaries - and it keeps the machine running while the cause is
	// found.
	reg [4:0] cpu_stall_cnt = 5'd0;
	always @(posedge clock) begin
		if (cpu_mem_active == 1'b0 || cpu_served == 1'b1)
			cpu_stall_cnt <= 5'd0;
		else if (slot_tick == 1'b1 && cpu_stall_cnt != 5'd31)
			cpu_stall_cnt <= cpu_stall_cnt + 5'd1;
	end
	wire cpu_overdue = (cpu_stall_cnt >= 5'd16);

	wire cpu_wants = cpu_mem_active & ~cpu_served & (~cpu_inflight | cpu_overdue);
	wire vid_wants = ~vid_rd_n;

	wire [1:0] next_own = cpu_wants ? OWN_CPU :
	                      vid_wants ? OWN_VID : OWN_NONE;

	always @(posedge clock) begin
		slot_tick_d    <= slot_tick;
		slot_tick_d2   <= slot_tick_d;
		vid_data_valid <= 1'b0;
		vid_req_ack    <= 1'b0;

		if (slot_tick == 1'b1) begin
			prev_own      <= cur_own;
			prev_vid_step <= cur_vid_step;
			prev_vid_gen  <= cur_vid_gen;
			cur_own       <= next_own;
			// Hold the address for the whole cycle. sdram_ep4ce.v opens
			// the row at the start and selects the column three clk56
			// later, so an address that moves underneath it splits one
			// transaction across two different locations.
			if (next_own == OWN_CPU) begin
				cpu_addr_held <= cpu_addr;
				// The control signals are held for the whole cycle for
				// the same reason as the address: sdram_ep4ce.v opens
				// the row at q==0 but issues the read or write at
				// q==3, from whatever oe/we say at that moment. Live
				// signals that change in between turn one transaction
				// into half of two.
				cpu_oe_held   <= ((~cpu_mreq_n) & (~cpu_rd_n)) | romld_read | bdi_img_rd;  // a slot read-back is an IO cycle, so mreq_n is high
				cpu_we_held   <= ram_write;
				cpu_di_held   <= cpu_do;
			end
			if (next_own == OWN_VID) begin
				vid_addr_held <= vid_addr;
				cur_vid_step  <= vid_req_step;
				cur_vid_gen   <= vid_req_gen;
				vid_req_ack   <= 1'b1;
			end
		end

		// Two clocks after the boundary the finished cycle's byte has
		// been registered inside sdram_ep4ce.v and is stable on
		// sdram_do. This is the same instant the previous fixed-slot
		// design captured at, just reached by counting from the cycle
		// boundary instead of from a cpu_cycle edge.
		if (slot_tick_d2 == 1'b1) begin
			if (prev_own == OWN_CPU) begin
				mem_do <= sdram_do;
				// Sizif's cpu_read_misaddress: only answer the request
				// if the CPU is still asking about the address the
				// cycle actually fetched. Without this the answer can
				// be credited to a later access - after a write to X,
				// a read of X straight afterwards took the write
				// cycle's leftovers.
				// Overdue accepts the answer whatever the address says.
				// Granting alone was not enough: serving is only
				// credited on an address match, so if that match never
				// comes the request waits for ever however many cycles
				// it is given - which is what the board shows, a CPU
				// executing nothing with the interrupt arriving at its
				// own pin and no way to take it.
				if (cpu_addr_held == cpu_addr || cpu_overdue == 1'b1)
					cpu_served <= 1'b1;
			end
			if (prev_own == OWN_VID) begin
				vid_do         <= sdram_do;
				vid_data_valid <= 1'b1;
				vid_data_step  <= prev_vid_step;
				vid_data_gen   <= prev_vid_gen;
			end
		end

		// The request going away retires its answer with it, so nothing
		// is ever carried over into the next access.
		if (cpu_mem_active == 1'b0) begin
			cpu_served   <= 1'b0;
		end
	end

	// The CPU runs at a steady 3.5MHz and is held only while its own
	// data is genuinely outstanding.
	assign cpu_wait_n = ~(cpu_mem_active & ~cpu_served);

	// What T80 is actually given: held by the arbiter or by an in-flight
	// DivMMC SPI transfer, whichever wants it.
	assign cpu_wait_all_n = cpu_wait_n & divmmc_wait_n;

	// CPU data bus mux
	assign cpu_di =
		// System RAM
		(ram_enable == 1'b1) ? mem_do :
		// DIVMMC memory mapped into ROM area
		((rom_enable == 1'b1) && (divmmc_maps == 1'b1) && (esxdos_downloaded[1] == 1'b1)) ? mem_do :
		// a machine ROM loaded from the card lives in SDRAM too
		((rom_enable == 1'b1) && ((rom_from_sd == 1'b1) || (trdos_active == 1'b1))) ? mem_do :
		// the loader's status, so software can tell a missing file from
		// a loaded one before it switches machine
		(romld_read == 1'b1) ? mem_do :
		(romld_ctl_enable == 1'b1) ? {4'b0000, rom_slot_filled} :
		// Internal ROM
		(rom_enable == 1'b1) ? rom_do :
		// IO ports
		(ula_enable == 1'b1) ? ula_do :
		// Only 0xFFFD reads back. The AY drives the bus when BC1 is
		// high with BDIR low, which is A14 set - port 0xFFFD, the
		// register read. At 0xBFFD, A14 clear, both are low and the
		// chip is inactive, so a read there gets the idle bus and not
		// the selected register. psg_enable alone does not tell the two
		// apart, so this returned register data for both and Test 4.3
		// reported the port wrong.
		((psg_enable == 1'b1) && (cpu_a[14] == 1'b1)) ? psg_do :
		(bdi_img_rd == 1'b1) ? mem_do :
		(bdi_enable == 1'b1) ? bdi_do :
		(divmmc_enable == 1'b1) ? divmmc_do :
		// map kempston joystick port - no joystick hardware on this board, idle
		(kempston_enable == 1'b1) ? 8'b00000000 :
		// The floating bus on port 0xFF. A read of an unattached port
		// picks up whatever the ULA is fetching, which programs use to
		// find where the raster is. zx-sizif-512 gives this to port
		// 0xFF alone and not on the +2A/+3, and so does this.
		((~cpu_ioreq_n) && (cpu_m1_n == 1'b1) && (cpu_a[7:0] == 8'hFF)
		 && (vid_port_ff_active == 1'b1) && (machine != MACHINE_S3)) ? vid_port_ff_data :
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
			// The loader's write goes FIRST, ahead of the DivMMC mapping.
			//
			// It used to sit below it, and that was silently fatal: a dot
			// command runs with DivMMC paged in, so every byte it sent to
			// the port was addressed as DivMMC RAM instead of as the slot
			// - which is exactly the memory the command itself is
			// executing from. It overwrote its own code and ESXDOS's
			// workspace from the first byte, and being SDRAM the damage
			// survived a reset.
			//
			// The same two lines typed at the BASIC prompt worked
			// perfectly, because there DivMMC is not paged in and the
			// slot address won. That difference is what identified it.
			// romld_cnt[14:0], not romld_cnt.
			//
			// rom_addr is 20 bits and a slot is 32K, so the counter
			// contributes fifteen of them. Written with the whole 20-bit
			// counter the concatenation came to twenty-five bits, and
			// Verilog trims a too-wide value from the TOP - so
			// slot_base fell off the front and every slot was written at
			// address zero, one image on top of the last. Reads still
			// used the proper base, so the 128K slot came back holding
			// whatever had been written there last and the Pentagon and
			// TR-DOS slots came back holding nothing at all. No warning,
			// no error: the widths just quietly did not add up.
			//
			// The counter is 20 bits wide because the disk image needs
			// that reach, and the disk slot takes its own path through
			// cpu_addr rather than this one.
			(romld_write | romld_read) ? {slot_base(romld_slot), romld_cnt[14:0]} :
			trdos_active ? {slot_base(2'd2), 1'b0, cpu_a[13:0]} :
			((esxdos_downloaded[1] == 1'b1) && (divmmc_maps == 1'b1)) ? {1'b1, divmmc_addr} :
			// Otherwise access the internal ROM
			// a loaded 128K or Pentagon image, 32K via page_rom_sel
			rom_from_sd ? {mach_base, page_rom_sel, cpu_a[13:0]} :
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
			((esxdos_downloaded[1] == 1'b1) && (divmmc_maps == 1'b1)) ? {1'b1, divmmc_addr} :
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
			((esxdos_downloaded[1] == 1'b1) && (divmmc_maps == 1'b1)) ? {1'b1, divmmc_addr} :

			// Otherwise access the internal ROMs
			{4'b0000, plus3_page[1], page_rom_sel, cpu_a[13:0]};
	end
	endgenerate

	// first 1MB of sdram are used as ram, second 1MB sdram are used as rom
	// Both halves are combinational now. Holding the address still for
	// the whole of the SDRAM RAS->CAS sequence is the arbiter's job -
	// it captures cpu_addr into cpu_addr_held when it grants the cycle -
	// and doing it here as well only made the address the arbiter
	// captured a stale one.
	wire [19:0] disk_addr = 20'h40000 + romld_cnt;
	assign cpu_addr =
		bdi_img_rd ? {1'b0, 20'h40000 + bdi_img_addr} :
		((romld_write | romld_read) & disk_slot) ? {1'b0, disk_addr} :
		(ram_enable == 1'b1) ? {1'b0, ram_addr} : {1'b1, rom_addr};

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
	// Pentagon 1024 keeps its extra page bits in the top three bits of
	// the same 0x7FFD port, where a 128K has the paging lock and the
	// unused pair. Six bits give 64 banks of 16K.
	reg     [2:0] pram_hi;
	// Taken on the start of the OUT, not on the level while psg_clken
	// happens to be high.
	//
	// psg_clken fires once every 16 clocks and an IO cycle lasts about
	// 20, so whether a write to 0x7FFD was seen at all depended on
	// where the CPU's T-states happened to fall. Simulation of a
	// program that pages bank 1, then bank 2, then bank 1 again caught
	// it: only the middle OUT took effect, so the machine reported
	// itself as 48K however often software asked for a bank. This is
	// the same fault the DivMMC SPI strobe had, for the same reason.
	reg page_wr_d = 1'b0;
	wire page_wr = page_enable & ~cpu_wr_n;
	always @(posedge clock or negedge reset_n) begin
		if (reset_n == 1'b0) begin
			preg_disable <= 1'b0;
			prom_sel <= 1'b0;
			pshadow_scr <= 1'b0;
			pram_sel <= 3'b000;
			pram_hi  <= 3'b000;
			page_wr_d <= 1'b0;
		end else begin
			page_wr_d <= page_wr;
			if (page_wr == 1'b1 && page_wr_d == 1'b0 && preg_disable == 1'b0) begin
				// On Pentagon 1024 bit 5 is a page bit, not the paging
				// lock, so the lock must never engage there - otherwise
				// the first write selecting a high bank would freeze the
				// port for good.
				preg_disable <= ext1024 ? 1'b0 : cpu_do[5];
				prom_sel <= cpu_do[4];
				pshadow_scr <= cpu_do[3];
				pram_sel <= cpu_do[2:0];
				// Bits 7:5 are an extended bank number only when the
				// 1024K extension is on. On a plain 128K or a Pentagon
				// bit 5 is the paging lock and 6:7 mean nothing, so
				// taking them as bank bits regardless moved the bank at
				// $C000 by eight the moment anything wrote the lock -
				// and the machine lost the RAM out from under itself.
				// Test v4.3 hung exactly there, on its $7FFD test.
				pram_hi  <= ext1024 ? cpu_do[7:5] : 3'b000;
			end
		end
	end
	assign page_reg_disable = preg_disable;
	assign page_rom_sel = prom_sel;
	assign page_shadow_scr = mem128 & pshadow_scr;
	// In 48K mode the paging register still exists and can be written,
	// but has no effect: bank 0 at 0xC000 and the normal screen is
	// exactly the 48K machine's layout.
	assign page_ram_sel =
		(mem128 == 1'b0)  ? 6'b000000 :
		(ext1024 == 1'b1) ? {pram_hi, pram_sel} :
		                    {3'b000, pram_sel};

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

	// DIAGNOSTIC: display the SDRAM readback verify result instead of the
	// live PC. 0000 = all 8192 bytes of the ESXDOS image read back out of
	// SDRAM exactly as written, so the SDRAM round-trip is sound and the
	// DivMMC fault lies elsewhere. Any other value = number of mismatching
	// bytes, i.e. the ROM image the CPU is actually executing is corrupt.
	// DIAGNOSTIC: boot copy address, so a stalled copy shows where it stopped
	// address of the first fetch that landed in the DivMMC sram-page
	// window - stable, unlike a live PC, and says exactly where a jump
	// into uninitialised page memory happened
	// DIAGNOSTIC: count CPU clock enables between frame interrupts, i.e.
	// how many T-states the CPU actually gets per frame. Shown divided
	// by 16, so Sinclair's 69888 reads as 1110 and Pentagon's 71680 as
	// 1180. Anything well below that is the shortfall the Pentagon demos
	// are complaining about.
	reg [19:0] tcount     = 20'd0;
	reg [19:0] tcount_lat = 20'd0;
	reg        irq_prev   = 1'b1;
	always @(posedge clock) begin
		irq_prev <= vid_irq_n;
		if (irq_prev == 1'b1 && vid_irq_n == 1'b0) begin
			tcount_lat <= tcount;
			tcount     <= 20'd0;
		end else if (cpu_clken == 1'b1) begin
			tcount <= tcount + 20'd1;
		end
	end

	reg [15:0] pc_slow = 16'd0;
	reg [22:0] pc_slow_cnt = 23'd0;
	reg        pc_arm = 1'b0;
	always @(posedge clock) begin
		pc_slow_cnt <= pc_slow_cnt + 23'd1;
		// arm on the tick, then take the next opcode fetch. Requiring the
		// tick and the fetch in the same cycle - as a first attempt did -
		// is a coincidence that almost never happens, so the display just
		// sat at its initial value and read as a hang at 0000.
		if (pc_slow_cnt == 23'd0)
			pc_arm <= 1'b1;
		else if (pc_arm && (prev_cpu_m1_n == 1'b1) && (cpu_m1_n == 1'b0)) begin
			pc_slow <= cpu_a;
			pc_arm  <= 1'b0;
		end
	end
	// "3.5" for the CPU clock on the two left digits, then a blank, then
	// the upper RAM page on the right. While the interrupt trim is
	// non-zero it takes over the right-hand pair.
	// Page number in decimal, so it reads the way software counts banks.
	// Pentagon 1024 goes to 63, hence two digits; the tens digit is
	// blanked below 10 so a 128K machine still shows a single figure.
	reg [3:0] pg_tens;
	reg [3:0] pg_units;
	always @* begin
		if (page_ram_sel >= 6'd60) begin
			pg_tens = 4'd6; pg_units = page_ram_sel - 6'd60;
		end else if (page_ram_sel >= 6'd50) begin
			pg_tens = 4'd5; pg_units = page_ram_sel - 6'd50;
		end else if (page_ram_sel >= 6'd40) begin
			pg_tens = 4'd4; pg_units = page_ram_sel - 6'd40;
		end else if (page_ram_sel >= 6'd30) begin
			pg_tens = 4'd3; pg_units = page_ram_sel - 6'd30;
		end else if (page_ram_sel >= 6'd20) begin
			pg_tens = 4'd2; pg_units = page_ram_sel - 6'd20;
		end else if (page_ram_sel >= 6'd10) begin
			pg_tens = 4'd1; pg_units = page_ram_sel - 6'd10;
		end else begin
			pg_tens = 4'd0; pg_units = page_ram_sel[3:0];
		end
	end

	// The display carries whichever trim was touched last, named by a
	// letter so there is no doubt which one is on it:
	//
	//   A0nn  interrupt position, F1 and F2, a pixel a press
	//   d0nn  interrupt line, F3 and F4, a sixteenth of a line a press
	//   C0nn  contention window, KEY2 and KEY3, a T-state a press
	//
	// It used to pick by a fixed priority, with the contention window
	// first. Set that one with the board buttons and the display stayed
	// on it, so pressing F3 or F4 changed a number that was not being
	// shown - which on the board looked exactly like the keys being
	// dead. That is the fifth instrument in this project to report
	// something other than what it was being asked about.
	//
	// With every trim at zero it goes back to "3.5" and the page.
	// Also shown once the contention model is moved off its default, so
	// which variant is running can be read off the board.
	//   E0nn  IO contention window, keypad - and +, a T-state a press
	wire any_trim = (cont_adj != 5'd0) || (cont_model != 2'd1)
	                || (io_adj != 5'd0);


	// The left pair carries the CPU speed: 3.5, 7.0, 14, 28. The two
	// slower ones take a decimal point after the first digit, which is
	// also where "3.5" came from before there was anything to choose.
	wire [3:0] spd_hi = (cpu_speed == 2'd0) ? 4'd3 :
	                    (cpu_speed == 2'd1) ? 4'd7 :
	                    (cpu_speed == 2'd2) ? 4'd1 : 4'd2;
	wire [3:0] spd_lo = (cpu_speed == 2'd0) ? 4'd5 :
	                    (cpu_speed == 2'd1) ? 4'd0 :
	                    (cpu_speed == 2'd2) ? 4'd4 : 4'd8;

	// Diagnostic: where the CPU is, and whether it is still moving.
	//
	// The four digits carry the FULL address of the last opcode fetch.
	// The high byte alone said Test v4.3 stops somewhere in the ROM; it
	// takes all sixteen bits to say where in it.
	//
	// While the CPU is running the reading is a sample refreshed twice a
	// second, so it flickers across whatever is executing. Once nothing
	// has been fetched for about a third of a second the CPU is not
	// running at all, and the display freezes on the last fetch it
	// managed - the address it died at. The decimal points come on to
	// say the number is frozen rather than sampled, so a still display
	// cannot be mistaken for a slow one.
	//
	// A frozen reading also says something the value itself cannot: the
	// CPU is stopped part-way through an instruction, not looping. A
	// loop of even two instructions would show a different one of them
	// at each refresh.
	// Every lamp below reports the same shape of fact - "this has been
	// true without a break for about a third of a second" - so a steady
	// lamp means a fault and a dark one means health. The first version
	// mixed live signals in with latched ones, and a lamp that is lit
	// half the time in normal running says nothing at all.
	localparam DIAG_GAP = 24'd9000000;   // ~1/3 second at 28MHz

	reg [15:0] opa_last = 16'h0000;
	reg [15:0] opa_prev = 16'h0000;
	reg [15:0] opa_show = 16'h0000;
	// Where the $3Dxx page was entered FROM. Knowing the machine stops
	// at $3D2A says almost nothing on its own - that address is the
	// middle of an operand in the TR-DOS ROM, so nothing can be calling
	// it deliberately, and it is the same number in both machines. What
	// decides this is which instruction jumped into the page, and that
	// is one register's worth of history.
	reg [15:0] caller   = 16'h0000;
	reg [15:0] ring0 = 16'h0000, ring1 = 16'h0000;
	reg [15:0] ring2 = 16'h0000, ring3 = 16'h0000;
	reg [15:0] sh0   = 16'h0000, sh1   = 16'h0000;
	reg [15:0] sh2   = 16'h0000, sh3   = 16'h0000;
	reg [23:0] pc_div   = 24'd0;
	reg [2:0]  ph_cnt     = 3'd0;
	reg [2:0]  diag_frame = 3'd0;
	reg [7:0]  op_last    = 8'h00;  // the byte the last fetch was given
	reg        m1_now_d = 1'b0;
	reg [23:0] m1_gap   = 24'd0;   // clocks since a fetch last STARTED
	reg [23:0] wt_gap   = 24'd0;   // clocks the arbiter has held WAIT
	reg [23:0] dw_gap   = 24'd0;   // clocks the SPI has held WAIT
	reg [23:0] dm_gap   = 24'd0;   // clocks DivMMC has stayed paged in
	reg [23:0] ce_gap   = 24'd0;   // clocks since the CPU was last clocked
	reg        cpu_dead = 1'b0;
	reg        arb_hold = 1'b0;
	reg        spi_hold = 1'b0;
	reg        dm_stuck = 1'b0;
	reg        ce_dead  = 1'b0;
	wire       m1_now   = (cpu_mreq_n == 1'b0) & (cpu_rd_n == 1'b0)
	                      & (cpu_m1_n == 1'b0);
	always @(posedge clock) begin
		m1_now_d <= m1_now;

		// The START of a fetch, not the fact that one is in progress.
		// While the CPU is held on WAIT, MREQ, RD and M1 all stay
		// asserted for as long as it is stopped, so testing the level
		// reports a frozen CPU as a healthy one - which is precisely
		// what the first version of this did, and why it showed a
		// stable address with the "stopped" lamp dark.
		if (m1_now == 1'b1 && m1_now_d == 1'b0) begin
			opa_prev <= opa_last;
			opa_last <= cpu_a;
			// Four fetches deep, so the loop can be read rather than
			// guessed at. One address told us the CPU sits at $35AA with
			// $70 under it, and $70 is LD (HL),B - an instruction that
			// cannot jump anywhere, so it cannot be the whole loop. Four
			// consecutive fetches, snapshotted together, are the loop.
			ring0 <= cpu_a;
			ring1 <= ring0;
			ring2 <= ring1;
			ring3 <= ring2;
			// The first fetch of a run inside $3Dxx: remember what was
			// executing just before it. Fetches that were already in
			// the page do not overwrite it, so this keeps the way in
			// rather than the last step of the wander that follows.
			if (cpu_a[15:8] == 8'h3d && opa_last[15:8] != 8'h3d)
				caller <= opa_last;
			m1_gap   <= 24'd0;
			cpu_dead <= 1'b0;
		end
		else if (m1_gap >= DIAG_GAP) begin
			cpu_dead <= 1'b1;
		end else begin
			m1_gap <= m1_gap + 24'd1;
		end

		// The byte, taken on the level rather than the edge: at the
		// start of a fetch the bus has not answered yet. For a fetch
		// that completes this settles on the real byte; for one that
		// never completes it holds whatever the bus last carried, which
		// is why it is only worth reading next to the "CPU stopped" bit.
		if (m1_now == 1'b1)
			op_last <= cpu_di;

		// Which of the two WAIT sources is doing it. They are wired
		// together into one pin, so from the CPU's side they are
		// indistinguishable, and they have nothing in common as faults.
		if (cpu_wait_n == 1'b1) begin
			wt_gap   <= 24'd0;
			arb_hold <= 1'b0;
		end else if (wt_gap >= DIAG_GAP) begin
			arb_hold <= 1'b1;
		end else begin
			wt_gap <= wt_gap + 24'd1;
		end

		if (divmmc_wait_n == 1'b1) begin
			dw_gap   <= 24'd0;
			spi_hold <= 1'b0;
		end else if (dw_gap >= DIAG_GAP) begin
			spi_hold <= 1'b1;
		end else begin
			dw_gap <= dw_gap + 24'd1;
		end

		// DivMMC paged in is normal - it is paged in for every ESXDOS
		// call - but paged in without a break for a third of a second
		// while an ordinary program runs means its exit was missed, and
		// the machine is reading ESXDOS's RAM where it believes it is
		// reading ROM. When that happens the digits stop showing the PC
		// and show the address of the fetch that armed the automapper
		// instead, which says whether a trap fired that should not have
		// or an exit was lost.
		if (divmmc_paged_in == 1'b0) begin
			dm_gap   <= 24'd0;
			dm_stuck <= 1'b0;
		end else if (dm_gap >= DIAG_GAP) begin
			dm_stuck <= 1'b1;
		end else begin
			dm_gap <= dm_gap + 24'd1;
		end

		// And whether it is being clocked at all. A stopped clock enable
		// and a CPU held on WAIT look identical from outside - both stop
		// fetching - so the two are worth telling apart before guessing.
		if (cpu_clken_gated == 1'b1) begin
			ce_gap  <= 24'd0;
			ce_dead <= 1'b0;
		end else if (ce_gap >= DIAG_GAP) begin
			ce_dead <= 1'b1;
		end else begin
			ce_gap <= ce_gap + 24'd1;
		end

		// Three frames of two seconds each: the last fetch address, the
		// address the $3Dxx page was entered from, and a word of state.
		// Points 1 and 2 are the frame number and nothing else - a point
		// that means "frame 2" on one turn and "TR-DOS paged" on the
		// next is how a reading gets misread, and this display has
		// already been misread twice.
		pc_div <= pc_div + 24'd1;
		if (pc_div >= 24'd13999999) begin
			pc_div <= 24'd0;
			ph_cnt <= ph_cnt + 3'd1;
			if (ph_cnt == 3'd3) begin
				ph_cnt     <= 3'd0;
				diag_frame <= (diag_frame == 3'd5) ? 3'd0
				                                   : diag_frame + 3'd1;
			end
		end
		if (cpu_dead == 1'b1 || pc_div >= 24'd13999999) begin
			opa_show <= opa_last;
			// All four together, so they really are four consecutive
			// fetches and not a mixture of two passes round the loop.
			sh0 <= ring0;
			sh1 <= ring1;
			sh2 <= ring2;
			sh3 <= ring3;
		end
	end
	// Frame 2, the state word, reading left to right:
	//
	//   digit 3  bit3 CPU stopped fetching   bit2 arbiter holding WAIT
	//            bit1 CPU is HALTed           bit0 DivMMC paged in
	//   digit 2  bit3 TR-DOS ROM paged in    bit2 TR-DOS available here
	//            bit1 ROM from the SD slots  bit0 48 BASIC half selected
	//   digits 1-0  the byte the last fetch was given
	//
	// The byte is what settles which ROM answered: $FF is TR-DOS padding,
	// $4D is LD C,L in the 48 BASIC ROM's string routine, $45 is the
	// keyword table in the 128 menu ROM. The same address means a
	// different thing in each.
	wire [15:0] diag_stat = {cpu_dead, arb_hold, ~cpu_halt_n, divmmc_paged_in,
	                         trdos_active, trdos_avail, rom_from_sd,
	                         page_rom_sel, op_last};

	// Six frames now. Frames 0, 3, 4 and 5 are four consecutive opcode
	// fetches, newest first, so a loop can be read off the display
	// instead of inferred from one address.
	wire [15:0] diag_show = (diag_frame == 3'd0) ? sh0       :
	                        (diag_frame == 3'd1) ? caller    :
	                        (diag_frame == 3'd2) ? diag_stat :
	                        (diag_frame == 3'd3) ? sh1       :
	                        (diag_frame == 3'd4) ? sh2       : sh3;
	wire [3:0] pc_nibble = (digit_scan == 2'd3) ? diag_show[15:12] :
	                       (digit_scan == 2'd2) ? diag_show[11:8]  :
	                       (digit_scan == 2'd1) ? diag_show[7:4]   :
	                                              diag_show[3:0];

	// Silkscreen numbering runs opposite to the LED[] index, so LED[3] is
	// the leftmost lamp (silkscreen LED1) and LED[0] the rightmost
	// (LED4). Active low.
	//
	// The four lamps are now the four slot flags. Whether a machine comes
	// up on a ROM loaded from the card is decided by these four bits and
	// nothing else, so when a menu does not appear this is the first
	// thing worth seeing. They are set by the loader, and cleared only by
	// reconfiguring the FPGA or by F11 with SPACE held down.
	//
	//   LED1, leftmost  - 128K slot filled
	//   LED2            - Pentagon slot filled
	//   LED3            - TR-DOS slot filled
	//   LED4, rightmost - disk image slot filled
	assign LED[3] = ~rom_slot_filled[0];
	assign LED[2] = ~rom_slot_filled[1];
	assign LED[1] = ~rom_slot_filled[2];
	assign LED[0] = ~rom_slot_filled[3];

	wire [3:0] nibble = pc_nibble;
	wire [3:0] nibble_unused = any_trim ?
	                    ((trim_show == 2'd1) ?
	                     ((digit_scan == 2'd3) ? 4'he :  // E, IO window
	                      (digit_scan == 2'd2) ? 4'd0 :
	                      (digit_scan == 2'd1) ? {3'b000, io_adj[4]} :
	                                             io_adj[3:0]) :
	                     ((digit_scan == 2'd3) ? 4'hc :  // C, contention window
	                      (digit_scan == 2'd2) ? {2'b00, cont_model} :
	                      (digit_scan == 2'd1) ? {3'b000, cont_adj[4]} :
	                                             cont_adj[3:0])) :
	                    (digit_scan == 2'd3) ? spd_hi :
	                    (digit_scan == 2'd2) ? spd_lo :
	                    (digit_scan == 2'd1) ? pg_tens :
	                                           pg_units;

	wire digit_blank = 1'b0;
	wire digit_blank_unused = any_trim ? 1'b0 :
	                   ((digit_scan == 2'd1) && (page_ram_sel < 6'd10));
	// decimal point after the 3, and on the page digit while DivMMC is
	// paged in
	// Point after the first digit only where the speed has a fraction -
	// "3.5" and "7.0" - not on "14" or "28".
	// The decimal points are four more free bits: the point is scanned
	// per digit like the segments are, so each one can carry something
	// different. What they say is which memory the address on the digits
	// above them actually belongs to - the same number means completely
	// different things depending on what is paged in, and reading it
	// wrong is how an address in ESXDOS's own RAM gets looked up in a
	// ROM listing.
	//
	//   no points        - frame 0, the address of the last opcode fetch
	//   point 1 only     - frame 1, the address $3Dxx was entered from
	//   point 2 only     - frame 2, the state word decoded above
	//
	// Points 3 and 4 stay dark. Everything they used to carry has moved
	// into the state word, where it is read as a number instead of being
	// squinted at.
	// The frame number in binary across the first three points: point 1
	// is bit 0, point 2 is bit 1, point 3 is bit 2. Nothing else uses
	// them, so a point never means two things.
	wire digit_dp    = (digit_scan == 2'd3) ? diag_frame[0] :
	                   (digit_scan == 2'd2) ? diag_frame[1] :
	                   (digit_scan == 2'd1) ? diag_frame[2] :
	                                          1'b0;
	wire digit_dp_unused = ((digit_scan == 2'd3) &&
	                    (any_trim || (cpu_speed == 2'd0) || (cpu_speed == 2'd1))) ||
	                   (divmmc_paged_in && (digit_scan == 2'd0));

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
	// REVERTED: a b/f segment swap was added here on the theory that the
	// board wired those two segments crossed ("3" appearing as a mirrored
	// "6"). It made every digit unreadable, so the wiring is in fact
	// standard - the original odd-looking digit was a persistence blur
	// from the display showing a rapidly-changing value (the PC), not a
	// wiring fault. Straight mapping.
	wire [6:0] seg_out = digit_blank ? 7'b0000000 : seg_gfedcba;
	assign SEG[6:0] = SEG_ACTIVE_LOW ? ~seg_out : seg_out;
	assign SEG[7] = SEG_ACTIVE_LOW ? ~digit_dp : digit_dp;

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

	// Connect ULA to video output. This board has a single pin per colour
	// channel, so the ULA's 4-bit levels cannot be output directly - but
	// the BRIGHT attribute can still be reproduced by switching the pin
	// on and off within each pixel and letting the monitor average it.
	//
	// video.v builds each channel as {colour, {3{bright & colour}}}, so
	// bit 3 says whether the colour is present at all and bit 0 says
	// whether it is bright. One PWM period is exactly one pixel: the
	// pixel clock is 7MHz and this counter runs on the 56MHz clock, so
	// eight steps fit per pixel. Bright colours stay on for all eight,
	// normal ones for six - about the 3/4 ratio between the two levels
	// on a real Spectrum.
	assign zx_red = vid_r_out[3];
	assign zx_green = vid_g_out[3];
	assign zx_blue = vid_b_out[3];

	reg [2:0] pwm_cnt = 3'd0;
	always @(posedge clk56) pwm_cnt <= pwm_cnt + 3'd1;
	wire pwm_dim = (pwm_cnt < 3'd6);   // 6/8 duty

	assign VGA_R = zx_red   & (vid_r_out[0] | pwm_dim);
	assign VGA_G = zx_green & (vid_g_out[0] | pwm_dim);
	assign VGA_B = zx_blue  & (vid_b_out[0] | pwm_dim);
	// 15kHz mode: composite (H^V) sync on VGA_HS, VGA_VS unused/high
	assign VGA_HS = vid_hcsync_n;
	assign VGA_VS = 1'b1;


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
			sdram_di = boot_copy_rom_do;
			// pass 0 (boot_copy_addr[13]=0): fixed ROM location, same
			// address layout as rom_addr's DivMMC {1'b1, divmmc_addr}
			// mapping with conmem=1 or mapram=0: {6'b000000, addr[12:0]}.
			// pass 1: the mapram location (conmem=0, mapram=1):
			// {6'b010011, addr[12:0]} - see boot_copy_addr comment above
			sdram_addr = boot_copy_addr[13] ?
				{4'b0000, 2'b11, 6'b010011, boot_copy_addr[12:0]} :
				{4'b0000, 2'b11, 6'b000000, boot_copy_addr[12:0]};
		end else if (boot_zero_wr == 1'b1) begin
			// zeroing the DivMMC sram pages: {2'b11, 2'b01, page, offset}
			sdram_oe = 1'b0;
			sdram_we = 1'b1;
			sdram_di = 8'h00;
			sdram_addr = {4'b0000, 2'b11, 2'b01, boot_zero_addr[16:13], boot_zero_addr[12:0]};
		end else if (cur_own == OWN_CPU) begin
			// All held at the grant, see the arbiter above.
			sdram_oe = cpu_oe_held;
			sdram_we = cpu_we_held;
			sdram_di = cpu_di_held;
			// The held address, not the live one: the CPU may move on
			// mid-cycle, and sdram_ep4ce.v needs one address for the
			// whole RAS-to-CAS sequence.
			sdram_addr = {4'b0000, cpu_addr_held};
		end else if (cur_own == OWN_VID) begin
			sdram_oe = 1'b1;
			sdram_we = 1'b0;    // video never writes
			sdram_di = 8'b00000000;
			sdram_addr = {6'b000000, vid_addr_held};
		end else begin
			// nobody asked for this cycle - leave it idle so
			// sdram_ep4ce.v can slot a refresh into it
			sdram_oe = 1'b0;
			sdram_we = 1'b0;
			sdram_di = 8'b00000000;
			sdram_addr = {6'b000000, vid_addr_held};
		end
	end

endmodule
