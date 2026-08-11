//
// A simulation model of YM2149 (AY-3-8910 with bells on)

// Copyright (c) MikeJ - Jan 2005
//
// All rights reserved
//
// Redistribution and use in source and synthezised forms, with or without
// modification, are permitted provided that the following conditions are met:
//
// Redistributions of source code must retain the above copyright notice,
// this list of conditions and the following disclaimer.
//
// Redistributions in synthesized form must reproduce the above copyright
// notice, this list of conditions and the following disclaimer in the
// documentation and/or other materials provided with the distribution.
//
// Neither the name of the author nor the names of other contributors may
// be used to endorse or promote products derived from this software without
// specific prior written permission.
//
// THIS CODE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
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
// You are responsible for any legal issues arising from your use of this code.
//
// The latest version of this file can be found at: www.fpgaarcade.com
//
// Email support@fpgaarcade.com
//
// Clues from MAME sound driver and Kazuhiro TSUJIKAWA
//
// These are the measured outputs from a real chip for a single Isolated channel into a 1K load (V)
// vol 15 .. 0
// 3.27 2.995 2.741 2.588 2.452 2.372 2.301 2.258 2.220 2.198 2.178 2.166 2.155 2.148 2.141 2.132
// As the envelope volume is 5 bit, I have fitted a curve to the not quite log shape in order
// to produced all the required values.
// (The first part of the curve is a bit steeper and the last bit is more linear than expected)
//
// NOTE, this component uses a volume table for accurate mixing of the three analogue channels,
// where the outputs are wired together - like in the Atari ST

