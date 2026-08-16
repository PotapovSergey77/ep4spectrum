// Copyright (c) 2026 Sergey Potapov (potapov.sergey.77@gmail.com)
//
// sdram_model.v
//
// Behavioral SDRAM model, just complete enough to validate
// sdram_ep4ce.v's ACTIVE -> READ/WRITE sequencing and the way
// spectrum_top.v paces its accesses. Models the 4M x 16 x 4 bank part
// on the EP4CE6E22C8 board: 12-bit row, 8-bit column, 2 bank bits.
//
// Deliberately not modelled: refresh timing/retention, tRP/tRC and
// friends, power-up sequencing rules. The question this exists to
// answer is purely "does a byte written at address X read back as the
// same byte at address X", which is about command/address sequencing,
// not analog retention.

`timescale 1ns/1ps

module sdram_model (
	inout  [15:0] sd_data,
	input  [11:0] sd_addr,
	input  [1:0]  sd_dqm,
	input  [1:0]  sd_ba,
	input         sd_cs,
	input         sd_we,
	input         sd_ras,
	input         sd_cas,
	input         clk
);

	// flat address = {ba, row, col}, matching sdram_ep4ce.v's split of
	// the 22-bit byte address it is handed (row=addr[19:8],
	// ba=addr[21:20], col=addr[7:0])
	reg [15:0] mem [0:4194303];

	reg [11:0] active_row [0:3];

	wire [3:0] cmd = {sd_cs, sd_ras, sd_cas, sd_we};

	localparam CMD_NOP          = 4'b0111;
	localparam CMD_ACTIVE       = 4'b0011;
	localparam CMD_READ         = 4'b0101;
	localparam CMD_WRITE        = 4'b0100;
	localparam CMD_PRECHARGE    = 4'b0010;
	localparam CMD_AUTO_REFRESH = 4'b0001;
	localparam CMD_LOAD_MODE    = 4'b0000;

	// CAS latency 3 read pipeline
	reg [15:0] rd_data [0:3];
	reg        rd_valid [0:3];

	integer i;
	initial begin
		for (i = 0; i < 4; i = i + 1) begin
			rd_valid[i] = 1'b0;
			rd_data[i]  = 16'h0000;
			active_row[i] = 12'h000;
		end
	end
	// The array is deliberately NOT cleared here. A real part powers up
	// holding arbitrary but defined bits, and x is worse than useless -
	// it propagates through every read of memory the ROM has not written
	// yet. But clearing it in this module's own initial block races the
	// testbench's ROM preload, which pokes straight into mem from an
	// initial block of its own: Verilog does not order the two, and when
	// the clear won it wiped the image and left the CPU executing zeros.
	// tb_top.v now zeroes the array itself, immediately before the
	// preload, where the order is guaranteed.

	// statistics, handy for spotting a write that never happened
	integer writes_seen = 0;
	integer reads_seen  = 0;

	reg [21:0] a_full;

	// SDRAM protocol violations - see the ACTIVE case below
	reg [3:0] bank_open = 4'b0000;
	integer prot_err = 0;
	integer refresh_seen = 0;

	always @(posedge clk) begin
		// shift the CAS pipeline
		rd_valid[3] <= rd_valid[2];
		rd_data[3]  <= rd_data[2];
		rd_valid[2] <= rd_valid[1];
		rd_data[2]  <= rd_data[1];
		rd_valid[1] <= rd_valid[0];
		rd_data[1]  <= rd_data[0];
		rd_valid[0] <= 1'b0;

		case (cmd)
			CMD_ACTIVE: begin
				// Protocol check: a bank must be precharged before it
				// is activated again. The controller relies on the
				// auto-precharge bit of the READ/WRITE that follows, so
				// a cycle that opens a row and then issues no column
				// command at all leaves the bank open - and the next
				// ACTIVE to it reads or writes the wrong row.
				if (bank_open[sd_ba] === 1'b1) begin
					prot_err = prot_err + 1;
					if (prot_err <= 8)
						$display("[%0t] SDRAM PROTOCOL: ACTIVE on bank %0d with row %0h still open",
							$time, sd_ba, active_row[sd_ba]);
				end
				bank_open[sd_ba] <= 1'b1;
				active_row[sd_ba] <= sd_addr;
			end

			CMD_WRITE: begin
				a_full = {sd_ba, active_row[sd_ba], sd_addr[7:0]};
				if (sd_dqm[0] == 1'b0) mem[a_full][7:0]  = sd_data[7:0];
				if (sd_dqm[1] == 1'b0) mem[a_full][15:8] = sd_data[15:8];
				writes_seen = writes_seen + 1;
				if (sd_addr[10]) bank_open[sd_ba] <= 1'b0;
			end

			CMD_READ: begin
				a_full = {sd_ba, active_row[sd_ba], sd_addr[7:0]};
				rd_data[0]  <= mem[a_full];
				rd_valid[0] <= 1'b1;
				reads_seen  = reads_seen + 1;
				if (sd_addr[10]) bank_open[sd_ba] <= 1'b0;
			end

			CMD_AUTO_REFRESH: begin
				refresh_seen = refresh_seen + 1;
			end

			CMD_PRECHARGE: begin
				if (sd_addr[10]) bank_open <= 4'b0000;
				else             bank_open[sd_ba] <= 1'b0;
			end

			default: ;
		endcase
	end

	// Access time from the clock edge (tAC). Without this the model puts
	// read data on the bus instantaneously, which real parts do not do -
	// and that difference is not cosmetic: constraining the interface
	// showed the design was capturing reads ~7ns before the chip could
	// possibly have driven them. A zero-delay model hides exactly that
	// class of fault, so give it a realistic tAC.
	assign #6 sd_data = rd_valid[3] ? rd_data[3] : 16'bzzzzzzzzzzzzzzzz;

endmodule
