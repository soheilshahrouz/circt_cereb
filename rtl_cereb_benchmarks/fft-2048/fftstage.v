////////////////////////////////////////////////////////////////////////////////
//
// Filename:	fftstage.v
// {{{
// Project:	A General Purpose Pipelined FFT Implementation
//
// Purpose:	This file is (almost) a Verilog source file.  It is meant to
//		be used by a FFT core compiler to generate FFTs which may be
//	used as part of an FFT core.  Specifically, this file encapsulates
//	the options of an FFT-stage.  For any 2^N length FFT, there shall be
//	(N-1) of these stages.
//
//
// Operation:
// 	Given a stream of values, operate upon them as though they were
// 	value pairs, x[n] and x[n+N/2].  The stream begins when n=0, and ends
// 	when n=N/2-1 (i.e. there's a full set of N values).  When the value
// 	x[0] enters, the synchronization input, i_sync, must be true as well.
//
// 	For this stream, produce outputs
// 	y[n    ] = x[n] + x[n+N/2], and
// 	y[n+N/2] = (x[n] - x[n+N/2]) * c[n],
// 			where c[n] is a complex coefficient found in the
// 			external memory file COEFFILE.
// 	When y[0] is output, a synchronization bit o_sync will be true as
// 	well, otherwise it will be zero.
//
// 	Most of the work to do this is done within the butterfly, whether the
// 	hardware accelerated butterfly (uses a DSP) or not.
//
// Creator:	Dan Gisselquist, Ph.D.
//		Gisselquist Technology, LLC
//
////////////////////////////////////////////////////////////////////////////////
// }}}
// Copyright (C) 2015-2024, Gisselquist Technology, LLC
// {{{
// This file is part of the general purpose pipelined FFT project.
//
// The pipelined FFT project is free software (firmware): you can redistribute
// it and/or modify it under the terms of the GNU Lesser General Public License
// as published by the Free Software Foundation, either version 3 of the
// License, or (at your option) any later version.
//
// The pipelined FFT project is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTIBILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU Lesser
// General Public License for more details.
//
// You should have received a copy of the GNU Lesser General Public License
// along with this program.  (It's in the $(ROOT)/doc directory.  Run make
// with no target there if the PDF file isn't present.)  If not, see
// <http://www.gnu.org/licenses/> for a copy.
// }}}
// License:	LGPL, v3, as defined and found on www.gnu.org,
// {{{
//		http://www.gnu.org/licenses/lgpl.html
//
// }}}
////////////////////////////////////////////////////////////////////////////////
//
//
`default_nettype	none
//
module	fftstage #(
		// {{{
		parameter	IWIDTH=16,CWIDTH=20,OWIDTH=17,
		// Parameters specific to the core that should be changed when
		// this core is built ... Note that the minimum LGSPAN (the base
		// two log of the span, or the base two log of the current FFT
		// size) is 3.  Smaller spans (i.e. the span of 2) must use the
		// dbl laststage module.
		// Verilator lint_off UNUSED
		parameter	LGSPAN=10, BFLYSHIFT=0, // LGWIDTH=11
		parameter [0:0]	OPT_HWMPY = 1,
		// Clocks per CE.  If your incoming data rate is less than 50%
		// of your clock speed, you can set CKPCE to 2'b10, make sure
		// there's at least one clock between cycles when i_ce is high,
		// and then use two multiplies instead of three.  Setting CKPCE
		// to 2'b11, and insisting on at least two clocks with i_ce low
		// between cycles with i_ce high, then the hardware optimized
		// butterfly code will used one multiply instead of two.
		parameter	CKPCE = 1,
		// The COEFFILE parameter contains the name of the file
		// containing the FFT twiddle factors
		parameter	COEFFILE="cmem_2048.hex",
		// Verilator lint_on  UNUSED

`ifdef	VERILATOR
		parameter  [0:0]	ZERO_ON_IDLE = 1'b0
`else
		localparam [0:0]	ZERO_ON_IDLE = 1'b0
`endif // VERILATOR
		// }}}
	) (
		// {{{
		input	wire				i_clk, i_reset,
							i_ce, i_sync,
		input	wire	[(2*IWIDTH-1):0]	i_data,
		output	reg	[(2*OWIDTH-1):0]	o_data,
		output	reg				o_sync

		// }}}
	);

	// Local signal definitions
	// {{{
	// I am using the prefixes
	// 	ib_*	to reference the inputs to the butterfly, and
	// 	ob_*	to reference the outputs from the butterfly
	reg	wait_for_sync;
	reg	[(2*IWIDTH-1):0]	ib_a, ib_b;
	reg	[(2*CWIDTH-1):0]	ib_c;
	reg	ib_sync;

	reg	b_started;
	wire	ob_sync;
	wire	[(2*OWIDTH-1):0]	ob_a, ob_b;

	// cmem is defined as an array of real and complex values,
	// where the top CWIDTH bits are the real value and the bottom
	// CWIDTH bits are the imaginary value.
	//
	// cmem[i] = { (2^(CWIDTH-2)) * cos(2*pi*i/(2^LGWIDTH)),
	//		(2^(CWIDTH-2)) * sin(2*pi*i/(2^LGWIDTH)) };
	//
`ifdef	FORMAL
	// Let the formal tool pick the coefficients
	reg	[(2*CWIDTH-1):0]	cmem [0:((1<<LGSPAN)-1)];
`endif

	reg	[(LGSPAN):0]		iaddr;
	reg	[(2*IWIDTH-1):0]	imem	[0:((1<<LGSPAN)-1)];

	reg	[LGSPAN:0]		oaddr;
	reg	[(2*OWIDTH-1):0]	omem	[0:((1<<LGSPAN)-1)];

	wire				idle;
	reg	[(LGSPAN-1):0]		nxt_oaddr;
	reg	[(2*OWIDTH-1):0]	pre_ovalue;
	// }}}

