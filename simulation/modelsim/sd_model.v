// Copyright (c) 2026 Sergey Potapov (potapov.sergey.77@gmail.com)
//
// sd_model.v
//
// Minimal behavioral SD card SPI slave for simulation. Not a full card -
// just enough protocol to see whether the FPGA side (spi.v/divmmc.v)
// conducts a plausible SD SPI command/response exchange:
//   CMD0  (GO_IDLE_STATE)     -> R1 = 0x01
//   CMD8  (SEND_IF_COND)      -> R7 = 0x01, 0x00,0x00,0x01,0xAA
//   CMD55 (APP_CMD)           -> R1 = 0x01
//   ACMD41(SD_SEND_OP_COND)   -> R1 = 0x00 (ready, first try already)
//   CMD58 (READ_OCR)          -> R1 = 0x00, OCR = 0xC0FF8000 (busy=0,ccs=1)
//   CMD16 (SET_BLOCKLEN)      -> R1 = 0x00
//   CMD17 (READ_SINGLE_BLOCK) -> R1 = 0x00, then FE token + 512 bytes of
//                                 0xE5 (arbitrary marker) + 2 CRC bytes
// Anything else: R1 = 0x04 (illegal command).
//
// This is deliberately minimal/idealized (always answers immediately, no
// real timing/retry edge cases) - the goal is just to confirm the FPGA
// side can complete a basic exchange at all.

module sd_model (
	input  wire clk_sys,   // just needs to be faster than sd_sck, any clock works
	input  wire sd_cs,     // active low
	input  wire sd_sck,
	input  wire sd_mosi,   // FPGA -> card
	output reg  sd_miso    // card -> FPGA
);

initial sd_miso = 1'b1;

reg [7:0] shift_in;
reg [3:0] bitcnt;
reg [7:0] cmd_buf [0:5];
reg [2:0] cmd_idx;
reg       synced;

reg [7:0] tx_byte;
reg       tx_active;
reg [3:0] tx_bitcnt;

// response construction
reg [7:0] resp [0:5];
reg [3:0] resp_len;
reg [3:0] resp_ptr;
reg       sending_resp;
reg       sending_data;
reg [8:0] data_ptr;

always @(posedge sd_sck or posedge sd_cs) begin
	if (sd_cs) begin
		bitcnt <= 0;
		synced <= 0;
	end else begin
		shift_in <= {shift_in[6:0], sd_mosi};
		bitcnt <= bitcnt + 1;
	end
end

// command byte capture + dispatch (evaluated after each completed byte)
reg [7:0] cmd, arg3, arg2, arg1, arg0, crc;
reg [2:0] byte_no;
reg       have_cmd;

always @(posedge sd_sck or posedge sd_cs) begin
	if (sd_cs) begin
		byte_no <= 0;
		have_cmd <= 0;
	end else if (bitcnt == 4'd7) begin
		// about to complete a byte (this edge shifts in the last bit above,
		// but shift_in isn't updated until after; use the about-to-be-formed
		// byte directly)
		case (byte_no)
			0: cmd  <= {shift_in[6:0], sd_mosi};
			1: arg3 <= {shift_in[6:0], sd_mosi};
			2: arg2 <= {shift_in[6:0], sd_mosi};
			3: arg1 <= {shift_in[6:0], sd_mosi};
			4: arg0 <= {shift_in[6:0], sd_mosi};
			5: crc  <= {shift_in[6:0], sd_mosi};
		endcase
		if (byte_no == 5) begin
			have_cmd <= 1;
		end
		if (byte_no != 5)
			byte_no <= byte_no + 3'd1;
	end
end

// build response once a full 6-byte command has arrived, and shift it
// out on subsequent SCK edges.
//
// Edge choice derived from spi.v's actual behavior, not assumed: its
// counter increments every clk, spi_clk=counter[0], and the shift
// "if(spi_clk) io_byte<={io_byte[6:0],spi_di}" evaluates using
// spi_clk's value from *before* this same edge - which is the edge
// where spi_clk is about to fall (spi.v samples MOSI, and by
// implication expects MISO to be sampled, at the SCK falling edge,
// not rising - i.e. this interface is CPHA=1, not the SD-conventional
// CPHA=0). Driving MISO on negedge (as originally written here,
// assuming standard Mode 0) raced against the master's own
// falling-edge sample of that same edge and produced torn bytes in
// simulation (confirmed: a prepared 0xFF,0x01 response came back as
// stray values like 0x82 instead). Driving on posedge instead holds
// MISO stable clear through the master's negedge sample.
reg [47:0] resp_shift;
reg [7:0]  resp_bytes_left;
reg        driving;

always @(posedge sd_sck or posedge sd_cs) begin
	if (sd_cs) begin
		sd_miso <= 1'b1;
		driving <= 0;
	end else begin
		if (have_cmd && !driving) begin
			driving <= 1;
			case (cmd[5:0])
				6'h00: begin // CMD0
					resp_shift <= {8'hFF, 8'h01, 32'hFFFFFFFF};
					resp_bytes_left <= 1;
				end
				6'h08: begin // CMD8
					resp_shift <= {8'h01, 8'h00, 8'h00, 8'h01, 8'hAA, 8'hFF};
					resp_bytes_left <= 5;
				end
				6'h37: begin // CMD55
					resp_shift <= {8'hFF, 8'h01, 32'hFFFFFFFF};
					resp_bytes_left <= 1;
				end
				6'h29: begin // ACMD41
					resp_shift <= {8'hFF, 8'h00, 32'hFFFFFFFF};
					resp_bytes_left <= 1;
				end
				6'h3A: begin // CMD58
					resp_shift <= {8'h00, 8'hC0, 8'hFF, 8'h80, 8'h00, 8'hFF};
					resp_bytes_left <= 5;
				end
				6'h10: begin // CMD16
					resp_shift <= {8'hFF, 8'h00, 32'hFFFFFFFF};
					resp_bytes_left <= 1;
				end
				6'h11: begin // CMD17 - R1=0 then handled by data phase below
					resp_shift <= {8'hFF, 8'h00, 32'hFFFFFFFF};
					resp_bytes_left <= 1;
				end
				default: begin
					resp_shift <= {8'hFF, 8'h04, 32'hFFFFFFFF};
					resp_bytes_left <= 1;
				end
			endcase
			sd_miso <= 1'b1; // NCR gap bit
		end else if (driving) begin
			sd_miso <= resp_shift[47];
			resp_shift <= {resp_shift[46:0], 1'b1};
		end
	end
end

initial begin
	$display("[sd_model] behavioral SD card responder active");
end

endmodule
