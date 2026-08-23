// The line itself: thirty-two characters, built from the machine,
// the clock and the memory size. Frequency at the left, the machine
// centred, the memory size at the right, all on one row.
//
// Returns a glyph index for osd_font. Column 0 is the leftmost.
function [5:0] osd_text;
	input [1:0] mc;
	input [1:0] sp;
	input ex;
	input [4:0] col;
	begin
		osd_text = 6'd0;
		case (col)
			5'd0: case (sp)
				2'd0: osd_text = 6'd7;
				2'd1: osd_text = 6'd11;
				2'd2: osd_text = 6'd5;
				2'd3: osd_text = 6'd6;
			endcase
			5'd1: case (sp)
				2'd0: osd_text = 6'd1;
				2'd1: osd_text = 6'd1;
				2'd2: osd_text = 6'd8;
				2'd3: osd_text = 6'd12;
			endcase
			5'd2: case (sp)
				2'd0: osd_text = 6'd9;
				2'd1: osd_text = 6'd4;
				2'd2: osd_text = 6'd20;
				2'd3: osd_text = 6'd20;
			endcase
			5'd3: case (sp)
				2'd0: osd_text = 6'd20;
				2'd1: osd_text = 6'd20;
				2'd2: osd_text = 6'd18;
				2'd3: osd_text = 6'd18;
			endcase
			5'd4: case (sp)
				2'd0: osd_text = 6'd18;
				2'd1: osd_text = 6'd18;
				2'd2: osd_text = 6'd28;
				2'd3: osd_text = 6'd28;
			endcase
			5'd5: case (sp)
				2'd0: osd_text = 6'd28;
				2'd1: osd_text = 6'd28;
				2'd2: osd_text = 6'd0;
				2'd3: osd_text = 6'd0;
			endcase
			5'd8: case (mc)
				2'd0: osd_text = 6'd0;
				2'd1: osd_text = 6'd0;
				2'd2: osd_text = 6'd25;
				2'd3: osd_text = 6'd0;
			endcase
			5'd9: case (mc)
				2'd0: osd_text = 6'd0;
				2'd1: osd_text = 6'd25;
				2'd2: osd_text = 6'd23;
				2'd3: osd_text = 6'd0;
			endcase
			5'd10: case (mc)
				2'd0: osd_text = 6'd25;
				2'd1: osd_text = 6'd23;
				2'd2: osd_text = 6'd16;
				2'd3: osd_text = 6'd0;
			endcase
			5'd11: case (mc)
				2'd0: osd_text = 6'd23;
				2'd1: osd_text = 6'd16;
				2'd2: osd_text = 6'd15;
				2'd3: osd_text = 6'd23;
			endcase
			5'd12: case (mc)
				2'd0: osd_text = 6'd16;
				2'd1: osd_text = 6'd15;
				2'd2: osd_text = 6'd26;
				2'd3: osd_text = 6'd16;
			endcase
			5'd13: case (mc)
				2'd0: osd_text = 6'd15;
				2'd1: osd_text = 6'd26;
				2'd2: osd_text = 6'd24;
				2'd3: osd_text = 6'd21;
			endcase
			5'd14: case (mc)
				2'd0: osd_text = 6'd26;
				2'd1: osd_text = 6'd24;
				2'd2: osd_text = 6'd27;
				2'd3: osd_text = 6'd26;
			endcase
			5'd15: case (mc)
				2'd0: osd_text = 6'd24;
				2'd1: osd_text = 6'd27;
				2'd2: osd_text = 6'd20;
				2'd3: osd_text = 6'd14;
			endcase
			5'd16: case (mc)
				2'd0: osd_text = 6'd27;
				2'd1: osd_text = 6'd20;
				2'd2: osd_text = 6'd0;
				2'd3: osd_text = 6'd17;
			endcase
			5'd17: case (mc)
				2'd0: osd_text = 6'd20;
				2'd1: osd_text = 6'd0;
				2'd2: osd_text = 6'd2;
				2'd3: osd_text = 6'd22;
			endcase
			5'd18: case (mc)
				2'd0: osd_text = 6'd0;
				2'd1: osd_text = 6'd5;
				2'd2: osd_text = 6'd6;
				2'd3: osd_text = 6'd21;
			endcase
			5'd19: case (mc)
				2'd0: osd_text = 6'd8;
				2'd1: osd_text = 6'd6;
				2'd2: osd_text = 6'd14;
				2'd3: osd_text = 6'd0;
			endcase
			5'd20: case (mc)
				2'd0: osd_text = 6'd12;
				2'd1: osd_text = 6'd12;
				2'd2: osd_text = 6'd3;
				2'd3: osd_text = 6'd0;
			endcase
			5'd21: case (mc)
				2'd0: osd_text = 6'd19;
				2'd1: osd_text = 6'd19;
				2'd2: osd_text = 6'd2;
				2'd3: osd_text = 6'd0;
			endcase
			5'd22: case (mc)
				2'd0: osd_text = 6'd0;
				2'd1: osd_text = 6'd0;
				2'd2: osd_text = 6'd7;
				2'd3: osd_text = 6'd0;
			endcase
			5'd23: case (mc)
				2'd0: osd_text = 6'd0;
				2'd1: osd_text = 6'd0;
				2'd2: osd_text = 6'd0;
				2'd3: osd_text = 6'd0;
			endcase
			5'd27: osd_text = (mc == 2'd0) ? 6'd0 : ex ? 6'd5 : 6'd0;
			5'd28: osd_text = (mc == 2'd0) ? 6'd0 : ex ? 6'd4 : 6'd5;
			5'd29: osd_text = (mc == 2'd0) ? 6'd8 : ex ? 6'd6 : 6'd6;
			5'd30: osd_text = (mc == 2'd0) ? 6'd12 : ex ? 6'd8 : 6'd12;
			5'd31: osd_text = (mc == 2'd0) ? 6'd19 : ex ? 6'd19 : 6'd19;
			default: osd_text = 6'd0;
		endcase
	end
endfunction