`ifndef	FORMAL
	wire	[(2*CWIDTH-1):0]	cmem_rdata;
	generate
	if (LGSPAN == 10) begin : g_cmem_lut
		localparam [39:0] CMEM_INIT [0:1023] = '{
			40'h4000000000,
			40'h3ffffffcdc,
			40'h3fffbff9b8,
			40'h3fff5ff693,
			40'h3ffecff36f,
			40'h3ffe1ff04b,
			40'h3ffd4fed27,
			40'h3ffc4fea03,
			40'h3ffb1fe6df,
			40'h3ff9cfe3bb,
			40'h3ff85fe097,
			40'h3ff6bfdd73,
			40'h3ff4efda4f,
			40'h3ff30fd72c,
			40'h3ff0efd408,
			40'h3feeafd0e5,
			40'h3fec4fcdc1,
			40'h3fe9cfca9e,
			40'h3fe70fc77b,
			40'h3fe43fc458,
			40'h3fe13fc135,
			40'h3fde0fbe12,
			40'h3fdabfbaf0,
			40'h3fd74fb7ce,
			40'h3fd3afb4ab,
			40'h3fcfdfb18a,
			40'h3fcbefae68,
			40'h3fc7dfab46,
			40'h3fc39fa825,
			40'h3fbf3fa504,
			40'h3fbaafa1e3,
			40'h3fb5ff9ec2,
			40'h3fb12f9ba1,
			40'h3fac2f9881,
			40'h3fa6ff9561,
			40'h3fa1af9241,
			40'h3f9c3f8f22,
			40'h3f969f8c03,
			40'h3f90df88e4,
			40'h3f8aef85c5,
			40'h3f84df82a7,
			40'h3f7e9f7f89,
			40'h3f783f7c6b,
			40'h3f71af794e,
			40'h3f6aff7630,
			40'h3f642f7314,
			40'h3f5d2f6ff7,
			40'h3f55ff6cdb,
			40'h3f4ebf69bf,
			40'h3f473f66a4,
			40'h3f3faf6389,
			40'h3f37ef606f,
			40'h3f2fff5d54,
			40'h3f27ef5a3a,
			40'h3f1fbf5721,
			40'h3f175f5408,
			40'h3f0edf50ef,
			40'h3f062f4dd7,
			40'h3efd5f4abf,
			40'h3ef45f47a8,
			40'h3eeb3f4491,
			40'h3ee1ff417b,
			40'h3ed88f3e65,
			40'h3eceff3b4f,
			40'h3ec53f383a,
			40'h3ebb5f3526,
			40'h3eb14f3212,
			40'h3ea71f2efe,
			40'h3e9ccf2beb,
			40'h3e924f28d8,
			40'h3e87af25c6,
			40'h3e7cdf22b5,
			40'h3e71ef1fa4,
			40'h3e66df1c93,
			40'h3e5b9f1984,
			40'h3e503f1674,
			40'h3e44af1366,
			40'h3e38ff1057,
			40'h3e2d2f0d4a,
			40'h3e212f0a3d,
			40'h3e150f0730,
			40'h3e08bf0424,
			40'h3dfc4f0119,
			40'h3defbefe0e,
			40'h3de2fefb04,
			40'h3dd61ef7fb,
			40'h3dc90ef4f2,
			40'h3dbbdef1ea,
			40'h3dae8eeee3,
			40'h3da10eebdc,
			40'h3d936ee8d6,
			40'h3d85aee5d1,
			40'h3d77bee2cc,
			40'h3d69aedfc8,
			40'h3d5b6edcc4,
			40'h3d4d0ed9c2,
			40'h3d3e8ed6c0,
			40'h3d2feed3be,
			40'h3d211ed0be,
			40'h3d121ecdbe,
			40'h3d02fecabf,
			40'h3cf3bec7c1,
			40'h3ce45ec4c3,
			40'h3cd4cec1c6,
			40'h3cc51ebeca,
			40'h3cb54ebbcf,
			40'h3ca54eb8d4,
			40'h3c952eb5db,
			40'h3c84deb2e2,
			40'h3c746eafea,
			40'h3c63deacf2,
			40'h3c532ea9fc,
			40'h3c424ea706,
			40'h3c314ea412,
			40'h3c202ea11e,
			40'h3c0ede9e2a,
			40'h3bfd6e9b38,
			40'h3bebce9847,
			40'h3bda1e9556,
			40'h3bc83e9266,
			40'h3bb62e8f78,
			40'h3ba40e8c8a,
			40'h3b91be899d,
			40'h3b7f4e86b1,
			40'h3b6cae83c5,
			40'h3b59fe80db,
			40'h3b470e7df2,
			40'h3b340e7b09,
			40'h3b20de7822,
			40'h3b0d9e753b,
			40'h3afa1e7256,
			40'h3ae68e6f71,
			40'h3ad2ce6c8d,
			40'h3abeee69ab,
			40'h3aaaee66c9,
			40'h3a96be63e8,
			40'h3a827e6108,
			40'h3a6e0e5e2a,
			40'h3a596e5b4c,
			40'h3a44be586f,
			40'h3a2fde5593,
			40'h3a1ade52b9,
			40'h3a05be4fdf,
			40'h39f06e4d07,
			40'h39dafe4a2f,
			40'h39c56e4758,
			40'h39afbe4483,
			40'h3999ee41af,
			40'h3983ee3edb,
			40'h396dce3c09,
			40'h39578e3938,
			40'h39412e3668,
			40'h392a9e3399,
			40'h3913fe30cb,
			40'h38fd2e2dff,
			40'h38e63e2b33,
			40'h38cf1e2869,
			40'h38b7ee259f,
			40'h38a08e22d7,
			40'h38890e2010,
			40'h38716e1d4a,
			40'h3859ae1a85,
			40'h3841ce17c2,
			40'h3829be1500,
			40'h38119e123e,
			40'h37f94e0f7e,
			40'h37e0de0cc0,
			40'h37c83e0a02,
			40'h37af8e0746,
			40'h3796be048b,
			40'h377dbe01d1,
			40'h37649dff18,
			40'h374b5dfc60,
			40'h3731fdf9aa,
			40'h37187df6f5,
			40'h36feddf442,
			40'h36e50df18f,
			40'h36cb2deede,
			40'h36b11dec2e,
			40'h3696fde97f,
			40'h367cade6d2,
			40'h36623de426,
			40'h3647ade17b,
			40'h362cfdded2,
			40'h36121ddc2a,
			40'h35f72dd983,
			40'h35dc1dd6dd,
			40'h35c0ddd439,
			40'h35a58dd196,
			40'h358a0dcef5,
			40'h356e6dcc55,
			40'h3552bdc9b6,
			40'h3536ddc719,
			40'h351addc47d,
			40'h34febdc1e2,
			40'h34e27dbf49,
			40'h34c61dbcb1,
			40'h34a99dba1a,
			40'h348cfdb785,
			40'h34703db4f2,
			40'h34535db25f,
			40'h34365dafcf,
			40'h34193dad3f,
			40'h33fbfdaab1,
			40'h33de8da825,
			40'h33c10da59a,
			40'h33a36da310,
			40'h3385ada088,
			40'h3367cd9e01,
			40'h3349cd9b7c,
			40'h332bad98f8,
			40'h330d6d9676,
			40'h32ef0d93f5,
			40'h32d08d9176,
			40'h32b1ed8ef8,
			40'h32932d8c7c,
			40'h32744d8a01,
			40'h32555d8787,
			40'h32363d8510,
			40'h3216fd829a,
			40'h31f7ad8025,
			40'h31d82d7db2,
			40'h31b89d7b40,
			40'h3198dd78d0,
			40'h31790d7662,
			40'h31591d73f5,
			40'h31390d7189,
			40'h3118dd6f20,
			40'h30f88d6cb7,
			40'h30d81d6a51,
			40'h30b79d67ec,
			40'h3096ed6588,
			40'h30762d6327,
			40'h30554d60c6,
			40'h30343d5e68,
			40'h30131d5c0b,
			40'h2ff1ed59b0,
			40'h2fd08d5756,
			40'h2faf0d54fe,
			40'h2f8d7d52a8,
			40'h2f6bcd5053,
			40'h2f49fd4e00,
			40'h2f280d4bae,
			40'h2f05fd495f,
			40'h2ee3dd4711,
			40'h2ec19d44c4,
			40'h2e9f3d4279,
			40'h2e7cbd4030,
			40'h2e5a1d3de9,
			40'h2e376d3ba3,
			40'h2e148d3960,
			40'h2df19d371d,
			40'h2dce9d34dd,
			40'h2dab6d329e,
			40'h2d882d3061,
			40'h2d64cd2e26,
			40'h2d414d2bec,
			40'h2d1dad29b4,
			40'h2cf9fd277e,
			40'h2cd62d254a,
			40'h2cb23d2317,
			40'h2c8e3d20e7,
			40'h2c6a0d1eb8,
			40'h2c45dd1c8a,
			40'h2c217d1a5f,
			40'h2bfd0d1835,
			40'h2bd87d160d,
			40'h2bb3cd13e7,
			40'h2b8efd11c3,
			40'h2b6a1d0fa1,
			40'h2b452d0d80,
			40'h2b200d0b61,
			40'h2afadd0944,
			40'h2ad58d0729,
			40'h2ab02d0510,
			40'h2a8aad02f8,
			40'h2a650d00e2,
			40'h2a3f5cfecf,
			40'h2a198cfcbd,
			40'h29f3acfaac,
			40'h29cd9cf89e,
			40'h29a78cf692,
			40'h29814cf487,
			40'h295afcf27f,
			40'h29349cf078,
			40'h290e0cee73,
			40'h28e77cec70,
			40'h28c0bcea6f,
			40'h2899ece870,
			40'h28730ce673,
			40'h284c0ce477,
			40'h2824ece27e,
			40'h27fdbce086,
			40'h27d66cde91,
			40'h27af0cdc9d,
			40'h27879cdaab,
			40'h275ffcd8bc,
			40'h27384cd6ce,
			40'h27108cd4e2,
			40'h26e8acd2f8,
			40'h26c0bcd110,
			40'h2698accf2a,
			40'h26708ccd46,
			40'h26484ccb64,
			40'h261ffcc984,
			40'h25f78cc7a6,
			40'h25cf0cc5ca,
			40'h25a66cc3f0,
			40'h257dbcc218,
			40'h2554fcc041,
			40'h252c1cbe6d,
			40'h25031cbc9b,
			40'h24da1cbacb,
			40'h24b0ecb8fd,
			40'h2487bcb731,
			40'h245e6cb567,
			40'h2434fcb39f,
			40'h240b7cb1d9,
			40'h23e1ecb015,
			40'h23b83cae53,
			40'h238e7cac93,
			40'h2364acaad5,
			40'h233abca91a,
			40'h2310bca760,
			40'h22e6aca5a8,
			40'h22bc7ca3f3,
			40'h22923ca23f,
			40'h2267dca08e,
			40'h223d6c9edf,
			40'h2212ec9d31,
			40'h21e85c9b86,
			40'h21bdac99dd,
			40'h2192ec9836,
			40'h21681c9691,
			40'h213d2c94ef,
			40'h21122c934e,
			40'h20e71c91b0,
			40'h20bbec9013,
			40'h2090bc8e79,
			40'h20656c8ce1,
			40'h203a0c8b4b,
			40'h200e8c89b7,
			40'h1fe2fc8825,
			40'h1fb75c8695,
			40'h1f8bac8508,
			40'h1f5fec837d,
			40'h1f340c81f3,
			40'h1f082c806c,
			40'h1edc2c7ee7,
			40'h1eb00c7d65,
			40'h1e83ec7be4,
			40'h1e57bc7a66,
			40'h1e2b6c78ea,
			40'h1dff0c7770,
			40'h1dd29c75f8,
			40'h1da61c7482,
			40'h1d797c730f,
			40'h1d4cdc719d,
			40'h1d201c702e,
			40'h1cf35c6ec1,
			40'h1cc67c6d57,
			40'h1c998c6bee,
			40'h1c6c8c6a88,
			40'h1c3f7c6924,
			40'h1c125c67c2,
			40'h1be51c6662,
			40'h1bb7dc6505,
			40'h1b8a8c63aa,
			40'h1b5d1c6251,
			40'h1b2f9c60fa,
			40'h1b021c5fa5,
			40'h1ad47c5e53,
			40'h1aa6dc5d03,
			40'h1a791c5bb5,
			40'h1a4b4c5a6a,
			40'h1a1d6c5920,
			40'h19ef8c57d9,
			40'h19c18c5695,
			40'h19937c5552,
			40'h19655c5412,
			40'h19373c52d4,
			40'h1908fc5198,
			40'h18daac505f,
			40'h18ac5c4f27,
			40'h187dec4df3,
			40'h184f7c4cc0,
			40'h1820ec4b90,
			40'h17f25c4a61,
			40'h17c3bc4936,
			40'h1794fc480c,
			40'h17663c46e5,
			40'h17376c45c0,
			40'h17088c449e,
			40'h16d9ac437d,
			40'h16aaac425f,
			40'h167b9c4144,
			40'h164c8c402a,
			40'h161d6c3f13,
			40'h15ee2c3dfe,
			40'h15beec3cec,
			40'h158fac3bdc,
			40'h15604c3ace,
			40'h1530ec39c3,
			40'h15016c38ba,
			40'h14d1ec37b3,
			40'h14a25c36ae,
			40'h1472cc35ac,
			40'h14431c34ac,
			40'h14136c33af,
			40'h13e3ac32b4,
			40'h13b3dc31bb,
			40'h1383fc30c5,
			40'h13541c2fd1,
			40'h13242c2edf,
			40'h12f42c2def,
			40'h12c42c2d02,
			40'h12940c2c18,
			40'h1263ec2b30,
			40'h1233cc2a4a,
			40'h12038c2966,
			40'h11d34c2885,
			40'h11a2fc27a6,
			40'h1172ac26ca,
			40'h11424c25f0,
			40'h1111dc2518,
			40'h10e16c2443,
			40'h10b0ec2370,
			40'h10805c229f,
			40'h104fcc21d1,
			40'h101f2c2105,
			40'h0fee7c203c,
			40'h0fbdcc1f75,
			40'h0f8d0c1eb0,
			40'h0f5c3c1dee,
			40'h0f2b6c1d2e,
			40'h0efa9c1c71,
			40'h0ec9ac1bb6,
			40'h0e98cc1afd,
			40'h0e67cc1a47,
			40'h0e36dc1993,
			40'h0e05cc18e2,
			40'h0dd4bc1833,
			40'h0da3ac1786,
			40'h0d728c16dc,
			40'h0d415c1634,
			40'h0d102c158f,
			40'h0cdeec14ec,
			40'h0cadac144b,
			40'h0c7c6c13ad,
			40'h0c4b1c1311,
			40'h0c19bc1278,
			40'h0be85c11e1,
			40'h0bb6fc114d,
			40'h0b858c10bb,
			40'h0b541c102b,
			40'h0b229c0f9e,
			40'h0af11c0f13,
			40'h0abf8c0e8b,
			40'h0a8dfc0e05,
			40'h0a5c6c0d82,
			40'h0a2acc0d01,
			40'h09f91c0c82,
			40'h09c77c0c06,
			40'h0995cc0b8d,
			40'h09641c0b15,
			40'h09325c0aa1,
			40'h09009c0a2e,
			40'h08cecc09be,
			40'h089d0c0951,
			40'h086b2c08e6,
			40'h08395c087d,
			40'h08077c0817,
			40'h07d59c07b3,
			40'h07a3bc0752,
			40'h0771cc06f3,
			40'h073fdc0697,
			40'h070dec063d,
			40'h06dbfc05e6,
			40'h06a9fc0591,
			40'h0677fc053e,
			40'h0645fc04ee,
			40'h0613ec04a1,
			40'h05e1dc0456,
			40'h05afcc040d,
			40'h057dbc03c7,
			40'h054bac0383,
			40'h05198c0342,
			40'h04e76c0303,
			40'h04b55c02c6,
			40'h04832c028c,
			40'h04510c0255,
			40'h041eec0220,
			40'h03ecbc01ed,
			40'h03ba8c01bd,
			40'h03885c0190,
			40'h03562c0164,
			40'h0323fc013c,
			40'h02f1bc0116,
			40'h02bf8c00f2,
			40'h028d4c00d0,
			40'h025b1c00b2,
			40'h0228dc0095,
			40'h01f69c007b,
			40'h01c45c0064,
			40'h01921c004f,
			40'h015fdc003c,
			40'h012d9c002c,
			40'h00fb5c001f,
			40'h00c91c0014,
			40'h0096dc000b,
			40'h00648c0005,
			40'h00324c0001,
			40'h00000c0000,
			40'hffcdcc0001,
			40'hff9b8c0005,
			40'hff693c000b,
			40'hff36fc0014,
			40'hff04bc001f,
			40'hfed27c002c,
			40'hfea03c003c,
			40'hfe6dfc004f,
			40'hfe3bbc0064,
			40'hfe097c007b,
			40'hfdd73c0095,
			40'hfda4fc00b2,
			40'hfd72cc00d0,
			40'hfd408c00f2,
			40'hfd0e5c0116,
			40'hfcdc1c013c,
			40'hfca9ec0164,
			40'hfc77bc0190,
			40'hfc458c01bd,
			40'hfc135c01ed,
			40'hfbe12c0220,
			40'hfbaf0c0255,
			40'hfb7cec028c,
			40'hfb4abc02c6,
			40'hfb18ac0303,
			40'hfae68c0342,
			40'hfab46c0383,
			40'hfa825c03c7,
			40'hfa504c040d,
			40'hfa1e3c0456,
			40'hf9ec2c04a1,
			40'hf9ba1c04ee,
			40'hf9881c053e,
			40'hf9561c0591,
			40'hf9241c05e6,
			40'hf8f22c063d,
			40'hf8c03c0697,
			40'hf88e4c06f3,
			40'hf85c5c0752,
			40'hf82a7c07b3,
			40'hf7f89c0817,
			40'hf7c6bc087d,
			40'hf794ec08e6,
			40'hf7630c0951,
			40'hf7314c09be,
			40'hf6ff7c0a2e,
			40'hf6cdbc0aa1,
			40'hf69bfc0b15,
			40'hf66a4c0b8d,
			40'hf6389c0c06,
			40'hf606fc0c82,
			40'hf5d54c0d01,
			40'hf5a3ac0d82,
			40'hf5721c0e05,
			40'hf5408c0e8b,
			40'hf50efc0f13,
			40'hf4dd7c0f9e,
			40'hf4abfc102b,
			40'hf47a8c10bb,
			40'hf4491c114d,
			40'hf417bc11e1,
			40'hf3e65c1278,
			40'hf3b4fc1311,
			40'hf383ac13ad,
			40'hf3526c144b,
			40'hf3212c14ec,
			40'hf2efec158f,
			40'hf2bebc1634,
			40'hf28d8c16dc,
			40'hf25c6c1786,
			40'hf22b5c1833,
			40'hf1fa4c18e2,
			40'hf1c93c1993,
			40'hf1984c1a47,
			40'hf1674c1afd,
			40'hf1366c1bb6,
			40'hf1057c1c71,
			40'hf0d4ac1d2e,
			40'hf0a3dc1dee,
			40'hf0730c1eb0,
			40'hf0424c1f75,
			40'hf0119c203c,
			40'hefe0ec2105,
			40'hefb04c21d1,
			40'hef7fbc229f,
			40'hef4f2c2370,
			40'hef1eac2443,
			40'heeee3c2518,
			40'heebdcc25f0,
			40'hee8d6c26ca,
			40'hee5d1c27a6,
			40'hee2ccc2885,
			40'hedfc8c2966,
			40'hedcc4c2a4a,
			40'hed9c2c2b30,
			40'hed6c0c2c18,
			40'hed3bec2d02,
			40'hed0bec2def,
			40'hecdbec2edf,
			40'hecabfc2fd1,
			40'hec7c1c30c5,
			40'hec4c3c31bb,
			40'hec1c6c32b4,
			40'hebecac33af,
			40'hebbcfc34ac,
			40'heb8d4c35ac,
			40'heb5dbc36ae,
			40'heb2e2c37b3,
			40'heafeac38ba,
			40'heacf2c39c3,
			40'hea9fcc3ace,
			40'hea706c3bdc,
			40'hea412c3cec,
			40'hea11ec3dfe,
			40'he9e2ac3f13,
			40'he9b38c402a,
			40'he9847c4144,
			40'he9556c425f,
			40'he9266c437d,
			40'he8f78c449e,
			40'he8c8ac45c0,
			40'he899dc46e5,
			40'he86b1c480c,
			40'he83c5c4936,
			40'he80dbc4a61,
			40'he7df2c4b90,
			40'he7b09c4cc0,
			40'he7822c4df3,
			40'he753bc4f27,
			40'he7256c505f,
			40'he6f71c5198,
			40'he6c8dc52d4,
			40'he69abc5412,
			40'he66c9c5552,
			40'he63e8c5695,
			40'he6108c57d9,
			40'he5e2ac5920,
			40'he5b4cc5a6a,
			40'he586fc5bb5,
			40'he5593c5d03,
			40'he52b9c5e53,
			40'he4fdfc5fa5,
			40'he4d07c60fa,
			40'he4a2fc6251,
			40'he4758c63aa,
			40'he4483c6505,
			40'he41afc6662,
			40'he3edbc67c2,
			40'he3c09c6924,
			40'he3938c6a88,
			40'he3668c6bee,
			40'he3399c6d57,
			40'he30cbc6ec1,
			40'he2dffc702e,
			40'he2b33c719d,
			40'he2869c730f,
			40'he259fc7482,
			40'he22d7c75f8,
			40'he2010c7770,
			40'he1d4ac78ea,
			40'he1a85c7a66,
			40'he17c2c7be4,
			40'he1500c7d65,
			40'he123ec7ee7,
			40'he0f7ec806c,
			40'he0cc0c81f3,
			40'he0a02c837d,
			40'he0746c8508,
			40'he048bc8695,
			40'he01d1c8825,
			40'hdff18c89b7,
			40'hdfc60c8b4b,
			40'hdf9aac8ce1,
			40'hdf6f5c8e79,
			40'hdf442c9013,
			40'hdf18fc91b0,
			40'hdeedec934e,
			40'hdec2ec94ef,
			40'hde97fc9691,
			40'hde6d2c9836,
			40'hde426c99dd,
			40'hde17bc9b86,
			40'hdded2c9d31,
			40'hddc2ac9edf,
			40'hdd983ca08e,
			40'hdd6ddca23f,
			40'hdd439ca3f3,
			40'hdd196ca5a8,
			40'hdcef5ca760,
			40'hdcc55ca91a,
			40'hdc9b6caad5,
			40'hdc719cac93,
			40'hdc47dcae53,
			40'hdc1e2cb015,
			40'hdbf49cb1d9,
			40'hdbcb1cb39f,
			40'hdba1acb567,
			40'hdb785cb731,
			40'hdb4f2cb8fd,
			40'hdb25fcbacb,
			40'hdafcfcbc9b,
			40'hdad3fcbe6d,
			40'hdaab1cc041,
			40'hda825cc218,
			40'hda59acc3f0,
			40'hda310cc5ca,
			40'hda088cc7a6,
			40'hd9e01cc984,
			40'hd9b7cccb64,
			40'hd98f8ccd46,
			40'hd9676ccf2a,
			40'hd93f5cd110,
			40'hd9176cd2f8,
			40'hd8ef8cd4e2,
			40'hd8c7ccd6ce,
			40'hd8a01cd8bc,
			40'hd8787cdaab,
			40'hd8510cdc9d,
			40'hd829acde91,
			40'hd8025ce086,
			40'hd7db2ce27e,
			40'hd7b40ce477,
			40'hd78d0ce673,
			40'hd7662ce870,
			40'hd73f5cea6f,
			40'hd7189cec70,
			40'hd6f20cee73,
			40'hd6cb7cf078,
			40'hd6a51cf27f,
			40'hd67eccf487,
			40'hd6588cf692,
			40'hd6327cf89e,
			40'hd60c6cfaac,
			40'hd5e68cfcbd,
			40'hd5c0bcfecf,
			40'hd59b0d00e2,
			40'hd5756d02f8,
			40'hd54fed0510,
			40'hd52a8d0729,
			40'hd5053d0944,
			40'hd4e00d0b61,
			40'hd4baed0d80,
			40'hd495fd0fa1,
			40'hd4711d11c3,
			40'hd44c4d13e7,
			40'hd4279d160d,
			40'hd4030d1835,
			40'hd3de9d1a5f,
			40'hd3ba3d1c8a,
			40'hd3960d1eb8,
			40'hd371dd20e7,
			40'hd34ddd2317,
			40'hd329ed254a,
			40'hd3061d277e,
			40'hd2e26d29b4,
			40'hd2becd2bec,
			40'hd29b4d2e26,
			40'hd277ed3061,
			40'hd254ad329e,
			40'hd2317d34dd,
			40'hd20e7d371d,
			40'hd1eb8d3960,
			40'hd1c8ad3ba3,
			40'hd1a5fd3de9,
			40'hd1835d4030,
			40'hd160dd4279,
			40'hd13e7d44c4,
			40'hd11c3d4711,
			40'hd0fa1d495f,
			40'hd0d80d4bae,
			40'hd0b61d4e00,
			40'hd0944d5053,
			40'hd0729d52a8,
			40'hd0510d54fe,
			40'hd02f8d5756,
			40'hd00e2d59b0,
			40'hcfecfd5c0b,
			40'hcfcbdd5e68,
			40'hcfaacd60c6,
			40'hcf89ed6327,
			40'hcf692d6588,
			40'hcf487d67ec,
			40'hcf27fd6a51,
			40'hcf078d6cb7,
			40'hcee73d6f20,
			40'hcec70d7189,
			40'hcea6fd73f5,
			40'hce870d7662,
			40'hce673d78d0,
			40'hce477d7b40,
			40'hce27ed7db2,
			40'hce086d8025,
			40'hcde91d829a,
			40'hcdc9dd8510,
			40'hcdaabd8787,
			40'hcd8bcd8a01,
			40'hcd6ced8c7c,
			40'hcd4e2d8ef8,
			40'hcd2f8d9176,
			40'hcd110d93f5,
			40'hccf2ad9676,
			40'hccd46d98f8,
			40'hccb64d9b7c,
			40'hcc984d9e01,
			40'hcc7a6da088,
			40'hcc5cada310,
			40'hcc3f0da59a,
			40'hcc218da825,
			40'hcc041daab1,
			40'hcbe6ddad3f,
			40'hcbc9bdafcf,
			40'hcbacbdb25f,
			40'hcb8fddb4f2,
			40'hcb731db785,
			40'hcb567dba1a,
			40'hcb39fdbcb1,
			40'hcb1d9dbf49,
			40'hcb015dc1e2,
			40'hcae53dc47d,
			40'hcac93dc719,
			40'hcaad5dc9b6,
			40'hca91adcc55,
			40'hca760dcef5,
			40'hca5a8dd196,
			40'hca3f3dd439,
			40'hca23fdd6dd,
			40'hca08edd983,
			40'hc9edfddc2a,
			40'hc9d31dded2,
			40'hc9b86de17b,
			40'hc99ddde426,
			40'hc9836de6d2,
			40'hc9691de97f,
			40'hc94efdec2e,
			40'hc934edeede,
			40'hc91b0df18f,
			40'hc9013df442,
			40'hc8e79df6f5,
			40'hc8ce1df9aa,
			40'hc8b4bdfc60,
			40'hc89b7dff18,
			40'hc8825e01d1,
			40'hc8695e048b,
			40'hc8508e0746,
			40'hc837de0a02,
			40'hc81f3e0cc0,
			40'hc806ce0f7e,
			40'hc7ee7e123e,
			40'hc7d65e1500,
			40'hc7be4e17c2,
			40'hc7a66e1a85,
			40'hc78eae1d4a,
			40'hc7770e2010,
			40'hc75f8e22d7,
			40'hc7482e259f,
			40'hc730fe2869,
			40'hc719de2b33,
			40'hc702ee2dff,
			40'hc6ec1e30cb,
			40'hc6d57e3399,
			40'hc6beee3668,
			40'hc6a88e3938,
			40'hc6924e3c09,
			40'hc67c2e3edb,
			40'hc6662e41af,
			40'hc6505e4483,
			40'hc63aae4758,
			40'hc6251e4a2f,
			40'hc60fae4d07,
			40'hc5fa5e4fdf,
			40'hc5e53e52b9,
			40'hc5d03e5593,
			40'hc5bb5e586f,
			40'hc5a6ae5b4c,
			40'hc5920e5e2a,
			40'hc57d9e6108,
			40'hc5695e63e8,
			40'hc5552e66c9,
			40'hc5412e69ab,
			40'hc52d4e6c8d,
			40'hc5198e6f71,
			40'hc505fe7256,
			40'hc4f27e753b,
			40'hc4df3e7822,
			40'hc4cc0e7b09,
			40'hc4b90e7df2,
			40'hc4a61e80db,
			40'hc4936e83c5,
			40'hc480ce86b1,
			40'hc46e5e899d,
			40'hc45c0e8c8a,
			40'hc449ee8f78,
			40'hc437de9266,
			40'hc425fe9556,
			40'hc4144e9847,
			40'hc402ae9b38,
			40'hc3f13e9e2a,
			40'hc3dfeea11e,
			40'hc3cecea412,
			40'hc3bdcea706,
			40'hc3aceea9fc,
			40'hc39c3eacf2,
			40'hc38baeafea,
			40'hc37b3eb2e2,
			40'hc36aeeb5db,
			40'hc35aceb8d4,
			40'hc34acebbcf,
			40'hc33afebeca,
			40'hc32b4ec1c6,
			40'hc31bbec4c3,
			40'hc30c5ec7c1,
			40'hc2fd1ecabf,
			40'hc2edfecdbe,
			40'hc2defed0be,
			40'hc2d02ed3be,
			40'hc2c18ed6c0,
			40'hc2b30ed9c2,
			40'hc2a4aedcc4,
			40'hc2966edfc8,
			40'hc2885ee2cc,
			40'hc27a6ee5d1,
			40'hc26caee8d6,
			40'hc25f0eebdc,
			40'hc2518eeee3,
			40'hc2443ef1ea,
			40'hc2370ef4f2,
			40'hc229fef7fb,
			40'hc21d1efb04,
			40'hc2105efe0e,
			40'hc203cf0119,
			40'hc1f75f0424,
			40'hc1eb0f0730,
			40'hc1deef0a3d,
			40'hc1d2ef0d4a,
			40'hc1c71f1057,
			40'hc1bb6f1366,
			40'hc1afdf1674,
			40'hc1a47f1984,
			40'hc1993f1c93,
			40'hc18e2f1fa4,
			40'hc1833f22b5,
			40'hc1786f25c6,
			40'hc16dcf28d8,
			40'hc1634f2beb,
			40'hc158ff2efe,
			40'hc14ecf3212,
			40'hc144bf3526,
			40'hc13adf383a,
			40'hc1311f3b4f,
			40'hc1278f3e65,
			40'hc11e1f417b,
			40'hc114df4491,
			40'hc10bbf47a8,
			40'hc102bf4abf,
			40'hc0f9ef4dd7,
			40'hc0f13f50ef,
			40'hc0e8bf5408,
			40'hc0e05f5721,
			40'hc0d82f5a3a,
			40'hc0d01f5d54,
			40'hc0c82f606f,
			40'hc0c06f6389,
			40'hc0b8df66a4,
			40'hc0b15f69bf,
			40'hc0aa1f6cdb,
			40'hc0a2ef6ff7,
			40'hc09bef7314,
			40'hc0951f7630,
			40'hc08e6f794e,
			40'hc087df7c6b,
			40'hc0817f7f89,
			40'hc07b3f82a7,
			40'hc0752f85c5,
			40'hc06f3f88e4,
			40'hc0697f8c03,
			40'hc063df8f22,
			40'hc05e6f9241,
			40'hc0591f9561,
			40'hc053ef9881,
			40'hc04eef9ba1,
			40'hc04a1f9ec2,
			40'hc0456fa1e3,
			40'hc040dfa504,
			40'hc03c7fa825,
			40'hc0383fab46,
			40'hc0342fae68,
			40'hc0303fb18a,
			40'hc02c6fb4ab,
			40'hc028cfb7ce,
			40'hc0255fbaf0,
			40'hc0220fbe12,
			40'hc01edfc135,
			40'hc01bdfc458,
			40'hc0190fc77b,
			40'hc0164fca9e,
			40'hc013cfcdc1,
			40'hc0116fd0e5,
			40'hc00f2fd408,
			40'hc00d0fd72c,
			40'hc00b2fda4f,
			40'hc0095fdd73,
			40'hc007bfe097,
			40'hc0064fe3bb,
			40'hc004ffe6df,
			40'hc003cfea03,
			40'hc002cfed27,
			40'hc001fff04b,
			40'hc0014ff36f,
			40'hc000bff693,
			40'hc0005ff9b8,
			40'hc0001ffcdc
		};
		assign cmem_rdata = CMEM_INIT[iaddr[(LGSPAN-1):0]];
	end
	else if (LGSPAN == 9) begin : g_cmem_lut
		localparam [41:0] CMEM_INIT [0:511] = '{
			42'h10000000000,
			42'h0fffedff36f,
			42'h0fffb3fe6de,
			42'h0fff4ffda4e,
			42'h0ffec5fcdbd,
			42'h0ffe13fc12e,
			42'h0ffd3bfb49e,
			42'h0ffc39fa810,
			42'h0ffb11f9b82,
			42'h0ff9c3f8ef6,
			42'h0ff84bf826a,
			42'h0ff6adf75e0,
			42'h0ff4e7f6957,
			42'h0ff2fbf5ccf,
			42'h0ff0e7f5049,
			42'h0feeabf43c5,
			42'h0fec47f3743,
			42'h0fe9bdf2ac2,
			42'h0fe70bf1e44,
			42'h0fe433f11c8,
			42'h0fe133f054e,
			42'h0fde0def8d6,
			42'h0fdabdeec61,
			42'h0fd749edfef,
			42'h0fd3abed37f,
			42'h0fcfe9ec712,
			42'h0fcbfdebaa9,
			42'h0fc7ebeae42,
			42'h0fc3b3ea1df,
			42'h0fbf55e957f,
			42'h0fbacde8922,
			42'h0fb621e7cca,
			42'h0fb14de7074,
			42'h0fac53e6423,
			42'h0fa731e57d6,
			42'h0fa1e9e4b8d,
			42'h0f9c7be3f48,
			42'h0f96e5e3307,
			42'h0f912be26cb,
			42'h0f8b49e1a93,
			42'h0f8541e0e60,
			42'h0f7f13e0232,
			42'h0f78bddf609,
			42'h0f7243de9e5,
			42'h0f6ba1dddc6,
			42'h0f64dbdd1ac,
			42'h0f5deddc597,
			42'h0f56dbdb989,
			42'h0f4fa1dad7f,
			42'h0f4843da17c,
			42'h0f40bfd957e,
			42'h0f3915d8986,
			42'h0f3145d7d94,
			42'h0f2951d71a9,
			42'h0f2137d65c4,
			42'h0f18f7d59e5,
			42'h0f1091d4e0d,
			42'h0f0807d423b,
			42'h0eff59d3670,
			42'h0ef683d2aac,
			42'h0eed8bd1eef,
			42'h0ee46dd1339,
			42'h0edb2bd078b,
			42'h0ed1c3cfbe4,
			42'h0ec837cf044,
			42'h0ebe87ce4ab,
			42'h0eb4b1cd91b,
			42'h0eaab9ccd92,
			42'h0ea09bcc211,
			42'h0e965bcb698,
			42'h0e8bf5cab27,
			42'h0e816bc9fbe,
			42'h0e76bfc945e,
			42'h0e6bedc8906,
			42'h0e60f9c7db7,
			42'h0e55e1c7270,
			42'h0e4aa7c6732,
			42'h0e3f49c5bfd,
			42'h0e33c7c50d1,
			42'h0e2823c45ae,
			42'h0e1c5bc3a94,
			42'h0e1071c2f84,
			42'h0e0463c247d,
			42'h0df833c197f,
			42'h0debe1c0e8b,
			42'h0ddf6dc03a1,
			42'h0dd2d7bf8c1,
			42'h0dc61dbedea,
			42'h0db943be31e,
			42'h0dac45bd85c,
			42'h0d9f27bcda4,
			42'h0d91e7bc2f6,
			42'h0d8487bb853,
			42'h0d7703badbb,
			42'h0d695fba32d,
			42'h0d5b9bb98a9,
			42'h0d4db5b8e31,
			42'h0d3fadb83c4,
			42'h0d3185b7962,
			42'h0d233db6f0b,
			42'h0d14d5b64bf,
			42'h0d064bb5a7e,
			42'h0cf7a3b5049,
			42'h0ce8d9b4620,
			42'h0cd9f1b3c02,
			42'h0ccae9b31f0,
			42'h0cbbc1b27ea,
			42'h0cac79b1df0,
			42'h0c9d13b1401,
			42'h0c8d8db0a1f,
			42'h0c7de7b004a,
			42'h0c6e23af680,
			42'h0c5e41aecc3,
			42'h0c4e41ae313,
			42'h0c3e21ad96f,
			42'h0c2de3acfd8,
			42'h0c1d89ac64d,
			42'h0c0d0fabcd0,
			42'h0bfc77ab35f,
			42'h0bebc3aa9fc,
			42'h0bdaf1aa0a6,
			42'h0bca01a975d,
			42'h0bb8f5a8e21,
			42'h0ba7cba84f3,
			42'h0b9685a7bd2,
			42'h0b8523a72bf,
			42'h0b73a3a69ba,
			42'h0b6207a60c2,
			42'h0b5051a57d8,
			42'h0b3e7da4efd,
			42'h0b2c8da462f,
			42'h0b1a83a3d6f,
			42'h0b085da34be,
			42'h0af61ba2c1b,
			42'h0ae3bfa2386,
			42'h0ad147a1b00,
			42'h0abeb5a1288,
			42'h0aac09a0a1f,
			42'h0a9943a01c5,
			42'h0a86619f979,
			42'h0a73679f13c,
			42'h0a60519e90f,
			42'h0a4d239e0f0,
			42'h0a39db9d8e0,
			42'h0a267b9d0e0,
			42'h0a13019c8ef,
			42'h09ff6d9c10d,
			42'h09ebc39b93a,
			42'h09d7ff9b177,
			42'h09c4219a9c4,
			42'h09b02d9a220,
			42'h099c2199a8c,
			42'h0987fd99308,
			42'h0973c198b94,
			42'h095f6f9842f,
			42'h094b0597cdb,
			42'h09368397596,
			42'h0921eb96e62,
			42'h090d3d9673e,
			42'h08f8799602a,
			42'h08e39f95926,
			42'h08ceaf95233,
			42'h08b9a794b51,
			42'h08a48b9447f,
			42'h088f5b93dbd,
			42'h087a159370d,
			42'h0864b99306d,
			42'h084f49929de,
			42'h0839c59235f,
			42'h08242d91cf2,
			42'h080e7f91695,
			42'h07f8bf9104a,
			42'h07e2eb90a10,
			42'h07cd03903e7,
			42'h07b7078fdcf,
			42'h07a0f98f7c8,
			42'h078ad98f1d3,
			42'h0774a58ebef,
			42'h075e5f8e61d,
			42'h0748078e05c,
			42'h07319d8daad,
			42'h071b218d510,
			42'h0704938cf84,
			42'h06edf58ca0a,
			42'h06d7458c4a1,
			42'h06c0858bf4b,
			42'h06a9b38ba06,
			42'h0692d18b4d3,
			42'h067bdf8afb3,
			42'h0664dd8aaa4,
			42'h064dcb8a5a8,
			42'h0636ab8a0bd,
			42'h061f7989be5,
			42'h0608398971f,
			42'h05f0eb8926b,
			42'h05d98f88dca,
			42'h05c2238893b,
			42'h05aaa9884bf,
			42'h05932188054,
			42'h057b8b87bfd,
			42'h0563e7877b8,
			42'h054c3787385,
			42'h05347986f65,
			42'h051caf86b58,
			42'h0504d98675e,
			42'h04ecf586376,
			42'h04d50585fa1,
			42'h04bd0985bdf,
			42'h04a50385830,
			42'h048cef85493,
			42'h0474d38510a,
			42'h045ca984d93,
			42'h04447584a30,
			42'h042c37846df,
			42'h0413ef843a2,
			42'h03fb9d84077,
			42'h03e34183d60,
			42'h03cadb83a5c,
			42'h03b26b8376b,
			42'h0399f38348e,
			42'h038171831c3,
			42'h0368e782f0c,
			42'h03505582c68,
			42'h0337bb829d7,
			42'h031f198275a,
			42'h03066d824f0,
			42'h02edbd8229a,
			42'h02d50382056,
			42'h02bc4381e27,
			42'h02a37d81c0b,
			42'h028aaf81a02,
			42'h0271dd8180c,
			42'h0259038162b,
			42'h0240238145c,
			42'h02273f812a2,
			42'h020e55810fa,
			42'h01f56580f67,
			42'h01dc7180de7,
			42'h01c37980c7b,
			42'h01aa7d80b22,
			42'h01917b809dd,
			42'h017877808ab,
			42'h015f6f8078d,
			42'h01466380683,
			42'h012d538058d,
			42'h011441804aa,
			42'h00fb2d803db,
			42'h00e2158031f,
			42'h00c8fd80278,
			42'h00afe1801e4,
			42'h0096c580163,
			42'h007da5800f7,
			42'h0064878009e,
			42'h004b6580059,
			42'h00324580027,
			42'h0019238000a,
			42'h00000180000,
			42'h3fe6df8000a,
			42'h3fcdbd80027,
			42'h3fb49d80059,
			42'h3f9b7b8009e,
			42'h3f825d800f7,
			42'h3f693d80163,
			42'h3f5021801e4,
			42'h3f370580278,
			42'h3f1ded8031f,
			42'h3f04d5803db,
			42'h3eebc1804aa,
			42'h3ed2af8058d,
			42'h3eb99f80683,
			42'h3ea0938078d,
			42'h3e878b808ab,
			42'h3e6e87809dd,
			42'h3e558580b22,
			42'h3e3c8980c7b,
			42'h3e239180de7,
			42'h3e0a9d80f67,
			42'h3df1ad810fa,
			42'h3dd8c3812a2,
			42'h3dbfdf8145c,
			42'h3da6ff8162b,
			42'h3d8e258180c,
			42'h3d755381a02,
			42'h3d5c8581c0b,
			42'h3d43bf81e27,
			42'h3d2aff82056,
			42'h3d12458229a,
			42'h3cf995824f0,
			42'h3ce0e98275a,
			42'h3cc847829d7,
			42'h3cafad82c68,
			42'h3c971b82f0c,
			42'h3c7e91831c3,
			42'h3c660f8348e,
			42'h3c4d978376b,
			42'h3c352783a5c,
			42'h3c1cc183d60,
			42'h3c046584077,
			42'h3bec13843a2,
			42'h3bd3cb846df,
			42'h3bbb8d84a30,
			42'h3ba35984d93,
			42'h3b8b2f8510a,
			42'h3b731385493,
			42'h3b5aff85830,
			42'h3b42f985bdf,
			42'h3b2afd85fa1,
			42'h3b130d86376,
			42'h3afb298675e,
			42'h3ae35386b58,
			42'h3acb8986f65,
			42'h3ab3cb87385,
			42'h3a9c1b877b8,
			42'h3a847787bfd,
			42'h3a6ce188054,
			42'h3a5559884bf,
			42'h3a3ddf8893b,
			42'h3a267388dca,
			42'h3a0f178926b,
			42'h39f7c98971f,
			42'h39e08989be5,
			42'h39c9578a0bd,
			42'h39b2378a5a8,
			42'h399b258aaa4,
			42'h3984238afb3,
			42'h396d318b4d3,
			42'h39564f8ba06,
			42'h393f7d8bf4b,
			42'h3928bd8c4a1,
			42'h39120d8ca0a,
			42'h38fb6f8cf84,
			42'h38e4e18d510,
			42'h38ce658daad,
			42'h38b7fb8e05c,
			42'h38a1a38e61d,
			42'h388b5d8ebef,
			42'h3875298f1d3,
			42'h385f098f7c8,
			42'h3848fb8fdcf,
			42'h3832ff903e7,
			42'h381d1790a10,
			42'h3807439104a,
			42'h37f18391695,
			42'h37dbd591cf2,
			42'h37c63d9235f,
			42'h37b0b9929de,
			42'h379b499306d,
			42'h3785ed9370d,
			42'h3770a793dbd,
			42'h375b779447f,
			42'h37465b94b51,
			42'h37315395233,
			42'h371c6395926,
			42'h3707899602a,
			42'h36f2c59673e,
			42'h36de1796e62,
			42'h36c97f97596,
			42'h36b4fd97cdb,
			42'h36a0939842f,
			42'h368c4198b94,
			42'h36780599308,
			42'h3663e199a8c,
			42'h364fd59a220,
			42'h363be19a9c4,
			42'h3628039b177,
			42'h36143f9b93a,
			42'h3600959c10d,
			42'h35ed019c8ef,
			42'h35d9879d0e0,
			42'h35c6279d8e0,
			42'h35b2df9e0f0,
			42'h359fb19e90f,
			42'h358c9b9f13c,
			42'h3579a19f979,
			42'h3566bfa01c5,
			42'h3553f9a0a1f,
			42'h35414da1288,
			42'h352ebba1b00,
			42'h351c43a2386,
			42'h3509e7a2c1b,
			42'h34f7a5a34be,
			42'h34e57fa3d6f,
			42'h34d375a462f,
			42'h34c185a4efd,
			42'h34afb1a57d8,
			42'h349dfba60c2,
			42'h348c5fa69ba,
			42'h347adfa72bf,
			42'h34697da7bd2,
			42'h345837a84f3,
			42'h34470da8e21,
			42'h343601a975d,
			42'h342511aa0a6,
			42'h34143faa9fc,
			42'h34038bab35f,
			42'h33f2f3abcd0,
			42'h33e279ac64d,
			42'h33d21facfd8,
			42'h33c1e1ad96f,
			42'h33b1c1ae313,
			42'h33a1c1aecc3,
			42'h3391dfaf680,
			42'h33821bb004a,
			42'h337275b0a1f,
			42'h3362efb1401,
			42'h335389b1df0,
			42'h334441b27ea,
			42'h333519b31f0,
			42'h332611b3c02,
			42'h331729b4620,
			42'h33085fb5049,
			42'h32f9b7b5a7e,
			42'h32eb2db64bf,
			42'h32dcc5b6f0b,
			42'h32ce7db7962,
			42'h32c055b83c4,
			42'h32b24db8e31,
			42'h32a467b98a9,
			42'h3296a3ba32d,
			42'h3288ffbadbb,
			42'h327b7bbb853,
			42'h326e1bbc2f6,
			42'h3260dbbcda4,
			42'h3253bdbd85c,
			42'h3246bfbe31e,
			42'h3239e5bedea,
			42'h322d2bbf8c1,
			42'h322095c03a1,
			42'h321421c0e8b,
			42'h3207cfc197f,
			42'h31fb9fc247d,
			42'h31ef91c2f84,
			42'h31e3a7c3a94,
			42'h31d7dfc45ae,
			42'h31cc3bc50d1,
			42'h31c0b9c5bfd,
			42'h31b55bc6732,
			42'h31aa21c7270,
			42'h319f09c7db7,
			42'h319415c8906,
			42'h318943c945e,
			42'h317e97c9fbe,
			42'h31740dcab27,
			42'h3169a7cb698,
			42'h315f67cc211,
			42'h315549ccd92,
			42'h314b51cd91b,
			42'h31417bce4ab,
			42'h3137cbcf044,
			42'h312e3fcfbe4,
			42'h3124d7d078b,
			42'h311b95d1339,
			42'h311277d1eef,
			42'h31097fd2aac,
			42'h3100a9d3670,
			42'h30f7fbd423b,
			42'h30ef71d4e0d,
			42'h30e70bd59e5,
			42'h30decbd65c4,
			42'h30d6b1d71a9,
			42'h30cebdd7d94,
			42'h30c6edd8986,
			42'h30bf43d957e,
			42'h30b7bfda17c,
			42'h30b061dad7f,
			42'h30a927db989,
			42'h30a215dc597,
			42'h309b27dd1ac,
			42'h309461dddc6,
			42'h308dbfde9e5,
			42'h308745df609,
			42'h3080efe0232,
			42'h307ac1e0e60,
			42'h3074b9e1a93,
			42'h306ed7e26cb,
			42'h30691de3307,
			42'h306387e3f48,
			42'h305e19e4b8d,
			42'h3058d1e57d6,
			42'h3053afe6423,
			42'h304eb5e7074,
			42'h3049e1e7cca,
			42'h304535e8922,
			42'h3040ade957f,
			42'h303c4fea1df,
			42'h303817eae42,
			42'h303405ebaa9,
			42'h303019ec712,
			42'h302c57ed37f,
			42'h3028b9edfef,
			42'h302545eec61,
			42'h3021f5ef8d6,
			42'h301ecff054e,
			42'h301bcff11c8,
			42'h3018f7f1e44,
			42'h301645f2ac2,
			42'h3013bbf3743,
			42'h301157f43c5,
			42'h300f1bf5049,
			42'h300d07f5ccf,
			42'h300b1bf6957,
			42'h300955f75e0,
			42'h3007b7f826a,
			42'h30063ff8ef6,
			42'h3004f1f9b82,
			42'h3003c9fa810,
			42'h3002c7fb49e,
			42'h3001effc12e,
			42'h30013dfcdbd,
			42'h3000b3fda4e,
			42'h30004ffe6de,
			42'h300015ff36f
		};
		assign cmem_rdata = CMEM_INIT[iaddr[(LGSPAN-1):0]];
	end
	else if (LGSPAN == 8) begin : g_cmem_lut
		localparam [43:0] CMEM_INIT [0:255] = '{
			44'h40000000000,
			44'h3ffec7fcdbc,
			44'h3ffb13f9b7b,
			44'h3ff4e7f693d,
			44'h3fec47f3705,
			44'h3fe12ff04d5,
			44'h3fd39fed2ae,
			44'h3fc397ea093,
			44'h3fb11fe6e86,
			44'h3f9c2fe3c88,
			44'h3f84cbe0a9b,
			44'h3f6af7dd8c2,
			44'h3f4eafda6fe,
			44'h3f2ff7d7551,
			44'h3f0ecbd43bd,
			44'h3eeb37d1245,
			44'h3ec533ce0e9,
			44'h3e9cc3cafac,
			44'h3e71ebc7e90,
			44'h3e44a7c4d96,
			44'h3e14ffc1cc1,
			44'h3de2f3bec12,
			44'h3dae83bbb8b,
			44'h3d77b3b8b2f,
			44'h3d3e87b5afe,
			44'h3d02fbb2afc,
			44'h3cc513afb29,
			44'h3c84d7acb87,
			44'h3c4247a9c19,
			44'h3bfd5fa6ce1,
			44'h3bb62ba3ddf,
			44'h3b6ca7a0f16,
			44'h3b20db9e087,
			44'h3ad2c79b235,
			44'h3a826b98422,
			44'h3a2fd39564e,
			44'h39daf7928bc,
			44'h3983e38fb6e,
			44'h392a9b8ce64,
			44'h38cf1b8a1a2,
			44'h38716787529,
			44'h38118b848fa,
			44'h37af8381d17,
			44'h374b577f182,
			44'h36e50b7c63c,
			44'h367c9f79b48,
			44'h361217770a6,
			44'h35a57b74659,
			44'h3536cf71c62,
			44'h34c6176f2c3,
			44'h3453536c97d,
			44'h33de8b6a092,
			44'h3367c367804,
			44'h32eeff64fd4,
			44'h32744762803,
			44'h31f79b60093,
			44'h3179035d986,
			44'h30f8835b2de,
			44'h30761f58c9b,
			44'h2ff1db566bf,
			44'h2f6bc35414b,
			44'h2ee3d351c42,
			44'h2e5a134f7a4,
			44'h2dce8b4d373,
			44'h2d413f4afb1,
			44'h2cb23748c5e,
			44'h2c21734697c,
			44'h2b8efb4470c,
			44'h2afad742510,
			44'h2a65074038a,
			44'h29cd973e279,
			44'h29348b3c1e0,
			44'h2899eb3a1c0,
			44'h27fdb73821a,
			44'h275ff7362ef,
			44'h26c0b334441,
			44'h261ff332610,
			44'h257dbb3085e,
			44'h24da0f2eb2c,
			44'h2434f72ce7b,
			44'h238e7b2b24d,
			44'h22e69f296a2,
			44'h223d6b27b7b,
			44'h2192e3260d9,
			44'h20e713246be,
			44'h2039fb22d2b,
			44'h1f8ba721420,
			44'h1edc1b1fb9e,
			44'h1e2b5f1e3a7,
			44'h1d797b1cc3a,
			44'h1cc6731b55a,
			44'h1c124b19f08,
			44'h1b5d1318943,
			44'h1aa6cb1740c,
			44'h19ef7b15f66,
			44'h19372f14b4f,
			44'h187de7137ca,
			44'h17c3ab124d7,
			44'h17088711276,
			44'h164c7f100a9,
			44'h158f9f0ef6f,
			44'h14d1e70decb,
			44'h14135f0cebc,
			44'h1354130bf42,
			44'h12940b0b05f,
			44'h11d3470a214,
			44'h1111d709460,
			44'h104fbb08744,
			44'h0f8cff07ac1,
			44'h0ec9ab06ed7,
			44'h0e05c306386,
			44'h0d4153058d0,
			44'h0c7c5f04eb4,
			44'h0bb6ef04533,
			44'h0af10f03c4e,
			44'h0a2abf03403,
			44'h09640b02c55,
			44'h089cfb02543,
			44'h07d59701ece,
			44'h070de3018f5,
			44'h0645eb013b9,
			44'h057db700f1b,
			44'h04b54b00b19,
			44'h03ecaf007b5,
			44'h0323ef004ef,
			44'h025b0f002c7,
			44'h0192170013c,
			44'h00c9130004f,
			44'h00000300000,
			44'hff36f30004f,
			44'hfe6def0013c,
			44'hfda4f7002c7,
			44'hfcdc17004ef,
			44'hfc1357007b5,
			44'hfb4abb00b19,
			44'hfa824f00f1b,
			44'hf9ba1b013b9,
			44'hf8f223018f5,
			44'hf82a6f01ece,
			44'hf7630b02543,
			44'hf69bfb02c55,
			44'hf5d54703403,
			44'hf50ef703c4e,
			44'hf4491704533,
			44'hf383a704eb4,
			44'hf2beb3058d0,
			44'hf1fa4306386,
			44'hf1365b06ed7,
			44'hf0730707ac1,
			44'hefb04b08744,
			44'heeee2f09460,
			44'hee2cbf0a214,
			44'hed6bfb0b05f,
			44'hecabf30bf42,
			44'hebeca70cebc,
			44'heb2e1f0decb,
			44'hea70670ef6f,
			44'he9b387100a9,
			44'he8f77f11276,
			44'he83c5b124d7,
			44'he7821f137ca,
			44'he6c8d714b4f,
			44'he6108b15f66,
			44'he5593b1740c,
			44'he4a2f318943,
			44'he3edbb19f08,
			44'he339931b55a,
			44'he2868b1cc3a,
			44'he1d4a71e3a7,
			44'he123eb1fb9e,
			44'he0745f21420,
			44'hdfc60b22d2b,
			44'hdf18f3246be,
			44'hde6d23260d9,
			44'hddc29b27b7b,
			44'hdd1967296a2,
			44'hdc718b2b24d,
			44'hdbcb0f2ce7b,
			44'hdb25f72eb2c,
			44'hda824b3085e,
			44'hd9e01332610,
			44'hd93f5334441,
			44'hd8a00f362ef,
			44'hd8024f3821a,
			44'hd7661b3a1c0,
			44'hd6cb7b3c1e0,
			44'hd6326f3e279,
			44'hd59aff4038a,
			44'hd5052f42510,
			44'hd4710b4470c,
			44'hd3de934697c,
			44'hd34dcf48c5e,
			44'hd2bec74afb1,
			44'hd2317b4d373,
			44'hd1a5f34f7a4,
			44'hd11c3351c42,
			44'hd094435414b,
			44'hd00e2b566bf,
			44'hcf89e758c9b,
			44'hcf07835b2de,
			44'hce87035d986,
			44'hce086b60093,
			44'hcd8bbf62803,
			44'hcd110764fd4,
			44'hcc984367804,
			44'hcc217b6a092,
			44'hcbacb36c97d,
			44'hcb39ef6f2c3,
			44'hcac93771c62,
			44'hca5a8b74659,
			44'hc9edef770a6,
			44'hc9836779b48,
			44'hc91afb7c63c,
			44'hc8b4af7f182,
			44'hc8508381d17,
			44'hc7ee7b848fa,
			44'hc78e9f87529,
			44'hc730eb8a1a2,
			44'hc6d56b8ce64,
			44'hc67c238fb6e,
			44'hc6250f928bc,
			44'hc5d0339564e,
			44'hc57d9b98422,
			44'hc52d3f9b235,
			44'hc4df2b9e087,
			44'hc4935fa0f16,
			44'hc449dba3ddf,
			44'hc402a7a6ce1,
			44'hc3bdbfa9c19,
			44'hc37b2facb87,
			44'hc33af3afb29,
			44'hc2fd0bb2afc,
			44'hc2c17fb5afe,
			44'hc28853b8b2f,
			44'hc25183bbb8b,
			44'hc21d13bec12,
			44'hc1eb07c1cc1,
			44'hc1bb5fc4d96,
			44'hc18e1bc7e90,
			44'hc16343cafac,
			44'hc13ad3ce0e9,
			44'hc114cfd1245,
			44'hc0f13bd43bd,
			44'hc0d00fd7551,
			44'hc0b157da6fe,
			44'hc0950fdd8c2,
			44'hc07b3be0a9b,
			44'hc063d7e3c88,
			44'hc04ee7e6e86,
			44'hc03c6fea093,
			44'hc02c67ed2ae,
			44'hc01ed7f04d5,
			44'hc013bff3705,
			44'hc00b1ff693d,
			44'hc004f3f9b7b,
			44'hc0013ffcdbc
		};
		assign cmem_rdata = CMEM_INIT[iaddr[(LGSPAN-1):0]];
	end
	else if (LGSPAN == 7) begin : g_cmem_lut
		localparam [43:0] CMEM_INIT [0:127] = '{
			44'h40000000000,
			44'h3ffb13f9b7b,
			44'h3fec47f3705,
			44'h3fd39fed2ae,
			44'h3fb11fe6e86,
			44'h3f84cbe0a9b,
			44'h3f4eafda6fe,
			44'h3f0ecbd43bd,
			44'h3ec533ce0e9,
			44'h3e71ebc7e90,
			44'h3e14ffc1cc1,
			44'h3dae83bbb8b,
			44'h3d3e87b5afe,
			44'h3cc513afb29,
			44'h3c4247a9c19,
			44'h3bb62ba3ddf,
			44'h3b20db9e087,
			44'h3a826b98422,
			44'h39daf7928bc,
			44'h392a9b8ce64,
			44'h38716787529,
			44'h37af8381d17,
			44'h36e50b7c63c,
			44'h361217770a6,
			44'h3536cf71c62,
			44'h3453536c97d,
			44'h3367c367804,
			44'h32744762803,
			44'h3179035d986,
			44'h30761f58c9b,
			44'h2f6bc35414b,
			44'h2e5a134f7a4,
			44'h2d413f4afb1,
			44'h2c21734697c,
			44'h2afad742510,
			44'h29cd973e279,
			44'h2899eb3a1c0,
			44'h275ff7362ef,
			44'h261ff332610,
			44'h24da0f2eb2c,
			44'h238e7b2b24d,
			44'h223d6b27b7b,
			44'h20e713246be,
			44'h1f8ba721420,
			44'h1e2b5f1e3a7,
			44'h1cc6731b55a,
			44'h1b5d1318943,
			44'h19ef7b15f66,
			44'h187de7137ca,
			44'h17088711276,
			44'h158f9f0ef6f,
			44'h14135f0cebc,
			44'h12940b0b05f,
			44'h1111d709460,
			44'h0f8cff07ac1,
			44'h0e05c306386,
			44'h0c7c5f04eb4,
			44'h0af10f03c4e,
			44'h09640b02c55,
			44'h07d59701ece,
			44'h0645eb013b9,
			44'h04b54b00b19,
			44'h0323ef004ef,
			44'h0192170013c,
			44'h00000300000,
			44'hfe6def0013c,
			44'hfcdc17004ef,
			44'hfb4abb00b19,
			44'hf9ba1b013b9,
			44'hf82a6f01ece,
			44'hf69bfb02c55,
			44'hf50ef703c4e,
			44'hf383a704eb4,
			44'hf1fa4306386,
			44'hf0730707ac1,
			44'heeee2f09460,
			44'hed6bfb0b05f,
			44'hebeca70cebc,
			44'hea70670ef6f,
			44'he8f77f11276,
			44'he7821f137ca,
			44'he6108b15f66,
			44'he4a2f318943,
			44'he339931b55a,
			44'he1d4a71e3a7,
			44'he0745f21420,
			44'hdf18f3246be,
			44'hddc29b27b7b,
			44'hdc718b2b24d,
			44'hdb25f72eb2c,
			44'hd9e01332610,
			44'hd8a00f362ef,
			44'hd7661b3a1c0,
			44'hd6326f3e279,
			44'hd5052f42510,
			44'hd3de934697c,
			44'hd2bec74afb1,
			44'hd1a5f34f7a4,
			44'hd094435414b,
			44'hcf89e758c9b,
			44'hce87035d986,
			44'hcd8bbf62803,
			44'hcc984367804,
			44'hcbacb36c97d,
			44'hcac93771c62,
			44'hc9edef770a6,
			44'hc91afb7c63c,
			44'hc8508381d17,
			44'hc78e9f87529,
			44'hc6d56b8ce64,
			44'hc6250f928bc,
			44'hc57d9b98422,
			44'hc4df2b9e087,
			44'hc449dba3ddf,
			44'hc3bdbfa9c19,
			44'hc33af3afb29,
			44'hc2c17fb5afe,
			44'hc25183bbb8b,
			44'hc1eb07c1cc1,
			44'hc18e1bc7e90,
			44'hc13ad3ce0e9,
			44'hc0f13bd43bd,
			44'hc0b157da6fe,
			44'hc07b3be0a9b,
			44'hc04ee7e6e86,
			44'hc02c67ed2ae,
			44'hc013bff3705,
			44'hc004f3f9b7b
		};
		assign cmem_rdata = CMEM_INIT[iaddr[(LGSPAN-1):0]];
	end
	else if (LGSPAN == 6) begin : g_cmem_lut
		localparam [45:0] CMEM_INIT [0:63] = '{
			46'h100000000000,
			46'h0ffb117e6e0a,
			46'h0fec477cdd0b,
			46'h0fd3aafb4dfc,
			46'h0fb14c79c1d2,
			46'h0f853ff83982,
			46'h0f4fa0f6b5fd,
			46'h0f1090f53833,
			46'h0ec83673c10f,
			46'h0e76bdf25178,
			46'h0e1c59f0ea51,
			46'h0db941ef8c78,
			46'h0d4db36e38c5,
			46'h0cd9f06cf008,
			46'h0c5e406bb30d,
			46'h0bdaefea8297,
			46'h0b504f695f62,
			46'h0abeb4e84a21,
			46'h0a2679e74380,
			46'h0987fc664c20,
			46'h08e39de5649a,
			46'h0839c4648d7d,
			46'h078ad7e3c74d,
			46'h06d744631285,
			46'h061f78e26f94,
			46'h0563e6e1dedf,
			46'h04a501e160bf,
			46'h03e33f60f581,
			46'h031f17609d68,
			46'h0259026058ab,
			46'h01917ae02772,
			46'h00c8fb6009de,
			46'h000000600000,
			46'h3f37056009de,
			46'h3e6e85e02772,
			46'h3da6fe6058ab,
			46'h3ce0e9609d68,
			46'h3c1cc160f581,
			46'h3b5afee160bf,
			46'h3a9c19e1dedf,
			46'h39e087e26f94,
			46'h3928bc631285,
			46'h387528e3c74d,
			46'h37c63c648d7d,
			46'h371c62e5649a,
			46'h367804664c20,
			46'h35d986e74380,
			46'h35414be84a21,
			46'h34afb1695f62,
			46'h342510ea8297,
			46'h33a1c06bb30d,
			46'h3326106cf008,
			46'h32b24d6e38c5,
			46'h3246beef8c78,
			46'h31e3a6f0ea51,
			46'h318942f25178,
			46'h3137ca73c10f,
			46'h30ef6ff53833,
			46'h30b05ff6b5fd,
			46'h307ac0f83982,
			46'h304eb479c1d2,
			46'h302c55fb4dfc,
			46'h3013b97cdd0b,
			46'h3004ef7e6e0a
		};
		assign cmem_rdata = CMEM_INIT[iaddr[(LGSPAN-1):0]];
	end
	else if (LGSPAN == 5) begin : g_cmem_lut
		localparam [45:0] CMEM_INIT [0:31] = '{
			46'h100000000000,
			46'h0fec477cdd0b,
			46'h0fb14c79c1d2,
			46'h0f4fa0f6b5fd,
			46'h0ec83673c10f,
			46'h0e1c59f0ea51,
			46'h0d4db36e38c5,
			46'h0c5e406bb30d,
			46'h0b504f695f62,
			46'h0a2679e74380,
			46'h08e39de5649a,
			46'h078ad7e3c74d,
			46'h061f78e26f94,
			46'h04a501e160bf,
			46'h031f17609d68,
			46'h01917ae02772,
			46'h000000600000,
			46'h3e6e85e02772,
			46'h3ce0e9609d68,
			46'h3b5afee160bf,
			46'h39e087e26f94,
			46'h387528e3c74d,
			46'h371c62e5649a,
			46'h35d986e74380,
			46'h34afb1695f62,
			46'h33a1c06bb30d,
			46'h32b24d6e38c5,
			46'h31e3a6f0ea51,
			46'h3137ca73c10f,
			46'h30b05ff6b5fd,
			46'h304eb479c1d2,
			46'h3013b97cdd0b
		};
		assign cmem_rdata = CMEM_INIT[iaddr[(LGSPAN-1):0]];
	end
	else if (LGSPAN == 4) begin : g_cmem_lut
		localparam [47:0] CMEM_INIT [0:15] = '{
			48'h400000000000,
			48'h3ec530f383a4,
			48'h3b20d8e7821d,
			48'h3536ccdc718a,
			48'h2d413dd2bec3,
			48'h238e76cac934,
			48'h187de3c4df28,
			48'h0c7c5cc13ad0,
			48'h000000c00000,
			48'hf383a4c13ad0,
			48'he7821dc4df28,
			48'hdc718acac934,
			48'hd2bec3d2bec3,
			48'hcac934dc718a,
			48'hc4df28e7821d,
			48'hc13ad0f383a4
		};
		assign cmem_rdata = CMEM_INIT[iaddr[(LGSPAN-1):0]];
	end
	else if (LGSPAN == 3) begin : g_cmem_lut
		localparam [47:0] CMEM_INIT [0:7] = '{
			48'h400000000000,
			48'h3b20d8e7821d,
			48'h2d413dd2bec3,
			48'h187de3c4df28,
			48'h000000c00000,
			48'he7821dc4df28,
			48'hd2bec3d2bec3,
			48'hc4df28e7821d
		};
		assign cmem_rdata = CMEM_INIT[iaddr[(LGSPAN-1):0]];
	end
	else if (LGSPAN == 2) begin : g_cmem_lut
		localparam [49:0] CMEM_INIT [0:3] = '{
			50'h1000000000000,
			50'h0b504f5a57d86,
			50'h0000001800000,
			50'h34afb0da57d86
		};
		assign cmem_rdata = CMEM_INIT[iaddr[(LGSPAN-1):0]];
	end
	else begin : g_cmem_lut
		assign cmem_rdata = {(2*CWIDTH){1'b0}};
	end
	endgenerate
`endif

	// wait_for_sync, iaddr
	// {{{
	always @(posedge i_clk)
	if (i_reset)
	begin
		wait_for_sync <= 1'b1;
		iaddr <= 0;
	end else if ((i_ce)&&((!wait_for_sync)||(i_sync)))
	begin
		//
		// First step: Record what we're not ready to use yet
		//
		iaddr <= iaddr + { {(LGSPAN){1'b0}}, 1'b1 };
		wait_for_sync <= 1'b0;
	end
	// }}}

	// Write to imem
	// {{{
	always @(posedge i_clk) // Need to make certain here that we don't read
	if ((i_ce)&&(!iaddr[LGSPAN])) // and write the same address on
		imem[iaddr[(LGSPAN-1):0]] <= i_data; // the same clk
	// }}}

	// ib_sync
	// {{{
	// Now, we have all the inputs, so let's feed the butterfly
	//
	// ib_sync is the synchronization bit to the butterfly.  It will
	// be tracked within the butterfly, and used to create the o_sync
	// value when the results from this output are produced
	always @(posedge i_clk)
	if (i_reset)
		ib_sync <= 1'b0;
	else if (i_ce)
	begin
		// Set the sync to true on the very first
		// valid input in, and hence on the very
		// first valid data out per FFT.
		ib_sync <= (iaddr==(1<<(LGSPAN)));
	end
	// }}}

	// ib_a, ib_b, ib_c
	// {{{
	// Read the values from our input memory, and use them to feed
	// first of two butterfly inputs
	always	@(posedge i_clk)
	if (i_ce)
	begin
		// One input from memory, ...
		ib_a <= imem[iaddr[(LGSPAN-1):0]];
		// One input clocked in from the top
		ib_b <= i_data;
		// and the coefficient or twiddle factor
`ifdef	FORMAL
		ib_c <= cmem[iaddr[(LGSPAN-1):0]];
`else
		ib_c <= cmem_rdata;
`endif
	end
	// }}}

	// idle
	// {{{
	// The idle register is designed to keep track of when an input
	// to the butterfly is important and going to be used.  It's used
	// in a flag following, so that when useful values are placed
	// into the butterfly they'll be non-zero (idle=0), otherwise when
	// the inputs to the butterfly are irrelevant and will be ignored,
	// then (idle=1) those inputs will be set to zero.  This
	// functionality is not designed to be used in operation, but only
	// within a Verilator simulation context when chasing a bug.
	// In this limited environment, the non-zero answers will stand
	// in a trace making it easier to highlight a bug.
	generate if (ZERO_ON_IDLE)
	begin : GEN_ZERO_ON_IDLE
		reg	r_idle;

		always @(posedge i_clk)
		if (i_reset)
			r_idle <= 1'b1;
		else if (i_ce)
			r_idle <= (!iaddr[LGSPAN])&&(!wait_for_sync);

		assign	idle = r_idle;

	end else begin : NO_IDLE_GENERATION

		assign	idle = 0;

	end endgenerate
	// }}}

	////////////////////////////////////////////////////////////////////////
	//
	// Instantiate the butterfly
	// {{{
	////////////////////////////////////////////////////////////////////////
	//
	//
// For the formal proof, we'll assume the outputs of hwbfly and/or
// butterfly, rather than actually calculating them.  This will simplify
// the proof and (if done properly) will be equivalent.  Be careful of
// defining FORMAL if you want the full logic!
`ifndef	FORMAL
	//
	generate if (OPT_HWMPY)
	begin : HWBFLY

		hwbfly #(
			// {{{
			.IWIDTH(IWIDTH),
			.CWIDTH(CWIDTH),
			.OWIDTH(OWIDTH),
			.CKPCE(CKPCE),
			.SHIFT(BFLYSHIFT)
			// }}}
		) bfly(
			// {{{
			.i_clk(i_clk), .i_reset(i_reset), .i_ce(i_ce),
			.i_coef( (idle && !i_ce) ? {(2*CWIDTH){1'b0}}:ib_c),
			.i_left( (idle && !i_ce) ? {(2*IWIDTH){1'b0}}:ib_a),
			.i_right((idle && !i_ce) ? {(2*IWIDTH){1'b0}}:ib_b),
			.i_aux(ib_sync && i_ce),
			.o_left(ob_a), .o_right(ob_b), .o_aux(ob_sync)
			// }}}
		);

	end else begin : FWBFLY

		butterfly #(
			// {{{
			.IWIDTH(IWIDTH),
			.CWIDTH(CWIDTH),
			.OWIDTH(OWIDTH),
			.CKPCE(CKPCE),
			.SHIFT(BFLYSHIFT)
			// }}}
		) bfly(
			// {{{
			.i_clk(i_clk), .i_reset(i_reset), .i_ce(i_ce),
			.i_coef( (idle && !i_ce)? {(2*CWIDTH){1'b0}} :ib_c),
			.i_left( (idle && !i_ce)? {(2*IWIDTH){1'b0}} :ib_a),
			.i_right((idle && !i_ce)? {(2*IWIDTH){1'b0}} :ib_b),
			.i_aux(ib_sync && i_ce),
			.o_left(ob_a), .o_right(ob_b), .o_aux(ob_sync)
			// }}}
		);

	end endgenerate
`else

	// Verilator lint_off UNDRIVEN
	(* anyseq *)    wire    [(2*OWIDTH-1):0]        f_ob_a, f_ob_b;
	(* anyseq *)    wire    f_ob_sync;
	// Verilator lint_on  UNDRIVEN

	assign  ob_sync = f_ob_sync;
	assign  ob_a    = f_ob_a;
	assign  ob_b    = f_ob_b;

`endif

	// }}}

	// oaddr, o_sync, b_started
	// {{{
	// Next step: recover the outputs from the butterfly
	//
	// The first output can go immediately to the output of this routine
	// The second output must wait until this time in the idle cycle
	// oaddr is the output memory address, keeping track of where we are
	// in this output cycle.
	always @(posedge i_clk)
	if (i_reset)
	begin
		oaddr     <= 0;
		o_sync    <= 0;
		// b_started will be true once we've seen the first ob_sync
		b_started <= 0;
	end else if (i_ce)
	begin
		o_sync <= (!oaddr[LGSPAN])?ob_sync : 1'b0;
		if (ob_sync||b_started)
			oaddr <= oaddr + 1'b1;
		if ((ob_sync)&&(!oaddr[LGSPAN]))
			// If b_started is true, then a butterfly output
			// is available
			b_started <= 1'b1;
	end
	// }}}

	// nxt_oaddr
	// {{{
	always @(posedge i_clk)
	if (i_ce)
	begin
		nxt_oaddr[0] <= oaddr[0];
		if (LGSPAN > 1)
			nxt_oaddr[LGSPAN-1:1] <= oaddr[LGSPAN-1:1] + 1'b1;
	end
	// }}}

	// omem
	// {{{
	// Only write to the memory on the first half of the outputs
	// We'll use the memory value on the second half of the outputs
	always @(posedge i_clk)
	if ((i_ce)&&(!oaddr[LGSPAN]))
		omem[oaddr[(LGSPAN-1):0]] <= ob_b;
	// }}}

	// pre_ovalue
	// {{{
	always @(posedge i_clk)
	if (i_ce)
		pre_ovalue <= omem[nxt_oaddr[(LGSPAN-1):0]];
	// }}}

	// o_data
	// {{{
	always @(posedge i_clk)
	if (i_ce)
		o_data <= (!oaddr[LGSPAN]) ? ob_a : pre_ovalue;
	// }}}

////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////
//
// Formal properties
// {{{
////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////
`ifdef	FORMAL
	// Local (formal) declarations
	// {{{
	// An arbitrary processing delay from butterfly input to
	// butterfly output(s)
	// Verilator lint_off UNDRIVEN
	(* anyconst *) reg	[LGSPAN:0]	f_mpydelay;
	(* anyconst *)	reg	[LGSPAN:0]	f_addr;
	// Verilator lint_on  UNDRIVEN
	reg	[2*IWIDTH-1:0]			f_left, f_right;
	reg	[2*OWIDTH-1:0]	f_oleft, f_oright;
	reg	[LGSPAN:0]	f_oaddr;
	wire	[LGSPAN:0]	f_oaddr_m1 = f_oaddr - 1'b1;
	reg	f_output_active;
	// }}}


	always @(*)
		assume(f_mpydelay > 1);

	reg	f_past_valid;
	initial	f_past_valid = 1'b0;
	always @(posedge i_clk)
		f_past_valid <= 1'b1;

	always @(posedge i_clk)
	if ((!f_past_valid)||($past(i_reset)))
	begin
		assert(iaddr == 0);
		assert(wait_for_sync);
		assert(o_sync == 0);
		assert(oaddr == 0);
		assert(!b_started);
		assert(!o_sync);
	end

	////////////////////////////////////////////////////////////////////////
	//
	// Formally verify the input half, from the inputs to this module
	// to the inputs of the butterfly
	//
	////////////////////////////////////////////////////////////////////////
	//
	//

	// Let's  verify a specific set of inputs

	always @(posedge i_clk)
	if (!$past(i_ce) && !$past(i_ce,2) && !$past(i_ce,3) && !$past(i_ce,4))
		assume(!i_ce);

	always @(*)
		assume(f_addr[LGSPAN]==1'b0);

	always @(posedge i_clk)
	if ((i_ce)&&(iaddr[LGSPAN:0] == f_addr))
		f_left <= i_data;

	always @(*)
	if (wait_for_sync)
		assert(iaddr == 0);

	wire	[LGSPAN:0]	f_last_addr = iaddr - 1'b1;

	always @(posedge i_clk)
	if ((!wait_for_sync)&&(f_last_addr >= { 1'b0, f_addr[LGSPAN-1:0]}))
		assert(f_left == imem[f_addr[LGSPAN-1:0]]);

	always @(posedge i_clk)
	if ((i_ce)&&(iaddr == { 1'b1, f_addr[LGSPAN-1:0]}))
		f_right <= i_data;

	always @(posedge i_clk)
	if (i_ce && !wait_for_sync
		&& (f_last_addr == { 1'b1, f_addr[LGSPAN-1:0]}))
	begin
		assert(ib_a == f_left);
		assert(ib_b == f_right);
		assert(ib_c == cmem[f_addr[LGSPAN-1:0]]);
	end

	////////////////////////////////////////////////////////////////////////
	//
	// Formally verify the output half, from the output of the butterfly
	// to the outputs of this module
	//
	////////////////////////////////////////////////////////////////////////
	//
	//

	always @(*)
		f_oaddr = iaddr - f_mpydelay + {1'b1,{(LGSPAN-1){1'b0}} };

	assign	f_oaddr_m1 = f_oaddr - 1'b1;

	initial	f_output_active = 1'b0;
	always @(posedge i_clk)
	if (i_reset)
		f_output_active <= 1'b0;
	else if ((i_ce)&&(ob_sync))
		f_output_active <= 1'b1;

	always @(*)
		assert(f_output_active == b_started);

	always @(*)
	if (wait_for_sync)
		assert(!f_output_active);

	always @(*)
	if (f_output_active)
	begin
		assert(oaddr == f_oaddr);
	end else
		assert(oaddr == 0);

	always @(*)
	if (wait_for_sync)
		assume(!ob_sync);

	always @(*)
		assume(ob_sync == (f_oaddr == 0));

	always @(posedge i_clk)
	if ((f_past_valid)&&(!$past(i_ce)))
	begin
		assume($stable(ob_a));
		assume($stable(ob_b));
	end

	initial	f_oleft  = 0;
	initial	f_oright = 0;
	always @(posedge i_clk)
	if ((i_ce)&&(f_oaddr == f_addr))
	begin
		f_oleft  <= ob_a;
		f_oright <= ob_b;
	end

	always @(posedge i_clk)
	if ((f_output_active)&&(f_oaddr_m1 >= { 1'b0, f_addr[LGSPAN-1:0]}))
		assert(omem[f_addr[LGSPAN-1:0]] == f_oright);

	always @(posedge i_clk)
	if ((i_ce)&&(f_oaddr_m1 == 0)&&(f_output_active))
	begin
		assert(o_sync);
	end else if ((i_ce)||(!f_output_active))
		assert(!o_sync);

	always @(posedge i_clk)
	if ((i_ce)&&(f_output_active)&&(f_oaddr_m1 == f_addr))
		assert(o_data == f_oleft);

	always @(posedge i_clk)
	if ((i_ce)&&(f_output_active)&&(f_oaddr[LGSPAN])
			&&(f_oaddr[LGSPAN-1:0] == f_addr[LGSPAN-1:0]))
		assert(pre_ovalue == f_oright);

	always @(posedge i_clk)
	if ((i_ce)&&(f_output_active)&&(f_oaddr_m1[LGSPAN])
			&&(f_oaddr_m1[LGSPAN-1:0] == f_addr[LGSPAN-1:0]))
		assert(o_data == f_oright);

	// Make Verilator happy
	// {{{
	// Verilator lint_off UNUSED
	wire	unused_formal;
	assign unused_formal = &{ 1'b0, idle, ib_sync };
	// Verilator lint_on  UNUSED
	// }}}

`endif // FORMAL
// }}}
endmodule
