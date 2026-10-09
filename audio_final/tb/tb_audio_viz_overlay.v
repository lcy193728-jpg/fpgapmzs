`timescale 1ns/1ps
//=====================================================================
// audio_viz_overlay 50 根柱 / 底边条带 / 静音整条消失 回归测试
//
// 被验证的行为(与 audio_viz_overlay.v 头注释的 [C1]~[C6][C8] 对应):
//   * 分帧: 每 1024 个 48 kHz 样本合成 1 根柱, 50 根柱 = 1.07 s 历史。
//   * 柱高来源是过零率(音高): 半周期 HP 个样本地翻转 pcm 符号, 则每组
//     恰好 1024/HP 次过零; pit = 过零率*3/4, 柱高 = pit*2(条带加高两倍)。
//       HP=64 → 16 次 → pit 12 → 柱高 24 (柱顶 y=454)
//       HP=32 → 32 次 → pit 24 → 柱高 48 (柱顶 y=430)
//   * 条带几何(2026-10-09 下移到屏幕底边): y∈[404,479], 上下边框
//     y=404/479 为 accent, 内部底色 101820; 基线 y=478(dh=0 恒亮)。
//   * [C8] "有声音才出现、静音整条消失": 静音时**连底色与上下边框一起消失**,
//     整条 y∈[404,479] 全部透传 data_i —— 这是本次改动最核心的断言(F1~F5)。
//   * 滚动: 先灌 51 组慢音(柱高24), 再灌 13 组快音(柱高48), 则最右 13 根
//     是新高柱、其左边仍是矮柱 —— 同一帧内同时看到两档柱高, 直接证明
//     "柱子跟着声音变"且"自右向左顺过去"。分界在 col37/col36。
//   * 列划分: 50 根柱均分 640 px; col = (5*x)>>6, 列内 sub = (5*x)&63,
//     sub<46 是柱体(约 9.2 px)、其余是间隙(约 3.6 px)。
//   * accent 随场景 0/2/3 变色; menu 态与会议场景(scene=1) 完全不叠加。
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
    $display("---- A: 抢答场景 过零16 → 柱高24(柱占 y455..478) ----");
    chk(628, 478, C_ACC2, "A1  柱底基线 y478");
    chk(628, 454, C_ACC2, "A2  最新柱顶一行(高24)");
    chk(628, 453, C_BG,   "A3  最新柱顶上一行为底色");
    chk(  0, 404, C_ACC2, "A4  条带上边框");
    chk(  0, 479, C_ACC2, "A5  条带下边框(屏幕最后一行)");
    chk(  0, 403, C_PASS, "A6  条带上方不叠加");
    chk(  0, 480, C_PASS, "A7  (越界行, 不叠加)");
    chk( 10, 470, C_BG,   "A8  柱间间隙(sub=50)");
    chk(  9, 470, C_ACC2, "A9  第0根柱柱体(sub=45)");
    chk( 13, 470, C_ACC2, "A10 第1根柱起点是柱体");
    chk(628, 470, C_ACC2, "A11 最右柱(col 49)也是柱体");

    // ---------- 阶段 B: 再灌 13 组 HP=32(柱高48) → 右侧变高, 左侧仍矮 ----------
    feed_pat(32, 13, AMP);
    repeat (4) @(posedge clk);
    $display("---- B: 过零32 → 柱高48, 最右高、左边仍矮(同一帧两档) ----");
    chk(628, 430, C_ACC2, "B1  新柱顶一行(高48)");
    chk(628, 429, C_BG,   "B2  新柱顶上一行为底色");
    chk(628, 470, C_ACC2, "B3  新柱柱身");
    chk(461, 454, C_ACC2, "B4  旧柱(col36,高24)柱顶在");
    chk(461, 430, C_BG,   "B5  同一行: 旧柱够不到 → 旧柱没有柱体");
    chk(628, 453, C_ACC2, "B6  同一行: 新柱有柱体");
    chk(461, 453, C_BG,   "B7  同一行: 旧柱没有 → 同帧两档");

    // ---------- 阶段 C: 灌 50 组静音 → [C8] 整条消失(连底色/边框一起) ----------
    feed_pat(64, 50, 16'sd0);
    repeat (4) @(posedge clk);
    $display("---- C: [C8] 静音 → 整条 y[404,479] 全部透传(不含底色/边框) ----");
    chk(628, 478, C_PASS, "C1 静音: 原基线处透传(不再有点亮基线)");
    chk(628, 454, C_PASS, "C2 静音: 柱体区透传");
    chk(  0, 404, C_PASS, "C3 静音: 上边框消失");
    chk(  0, 479, C_PASS, "C4 静音: 下边框消失");
    chk(  0, 440, C_PASS, "C5 静音: 条带内部底色消失");
    chk( 10, 470, C_PASS, "C6 静音: 柱间区透传");
    chk(  0, 403, C_PASS, "C7 静音: 条带上方透传(本来就该是)");
    chk(628, 470, C_PASS, "C8 静音: 最右柱柱身也消失");

    // ---------- 阶段 D: 配色随场景 + 应急场景无条带框(融合) ----------
    //   [C8] 注意: 阶段 C 末尾是静音, live_sr 已回 0 → 这时整条本就该是隐藏的。
    //   所以配色断言必须先喂音把柱子立起来; 同时这也顺带覆盖"静音后再响,
    //   整条会自动重新出现"这条行为(即用户要的"响的时候才出现")。
    scene_id = 2; repeat (4) @(posedge clk);
    chk(  0, 404, C_PASS, "D0 抢答场景: 静音延续中, 整条仍不叠加");
    feed_pat(64, 3, AMP); repeat (4) @(posedge clk);
    chk(  0, 404, C_ACC2, "D1 抢答场景青色(上边框, 响后整条重现)");
    chk( 10, 470, C_BG,   "D2 抢答场景柱间仍是底色");
    // 静音后新起的第 1 组因为过零统计窗口与半周期边界错开半格, 只有 15 次
    //   过零(柱高 20); 从第 2 组起进入稳态 16 次(柱高 24)。故这里灌 2 组,
    //   取第 2 组(最右 col49)做断言。
    scene_id = 3; feed_pat(64, 2, AMP); repeat (4) @(posedge clk);
    chk(  0, 404, C_PASS, "D3 应急场景无上边框(已融合)");
    chk(  0, 479, C_PASS, "D4 应急场景无下边框(已融合)");
    chk( 10, 470, C_PASS, "D5 应急场景柱间无底色(已融合)");
    chk(628, 454, C_ACC3, "D6 应急场景柱体照画(红色)");
    chk(628, 453, C_PASS, "D7 应急场景柱顶上一行透传");
    chk(628, 478, C_ACC3, "D8 应急场景基线柱体红色");

    // ---------- 阶段 E: 隐藏条件 ----------
    scene_id = 1; repeat (4) @(posedge clk);
    chk(  0, 478, C_PASS, "E1 会议场景不叠加");
    scene_id = 2; repeat (4) @(posedge clk);
    menu_active = 1; repeat (4) @(posedge clk);
    chk(  0, 404, C_PASS, "E2 菜单态不叠加");
    chk(628, 470, C_PASS, "E3 菜单态整条不叠加");
    menu_active = 0; repeat (4) @(posedge clk);
    chk(  0, 478, C_ACC2, "E4 退回场景2恢复显示");

    // ---------- 阶段 F: [包络路·迎新场景] 柱高真随音量(组内平均幅度) ----------
    //   迎新放 TF 卡真实音乐, 柱高 = Σ|pcm| / 1024 / 128:
    //     |pcm|=5120  → 柱高 40 → 柱顶 y=438
    //     |pcm|=2560  → 柱高 20 → 柱顶 y=458
    //     |pcm|=10240 → 柱高 80 > 74 → 整条填满(自然限幅)
    scene_id = 0; repeat (4) @(posedge clk);
    feed_pat(32, 2, 16'sd5120); repeat (4) @(posedge clk);
    $display("---- F: 迎新场景 包络音量柱 ----");
    chk(628, 438, C_ACC0, "F1  |pcm|5120 → 柱顶 y438");
    chk(628, 437, C_BG,   "F2  |pcm|5120 → 柱顶上一行为底色");
    chk(  0, 404, C_ACC0, "F3  迎新场景有条带框(上边框)");
    chk( 10, 470, C_BG,   "F4  迎新场景柱间仍是底色");

    feed_pat(32, 2, 16'sd2560); repeat (4) @(posedge clk);
    chk(628, 458, C_ACC0, "F5  音量减半 → 柱顶 y458(真随音量)");
    chk(628, 457, C_BG,   "F6  音量减半 → 柱顶上一行为底色");
    chk(628, 438, C_BG,   "F7  音量减半 → 原来的柱顶已够不到");

    feed_pat(32, 2, 16'sd10240); repeat (4) @(posedge clk);
    chk(628, 405, C_ACC0, "F8  大音量(|pcm|10240) → 整条填满(边框下一行也是柱体)");
    chk(628, 412, C_ACC0, "F9  大音量下条带内高处仍是柱体");

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
