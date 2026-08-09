// generated with tablegen by MikeJ

module vol_table (
	CLK,
	ADDR,
	DATA
);

	input           CLK;
	input   [11:0]  ADDR;
	output reg [9:0]   DATA;

	reg     [9:0]   ROM [0:4095];

	initial begin
		$readmemh("vol_table.hex", ROM);
	end

	always @(posedge CLK) begin
		DATA <= ROM[ADDR];
	end

endmodule
