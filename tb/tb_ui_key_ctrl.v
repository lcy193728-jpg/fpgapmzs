//====================================================================
// 模块名 : tb_ui_key_ctrl.v  (2026-09-17 批次4: 新增"周期"档 + 参数强显保持)
// 功能   : 全局统一人机交互控制器(ui_key_ctrl)仿真
// 规格(四个场景下语义完全一致, 与场景解耦):
//   KEY1 : 功能模式循环, 每按一次 +1: 0图片/切图→1亮度→2缩放→3周期→0
//   KEY2 : 当前模式参数 减 / KEY3 : 当前模式参数 加
//     模式0 图片/切图 : 默认自动轮播; KEY3=下一张(并转入手动单张);
//                       KEY2=上一张(已在第1张时改为回自动轮播);
//                       离开模式0(去亮度/缩放/周期)自动回自动轮播
//     模式1 亮度 : 0..15(默认8), 到边界钳位
//     模式2 缩放 : 0..7(默认4=100%), 到边界钳位; 有效变化时发 res_chg_pl
//     模式3 周期 : 2/3/5/10/30s(默认3s), KEY3/KEY2 环绕调档;
//                  输出 period_cycles = 秒数×CLK_FREQ_HZ
//   参数强显保持: 任一参数动作 → disp_hold 拉高 DISP_HOLD_CYCLES,
//                 disp_sel 锁存动作时的模式(顶层据此强显该参数值)
//   KEY4 : **已释放**(不再参与逻辑, 顶层引脚保留备用)
// 说明   : 消抖 10ms 对仿真太慢, 用 defparam 把 3 个消抖计数器缩到 100 拍;
//          保持时长 2s 同样用 defparam 缩到 500 拍, 否则远超仿真超时。
//          按键统一"上拉高、按下低", 一次按键一个下降沿脉冲。
//====================================================================

