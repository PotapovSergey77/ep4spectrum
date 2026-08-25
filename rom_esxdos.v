// rom_esxdos.v
//
// 8K block ROM holding the ESXDOS DivMMC ROM image (ESXMMC.BIN from the
// official esxdos 0.8.9 distribution, https://www.esxdos.org/), used to
// seed SDRAM at power-up in place of the MiST IO controller's upload
// mechanism - see the boot-copy state machine in ep4spectrum.v.
//
// Modeled on rom48.v/rom128.v (Quartus altsyncram ROM megafunction).
//
// Copyright (c) 2026 Sergey Potapov (potapov.sergey.77@gmail.com)
//
// The ROM image itself is ESXDOS, © its own authors (esxdos.org), and
// is not covered by this notice.

module rom_esxdos (
	address,
	clock,
	q);

	input	[12:0]  address;
	input	  clock;
	output	[7:0]  q;
	tri1	  clock;

	wire [7:0] sub_wire0;
	wire [7:0] q = sub_wire0[7:0];

	altsyncram	altsyncram_component (
				.address_a (address),
				.clock0 (clock),
				.q_a (sub_wire0),
				.aclr0 (1'b0),
				.aclr1 (1'b0),
				.address_b (1'b1),
				.addressstall_a (1'b0),
				.addressstall_b (1'b0),
				.byteena_a (1'b1),
				.byteena_b (1'b1),
				.clock1 (1'b1),
				.clocken0 (1'b1),
				.clocken1 (1'b1),
				.clocken2 (1'b1),
				.clocken3 (1'b1),
				.data_a ({8{1'b1}}),
				.data_b (1'b1),
				.eccstatus (),
				.q_b (),
				.rden_a (1'b1),
				.rden_b (1'b1),
				.wren_a (1'b0),
				.wren_b (1'b0));
	defparam
		altsyncram_component.address_aclr_a = "NONE",
		altsyncram_component.clock_enable_input_a = "BYPASS",
		altsyncram_component.clock_enable_output_a = "BYPASS",
		altsyncram_component.init_file = "esxmmc.hex",
		altsyncram_component.intended_device_family = "Cyclone IV E",
		altsyncram_component.lpm_hint = "ENABLE_RUNTIME_MOD=NO",
		altsyncram_component.lpm_type = "altsyncram",
		altsyncram_component.numwords_a = 8192,
		altsyncram_component.operation_mode = "ROM",
		altsyncram_component.outdata_aclr_a = "NONE",
		altsyncram_component.outdata_reg_a = "UNREGISTERED",
		altsyncram_component.widthad_a = 13,
		altsyncram_component.width_a = 8,
		altsyncram_component.width_byteena_a = 1;

endmodule
