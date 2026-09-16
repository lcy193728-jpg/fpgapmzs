//====================================================================
// 模块名 : tb_scene_control.v
// 功能   : 场景仲裁(scene_control) 语义验证 —— "应急最高 + 先触发先锁定"版
// 语义(2026-09-16 用户定稿):
//   1. 应急最高: SW4(SW[3]) 打开立即进应急(电平直通, 拨回即解), 与
//      普通场景的触发顺序无关; 应急中普通场景的拨动只更新"锁定权", 不改
//      显示, 退出应急即回到当时仍生效的锁定场景。
//   2. 无应急时 = **第一个被触发的场景为准**(先到先得, 不抢占):
//      SW1/SW2/SW3 中先被拨上的锁定生效, 之后拨上的其它场景无效;
//      持锁场景被拨回 → 让给仍开着的其它场景(优先 SW1>SW2>SW3);
//      三路全关 → 解锁回菜单态。
//   3. 上电四 SW 全关 => menu_active=1(首页菜单引导态, 停轮播)。
//   4. 内容源 latch_sw(3bit) = 素材分区号: 0菜单 1迎新 2会议 3抢答 4应急
//      —— 四场景 = 四个独立素材分区, 应急是独立第 4 分区;
//      分区号变化 → scene_change_pulse → 顶层重载素材分区。
// 参数   : DEB_MAX=100(消抖100拍) SEC_CNT_MAX=999(1s=1000拍)
//          SW_ACTIVE_LOW=1 => sw_raw[n]=0 表示 ON
//====================================================================

