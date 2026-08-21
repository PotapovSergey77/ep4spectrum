// bdi - Beta Disk Interface, enough of a VG93/WD1793 for TR-DOS
//
// Copyright (c) 2026 Sergey Potapov (potapov.sergey.77@gmail.com)
//
// The ports only answer while the TR-DOS ROM is paged in, which is how a
// real Beta interface behaves and what keeps them out of the way of
// everything else on the bus:
//
//   $1F  write: command      read: status
//   $3F  track               $5F  sector          $7F  data
//   $FF  write: drive/side/density/reset   read: INTRQ and DRQ
//
// Sector data comes out of a disk image sitting in SDRAM, addressed the
// way a .trd is laid out: (track * sides + side) * 16 sectors of 256
// bytes. Reads only for now - writing would need the image carried back
// to the card, which is a separate piece of machinery.
//
// What this is NOT: no track formatting, no write track, no CRC
// generation, no write path. TR-DOS reads a catalogue and loads files
// with RESTORE, SEEK, STEP, READ SECTOR and READ ADDRESS, and those are
// what is here.

module bdi (
	input             clk,
	input             clken,       // CPU clock enable
	input             reset_n,

	// Bus, already qualified: only asserted while TR-DOS is paged in
	input             enable,
	input      [7:0]  a,
	input             wr_n,
	input             rd_n,
	input      [7:0]  din,
	output reg [7:0]  dout,

	// Is there an image to read at all
	input             disk_present,

	// Where in the image the next byte is. The read itself is done by
	// the top level on the CPU's own data-register read, holding the CPU
	// on WAIT exactly as an ordinary memory access does - the same
	// path the ROM slots are read back through, and already proven.
	output reg [19:0] img_addr,
	output            img_busy
);

	// --- register file ------------------------------------------------
	reg [7:0] r_track  = 8'h00;
	reg [7:0] r_sector = 8'h01;
	reg [7:0] r_data   = 8'h00;
	reg [7:0] r_system = 8'h00;   // $FF: drive, side, density, reset

	// Head position, kept separately from the track register: TR-DOS
	// writes the track register itself during a seek, and the two only
	// agree once the seek has finished.
	reg [7:0] head     = 8'h00;

	reg       intrq    = 1'b0;
	reg       drq      = 1'b0;
	reg       busy     = 1'b0;
	reg       seek_err = 1'b0;
	reg       crc_err  = 1'b0;
	reg       rec_nf   = 1'b0;

	wire      side     = ~r_system[4];   // $FF bit 4 is side select, active low
	// The Beta decode: A7 low picks a controller register with A6:A5,
	// A7 high is the system port. Written as a[6:0] comparisons instead,
	//  matched the data register as well - its low seven bits ARE
	//  - and since data was tested first, every poll of  for intrq
	// and drq came back with the data register. tr-dos waited on flags it
	// was never shown, which is why list hung without an error.
	wire      sel_cmd  = ~a[7] & (a[6:5] == 2'b00);
	wire      sel_trk  = ~a[7] & (a[6:5] == 2'b01);
	wire      sel_sec  = ~a[7] & (a[6:5] == 2'b10);
	wire      sel_dat  = ~a[7] & (a[6:5] == 2'b11);
	wire      sel_sys  =  a[7];

	// --- sector transfer ----------------------------------------------
	//
	// A .trd is (track * sides + side) * 16 sectors of 256 bytes, and
	// TR-DOS numbers sectors from 1. Sixteen 256-byte sectors is exactly
	// 4K a side, so the arithmetic is shifts.
	// A cylinder is BOTH sides - 2 x 16 x 256 - so it is 8192 bytes, not
	// 4096. Written as track * 4096 the sides overlapped one cylinder
	// apart, which reads correctly on track 0 and nowhere else.
	wire [19:0] trk_off  = {r_track[6:0], 13'h0000}; // cylinder * 8192
	wire [19:0] side_off = side ? 20'h01000 : 20'h00000;
	wire [19:0] sec_off  = {8'h00, (r_sector - 8'd1), 8'h00}; // (sector-1)*256

	reg  [7:0]  xfer_cnt = 8'h00;     // bytes left in this sector
	reg         reading  = 1'b0;
	assign      img_busy = reading;

	// --- READ ADDRESS ---------------------------------------------------
	//
	// Six bytes: track, side, sector, sector-length code, and two CRC
	// bytes. TR-DOS uses this to find out what is under the head, and
	// with nothing answering it decides there is no disk - which is what
	// CAT and LIST were both reporting. It is served from here rather
	// than out of the image, so img_busy stays low and the top level
	// leaves the data register to us.
	reg  [2:0]  adr_idx = 3'd0;
	reg         rd_adr  = 1'b0;

	// Which status word the command register reads back.
	//
	// A 1793 answers with the status for the type of the LAST COMMAND
	// WRITTEN, and holds that until another command is written. Keying it
	// on a transfer being in progress instead meant that the moment a
	// sector finished, the answer flipped back to type I - and type I bit
	// 5 is "head loaded", permanently 1 here, which in type I is nothing
	// and in type II is WRITE FAULT. So every completed read was reported
	// as a failure, and bits 2 and 1 of type I - track 0, and the index
	// pulse coming and going - changed which sector it blamed. That is
	// the "Disk Error Trk 0 Sec 9", and then Sec 1, and then Sec 15.
	reg         type2   = 1'b0;
	wire [7:0]  adr_byte = (adr_idx == 3'd0) ? r_track       :
	                       (adr_idx == 3'd1) ? {7'd0, side}  :
	                       (adr_idx == 3'd2) ? 8'd1          :  // sector 1
	                       (adr_idx == 3'd3) ? 8'd1          :  // 256 bytes
	                                           8'h00;           // CRC

	// --- index pulse ----------------------------------------------------
	//
	// A drive with a disk in it produces one index pulse per revolution,
	// 300rpm, so 200ms apart and about 4ms long. TR-DOS watches for them
	// to decide whether there is anything in the drive at all, and a
	// status bit wired permanently to zero says the disk is not turning.
	// That is a different answer from "not ready" and reaches the same
	// place: No disk.
	//
	// Gated on there being an image, so an empty drive still reports an
	// empty drive - truthfully this time, rather than by omission.
	localparam IDX_PERIOD = 23'd5599999;   // 200ms at 28MHz
	localparam IDX_WIDTH  = 23'd112000;    // 4ms
	reg  [22:0] idx_cnt = 23'd0;
	wire        index   = disk_present & (idx_cnt < IDX_WIDTH);
	always @(posedge clk) begin
		if (idx_cnt >= IDX_PERIOD) idx_cnt <= 23'd0;
		else                       idx_cnt <= idx_cnt + 23'd1;
	end

	// --- one action per bus cycle ---------------------------------------
	//
	// IORQ, RD/WR and the port address hold for the CPU's whole IN or
	// OUT, which is many clocks, so anything driven off the level happens
	// over and over. divmmc.v learnt this the hard way - on the level,
	// one IN pushed several bytes through the SPI engine - and this file
	// repeated the mistake in three places. A STEP IN moved the head once
	// per clock enable inside the write; a read of the data register
	// stepped the image pointer several times per byte, and stepped it
	// WHILE the arbiter was still fetching, so the byte that came back
	// was not the byte at the address the read started with.
	//
	// Writes act on the start of the access, where the data is valid.
	// The data-register read acts on the END of it, once the CPU has
	// taken the byte - advancing at the start would hand it the next one.
	wire acc_wr = enable & ~wr_n;
	wire dat_rd = enable & ~rd_n & sel_dat;
	wire cmd_rd = enable & ~rd_n & sel_cmd;
	reg  acc_wr_d = 1'b0;
	reg  dat_rd_d = 1'b0;
	reg  cmd_rd_d = 1'b0;

	// --- command decode -------------------------------------------------
	localparam CMD_RESTORE = 4'h0, CMD_SEEK = 4'h1,
	           CMD_STEP    = 4'h2, CMD_STEPI = 4'h4, CMD_STEPO = 4'h6,
	           CMD_RDSEC   = 4'h8, CMD_RDADR = 4'hC, CMD_FORCE = 4'hD;

	always @(posedge clk or negedge reset_n) begin
		if (reset_n == 1'b0) begin
			r_track  <= 8'h00;
			r_sector <= 8'h01;
			r_data   <= 8'h00;
			r_system <= 8'h00;
			head     <= 8'h00;
			intrq    <= 1'b0;
			drq      <= 1'b0;
			busy     <= 1'b0;
			seek_err <= 1'b0;
			crc_err  <= 1'b0;
			rec_nf   <= 1'b0;
			reading  <= 1'b0;
			rd_adr   <= 1'b0;
			type2    <= 1'b0;
			adr_idx  <= 3'd0;
			xfer_cnt <= 8'h00;
			img_addr <= 20'h00000;
		end else begin
			acc_wr_d <= acc_wr;
			dat_rd_d <= dat_rd;
			cmd_rd_d <= cmd_rd;

			if (acc_wr == 1'b1 && acc_wr_d == 1'b0) begin
				if (sel_trk) r_track  <= din;
				if (sel_sec) r_sector <= din;
				if (sel_dat) r_data   <= din;
				if (sel_sys) r_system <= din;

				if (sel_cmd) begin
					intrq <= 1'b0;
					// Type II (read sector) and type III (read
					// address) answer with the type II status;
					// everything else with type I.
					type2 <= (din[7:5] == 3'b100) | (din[7:4] == CMD_RDADR);
					case (din[7:4])
					CMD_RESTORE: begin
						head  <= 8'h00;
						r_track <= 8'h00;
						intrq <= 1'b1;
						seek_err <= 1'b0;   // a head can always seek
					end
					CMD_SEEK: begin
						head  <= r_data;
						r_track <= r_data;
						intrq <= 1'b1;
						seek_err <= 1'b0;   // a head can always seek
					end
					CMD_STEPI: begin
						head <= head + 8'd1;
						if (din[4]) r_track <= r_track + 8'd1;
						intrq <= 1'b1;
					end
					CMD_STEPO: begin
						head <= head - 8'd1;
						if (din[4]) r_track <= r_track - 8'd1;
						intrq <= 1'b1;
					end
					CMD_STEP: begin
						intrq <= 1'b1;
					end
					CMD_RDSEC: begin
						if (disk_present == 1'b0) begin
							rec_nf <= 1'b1;
							intrq  <= 1'b1;
						end else begin
							rec_nf   <= 1'b0;
							crc_err  <= 1'b0;
							busy     <= 1'b1;
							reading  <= 1'b1;
							// DRQ, which nothing here ever set before.
							// The 1793 raises it to say a byte is
							// waiting, and the driver reads the data
							// register only when it sees it. There is no
							// mechanism here to make a byte late - the
							// image is in SDRAM - so it is true from the
							// moment the command is taken until the
							// sector is done.
							drq      <= 1'b1;
							xfer_cnt <= 8'h00;    // 256 bytes, wraps to 0
							img_addr <= trk_off + side_off + sec_off;
						end
					end
					CMD_RDADR: begin
						if (disk_present == 1'b0) begin
							rec_nf <= 1'b1;
							intrq  <= 1'b1;
						end else begin
							rec_nf  <= 1'b0;
							crc_err <= 1'b0;
							busy    <= 1'b1;
							rd_adr  <= 1'b1;
							adr_idx <= 3'd0;
							drq     <= 1'b1;
						end
					end
					CMD_FORCE: begin
						busy    <= 1'b0;
						reading <= 1'b0;
						rd_adr  <= 1'b0;
						drq     <= 1'b0;
						intrq   <= 1'b1;
					end
					default: intrq <= 1'b1;
					endcase
				end
			end

			// Reading the data register takes the byte and asks for the
			// next one, until the sector is done.
			if (dat_rd_d == 1'b1 && dat_rd == 1'b0) begin
				if (reading == 1'b1) begin
					if (xfer_cnt == 8'hff) begin
						reading <= 1'b0;
						busy    <= 1'b0;
						drq     <= 1'b0;
						intrq   <= 1'b1;
					end else begin
						xfer_cnt <= xfer_cnt + 8'd1;
						img_addr <= img_addr + 20'd1;
					end
				end else if (rd_adr == 1'b1) begin
					if (adr_idx == 3'd5) begin
						rd_adr <= 1'b0;
						busy   <= 1'b0;
						drq    <= 1'b0;
						intrq  <= 1'b1;
					end else begin
						adr_idx <= adr_idx + 3'd1;
					end
				end
			end

			// Reading the status register clears INTRQ, as a 1793 does.
			if (cmd_rd == 1'b1 && cmd_rd_d == 1'b0)
				intrq <= 1'b0;

			// $FF bit 2 low resets the controller
			if (acc_wr == 1'b1 && acc_wr_d == 1'b0 && sel_sys
			    && din[2] == 1'b0) begin
				busy    <= 1'b0;
				reading <= 1'b0;
				rd_adr  <= 1'b0;
				drq     <= 1'b0;
				intrq   <= 1'b0;
			end
		end
	end

	// --- what the CPU reads ---------------------------------------------
	//
	// Status, type I: bit 7 not ready, 6 protect, 5 head loaded,
	// 4 seek error, 3 CRC, 2 track 0, 1 index, 0 busy.
	// Type II: 7 not ready, 5 write fault, 4 record not found, 3 CRC,
	// 2 lost data, 1 DRQ, 0 busy.
	// Bit 7 is NOT READY, and it stays clear: a real drive with no disk
	// in it is still ready - the motor turns - and software finds out
	// there is no disk by failing to find a sector. Reporting not-ready
	// instead left TR-DOS polling for a drive that would never arrive,
	// so LIST simply never came back and printed no error at all.
	wire [7:0] status_t1 = {1'b0, 1'b0, 1'b1, seek_err, crc_err,
	                        (head == 8'h00), index, busy};
	wire [7:0] status_t2 = {1'b0, 1'b0, 1'b0, rec_nf, crc_err,
	                        1'b0, drq, busy};

	always @* begin
		if (sel_cmd)      dout = type2 ? status_t2 : status_t1;
		else if (sel_trk) dout = r_track;
		else if (sel_sec) dout = r_sector;
		else if (sel_dat) dout = rd_adr ? adr_byte : r_data;
		else if (sel_sys) dout = {intrq, drq, 6'b111111};
		else              dout = 8'hff;
	end

endmodule