module YM2149 (
	// data bus
	I_DA,
	O_DA,
	O_DA_OE_L,
	// control
	I_A9_L,
	I_A8,
	I_BDIR,
	I_BC2,
	I_BC1,
	I_SEL_L,

	O_AUDIO,
	VOL_ADDR,
	VOL_DATA,
	// port a
	I_IOA,
	O_IOA,
	O_IOA_OE_L,
	// port b
	I_IOB,
	O_IOB,
	O_IOB_OE_L,
	//
	ENA,
	RESET_L,
	CLK
);

	input   [7:0]   I_DA;
	output reg [7:0]   O_DA;
	output          O_DA_OE_L;

	input           I_A9_L;
	input           I_A8;
	input           I_BDIR;
	input           I_BC2;
	input           I_BC1;
	input           I_SEL_L;

	output reg [7:0]   O_AUDIO;
	output  [11:0]  VOL_ADDR;
	input   [9:0]   VOL_DATA;

	input   [7:0]   I_IOA;
	output          O_IOA;
	output          O_IOA_OE_L;

	input   [7:0]   I_IOB;
	output          O_IOB;
	output          O_IOB_OE_L;

	input           ENA; // clock enable for higher speed operation
	input           RESET_L;
	input           CLK;  // note 6 Mhz

	// signals
	reg     [3:0]   cnt_div = 4'b0000;
	reg             noise_div = 1'b0;
	reg             ena_div;
	reg             ena_div_noise;
	reg     [16:0]  poly17 = 17'b0;

	// registers
	reg     [7:0]   addr;
	reg             busctrl_addr;
	reg             busctrl_we;
	reg             busctrl_re;

	reg     [7:0]   regs [0:15];
	wire            env_reset;
	reg     [7:0]   ioa_inreg;
	reg     [7:0]   iob_inreg;

	reg     [4:0]   noise_gen_cnt;
	wire            noise_gen_op;
	reg     [11:0]  tone_gen_cnt [1:3];
	reg     [3:1]   tone_gen_op = 3'b000;

	reg     [15:0]  env_gen_cnt;
	reg             env_ena;
	reg             env_hold;
	reg             env_inc;
	reg     [4:0]   env_vol;

	reg     [11:0]  vol_table_in;
	wire    [9:0]   vol_table_out;

	initial begin
		tone_gen_cnt[1] = 12'b0;
		tone_gen_cnt[2] = 12'b0;
		tone_gen_cnt[3] = 12'b0;
	end

	// cpu i/f
	// BDIR BC2 BC1 MODE
	//   0   0   0  inactive
	//   0   0   1  address
	//   0   1   0  inactive
	//   0   1   1  read
	//   1   0   0  address
	//   1   0   1  inactive
	//   1   1   0  write
	//   1   1   1  read
	reg             cs;
	always @(*) begin
		busctrl_addr = 1'b0;
		busctrl_we = 1'b0;
		busctrl_re = 1'b0;

		cs = 1'b0;
		if ((I_A9_L == 1'b0) && (I_A8 == 1'b1) && (addr[7:4] == 4'b0000))
			cs = 1'b1;

		case ({I_BDIR, I_BC2, I_BC1})
			3'b000: ;
			3'b001: busctrl_addr = 1'b1;
			3'b010: ;
			3'b011: busctrl_re = cs;
			3'b100: busctrl_addr = 1'b1;
			3'b101: ;
			3'b110: busctrl_we = cs;
			3'b111: busctrl_addr = 1'b1;
			default: ;
		endcase
	end

	// if we are emulating a real chip, maybe clock this to fake up the tristate typ delay of 100ns
	assign O_DA_OE_L = ~busctrl_re;

	// Originally these two blocks were clocked by busctrl_addr and
	// busctrl_we themselves - the source called it "nasty as gated
	// clock", and it is worse than untidy: those signals derive from the
	// CPU's IORQ_n, so TimeQuest saw IORQ_n as a clock with no
	// constraint and left everything they clock unanalysed. That is the
	// same class of problem that made this design behave differently
	// from build to build. Same behaviour, but clocked from CLK with the
	// falling edge detected in logic, so the paths are timed.
	//
	// I_DA is captured while the strobe is asserted and committed when it
	// falls, rather than sampled at the edge itself - by then the CPU may
	// already have let go of the bus.
	reg             busctrl_addr_d = 1'b1;
	reg             busctrl_we_d   = 1'b1;
	reg     [7:0]   da_hold        = 8'b0;

	always @(posedge CLK or negedge RESET_L) begin
		if (RESET_L == 1'b0) begin
			busctrl_addr_d <= 1'b1;
			busctrl_we_d   <= 1'b1;
			da_hold        <= 8'b0;
		end else begin
			busctrl_addr_d <= busctrl_addr;
			busctrl_we_d   <= busctrl_we;
			if (busctrl_addr == 1'b1 || busctrl_we == 1'b1)
				da_hold <= I_DA;
		end
	end

	wire addr_strobe_end = (busctrl_addr_d == 1'b1) && (busctrl_addr == 1'b0);
	wire we_strobe_end   = (busctrl_we_d   == 1'b1) && (busctrl_we   == 1'b0);

	always @(posedge CLK or negedge RESET_L) begin
		// looks like registers are latches in real chip, but the address is caught at the end of the address state.
		if (RESET_L == 1'b0)
			addr <= 8'b0;
		else if (addr_strobe_end)
			addr <= da_hold;
	end

	integer wi;
	always @(posedge CLK or negedge RESET_L) begin
		if (RESET_L == 1'b0) begin
			for (wi = 0; wi < 16; wi = wi + 1)
				regs[wi] <= 8'b0;
		end else if (we_strobe_end) begin
			case (addr[3:0])
				4'h0: regs[0]  <= da_hold;
				4'h1: regs[1]  <= da_hold;
				4'h2: regs[2]  <= da_hold;
				4'h3: regs[3]  <= da_hold;
				4'h4: regs[4]  <= da_hold;
				4'h5: regs[5]  <= da_hold;
				4'h6: regs[6]  <= da_hold;
				4'h7: regs[7]  <= da_hold;
				4'h8: regs[8]  <= da_hold;
				4'h9: regs[9]  <= da_hold;
				4'hA: regs[10] <= da_hold;
				4'hB: regs[11] <= da_hold;
				4'hC: regs[12] <= da_hold;
				4'hD: regs[13] <= da_hold;
				4'hE: regs[14] <= da_hold;
				4'hF: regs[15] <= da_hold;
				default: ;
			endcase
		end
	end

	assign env_reset = (busctrl_we == 1'b1 && addr[3:0] == 4'hD) ? 1'b1 : 1'b0;

	always @(*) begin
		O_DA = 8'b0; // 'X'
		if (busctrl_re == 1'b1) begin // not necessary, but useful for putting 'X's in the simulator
			case (addr[3:0])
				4'h0: O_DA = regs[0];
				4'h1: O_DA = {4'b0000, regs[1][3:0]};
				4'h2: O_DA = regs[2];
				4'h3: O_DA = {4'b0000, regs[3][3:0]};
				4'h4: O_DA = regs[4];
				4'h5: O_DA = {4'b0000, regs[5][3:0]};
				4'h6: O_DA = {3'b000, regs[6][4:0]};
				4'h7: O_DA = regs[7];
				4'h8: O_DA = {3'b000, regs[8][4:0]};
				4'h9: O_DA = {3'b000, regs[9][4:0]};
				4'hA: O_DA = {3'b000, regs[10][4:0]};
				4'hB: O_DA = regs[11];
				4'hC: O_DA = regs[12];
				4'hD: O_DA = {4'b0000, regs[13][3:0]};
				4'hE: begin
					if (regs[7][6] == 1'b0) // input
						O_DA = ioa_inreg;
					else
						O_DA = regs[14]; // read output reg
				end
				4'hF: begin
					if (regs[7][7] == 1'b0)
						O_DA = iob_inreg;
					else
						O_DA = regs[15];
				end
				default: ;
			endcase
		end
	end

	always @(posedge CLK) begin
		// / 8 when SEL is high and /16 when SEL is low
		if (ENA == 1'b1) begin
			ena_div <= 1'b0;
			ena_div_noise <= 1'b0;
			if (cnt_div == 4'b0000) begin
				cnt_div <= {~I_SEL_L, 3'b111};
				ena_div <= 1'b1;

				noise_div <= ~noise_div;
				if (noise_div == 1'b1)
					ena_div_noise <= 1'b1;
			end else begin
				cnt_div <= cnt_div - 4'b1;
			end
		end
	end

	reg     [4:0]   noise_gen_comp;
	reg             poly17_zero;
	always @(posedge CLK) begin
		if (regs[6][4:0] == 5'b00000)
			noise_gen_comp = 5'b00000;
		else
			noise_gen_comp = regs[6][4:0] - 5'b1;

		poly17_zero = 1'b0;
		if (poly17 == 17'b0)
			poly17_zero = 1'b1;

		if (ENA == 1'b1) begin
			if (ena_div_noise == 1'b1) begin // divider ena
				if (noise_gen_cnt >= noise_gen_comp) begin
					noise_gen_cnt <= 5'b00000;
					poly17 <= {poly17[0] ^ poly17[2] ^ poly17_zero, poly17[16:1]};
				end else begin
					noise_gen_cnt <= noise_gen_cnt + 5'b1;
				end
			end
		end
	end
	assign noise_gen_op = poly17[0];

	reg     [11:0]  tone_gen_freq_1, tone_gen_freq_2, tone_gen_freq_3;
	reg     [11:0]  tone_gen_comp_1, tone_gen_comp_2, tone_gen_comp_3;
	always @(posedge CLK) begin
		// looks like real chips count up - we need to get the Exact behaviour ..
		tone_gen_freq_1 = {regs[1][3:0], regs[0]};
		tone_gen_freq_2 = {regs[3][3:0], regs[2]};
		tone_gen_freq_3 = {regs[5][3:0], regs[4]};
		// period 0 = period 1
		tone_gen_comp_1 = (tone_gen_freq_1 == 12'h000) ? 12'h000 : (tone_gen_freq_1 - 12'b1);
		tone_gen_comp_2 = (tone_gen_freq_2 == 12'h000) ? 12'h000 : (tone_gen_freq_2 - 12'b1);
		tone_gen_comp_3 = (tone_gen_freq_3 == 12'h000) ? 12'h000 : (tone_gen_freq_3 - 12'b1);

		if (ENA == 1'b1) begin
			if (ena_div == 1'b1) begin // divider ena
				if (tone_gen_cnt[1] >= tone_gen_comp_1) begin
					tone_gen_cnt[1] <= 12'h000;
					tone_gen_op[1] <= ~tone_gen_op[1];
				end else begin
					tone_gen_cnt[1] <= tone_gen_cnt[1] + 12'b1;
				end

				if (tone_gen_cnt[2] >= tone_gen_comp_2) begin
					tone_gen_cnt[2] <= 12'h000;
					tone_gen_op[2] <= ~tone_gen_op[2];
				end else begin
					tone_gen_cnt[2] <= tone_gen_cnt[2] + 12'b1;
				end

				if (tone_gen_cnt[3] >= tone_gen_comp_3) begin
					tone_gen_cnt[3] <= 12'h000;
					tone_gen_op[3] <= ~tone_gen_op[3];
				end else begin
					tone_gen_cnt[3] <= tone_gen_cnt[3] + 12'b1;
				end
			end
		end
	end

	reg     [15:0]  env_gen_freq;
	reg     [15:0]  env_gen_comp;
	always @(posedge CLK) begin
		env_gen_freq = {regs[12], regs[11]};
		// envelope freqs 1 and 0 are the same.
		env_gen_comp = (env_gen_freq == 16'h0000) ? 16'h0000 : (env_gen_freq - 16'b1);

		if (ENA == 1'b1) begin
			env_ena <= 1'b0;
			if (ena_div == 1'b1) begin // divider ena
				if (env_gen_cnt >= env_gen_comp) begin
					env_gen_cnt <= 16'h0000;
					env_ena <= 1'b1;
				end else begin
					env_gen_cnt <= env_gen_cnt + 16'b1;
				end
			end
		end
	end

	// envelope shapes
	// C AtAlH
	// 0 0 x x  \___
	//
	// 0 1 x x  /___
	//
	// 1 0 0 0  \\\\
	//
	// 1 0 0 1  \___
	//
	// 1 0 1 0  \/\/
	//           ___
	// 1 0 1 1  \
	//
	// 1 1 0 0  ////
	//           ___
	// 1 1 0 1  /
	//
	// 1 1 1 0  /\/\
	//
	// 1 1 1 1  /___
	reg             is_bot;
	reg             is_bot_p1;
	reg             is_top_m1;
	reg             is_top;
	always @(posedge CLK) begin
		if (env_reset == 1'b1) begin
			// load initial state
			if (regs[13][2] == 1'b0) begin // attack
				env_vol <= 5'b11111;
				env_inc <= 1'b0; // -1
			end else begin
				env_vol <= 5'b00000;
				env_inc <= 1'b1; // +1
			end
			env_hold <= 1'b0;
		end else begin
			is_bot    = (env_vol == 5'b00000);
			is_bot_p1 = (env_vol == 5'b00001);
			is_top_m1 = (env_vol == 5'b11110);
			is_top    = (env_vol == 5'b11111);

			if (ENA == 1'b1) begin
				if (env_ena == 1'b1) begin
					if (env_hold == 1'b0) begin
						if (env_inc == 1'b1)
							env_vol <= env_vol + 5'b00001;
						else
							env_vol <= env_vol + 5'b11111;
					end

					// envelope shape control.
					if (regs[13][3] == 1'b0) begin
						if (env_inc == 1'b0) begin // down
							if (is_bot_p1) env_hold <= 1'b1;
						end else begin
							if (is_top) env_hold <= 1'b1;
						end
					end else begin
						if (regs[13][0] == 1'b1) begin // hold = 1
							if (env_inc == 1'b0) begin // down
								if (regs[13][1] == 1'b1) begin // alt
									if (is_bot) env_hold <= 1'b1;
								end else begin
									if (is_bot_p1) env_hold <= 1'b1;
								end
							end else begin
								if (regs[13][1] == 1'b1) begin // alt
									if (is_top) env_hold <= 1'b1;
								end else begin
									if (is_top_m1) env_hold <= 1'b1;
								end
							end
						end else if (regs[13][1] == 1'b1) begin // alternate
							if (env_inc == 1'b0) begin // down
								if (is_bot_p1) env_hold <= 1'b1;
								if (is_bot) begin
									env_hold <= 1'b0;
									env_inc <= 1'b1;
								end
							end else begin
								if (is_top_m1) env_hold <= 1'b1;
								if (is_top) begin
									env_hold <= 1'b0;
									env_inc <= 1'b0;
								end
							end
						end
					end
				end
			end
		end
	end

	reg     [2:0]   chan_mixed;
	always @(posedge CLK) begin
		if (ENA == 1'b1) begin
			chan_mixed[0] = (regs[7][0] | tone_gen_op[1]) & (regs[7][3] | noise_gen_op);
			chan_mixed[1] = (regs[7][1] | tone_gen_op[2]) & (regs[7][4] | noise_gen_op);
			chan_mixed[2] = (regs[7][2] | tone_gen_op[3]) & (regs[7][5] | noise_gen_op);

			vol_table_in <= 12'h000;

			if (chan_mixed[0] == 1'b1) begin
				if (regs[8][4] == 1'b0)
					vol_table_in[3:0] <= regs[8][3:0];
				else
					vol_table_in[3:0] <= env_vol[4:1];
			end

			if (chan_mixed[1] == 1'b1) begin
				if (regs[9][4] == 1'b0)
					vol_table_in[7:4] <= regs[9][3:0];
				else
					vol_table_in[7:4] <= env_vol[4:1];
			end

			if (chan_mixed[2] == 1'b1) begin
				if (regs[10][4] == 1'b0)
					vol_table_in[11:8] <= regs[10][3:0];
				else
					vol_table_in[11:8] <= env_vol[4:1];
			end
		end
	end

	// The table lives outside this module now, shared between the two
	// chips of the Turbo Sound pair - two copies do not fit in this
	// device alongside the ROMs.
	assign VOL_ADDR = vol_table_in;
	assign vol_table_out = VOL_DATA;

	always @(posedge CLK) begin
		if (RESET_L == 1'b0)
			O_AUDIO[7:0] <= 8'b00000000;
		else
			O_AUDIO[7:0] <= vol_table_out[9:2];
	end

	// input low
	assign O_IOA = regs[14];
	assign O_IOA_OE_L = ~regs[7][6];
	assign O_IOB = regs[15];
	assign O_IOB_OE_L = ~regs[7][7];

	always @(posedge CLK) begin
		ioa_inreg <= I_IOA;
		iob_inreg <= I_IOB;
	end

endmodule
