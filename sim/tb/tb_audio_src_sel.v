`timescale 1ns/1ps
//====================================================================
// tb_audio_src_sel.v —— audio_src_sel 单元测试(纯组合, 组合覆盖)
//
// 被测: 按 sel_wav 在 DDS / WAV 之间切源, 且 ready 只回被选源,
//       未选中的 DDS 用 drain_tick 排空。
//====================================================================
module tb_audio_src_sel;
	reg        sel_wav;
	reg        dds_valid, wav_valid;
	reg signed [15:0] dds_left, dds_right, wav_left, wav_right;
	reg [8:0]  dds_gain;
	reg        drain_tick, media_ready;

	wire        dds_ready, wav_ready;
	wire        media_valid;
	wire signed [15:0] media_left, media_right;
	wire [8:0]  media_gain;

	integer checks = 0, fails = 0;
	task chk;
		input cond;
		input [511:0] msg;
		begin
			checks = checks + 1;
			if(!cond) begin
				fails = fails + 1;
				$display("[FAIL #%0d] %0s", checks, msg);
			end
		end
	endtask

	audio_src_sel dut(
		.clk(1'b0), .rst_n(1'b1), .sel_wav(sel_wav),
		.dds_valid(dds_valid), .dds_ready(dds_ready),
		.dds_left(dds_left), .dds_right(dds_right), .dds_gain(dds_gain),
		.wav_valid(wav_valid), .wav_ready(wav_ready),
		.wav_left(wav_left), .wav_right(wav_right),
		.drain_tick(drain_tick),
		.media_valid(media_valid), .media_ready(media_ready),
		.media_left(media_left), .media_right(media_right), .media_gain(media_gain)
	);

	initial begin
		// 两个源给完全不同的可辨识数值, 便于发现串源
		dds_valid = 1'b1; wav_valid = 1'b1;
		dds_left  = 16'h1111; dds_right  = 16'h2222; dds_gain = 9'd200;
		wav_left  = 16'h7A7A; wav_right  = 16'h0B0B;
		drain_tick = 1'b0; media_ready = 1'b0; sel_wav = 1'b0;
		#1;

		//------------------------------------------------------------
		// DDS 被选中
		//------------------------------------------------------------
		chk(media_valid == 1'b1,              "s1.1 DDS选中: media_valid 跟 DDS");
		chk(media_left == 16'h1111 && media_right == 16'h2222,
		                                      "s1.2 DDS选中: 媒体口取 DDS 样本");
		chk(media_gain == 9'd200,             "s1.3 DDS选中: 增益取 DDS 包络");
		chk(dds_ready == 1'b0,                "s1.4 DDS选中: media_ready=0 时 dds_ready=0");
		chk(wav_ready == 1'b0,                "s1.5 DDS选中: WAV 侧 ready 恒为 0(不偷样本)");

		media_ready = 1'b1; #1;
		chk(dds_ready == 1'b1,                "s1.6 DDS选中: dds_ready 跟随 media_ready");
		chk(wav_ready == 1'b0,                "s1.7 DDS选中: WAV 侧仍拿不到 ready");

		media_ready = 1'b0; drain_tick = 1'b1; #1;
		chk(dds_ready == 1'b0,                "s1.8 DDS选中: drain_tick 不影响 dds_ready");
		chk(wav_ready == 1'b0,                "s1.9 DDS选中: drain_tick 不下发给 WAV");

		//------------------------------------------------------------
		// WAV 被选中
		//------------------------------------------------------------
		sel_wav = 1'b1; drain_tick = 1'b0; media_ready = 1'b0; #1;
		chk(media_valid == 1'b1,              "s2.1 WAV选中: media_valid 跟 WAV");
		chk(media_left == 16'h7A7A && media_right == 16'h0B0B,
		                                      "s2.2 WAV选中: 媒体口取 WAV 样本");
		chk(media_gain == 9'd256,             "s2.3 WAV选中: 增益固定 ×1.0(256)");
		chk(dds_ready == 1'b0,                "s2.4 WAV选中: drain_tick=0 时 DDS 不排空");
		chk(wav_ready == 1'b0,                "s2.5 WAV选中: media_ready=0 时 WAV 不推进");

		media_ready = 1'b1; #1;
		chk(wav_ready == 1'b1,                "s2.6 WAV选中: wav_ready 跟随 media_ready");
		chk(dds_ready == 1'b0,                "s2.7 WAV选中: DDS 只认 drain_tick, 不受 media_ready");

		media_ready = 1'b0; drain_tick = 1'b1; #1;
		chk(dds_ready == 1'b1,                "s2.8 WAV选中: drain_tick 排空 DDS(防 FIFO 淤积)");
		chk(wav_ready == 1'b0,                "s2.9 WAV选中: 无 media_ready 时 WAV 不推进");

		//------------------------------------------------------------
		// 切回 DDS(验证切源后媒体口立即换成 DDS)
		//------------------------------------------------------------
		sel_wav = 1'b0; #1;
		chk(media_left == 16'h1111 && media_gain == 9'd200,
		                                      "s3.1 切回 DDS: 媒体口/增益立即换回 DDS");
		chk(wav_ready == 1'b0,                "s3.2 切回 DDS: WAV 侧 ready 归零");

		$display("====================================================");
		$display("tb_audio_src_sel: checks=%0d fails=%0d", checks, fails);
		if(fails == 0) $display("RESULT: PASS");
		else           $display("RESULT: FAIL");
		$display("====================================================");
		$finish;
	end
endmodule