`timescale 1ns/1ps
module tb_ui_key_ctrl;

    localparam CLK_PERIOD = 10;      // 100MHz -> 10ns

    reg         clk;
    reg         rst;
    reg         key1, key2, key3;
    reg  [7:0]  img_no;
    reg         scene_chg;

    wire [1:0]  mode;
    wire [3:0]  bri_level;
    wire [3:0]  res_level;
    wire [7:0]  period_sec;
    wire [31:0] period_cycles;
    wire        disp_hold;
    wire [1:0]  disp_sel;
    wire        pic_manual;
    wire [7:0]  pic_param;
    wire        key_next_pl;
    wire        key_prev_pl;
    wire        res_chg_pl;

    integer     fail_cnt = 0;
    // 单周期脉冲捕获(粘滞)
    reg         next_seen, prev_seen, rchg_seen;

    ui_key_ctrl dut (
        .clk        (clk),
        .rst        (rst),
        .key1       (key1),
        .key2       (key2),
        .key3       (key3),
        .key4       (1'b1),
        .control_lock(1'b0),
        .img_no     (img_no),
        .scene_chg  (scene_chg),
        .mode       (mode),
        .bri_level  (bri_level),
        .res_level  (res_level),
        .period_sec (period_sec),
        .period_cycles(period_cycles),
        .disp_hold  (disp_hold),
        .disp_sel   (disp_sel),
        .pic_manual (pic_manual),
        .pic_param  (pic_param),
        .key_next_pl(key_next_pl),
        .key_prev_pl(key_prev_pl),
        .res_chg_pl (res_chg_pl)
    );

    // 缩短内部消抖时间(仅仿真; 上板用默认 10ms = 1_000_000 拍)
    defparam dut.u_k1.DEB_MAX = 20'd100;
    defparam dut.u_k2.DEB_MAX = 20'd100;
    defparam dut.u_k3.DEB_MAX = 20'd100;
    // 缩短参数强显保持(仅仿真; 上板用默认 2s = 200_000_000 拍)
    defparam dut.DISP_HOLD_CYCLES = 32'd3000;

    // 脉冲捕获
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            next_seen <= 1'b0;
            prev_seen <= 1'b0;
            rchg_seen <= 1'b0;
        end
        else begin
            if (key_next_pl) next_seen <= 1'b1;
            if (key_prev_pl) prev_seen <= 1'b1;
            if (res_chg_pl)  rchg_seen <= 1'b1;
        end
    end

    task check(input cond, input [255:0] msg);
        begin
            if (cond) begin
                $display("t=%0t  [PASS] %0s", $time, msg);
            end
            else begin
                fail_cnt = fail_cnt + 1;
                $display("t=%0t  [FAIL] %0s  (mode=%0d bri=%0d res=%0d prd=%0ds manual=%0b param=%0d)",
                         $time, msg, mode, bri_level, res_level, period_sec, pic_manual, pic_param);
            end
        end
    endtask

    task clear_flags;
        begin
            next_seen <= 1'b0;
            prev_seen <= 1'b0;
            rchg_seen <= 1'b0;
        end
    endtask

    task settle(input integer n);
        begin
            repeat (n) @(posedge clk);
        end
    endtask

    task press1; begin key1 = 1'b0; settle(150); key1 = 1'b1; settle(150); end endtask
    task press2; begin key2 = 1'b0; settle(150); key2 = 1'b1; settle(150); end endtask
    task press3; begin key3 = 1'b0; settle(150); key3 = 1'b1; settle(150); end endtask

    initial clk = 1'b0;
    always #(CLK_PERIOD/2) clk = ~clk;

    initial begin
        #8000000;   // 8ms 超时兜底
        $display("=== [TIMEOUT] 仿真超时提前结束,失败数=%0d ===", fail_cnt);
        $finish;
    end

    initial begin
        rst       = 1'b1;
        key1 = 1'b1; key2 = 1'b1; key3 = 1'b1;   // 全释放(高)
        img_no    = 8'd0;
        scene_chg = 1'b0;
        repeat (5) @(posedge clk);
        rst = 1'b0;
        repeat (20) @(posedge clk);

        //-------- 1. 上电默认 --------
        check(mode == 2'd0 && bri_level == 4'd8 && res_level == 4'd4 &&
              pic_manual == 1'b0 && pic_param == 8'd0,
              "上电默认: 模式0图片/亮度8/缩放4(100%)/自动轮播");
        check(period_sec == 8'd3 && period_cycles == 32'd300_000_000,
              "上电默认: 轮播周期档=3s(=300_000_000 周期, 与原固定间隔一致)");
        check(disp_hold == 1'b0, "上电默认: 无参数强显保持");

        //-------- 2. KEY1 功能模式循环 0→1→2→3→0→1 --------
        press1;
        check(mode == 2'd1, "KEY1 第1按 -> 模式1 亮度");
        press1;
        check(mode == 2'd2, "KEY1 第2按 -> 模式2 缩放");
        press1;
        check(mode == 2'd3, "KEY1 第3按 -> 模式3 轮播周期");
        press1;
        check(mode == 2'd0, "KEY1 第4按 -> 模式0 图片(循环回绕)");
        press1;
        check(mode == 2'd1, "KEY1 第5按 -> 模式1 亮度");

        //-------- 3. 模式1: 亮度 KEY3+/KEY2- 与边界钳位 --------
        clear_flags;                       // 之后整段不应出现 res_chg_pl
        press3;
        check(bri_level == 4'd9, "模式1 KEY3(加) -> 亮度 9");
        press3;
        check(bri_level == 4'd10, "模式1 KEY3(加) -> 亮度 10");
        press2;
        check(bri_level == 4'd9, "模式1 KEY2(减) -> 亮度 9");
        repeat (7) press3;                  // 9+7 -> 钳位 15
        check(bri_level == 4'd15, "模式1 连按 KEY3 -> 亮度上限钳位 15");
        press3;
        check(bri_level == 4'd15, "模式1 上限再按 KEY3 -> 保持 15");
        repeat (16) press2;                 // 15-16 -> 钳位 0
        check(bri_level == 4'd0, "模式1 连按 KEY2 -> 亮度下限钳位 0");
        press2;
        check(bri_level == 4'd0, "模式1 下限再按 KEY2 -> 保持 0");
        repeat (8) press3;                  // 回到 8
        check(bri_level == 4'd8, "模式1 KEY3×8 -> 亮度回到 8");
        check(res_level == 4'd4 && ~rchg_seen,
              "模式1 全程不改缩放档 / 不发 res_chg_pl");

        //-------- 4. 模式2: 缩放 KEY3+/KEY2- 与 res_chg_pl --------
        press1;                             // 1->2
        check(mode == 2'd2, "KEY1 -> 模式2 缩放");

        clear_flags; press3;
        check(res_level == 4'd5 && rchg_seen, "模式2 KEY3 -> 缩放 5, 且发 res_chg_pl");
        clear_flags; press3;
        check(res_level == 4'd6 && rchg_seen, "模式2 KEY3 -> 缩放 6, 且发 res_chg_pl");
        clear_flags; press3;
        check(res_level == 4'd7 && rchg_seen, "模式2 KEY3 -> 缩放 7(上限)");
        clear_flags; press3;
        check(res_level == 4'd7 && ~rchg_seen, "模式2 上限再按 KEY3 -> 保持 7 且不发脉冲");
        clear_flags; press2;
        check(res_level == 4'd6 && rchg_seen, "模式2 KEY2 -> 缩放 6, 且发 res_chg_pl");
        clear_flags; repeat (6) press2;      // 6-6 -> 0
        check(res_level == 4'd0, "模式2 连按 KEY2 -> 缩放下限钳位 0");
        clear_flags; press2;
        check(res_level == 4'd0 && ~rchg_seen, "模式2 下限再按 KEY2 -> 保持 0 且不发脉冲");
        repeat (4) press3;                   // 回到 4(100%)
        check(res_level == 4'd4 && bri_level == 4'd8,
              "模式2 回到缩放 4(100%) / 亮度未被改动");

        //-------- 5. 模式0: 切图(KEY2/KEY3 即上一张/下一张, 无需独立切换键) ----
        press1;                             // 2->3(周期)
        check(mode == 2'd3, "KEY1 -> 模式3 周期(经过周期档)");
        press1;                             // 3->0
        check(mode == 2'd0, "KEY1 -> 模式0 图片/切图");
        check(pic_manual == 1'b0 && pic_param == 8'd0,
              "刚进模式0 -> 默认自动轮播(上电/切场景/切模式回来一律如此)");

        img_no = 8'd1; settle(5);           // 假卡首图已显示
        clear_flags; press3;
        check(next_seen, "模式0 KEY3 -> 产生下一张脉冲");
        check(pic_manual == 1'b1 && pic_param == 8'd1,
              "模式0 KEY3 -> 顺带转入手动单张(参数=当前图1, 停自动计时)");
        check(~prev_seen, "模式0 KEY3 不产生上一张脉冲");

        img_no = 8'd2; settle(5);           // 假卡进到第 2 张
        clear_flags; press2;
        check(prev_seen, "模式0 第2张 KEY2 -> 产生上一张脉冲");
        check(pic_manual == 1'b1 && pic_param == 8'd2,
              "上一张 -> 仍手动 / 参数跟随图序号 2");

        img_no = 8'd1; settle(5);           // 回到第 1 张
        clear_flags; press2;
        check(~prev_seen, "模式0 首张 KEY2 -> 不发上一张脉冲");
        check(pic_manual == 1'b0 && pic_param == 8'd0,
              "模式0 首张 KEY2 -> 改为回到自动轮播(与上一张共用一键)");

        clear_flags; press3;                // 再按 KEY3 又转手动
        check(next_seen && pic_manual == 1'b1, "再按 KEY3 -> 再次转手动并切下一张");

        // 场景切换脉冲 -> 强制回自动
        scene_chg = 1'b1; @(posedge clk); scene_chg = 1'b0; settle(5);
        check(pic_manual == 1'b0 && pic_param == 8'd0,
              "scene_chg -> 图片参数复位为自动轮播");

        // 离开模式0(去亮度) -> 自动回自动轮播(不把底层图冻住)
        press3;                             // 先切手动
        check(pic_manual == 1'b1, "模式0 KEY3 -> 手动(离开模式0前)");
        press1;                             // 模式0->1
        check(mode == 2'd1 && pic_manual == 1'b0,
              "KEY1 离开模式0 -> 自动回自动轮播(不冻图)");

        // 模式1/2 下 KEY2/KEY3 只调参数, 绝不切图(模式互斥, 这就是"不冲突")
        clear_flags; press3;
        check(~next_seen && bri_level == 4'd9, "模式1 KEY3 -> 只调亮度, 不切图");
        press1;                             // 1->2
        clear_flags; press3;
        check(~next_seen && res_level == 4'd5, "模式2 KEY3 -> 只调缩放, 不切图");
        clear_flags; press2;                // 5->4, 复位缩放档便于后续用例
        check(res_level == 4'd4, "模式2 KEY2 -> 缩放回到 4(100%)");
        press1;                             // 2->3(周期)
        press1;                             // 3->0
        press1;                             // 0->1
        check(mode == 2'd1, "KEY1 -> 模式1(进入消抖鲁棒性测试段)");

        //-------- 6. 消抖鲁棒性(修"偶发失灵"): --------
        //   DEB_MAX=100 拍(=1us 仿真值, 上板 10ms)。
        //   (a) 按下过程带抖动(每段 40 拍 < 100)、最后稳定按下 →
        //       只应识别 **一次** 按键(不重复触发、也不丢键)
        //   当前 mode=2'd1(亮度) → 按 KEY1 一次应到 2'd2
        clear_flags;
        key1 = 1'b0; settle(40);      // 抖动段 1(不足 DEB_MAX, 不采纳)
        key1 = 1'b1; settle(30);
        key1 = 1'b0; settle(40);      // 抖动段 2
        key1 = 1'b1; settle(30);
        key1 = 1'b0; settle(150);     // 稳定按下(> DEB_MAX, 采纳)
        key1 = 1'b1; settle(150);     // 释放
        check(mode == 2'd2, "带抖动按下 KEY1 -> 只前进 1 次(模式 1->2, 未丢键未重复)");

        //   (b) 短毛刺(40 拍 < DEB_MAX)不应被当成按键
        clear_flags;
        key2 = 1'b0; settle(40); key2 = 1'b1; settle(150);
        check(res_level == 4'd4 && ~rchg_seen,
              "短毛刺 KEY2(40拍<DEB_MAX) -> 不触发(缩放档仍 4, 无重载脉冲)");

        //   (c) 快速连按(按下/释放各 110 拍, 刚好各超 DEB_MAX)应每次都被识别
        clear_flags;
        key3 = 1'b0; settle(110); key3 = 1'b1; settle(110);   // 第 1 次
        key3 = 1'b0; settle(110); key3 = 1'b1; settle(110);   // 第 2 次
        check(res_level == 4'd6 && rchg_seen,
              "快速连按 KEY2... KEY3 两次(各 110 拍) -> 缩放 4->6(连按不丢键)");

        //-------- 7. 模式3 周期档(批次4): KEY1 进入, KEY2/KEY3 环绕调档 --------
        press1;                             // 2->3
        check(mode == 2'd3, "KEY1 -> 模式3 轮播周期");
        check(period_sec == 8'd3,
              "周期档默认值 = 3s(与原固定 SLIDE_INTERVAL 一致, 默认行为不变)");

        clear_flags;                        // 之后整段不应出现切图/缩放重载脉冲
        press3; check(period_sec == 8'd5,  "周期档 KEY3 -> 3s→5s");
        press3; check(period_sec == 8'd10, "周期档 KEY3 -> 5s→10s");
        press3; check(period_sec == 8'd30, "周期档 KEY3 -> 10s→30s");
        press3; check(period_sec == 8'd2,  "周期档 KEY3 到顶环绕 -> 30s→2s");
        check(period_cycles == 32'd200_000_000,
              "2s 档 -> 周期数 200_000_000(=2s×100MHz)");
        press2; check(period_sec == 8'd30, "周期档 KEY2 到底环绕 -> 2s→30s");
        press2; check(period_sec == 8'd10, "周期档 KEY2 -> 30s→10s");
        press2; check(period_sec == 8'd5,  "周期档 KEY2 -> 10s→5s");
        press2; check(period_sec == 8'd3,  "周期档 KEY2 -> 5s→3s(调回默认)");
        check(~next_seen && ~prev_seen && ~rchg_seen,
              "周期档调档 -> 不切图(无上/下一张脉冲)、不触发缩放重载");

        //-------- 8. 参数强显保持(2s, 仿真 defparam 缩到 3000 拍) --------
        //   (a) 刚在周期档调过档 → 保持中, 显示选择=周期档(3)
        check(disp_hold == 1'b1 && disp_sel == 2'd3,
              "刚调周期档 -> 参数强显保持中, disp_sel=周期档(顶层据此强显秒数)");
        settle(3500);                       // > 保持时长
        check(disp_hold == 1'b0,
              "保持超时 -> disp_hold 自动落低(回到常规显示)");

        //   (b) 模式1 调亮度 → disp_sel=1; 切到模式2 后保持期内仍锁定亮度
        press1;                             // 3->0
        press1;                             // 0->1
        check(mode == 2'd1, "KEY1 -> 模式1 亮度");
        press3;                             // 亮度 9->10
        check(bri_level == 4'd10 && disp_hold == 1'b1 && disp_sel == 2'd1,
              "模式1 调亮度 -> 保持中, disp_sel=亮度");
        press1;                             // 1->2(离开亮度档)
        check(mode == 2'd2 && disp_hold == 1'b1 && disp_sel == 2'd1,
              "离开模式1 后保持期内 disp_sel 仍=亮度(第2~4位继续显示亮度值 2 秒)");
        settle(3500);
        check(disp_hold == 1'b0 && mode == 2'd2,
              "保持到期 -> 退回常规显示(按当前模式2 取缩放值), 模式本身不变");

        $display("=== ui_key_ctrl 仿真结束,失败数=%0d ===", fail_cnt);
        if (fail_cnt == 0) $display("=== [ALL PASS] ===");
        $finish;
    end

endmodule
