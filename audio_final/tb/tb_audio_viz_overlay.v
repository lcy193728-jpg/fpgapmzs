`timescale 1ns/1ps
//=====================================================================
// audio_viz_overlay 时间序列"音量柱"回归测试
//
// 被验证的行为(与 audio_viz_overlay.v 头注释的 [B1]~[B5] 对应):
//   * 柱高随输入 PCM 音量变化: 包络 80 → 柱高 15 行, 包络 160 → 30 行,
//     包络 0 → 只剩 y=436 一条基线; 三种情况各查柱顶/柱顶上一行。
//   * 柱体形状: 每 4 像素 = 3 像素柱体 + 1 像素间隙(x%4==3 必为底色)。
//   * 柱阵随时间滚动: 先灌 256 组"矮"包络, 再灌 160 组"高"包络, 则左半
//     (col<96) 仍是矮柱、右半(col>=96) 已是高柱 —— 同一帧内同时可见两种
//     高度, 直接证明"柱子跟着音量变"。
//   * 条带几何/配色/隐藏条件与上一版逐条一致: y∈[400,437], 上下边框
//     y=400/437 为 accent, 内部底色 101820; accent 随场景 0/2/3 变色;
//     menu 态与会议场景(scene=1) 完全不叠加(透传 data_i)。
//   * 2 拍流水对齐: 采样时刻 px_x_o 必须等于当拍驱动进去的 X。
//
// 需要的仿真模型: EG_LOGIC_BRAM_sim.v (厂商 eagle_macro.v 里该原语是空壳,
//   ModelSim 下 dob 会悬空)。本 TB 只用 8bit/512 深配置, 与该模型一致。
//=====================================================================
module tb_audio_viz_overlay;
  reg clk = 0;
  reg rst = 1;
  reg hs_i = 0, vs_i = 0, de_i = 0;
  reg [23:0] data_i = 0;
  reg [11:0] px_x = 0, px_y = 0;
  reg menu_active = 0;
  reg [1:0] scene_id = 0;
  reg pcm_take = 0;
  reg signed [15:0] pcm = 0;
  wire hs_o, vs_o, de_o;
  wire [23:0] data_o;
  wire [11:0] px_x_o, px_y_o;

  always #20 clk = ~clk;                      // 25 MHz 像素时钟

  audio_viz_overlay dut(
    .clk(clk), .rst(rst), .hs_i(hs_i), .vs_i(vs_i), .de_i(de_i), .data_i(data_i),
    .px_x(px_x), .px_y(px_y), .menu_active(menu_active), .scene_id(scene_id),
    .pcm_take(pcm_take), .pcm(pcm),
    .hs_o(hs_o), .vs_o(vs_o), .de_o(de_o), .data_o(data_o),
    .px_x_o(px_x_o), .px_y_o(px_y_o));

  localparam [23:0] C_ACC0 = 24'h44ff88;      // 场景0 迎新
  localparam [23:0] C_ACC2 = 24'h30e8ff;      // 场景2 抢答
  localparam [23:0] C_ACC3 = 24'hff3030;      // 场景3 应急
  localparam [23:0] C_BG   = 24'h101820;      // 条带底色
  localparam [23:0] C_PASS = 24'h1b2c3d;      // 未叠加时应透传的 data_i

  // 柱高换算(与 RTL 的 hgt = mag>>3 + mag>>4 一致)
  //   |pcm|=10240 → mag=80  → hgt=15  → 柱占 y 421..436
  //   |pcm|=20480 → mag=160 → hgt=30  → 柱占 y 406..436
  //   |pcm|=0     → mag=0   → hgt=0   → 只剩 y 436
  localparam signed [15:0] LV_LOW  = 16'sd10240;
  localparam signed [15:0] LV_HIGH = 16'sd20480;

  integer checks = 0, fails = 0;

  //------------------------------------------------------------------
  // 灌 PCM: N 个 48 kHz 采样节拍, 每组 16 个样本写 1 列进环形缓冲
  //------------------------------------------------------------------
  task feed;
    input signed [15:0] V;
    input integer N;
    integer k;
    begin
      for (k = 0; k < N; k = k + 1) begin
        @(negedge clk); pcm = V; pcm_take = 1;
        @(negedge clk); pcm_take = 0;
      end
      @(negedge clk); pcm = 0;
    end
  endtask

  //------------------------------------------------------------------
  // 取一个像素: 驱动 (X,Y) 后等 3 拍采样 data_o(2 拍流水 + 1 拍余量),
  // 顺带核对 px_x_o 是否与驱动的 X 对齐。
  //------------------------------------------------------------------
  task chk;
    input [11:0] X, Y;
    input [23:0] EXP;
    input [8*40-1:0] MSG;
    begin
      @(negedge clk); de_i = 1; px_x = X; px_y = Y; data_i = C_PASS;
      repeat (3) @(posedge clk);
      #1;
      checks = checks + 1;
      if (data_o !== EXP) begin
        fails = fails + 1;
        $display("FAIL  %0s : px(%0d,%0d) data_o=%06h 期望 %06h", MSG, X, Y, data_o, EXP);
      end else begin
        $display("ok    %0s : px(%0d,%0d) data_o=%06h", MSG, X, Y, data_o);
      end
      if (px_x_o !== X) begin
        fails = fails + 1;
        $display("FAIL  流水对齐 : px_x_o=%0d 期望 %0d", px_x_o, X);
      end
      @(negedge clk); de_i = 0; px_x = 0; px_y = 0; data_i = 0;
      repeat (2) @(posedge clk);
    end
  endtask

  initial begin
    $display("==== tb_audio_viz_overlay: 时间序列音量柱 ====");

    // ---------- 复位 ----------
    rst = 1; repeat (4) @(posedge clk);
    rst = 0; repeat (4) @(posedge clk);
    menu_active = 0; scene_id = 0; repeat (4) @(posedge clk);

    // ---------- 阶段 A: 灌 256 组矮包络 → 全屏等高的矮柱 ----------
    feed(LV_LOW, 4096);                     // 256 组 × 16 样本
    repeat (4) @(posedge clk);
    $display("---- A: 包络80 → 柱高15(柱占 y421..436) ----");
    chk(  0, 436, C_ACC0, "A1 柱底 y436 为柱体");
    chk(  2, 430, C_ACC0, "A2 柱身中段");
    chk(  0, 421, C_ACC0, "A3 柱顶一行(高15)");
    chk(  0, 420, C_BG,   "A4 柱顶上一行为底色");
    chk(  3, 430, C_BG,   "A5 x%4==3 是柱间间隙");
    chk(  0, 400, C_ACC0, "A6 条带上边框");
    chk(  0, 437, C_ACC0, "A7 条带下边框");
    chk(  0, 399, C_PASS, "A8 条带上方不叠加");
    chk(  0, 438, C_PASS, "A9 条带下方不叠加");

    // ---------- 阶段 B: 再灌 160 组高包络 → 右半变高柱, 左半仍是矮柱 ----------
    feed(LV_HIGH, 2560);                    // 160 组 × 16 样本
    repeat (4) @(posedge clk);
    $display("---- B: 音量变大 → 右半柱高30, 左半柱高15(同帧两档) ----");
    chk(384, 406, C_ACC0, "B1 新高柱顶一行(高30)");
    chk(384, 405, C_BG,   "B2 新高柱顶上一行为底色");
    chk(384, 415, C_ACC0, "B3 新高柱 y415 有柱");
    chk(380, 421, C_ACC0, "B4 旧矮柱顶一行(高15)");
    chk(380, 415, C_BG,   "B5 旧矮柱 y415 无柱(比新柱矮)");
    chk(  0, 421, C_ACC0, "B6 最左旧矮柱顶仍在");

    // ---------- 阶段 C: 静音 256 组 → 柱高 0, 只剩基线 ----------
    feed(16'sd0, 4096);
    repeat (4) @(posedge clk);
    $display("---- C: 包络0 → 柱高0(只剩 y436 基线) ----");
    chk(  0, 436, C_ACC0, "C1 静音基线");
    chk(  0, 435, C_BG,   "C2 静音时基线之上为底色");
    chk(  0, 430, C_BG,   "C3 静音时柱身为空");
    chk(384, 436, C_ACC0, "C4 静音全宽都只剩基线");

    // ---------- 阶段 D: 配色随场景(柱仍在: 基线) ----------
    scene_id = 2; repeat (4) @(posedge clk);
    chk(  0, 436, C_ACC2, "D1 抢答场景青色");
    scene_id = 3; repeat (4) @(posedge clk);
    chk(  0, 436, C_ACC3, "D2 应急场景红色");

    // ---------- 阶段 E: 隐藏条件 ----------
    scene_id = 1; repeat (4) @(posedge clk);
    chk(  0, 436, C_PASS, "E1 会议场景不叠加");
    scene_id = 0; repeat (4) @(posedge clk);
    menu_active = 1; repeat (4) @(posedge clk);
    chk(  0, 436, C_PASS, "E2 菜单态不叠加");
    chk(384, 430, C_PASS, "E3 菜单态整条不叠加");
    menu_active = 0; repeat (4) @(posedge clk);
    chk(  0, 436, C_ACC0, "E4 退回场景0恢复显示");

    $display("==== checks=%0d  fails=%0d ====", checks, fails);
    if (fails == 0) $display("RESULT: PASS");
    else            $display("RESULT: FAIL");
    $finish;
  end

  // 看门狗, 防止死等(2 ms @1ns 精度; 全流程约 0.5 ms)
  initial begin
    #2000000;
    $display("RESULT: TIMEOUT");
    $finish;
  end
endmodule
