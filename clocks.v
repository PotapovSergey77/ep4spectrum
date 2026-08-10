// ZX Spectrum for Altera DE1
//
// Copyright (c) 2009-2011 Mike Stirling
//
// All rights reserved
//
// Redistribution and use in source and synthezised forms, with or without
// modification, are permitted provided that the following conditions are met:
//
// * Redistributions of source code must retain the above copyright notice,
//   this list of conditions and the following disclaimer.
//
// * Redistributions in synthesized form must reproduce the above copyright
//   notice, this list of conditions and the following disclaimer in the
//   documentation and/or other materials provided with the distribution.
//
// * Neither the name of the author nor the names of other contributors may
//   be used to endorse or promote products derived from this software without
//   specific prior written agreement from the author.
//
// * License is granted for non-commercial use only.  A fee may not be charged
//   for redistributions as source code or in synthesized/hardware form without
//   specific prior written agreement from the author.
//
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
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

module clocks (
	// 28 MHz master clock
	CLK,
	// Master reset
	nRESET,
	// cpu requests bus
	MREQ,

	// 1.75 MHz clock enable for sound
	CLKEN_PSG,
	// 3.5 MHz clock enable (1 in 8)
	CLKEN_CPU,
	// 3.5 MHz clock enable (1 in 8) for cpu memory access
	CLKEN_MEM,
	// 1.75 MHz clock enable (1 in 8) for data_io
	CLKEN_DIO,
	// 14 MHz clock enable (out of phase with CPU)
	CLKEN_VID,
	// reference to sync video memory access to
	VID_MEM_SYNC,
	// clock reference for sdram to sync onto
	CLK_REF,
	// one tick per SDRAM cycle boundary, for the CPU/video arbiter
	CLKEN_SLOT
);

	input           CLK;
	input           nRESET;
	input           MREQ;

	output reg      CLKEN_PSG;
	output reg      CLKEN_CPU;
	output reg      CLKEN_MEM;
	output reg      CLKEN_DIO;
	output reg      CLKEN_VID;
	output reg      VID_MEM_SYNC;
	output reg      CLK_REF;
	output reg      CLKEN_SLOT;

	reg     [3:0]   counter;

	always @(posedge CLK) begin
		if (counter[1] == 1'b1)
			CLK_REF <= 1'b1;
		else
			CLK_REF <= 1'b0;
	end

	always @(negedge CLK or negedge nRESET) begin
		if (nRESET == 1'b0) begin
			counter <= 4'b0000;
		end else begin
			counter <= counter + 1'b1;

			if (counter[0] == 1'b1)
				CLKEN_VID <= 1'b1;
			else
				CLKEN_VID <= 1'b0;

			if (counter == 4'b1000)
				CLKEN_PSG <= 1'b1;
			else
				CLKEN_PSG <= 1'b0;

			if (counter == 4'b1011 || counter == 4'b1100 || counter == 4'b1101)
				CLKEN_DIO <= 1'b1;
			else
				CLKEN_DIO <= 1'b0;

			if (counter == 4'b0111 || counter == 4'b1000 || counter == 4'b1001)
				CLKEN_MEM <= 1'b1;
			else
				CLKEN_MEM <= 1'b0;

			if (counter == 4'b1111)
				VID_MEM_SYNC <= 1'b1;
			else
				VID_MEM_SYNC <= 1'b0;

			// One tick per SDRAM cycle boundary. The four cycles in a
			// window run over counters 1-4, 5-8, 9-12 and 13-0, so the
			// arbiter's grant register has to update entering 1, 5, 9
			// and 13 - which means this must be high during 0, 4, 8, 12.
			if (counter[1:0] == 2'b11)
				CLKEN_SLOT <= 1'b1;
			else
				CLKEN_SLOT <= 1'b0;

			// Unconditional. The MREQ term used to withhold this enable
			// whenever the CPU was touching memory or IO, which is a
			// blanket wait state on every access: measured at 7 lost
			// enables in 5006, matching the 71456-against-71680 T-state
			// shortfall that stopped Pentagon-timed demos working.
			// The CPU is now held only when its data genuinely has not
			// arrived, through WAIT_n off the arbiter in spectrum_top.v.
			// Asserted one clock earlier than the obvious 7/15 so that
			// the CPU's MREQ lands exactly on an arbiter boundary. The
			// CPU updates its outputs on the enable, so an enable
			// during counter 8 only makes the request visible during 9
			// - one clock past the boundary at 8, which costs a whole
			// slot and shows up as a wait state on most accesses (82%
			// of full speed when measured). Enabling during 7 and 15
			// puts the request on the boundary at 8 and 0, and the byte
			// then comes back exactly at the next enable.
			if (counter == 4'b0110 || counter == 4'b1110)
				CLKEN_CPU <= 1'b1;
			else
				CLKEN_CPU <= 1'b0;
		end
	end

endmodule
