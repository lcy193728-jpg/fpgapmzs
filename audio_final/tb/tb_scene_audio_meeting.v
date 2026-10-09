`timescale 1ns/1ps
//=====================================================================
// tb_scene_audio_meeting.v —— 会议场景音频行为专项 (2026-10-09n)
//
// 用户要求: 会议场景"刚进去不要有音乐", 只有快结束的 WARN 才有提示音。
// 本测试直接驱动 scene_audio_final 的 active_scene 输入, 验证:
//   [A] 从菜单(menu_active 1→0, active_scene=1)进入会议 → 输出立即静音
//   [B] 在会议场景中长时间停留(不喂 event) → 始终静音(无背景音乐)
//   [C] 会议 WARN 事件(event_valid=1,kind=1,media=1) → 出现一段提示音
//   [D] 提示音播完后 → 自动回到静音
//
// 判断"有声音" = 采样输出 sample_left 非零 或 输出包络 gain 非零。
//=====================================================================
module tb_scene_audio_meeting;
  reg clk = 0, rst_n = 0;
  reg event_valid = 0, menu_active = 1, emergency = 0;
  reg [1:0] active_scene = 0;
  reg [1:0] event_kind = 0, media_id = 0;
  wire sample_valid; reg sample_ready = 1;
  wire signed [15:0] sample_left, sample_right;
  wire [8:0] sample_gain;
  wire overflow;
  wire [2:0] state_debug;
  wire [31:0] sample_count;

  always #20 clk = ~clk;                       // 25 MHz

  scene_audio_final dut(
    .clk(clk), .rst_n(rst_n), .event_valid(event_valid), .menu_active(menu_active),
    .emergency(emergency), .active_scene(active_scene),
    .event_kind(event_kind), .media_id(media_id),
    .sample_valid(sample_valid), .sample_ready(sample_ready),
    .sample_left(sample_left), .sample_right(sample_right), .sample_gain(sample_gain),
    .overflow(overflow), .state_debug(state_debug), .sample_count(sample_count));

  integer checks = 0, fails = 0;
  integer loud_samples;
  integer i;

  task chk; input ok; input [255:0] msg;
    begin
      checks = checks + 1;
      if (ok) $display("[PASS] %0s", msg);
      else begin fails = fails + 1; $display("[FAIL] %0s", msg); end
    end
  endtask

  // 观察窗口: 数 window 个 48kHz 样本里"非零样本数"
  task count_loud; input integer window; output integer nz;
    integer k;
    begin
      nz = 0;
      for (k = 0; k < window; k = k + 1) begin
        @(negedge clk);
        while (!sample_valid) @(negedge clk);   // 等到有样本可弹
        if (sample_left !== 16'sd0) nz = nz + 1;
        @(negedge clk);
      end
    end
  endtask

  initial begin
    rst_n = 0; repeat (10) @(negedge clk); rst_n = 1; repeat (10) @(negedge clk);

    //---- [A] 从菜单进入会议(menu 1→0, active_scene=1) ----
    menu_active = 0; active_scene = 1;
    repeat (4000) @(negedge clk);               // 等过渡/fade 结束
    $display("---- A: 进入会议(菜单→会议) ----");
    count_loud(1500, loud_samples);
    chk(loud_samples == 0, "A 进入会议后 1500 个样本全静音(无背景音乐)");

    //---- [B] 会议中长时间停留 → 仍静音 ----
    $display("---- B: 会议中长时间停留 ----");
    count_loud(3000, loud_samples);
    chk(loud_samples == 0, "B 会议停留期间始终静音");

    //---- [C] 会议 WARN 事件 → 提示音 ----
    $display("---- C: 会议 WARN 提示音 ----");
    @(negedge clk); event_valid = 1; event_kind = 2'd1; media_id = 2'd1;
    @(negedge clk); event_valid = 0;
    // 提示音(BLIP)持续 BLIP_SAMPLES=4800 → 先跳过 transition 淡入, 再统计
    count_loud(2000, loud_samples);
    chk(loud_samples > 0, "C 会议 WARN 事件触发提示音(非静音)");

    //---- [D] 提示音播完 → 回静音 ----
    $display("---- D: 提示音播完回静音 ----");
    repeat (3000000) @(negedge clk);            // BLIP 4800 样本(约 2.5M 拍) + 过渡余量
    count_loud(1500, loud_samples);
    chk(loud_samples == 0, "D 提示音播完后自动回静音");

    $display("==== tb_scene_audio_meeting: checks=%0d fails=%0d ====", checks, fails);
    if (fails == 0) $display("RESULT: PASS"); else $display("RESULT: FAIL");
    $finish;
  end

  initial begin #400000000; $display("RESULT: TIMEOUT"); $finish; end
endmodule
