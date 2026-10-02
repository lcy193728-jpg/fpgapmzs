`timescale 1ns/1ps
//====================================================================
// 模块名 : audio_src_sel.v —— 按场景在 DDS(片内合成) / WAV(TF卡) 之间切源
//
// 背景(2026-09-26 迎新场景背景音乐改造):
//   迎新技术场景改为播放 TF 卡上的真实音乐(裸 16bit/48kHz/单声道 PCM,
//   由 wav_stream_player 流式读出); 会议/抢答/应急三个场景仍沿用
//   scene_audio_final 的片内 DDS 合成音(旋律/提示音/国标防空警报)。
//
//   本模块插在 两个音源 与 audio_src_mux 的媒体口 之间:
//
//     scene_audio_final(DDS) ─┐
//                             ├→ audio_src_sel ─→ audio_src_mux ─→ HDMI
//     wav_stream_player(WAV) ─┘
//
// 三条关键约定:
//   1) ready 只回被选中的源 —— 否则未选源会被下游"偷走"样本(FIFO 水位
//      与播放进度全部错乱)。
//   2) 未被选中的源必须**仍然排空**(drain_tick): DDS 内部是 32 深 FIFO,
//      停止消费会迅速写满并置 overflow; 而切回 DDS 时若 FIFO 里积压的是
//      上一场景的旧样本, 听感上会先冒出旧音再切到新音。
//      (WAV 源未选中时 play_enable=0 → 播放器自己复位, 不产生样本, 无需排空。)
//   3) 增益语义: DDS 侧用 scene_audio_final 送来的 9 位包络(0..256, 用于
//      场景切换淡入淡出); WAV 侧固定 9'd256 = ×1.0(整首曲子不做包络,
//      切场景时的淡入淡出仍由 audio_src_mux 的 test(静音)↔media 交叉淡变
//      在下一级完成)。
//
// 切换瞬态: sel_wav 变化时输出会从"旧源当前样本"跳到"新源当前样本",
//   两个信号互不相关, 理论上有一次阶跃(轻微咔哒)。迎新的音乐与 DDS 的
//   提示音/警报本就是不同内容, 且切场景时画面同步做淡入淡出, 故不做
//   双源交叉淡变(那需要同时保留两路信号, 面积代价不值)。
//
// 时钟: 全部工作在 video_clk 域(与 audio_src_mux / scene_audio_final 同域)。
//====================================================================
module audio_src_sel(
	input  wire        clk,
	input  wire        rst_n,
	// ---- 选择: 1 = 用 WAV(TF 卡)源, 0 = 用 DDS(片内合成)源 ----
	input  wire        sel_wav,
	// ---- DDS 侧(scene_audio_final) ----
	input  wire        dds_valid,
	output wire        dds_ready,
	input  wire signed [15:0] dds_left,
	input  wire signed [15:0] dds_right,
	input  wire [8:0]  dds_gain,
	// ---- WAV 侧(wav_stream_player 读口) ----
	input  wire        wav_valid,
	output wire        wav_ready,
	input  wire signed [15:0] wav_left,
	input  wire signed [15:0] wav_right,
	// ---- 未选中源的排空节拍(48 kHz tick, 顶层给 audio_rate_tick) ----
	input  wire        drain_tick,
	// ---- 送往 audio_src_mux 的媒体口 ----
	output wire        media_valid,
	input  wire        media_ready,
	output wire signed [15:0] media_left,
	output wire signed [15:0] media_right,
	output wire [8:0]  media_gain
);
	// 媒体口 = 被选源的样本
	assign media_valid = sel_wav ? wav_valid : dds_valid;
	assign media_left  = sel_wav ? wav_left  : dds_left;
	assign media_right = sel_wav ? wav_right : dds_right;
	// WAV 固定满增益; DDS 用其自带包络
	assign media_gain  = sel_wav ? 9'd256   : dds_gain;

	// ready 只给被选源; 未选中源按 48 kHz 节拍排空
	assign dds_ready   = sel_wav ? drain_tick : media_ready;
	assign wav_ready   = sel_wav ? media_ready : 1'b0;
endmodule
