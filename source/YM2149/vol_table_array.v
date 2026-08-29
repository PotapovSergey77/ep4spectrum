// generated with tablegen by MikeJ
//
// Modifications copyright (c) 2026 Sergey Potapov (potapov.sergey.77@gmail.com)
//
// Changes:
//   - Second read port (ADDR_B/DATA_B) added, so the two AY-3-8912s of
//     the Turbo Sound pair share one copy of the table.
//
// Two read ports, so the two AY-3-8912s of the Turbo Sound pair can
// share one copy of the table.
//
// The table is 4096 x 10 bits, about five M9K blocks. Two copies do not
// fit alongside the 48K ROM and the ESXDOS ROM in this device's thirty
// blocks - the fitter reports "Can't place all RAM cells in design".
// The M9K has two ports and the table is constant, so one instance
// serves both chips with no loss of accuracy and no time-sharing.

module vol_table (
	CLK,
	ADDR,
	DATA,
	ADDR_B,
	DATA_B
);

	input           CLK;
	input   [11:0]  ADDR;
	output reg [9:0]   DATA;
	input   [11:0]  ADDR_B;
	output reg [9:0]   DATA_B;

	reg     [9:0]   ROM [0:4095];

	initial begin
		$readmemh("vol_table.hex", ROM);
	end

	always @(posedge CLK) begin
		DATA <= ROM[ADDR];
	end

	always @(posedge CLK) begin
		DATA_B <= ROM[ADDR_B];
	end

endmodule
