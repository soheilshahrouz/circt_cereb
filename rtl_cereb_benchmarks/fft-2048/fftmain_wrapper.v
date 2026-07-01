`default_nettype	none

module	fftmain_wrapper(
		i_clk,
		o_result, o_sync);
	localparam	IWIDTH = 16;
	localparam	OWIDTH = 22;

	input	wire				i_clk;
	output	wire	[(2*OWIDTH-1):0]	o_result;
	output	wire				o_sync;

	reg				i_reset;
	reg				i_ce;
	wire	[(2*IWIDTH-1):0]	i_sample;

	// Hold reset active for the first three clock cycles.
	reg	[1:0]	reset_cnt = 0;
	always @(posedge i_clk) begin
		i_reset <= (reset_cnt < 2'd3);
		if (reset_cnt != 2'd3)
			reset_cnt <= reset_cnt + 2'd1;
		i_ce <= 1'b1;
	end

	// Ramp test pattern: real = index, imag = index << 4.
	reg	[(IWIDTH-1):0]	sample_idx;
	reg	[(IWIDTH-1):0]	sample_re;
	reg	[(IWIDTH-1):0]	sample_im;

	always @(posedge i_clk)
	if (i_reset) begin
		sample_idx <= {IWIDTH{1'b0}};
		sample_re  <= {IWIDTH{1'b0}};
		sample_im  <= {IWIDTH{1'b0}};
	end else begin
		sample_re  <= sample_idx;
		sample_im  <= sample_idx << 4;
		sample_idx <= sample_idx + {{(IWIDTH-1){1'b0}}, 1'b1};
	end

	assign	i_sample = {sample_re, sample_im};

	fftmain	fft_inst(
		.i_clk(i_clk),
		.i_reset(i_reset),
		.i_ce(i_ce),
		.i_sample(i_sample),
		.o_result(o_result),
		.o_sync(o_sync)
	);

endmodule
