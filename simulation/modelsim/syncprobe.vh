	integer t = 0;
	integer i;
	reg [3:0] pv = 4'b1111;
	wire [3:0] cur = {anhs, ancs, anhcs, bnhcs};
	integer cnt [0:3];
	integer lastf [0:3];
	integer per [0:3];
	initial for (i = 0; i < 4; i = i + 1) begin cnt[i]=0; lastf[i]=0; per[i]=0; end
	always @(posedge clk) begin
		if (nreset) begin
			t = t + 1;
			for (i = 0; i < 4; i = i + 1) begin
				if (pv[i] === 1'b1 && cur[i] === 1'b0) begin
					cnt[i] = cnt[i] + 1;
					if (lastf[i] != 0) per[i] = t - lastf[i];
					lastf[i] = t;
				end
			end
			pv <= cur;
		end
	end
	initial begin
		#1_800_000;
		$display("");
		$display("  signal        falling edges   period(clk)   kHz");
		$display("  nHSYNC  VGA=1   %6d        %6d      %0d.%0d",
			cnt[3], per[3], (28000*10/(per[3]==0?1:per[3]))/10, (28000*10/(per[3]==0?1:per[3]))%10);
		$display("  nCSYNC  VGA=1   %6d        %6d      %0d.%0d",
			cnt[2], per[2], (28000*10/(per[2]==0?1:per[2]))/10, (28000*10/(per[2]==0?1:per[2]))%10);
		$display("  nHCSYNC VGA=1   %6d        %6d      %0d.%0d",
			cnt[1], per[1], (28000*10/(per[1]==0?1:per[1]))/10, (28000*10/(per[1]==0?1:per[1]))%10);
		$display("  nHCSYNC VGA=0   %6d        %6d      %0d.%0d",
			cnt[0], per[0], (28000*10/(per[0]==0?1:per[0]))/10, (28000*10/(per[0]==0?1:per[0]))%10);
	end