`timescale 1ns/1ps
module tb_scene_control;

    localparam CLK_PERIOD = 10;      // 100MHz -> 10ns

    reg         clk;
    reg         rst;                 // 高有效复位
    reg  [3:0]  sw_raw;              // sw_raw[0]=SW1 [1]=SW2 [2]=SW3 [3]=SW4

    wire        menu_active;         // 菜单态标志
    wire [2:0]  latch_sw;            // 内容源(0菜单 1迎新 2会议 3抢答 4应急)
    wire        emergency;
    wire [1:0]  scene_id;
    wire        slideshow_en;
    wire        scene_change_pulse;
    wire        emergency_pulse;
    wire        alarm_clr_pulse;
    wire        sec_tick;
    wire [7:0]  run_hh, run_mm, run_ss;

    integer     fail_cnt = 0;
    reg         change_p_seen;       // 事件捕获(单周期脉冲转电平便于断言)
    reg         emerg_p_seen;
    reg         clr_p_seen;

    scene_control #(
        .DEB_MAX     (21'd100),      // 消抖 100 拍
        .SEC_CNT_MAX (27'd999),      // 1s = 1000 拍
        .SW_ACTIVE_LOW(1'b1)         // sw_raw[n]=0 => ON(拉低)
    ) uut (
        .clk                (clk),
        .rst                (rst),
        .sw_raw             (sw_raw),
        .menu_active        (menu_active),
        .latch_sw           (latch_sw),
        .emergency          (emergency),
        .scene_id           (scene_id),
        .slideshow_en       (slideshow_en),
        .scene_change_pulse (scene_change_pulse),
        .emergency_pulse    (emergency_pulse),
        .alarm_clr_pulse    (alarm_clr_pulse),
        .sec_tick           (sec_tick),
        .run_hh             (run_hh),
        .run_mm             (run_mm),
        .run_ss             (run_ss)
    );

    // 事件捕获(单周期脉冲转电平)
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            change_p_seen <= 1'b0;
            emerg_p_seen  <= 1'b0;
            clr_p_seen    <= 1'b0;
        end
        else begin
            if (scene_change_pulse) change_p_seen <= 1'b1;
            if (emergency_pulse)    emerg_p_seen  <= 1'b1;
            if (alarm_clr_pulse)    clr_p_seen    <= 1'b1;
        end
    end

    task check(input cond, input [255:0] msg);
        begin
            if (cond) begin
                $display("t=%0t  [PASS] %0s", $time, msg);
            end
            else begin
                fail_cnt = fail_cnt + 1;
                $display("t=%0t  [FAIL] %0s  (menu=%0d scene=%0d latch=%0d emerg=%0d slide_en=%0b)",
                         $time, msg, menu_active, scene_id, latch_sw, emergency, slideshow_en);
            end
        end
    endtask

    task clear_flags;
        begin
            change_p_seen <= 1'b0;
            emerg_p_seen  <= 1'b0;
            clr_p_seen    <= 1'b0;
        end
    endtask

    task settle(input integer n);
        begin
            repeat (n) @(posedge clk);
        end
    endtask

    initial clk = 1'b0;
    always #(CLK_PERIOD/2) clk = ~clk;

    // 超时兜底
    initial begin
        #3000000;   // 3ms(仿真)
        $display("=== [TIMEOUT] 仿真超时提前结束,失败数=%0d ===", fail_cnt);
        $finish;
    end

    initial begin
        rst        = 1'b1;
        sw_raw     = 4'b1111;        // 全 OFF(ON=低)
        repeat (5) @(posedge clk);
        rst = 1'b0;
        repeat (20) @(posedge clk);

        //-------- 1. 上电默认 => 菜单态 --------
        check(menu_active == 1'b1 && ~emergency && ~slideshow_en &&
              scene_id == 2'd0 && latch_sw == 3'd0,
              "上电默认: 菜单态(无SW/停轮播/场景码0/内容源菜单0)");

        //-------- 1b. 运行时长 BCD 进位(1s=1000拍) --------
        wait (run_ss == 8'h01);
        check(run_ss == 8'h01 && run_mm == 8'h00 && run_hh == 8'h00,
              "00:00:01 -> 秒进位正确(BCD)");
        wait (run_mm == 8'h01 && run_ss == 8'h00);
        check(run_mm == 8'h01 && run_ss == 8'h00 && run_hh == 8'h00,
              "00:01:00 -> 分进位正确(BCD)");

        //=========================================================
        // 规则2: 第一个被触发的场景为准(先到先得, 不抢占)
        //=========================================================
        //-------- 2. 先拨 SW1 => 迎新 --------
        clear_flags;
        sw_raw[0] = 1'b0;            // SW1 ON(第一个触发)
        settle (250);
        check(scene_id == 2'd0 && menu_active == 1'b0 && latch_sw == 3'd1,
              "第一个触发=SW1 -> 迎新(场景0/内容源1), 退出菜单");
        check(change_p_seen, "菜单->迎新 scene_change_pulse 已产生");

        //-------- 3. 再拨 SW2 => 不抢占, 仍迎新 --------
        clear_flags;
        sw_raw[1] = 1'b0;            // SW2 ON(后触发)
        settle (250);
        check(scene_id == 2'd0 && latch_sw == 3'd1 && ~change_p_seen,
              "SW1 已持锁, 后拨 SW2 不抢占 -> 仍迎新(无分区重载脉冲)");

        //-------- 4. 再拨 SW3 => 仍不抢占 --------
        clear_flags;
        sw_raw[2] = 1'b0;            // SW3 ON(后触发)
        settle (250);
        check(scene_id == 2'd0 && latch_sw == 3'd1 && ~change_p_seen,
              "SW1 仍持锁, 后拨 SW3 不抢占 -> 仍迎新");

        //=========================================================
        // 规则1: 应急最高(SW4 电平直通, 与顺序无关)
        //=========================================================
        //-------- 5. SW4 ON => 立即应急(抢占所有普通场景) --------
        clear_flags;
        sw_raw[3] = 1'b0;            // SW4 ON
        settle (250);
        check(emergency == 1'b1 && scene_id == 2'd3,
              "SW1+SW2+SW3+SW4 -> 应急最高(场景3), 与触发顺序无关");
        check(slideshow_en == 1'b1 && menu_active == 1'b0,
              "应急中 -> 轮播使能(应急有独立第4分区素材), 非菜单态");
        check(emerg_p_seen, "进入应急 emergency_pulse 已产生");
        check(latch_sw == 3'd4, "应急内容源=4(独立第4素材分区)");
        check(change_p_seen, "迎新->应急 scene_change_pulse 已产生(分区重载)");

        //-------- 6. SW4 拨回 => 回到当时仍生效的锁定场景(SW1 迎新) --------
        clear_flags;
        sw_raw[3] = 1'b1;            // SW4 OFF
        settle (250);
        check(emergency == 1'b0 && scene_id == 2'd0 && latch_sw == 3'd1,
              "SW4 拨回 -> 回到锁定场景(SW1 迎新, 非拨码优先级最高者)");
        check(clr_p_seen, "退出应急 alarm_clr_pulse 已产生");
        check(change_p_seen, "应急->迎新 scene_change_pulse 已产生");

        //=========================================================
        // 持锁场景拨回 => 让给仍开着的其它场景(优先 SW1>SW2>SW3)
        //=========================================================
        //-------- 7. 关 SW1 => 让给 SW2(会议) --------
        clear_flags;
        sw_raw[0] = 1'b1;            // SW1 OFF
        settle (250);
        check(scene_id == 2'd1 && latch_sw == 3'd2 && change_p_seen,
              "持锁 SW1 拨回 -> 让给仍开着的 SW2 -> 会议(场景1)");

        //-------- 8. 关 SW2 => 让给 SW3(抢答) --------
        clear_flags;
        sw_raw[1] = 1'b1;            // SW2 OFF
        settle (250);
        check(scene_id == 2'd2 && latch_sw == 3'd3 && change_p_seen,
              "持锁 SW2 拨回 -> 让给仍开着的 SW3 -> 抢答(场景2)");

        //-------- 9. 关 SW3 => 全关, 回菜单 --------
        clear_flags;
        sw_raw[2] = 1'b1;            // SW3 OFF
        settle (250);
        check(menu_active == 1'b1 && latch_sw == 3'd0 && change_p_seen,
              "全 SW 拨回 -> 解锁回菜单态");

        //=========================================================
        // 新一轮: 先拨 SW3 再拨 SW1 => 仍以 SW3 为准(顺序决定, 非编号优先)
        //=========================================================
        clear_flags;
        sw_raw[2] = 1'b0;            // SW3 ON(先)
        settle (250);
        check(scene_id == 2'd2 && latch_sw == 3'd3 && change_p_seen,
              "新一轮: 先拨 SW3 -> 抢答(场景2)");
        clear_flags;
        sw_raw[0] = 1'b0;            // SW1 ON(后, 编号更小但不抢占)
        settle (250);
        check(scene_id == 2'd2 && ~change_p_seen,
              "SW3 已持锁, 后拨 SW1(编号更小)也不抢占 -> 仍抢答");
        clear_flags;
        sw_raw[2] = 1'b1;            // SW3 OFF -> 让给 SW1
        settle (250);
        check(scene_id == 2'd0 && latch_sw == 3'd1 && change_p_seen,
              "持锁 SW3 拨回 -> 让给 SW1 -> 迎新(场景0)");
        clear_flags;
        sw_raw[0] = 1'b1;            // 全关
        settle (250);
        check(menu_active == 1'b1 && change_p_seen, "全关 -> 回菜单");

        //=========================================================
        // 只有应急打开(无普通场景) => 应急; 拨回 => 直接回菜单
        //=========================================================
        clear_flags;
        sw_raw[3] = 1'b0;            // 仅 SW4 ON
        settle (250);
        check(emergency == 1'b1 && scene_id == 2'd3 && latch_sw == 3'd4 &&
              menu_active == 1'b0 && emerg_p_seen,
              "仅 SW4 -> 应急(场景3/内容源4), 非菜单态");
        clear_flags;
        sw_raw[3] = 1'b1;            // SW4 OFF
        settle (250);
        check(emergency == 1'b0 && menu_active == 1'b1 && clr_p_seen,
              "仅 SW4 拨回 -> 直接回菜单态");

        //-------- 收尾 --------
        settle (250);
        check(menu_active == 1'b1 && ~emergency && ~slideshow_en,
              "收尾: 菜单态稳定, 轮播停止(全屏菜单已覆盖底层)");

        $display("=== scene_control(应急最高+先触发先锁定) 仿真结束,失败数=%0d ===", fail_cnt);
        $finish;
    end

endmodule
