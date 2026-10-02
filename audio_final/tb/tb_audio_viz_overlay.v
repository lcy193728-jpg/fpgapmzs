`timescale 1ns/1ps
//=====================================================================
// audio_viz_overlay 50 根柱 / 条带加高两倍 回归测试
//
// 被验证的行为(与 audio_viz_overlay.v 头注释的 [C1]~[C5] 对应):
//   * 分帧: 每 1024 个 48 kHz 样本合成 1 根柱, 50 根柱 = 1.07 s 历史。
//   * 柱高来源是过零率(音高): 半周期 HP 个样本地翻转 pcm 符号, 则每组
//     恰好 1024/HP 次过零; pit = 过零率*3/4, 柱高 = pit*2(条带加高两倍)。
//       HP=64 → 16 次 → pit 12 → 柱高 24 (柱顶 y=412)
//       HP=32 → 32 次 → pit 24 → 柱高 48 (柱顶 y=388)
//   * 无声门控: 整组 pcm 恒 0 → 柱高 0, 只剩 y=436 基线。
//   * 滚动: 先灌 51 组慢音(柱高24), 再灌 13 组快音(柱高48), 则最右 13 根
//     是新高柱、其左边仍是矮柱 —— 同一帧内同时看到两档柱高, 直接证明
//     "柱子跟着声音变"且"自右向左顺过去"。分界在 col37/col36。
//   * 列划分: 50 根柱均分 640 px; col = (5*x)>>6, 列内 sub = (5*x)&63,
//     sub<46 是柱体(约 9.2 px)、其余是间隙(约 3.6 px)。
//   * 条带几何: y∈[362,437](本次由 [400,437] 拉高两倍), 上下边框
//     y=362/437 为 accent, 内部底色 101820; accent 随场景 0/2/3 变色;
//     menu 态与会议场景(scene=1) 完全不叠加(透传 data_i)。
//   * 应急场景(scene=3)无条带框: 不画底色/上下边框, 只有柱体透出在背景上
//     (D3~D8); 场景 0/2 的框保持不变(A1~A11, D1/D2)。
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

  // 测试用幅度(任意非 0 即可让门控通过; 与真实音频 224/448/620 一样都是
  //   |pcm|>>7 != 0)。
  localparam signed [15:0] AMP = 16'sd10240;

  // 列号/列内位置: col=(5*x)>>6, sub=(5*x)&63, sub<46 为柱体。
  //   x=0   → col 0,  sub 0  → 柱体
  //   x=9   → col 0,  sub 45 → 柱体(第 0 根柱最后一列柱体)
  //   x=10  → col 0,  sub 50 → 间隙
  //   x=13  → col 1,  sub 1  → 柱体(下一根柱起点)
  //   x=461 → col 36, sub 1  → 柱体
  //   x=474 → col 37, sub 2  → 柱体
  //   x=628 → col 49, sub 4  → 柱体(最右, 最新一根)

  integer checks = 0, fails = 0;

  //------------------------------------------------------------------
  // 灌 PCM: 符号每 HP 个样本翻转一次(HP 必须整除 1024), 共 NG 组。
  //   每个 1024 样本组恰好出现 1024/HP 次过零。
  //   A=0 时 pcm 恒 0 → 过零 0 次且包络 0 → 柱高 0 (静音)。
  //------------------------------------------------------------------
  task feed_pat;
    input integer HP;
    input integer NG;
    input signed [15:0] A;
    integer k, total, cnt;
    reg sg;
    begin
      total = NG * 1024; sg = 0; cnt = 0;
      for (k = 0; k < total; k = k + 1) begin
        @(negedge clk); pcm = sg ? -A : A; pcm_take = 1;
        @(negedge clk); pcm_take = 0;
        cnt = cnt + 1;
        if (cnt == HP) begin cnt = 0; sg = ~sg; end
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
    $display("==== tb_audio_viz_overlay: 50 根柱 / 条带加高两倍 ====");

    // ---------- 复位 ----------
    rst = 1; repeat (4) @(posedge clk);
    rst = 0; repeat (4) @(posedge clk);
    menu_active = 0; scene_id = 2; repeat (4) @(posedge clk);

    // ---------- 阶段 A: [音高路·抢答场景] 51 组 HP=64 → 过零16 → 柱高24 ----------
    feed_pat(64, 51, AMP);
    repeat (4) @(posedge clk);
    $display("---- A: 抢答场景 过零16 → 柱高24(柱占 y413..436) ----");
    chk(628, 436, C_ACC2, "A1  柱底基线 y436");
    chk(628, 412, C_ACC2, "A2  最新柱顶一行(高24)");
    chk(628, 411, C_BG,   "A3  最新柱顶上一行为底色");
    chk(  0, 362, C_ACC2, "A4  条带上边框(拉高后)");
    chk(  0, 437, C_ACC2, "A5  条带下边框");
    chk(  0, 361, C_PASS, "A6  条带上方不叠加");
    chk(  0, 438, C_PASS, "A7  条带下方不叠加");
    chk( 10, 430, C_BG,   "A8  柱间间隙(sub=50)");
    chk(  9, 430, C_ACC2, "A9  第0根柱柱体(sub=45)");
    chk( 13, 430, C_ACC2, "A10 第1根柱起点是柱体");
    chk(628, 430, C_ACC2, "A11 最右柱(col 49)也是柱体");

    // ---------- 阶段 B: 再灌 13 组 HP=32(柱高48) → 右侧变高, 左侧仍矮 ----------
    feed_pat(32, 13, AMP);
    repeat (4) @(posedge clk);
    $display("---- B: 过零32 → 柱高48, 最右高、左边仍矮(同一帧两档) ----");
    chk(628, 388, C_ACC2, "B1  新柱顶一行(高48)");
    chk(628, 387, C_BG,   "B2  新柱顶上一行为底色");
    chk(628, 430, C_ACC2, "B3  新柱柱身");
    chk(461, 412, C_ACC2, "B4  旧柱(col36,高24)柱顶在");
    chk(461, 388, C_BG,   "B5  同一行: 旧柱够不到 → 旧柱没有柱体");
    chk(628, 411, C_ACC2, "B6  同一行: 新柱有柱体");
    chk(461, 411, C_BG,   "B7  同一行: 旧柱没有 → 同帧两档");

    // ---------- 阶段 C: 灌 50 组静音 → 柱高 0, 只剩基线 ----------
    feed_pat(64, 50, 16'sd0);
    repeat (4) @(posedge clk);
    $display("---- C: 静音 → 柱高0(只剩 y436 基线) ----");
    chk(628, 436, C_ACC2, "C1 静音基线");
    chk(628, 435, C_BG,   "C2 静音时基线之上为底色");
    chk(  0, 436, C_ACC2, "C3 最左柱也只剩基线");
    chk(  0, 435, C_BG,   "C4 最左柱柱身已空");

    // ---------- 阶段 D: 配色随场景 + 应急场景无条带框(融合) ----------
    scene_id = 2; repeat (4) @(posedge clk);
    chk(  0, 362, C_ACC2, "D1 抢答场景青色(上边框)");
    chk( 10, 430, C_BG,   "D2 抢答场景柱间仍是底色");
    // 静音后新起的第 1 组因为过零统计窗口与半周期边界错开半格, 只有 15 次
    //   过零(柱高 20); 从第 2 组起进入稳态 16 次(柱高 24)。故这里灌 2 组,
    //   取第 2 组(最右 col49)做断言。
    scene_id = 3; feed_pat(64, 2, AMP); repeat (4) @(posedge clk);
    chk(  0, 362, C_PASS, "D3 应急场景无上边框(已融合)");
    chk(  0, 437, C_PASS, "D4 应急场景无下边框(已融合)");
    chk( 10, 430, C_PASS, "D5 应急场景柱间无底色(已融合)");
    chk(628, 412, C_ACC3, "D6 应急场景柱体照画(红色)");
    chk(628, 411, C_PASS, "D7 应急场景柱顶上一行透传");
    chk(628, 436, C_ACC3, "D8 应急场景基线柱体红色");

    // ---------- 阶段 E: 隐藏条件 ----------
    scene_id = 1; repeat (4) @(posedge clk);
    chk(  0, 436, C_PASS, "E1 会议场景不叠加");
    scene_id = 2; repeat (4) @(posedge clk);
    menu_active = 1; repeat (4) @(posedge clk);
    chk(  0, 362, C_PASS, "E2 菜单态不叠加");
    chk(628, 430, C_PASS, "E3 菜单态整条不叠加");
    menu_active = 0; repeat (4) @(posedge clk);
    chk(  0, 436, C_ACC2, "E4 退回场景2恢复显示");

    // ---------- 阶段 F: [包络路·迎新场景] 柱高真随音量(组内平均幅度) ----------
    //   迎新放 TF 卡真实音乐, 柱高 = Σ|pcm| / 1024 / 128:
    //     |pcm|=5120  → 柱高 40 → 柱顶 y=396
    //     |pcm|=2560  → 柱高 20 → 柱顶 y=416
    //     |pcm|=10240 → 柱高 80 > 74 → 整条填满(自然限幅)
    scene_id = 0; repeat (4) @(posedge clk);
    feed_pat(32, 2, 16'sd5120); repeat (4) @(posedge clk);
    $display("---- F: 迎新场景 包络音量柱 ----");
    chk(628, 396, C_ACC0, "F1  |pcm|5120 → 柱顶 y396");
    chk(628, 395, C_BG,   "F2  |pcm|5120 → 柱顶上一行为底色");
    chk(  0, 362, C_ACC0, "F3  迎新场景有条带框(上边框)");
    chk( 10, 430, C_BG,   "F4  迎新场景柱间仍是底色");

    feed_pat(32, 2, 16'sd2560); repeat (4) @(posedge clk);
    chk(628, 416, C_ACC0, "F5  音量减半 → 柱顶 y416(真随音量)");
    chk(628, 415, C_BG,   "F6  音量减半 → 柱顶上一行为底色");
    chk(628, 396, C_BG,   "F7  音量减半 → 原来的柱顶已够不到");

    feed_pat(32, 2, 16'sd10240); repeat (4) @(posedge clk);
    chk(628, 363, C_ACC0, "F8  大音量(|pcm|10240) → 整条填满(边框下一行也是柱体)");
    chk(628, 370, C_ACC0, "F9  大音量下条带内高处仍是柱体");

    $display("==== checks=%0d  fails=%0d ====", checks, fails);
    if (fails == 0) $display("RESULT: PASS");
    else            $display("RESULT: FAIL");
    $finish;
  end

  // 看门狗, 防止死等(约 4.7 ms 的 48 kHz 喂数 + 检查; 上限放到 15 ms)
  initial begin
    #15000000;
    $display("RESULT: TIMEOUT");
    $finish;
  end
endmodule
