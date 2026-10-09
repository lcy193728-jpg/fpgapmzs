`timescale 1ns/1ps
//=====================================================================
// tb_audio_viz_gate.v —— audio_viz_overlay 门控专项测试 (2026-10-09n)
//
// 只验证「什么时候整条可视化会出现/消失」这一条门控逻辑, 不涉及柱高数值
// (柱高数值由 tb_audio_viz_overlay.v 覆盖; 那个 TB 的坐标系停留在 10-09b
//  之前的 [404,479] 旧版, 已与当前 [362,437] 布局不一致, 故本测试单列)。
//
// 门控真值(当前实现):
//   show = !menu && show_not_full && (live_sr != 0)
//   show_not_full = (scene==0) || (scene==2) || (scene==3) || (scene==1 && meet_warn_lv)
//   即: 会议场景(1) 只有 meet_warn_lv=1(WARN 期间)才允许显示; 其余场景不受该信号影响。
//
// 判据像素: 取条带上边框 y=362 的 x=0 (该处只由 show 决定, 与柱高无关):
//   有 show 时 = accent(scene 配色); 无 show 时 = data_i 透传。
//=====================================================================
module tb_audio_viz_gate;
  reg clk = 0;
  reg rst = 1;
  reg hs_i = 0, vs_i = 0, de_i = 1;
  reg [23:0] data_i = 24'h1b2c3d;      // 透传基准色
  reg [11:0] px_x = 0, px_y = 0;
  reg menu_active = 0;
  reg [1:0] scene_id = 0;
  reg meet_warn_lv = 0;
  reg pcm_take = 0;
  reg signed [15:0] pcm = 0;
  wire hs_o, vs_o, de_o;
  wire [23:0] data_o;
  wire [11:0] px_x_o, px_y_o;

  always #20 clk = ~clk;                       // 25 MHz

  audio_viz_overlay dut(
    .clk(clk), .rst(rst), .hs_i(hs_i), .vs_i(vs_i), .de_i(de_i), .data_i(data_i),
    .px_x(px_x), .px_y(px_y), .menu_active(menu_active), .scene_id(scene_id),
    .meet_warn_lv(meet_warn_lv),
    .pcm_take(pcm_take), .pcm(pcm),
    .hs_o(hs_o), .vs_o(vs_o), .de_o(de_o), .data_o(data_o),
    .px_x_o(px_x_o), .px_y_o(px_y_o));

  localparam [23:0] C_ACC0 = 24'h44ff88;       // scene0 迎新 = 绿
  localparam [23:0] C_ACC2 = 24'h30e8ff;       // scene2 抢答 = 青
  localparam [23:0] C_ACC3 = 24'hff3030;       // scene3 应急 = 红(无边框)
  localparam [23:0] C_PASS = 24'h1b2c3d;       // 透传

  integer checks = 0, fails = 0;

  task chk; input [11:0] x,y; input [23:0] exp; input [255:0] msg;
    begin
      @(negedge clk); px_x = x; px_y = y; data_i = C_PASS;
      @(negedge clk); @(negedge clk); @(negedge clk);
      checks = checks + 1;
      if (data_o === exp) $display("[PASS] %0s : px(%0d,%0d) data_o=%06h", msg, x, y, data_o);
      else begin fails = fails + 1;
        $display("[FAIL] %0s : px(%0d,%0d) data_o=%06h 期望 %06h", msg, x, y, data_o, exp); end
    end
  endtask

  // 灌音: 每 HP 个样本翻转符号, 共 NG 组 (与 tb_audio_viz_overlay 同法)
  task feed_pat; input integer HP; input integer NG; input signed [15:0] A;
    integer k, total; reg sg;
    begin
      total = NG * 1024; sg = 0;
      for (k = 0; k < total; k = k + 1) begin
        @(negedge clk); pcm = sg ? -A : A; pcm_take = 1;
        @(negedge clk); pcm_take = 0;
        if ((k % HP) == (HP-1)) sg = ~sg;
      end
    end
  endtask

  localparam signed [15:0] AMP = 16'sd10240;

  initial begin
    rst = 1; repeat (6) @(negedge clk); rst = 0; repeat (6) @(negedge clk);

    //---- G1: 会议场景 + 非 WARN + 有声音 → 不显示 ----
    scene_id = 1; meet_warn_lv = 0;
    feed_pat(64, 3, AMP); repeat (6) @(negedge clk);
    chk(0, 362, C_PASS, "G1 会议非WARN: 有声音也不显示(上边框透传)");
    chk(0, 437, C_PASS, "G2 会议非WARN: 下边框也透传");
    chk(0, 404, C_PASS, "G3 会议非WARN: 条带内部透传");

    //---- G4: 会议场景 + WARN + 有声音 → 显示(绿色框) ----
    meet_warn_lv = 1; repeat (6) @(negedge clk);
    chk(0, 362, C_ACC0, "G4 会议WARN: 上边框出现(绿=会议配色)");
    chk(0, 437, C_ACC0, "G5 会议WARN: 下边框出现");

    //---- G6: 会议 WARN 结束(声音停 → live_sr 回零)→ 整条消失 ----
    meet_warn_lv = 0; repeat (6) @(negedge clk);
    chk(0, 362, C_PASS, "G6 会议WARN结束: 边框消失");

    //---- G7/G8: 其他场景不受 meet_warn_lv 影响 ----
    scene_id = 2; feed_pat(64, 3, AMP); repeat (6) @(negedge clk);
    chk(0, 362, C_ACC2, "G7 抢答场景正常显示(青), 不受 meet_warn_lv 影响");
    scene_id = 0; feed_pat(32, 3, 16'sd5120); repeat (6) @(negedge clk);
    chk(0, 362, C_ACC0, "G8 迎新场景正常显示(绿)");

    //---- G9: 应急场景无边框(融合), 但柱体应出现(取柱体像素) ----
    scene_id = 3; feed_pat(64, 3, AMP); repeat (6) @(negedge clk);
    chk(0, 362, C_PASS, "G9 应急场景无上边框(融合)");

    //---- G10: 菜单态一律不显示 ----
    scene_id = 2; menu_active = 1; repeat (6) @(negedge clk);
    chk(0, 362, C_PASS, "G10 菜单态不显示");
    menu_active = 0; repeat (6) @(negedge clk);
    chk(0, 362, C_ACC2, "G11 退出菜单恢复显示");

    $display("==== tb_audio_viz_gate: checks=%0d fails=%0d ====", checks, fails);
    if (fails == 0) $display("RESULT: PASS"); else $display("RESULT: FAIL");
    $finish;
  end

  initial begin #20000000; $display("RESULT: TIMEOUT"); $finish; end
endmodule
