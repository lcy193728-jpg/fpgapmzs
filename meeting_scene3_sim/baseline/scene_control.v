//====================================================================
// 模块名 : scene_control.v（含内部 key_debounce 子模块）
// 功能   : 校园多功能 FPGA 终端 —— 场景选择/应急仲裁(2026-09-16 先触发优先版)
//
// 场景源: 板载拨码 SW1~SW4(SW1=迎新 SW2=会议 SW3=抢答 SW4=应急)。
//   拨码为静态电平, 本模块做两级同步 + 10ms 消抖。
//   ※ 场景完全由 SW 决定; KEY1~KEY4 属于场景内的功能调节(见 ui_key_ctrl),
//     与场景切换无关, 不会进入/退出场景, 也不触发应急。
//   上电四个 SW 全关 => menu_active=1(首页菜单引导态, 等拨码)。
//
// 仲裁规则(用户定稿, 覆盖旧的"SW4>SW3>SW2>SW1 静态优先级"):
//   规则1【应急最高, 与顺序无关】SW4 一打开立即进应急(电平直通, 拨回即解),
//         无论之前锁定了哪个普通场景; 应急期间普通场景的拨动只更新"锁定
//         权"不改变显示, 退出应急即回到当时仍生效的锁定场景。
//   规则2【无应急时 = 第一个被触发的场景为准】SW1/SW2/SW3 中**先被拨上**
//         的那个场景锁定生效; 之后拨上来的其它场景**不抢占**(先到先得);
//         持锁场景被拨回时, 若有其它场景仍开着则让给其中优先者
//         (SW1>SW2>SW3), 都关了则回菜单态等下一次触发。
//   规则3【同拍多路】同一采样周期内多路同时拨上, 按硬件优先级
//         SW1>SW2>SW3 仲裁(需在报告/说明中注明这一硬件仲裁规则)。
//
// 应急语义(2026-09-16 四分区改造):
//   SW4 打开 => emergency=1:
//     · 最高优先级, 立即叠加应急内容(顶层 OSD);
//     · **内容源切到独立第 4 分区**(latch_sw=4=应急素材区), 与其它场景一样
//       从 TF 卡对应区域轮播告警素材, 不再冻结上一场景的画面;
//     · 四场景 = 四个独立素材分区(迎新/会议/抢答/应急), 一卡多区互不串扰。
//   SW4 拨回 即自动解除, 无需清除键, 内容源自动回到拨码所选场景分区。
//
// 输出：
//   menu_active    菜单态标志(1=显示首页菜单; 上电默认)
//   latch_sw       内容源/素材分区号(0=菜单 1=迎新 2=会议 3=抢答 4=应急);
//                  顶层按此查表做素材分区解码(菜单态=Z_MENU)
//   emergency      应急中(寄存器输出, 供 OSD/淡入淡出同步)
//   scene_id       生效场景号 0迎新 1会议 2抢答 3应急(数码管第1位显示)
//   slideshow_en   底层轮播使能(菜单态=0: 全屏菜单已覆盖底层, 停轮播省 SD 功耗;
//                  四个场景(含应急)=1 各自分区轮播)
//   scene_change_pulse  内容源切换(菜单↔场景/场景间)单周期脉冲 → bmp 分区重载
//   emergency_pulse/alarm_clr_pulse 进入/退出应急事件
//   运行时长 BCD 时:分:秒(自复位起), 供后续 OSD
//
// 时钟域 : 统一 sd_card_clk(100MHz)
// 极性   : SW_ACTIVE_LOW=1 表示拨码 ON=拉低有效(上拉, 与板载按键同);
//          若实测拨码 ON=拉高, 将此参数置 0 即可整体翻转, 无需改逻辑
//====================================================================

`timescale 1ns/1ps

module scene_control #(
    parameter [20:0] DEB_MAX      = 21'd1_000_000, // 消抖时间=10ms@100MHz(周期数-1)
    parameter [26:0] SEC_CNT_MAX  = 27'd99_999_999,// 1秒=100_000_000周期(100MHz)
    parameter        SW_ACTIVE_LOW = 1'b1          // 1=拨码 ON 时输入为低(上拉)
)(
    input               clk,            // 控制时钟(100MHz = sd_card_clk)
    input               rst,            // 高有效复位(由 rst_n 取反)
    // ---- 拨码输入(原始电平) ----
    // sw_raw[0]=SW1(场景0迎新) sw_raw[1]=SW2(场景1会议)
    // sw_raw[2]=SW3(场景2抢答) sw_raw[3]=SW4(场景3应急)
    input       [3:0]   sw_raw,
    // ---- 输出 ----
    output              menu_active,    // 1=菜单态(四个 SW 全关; 上电默认)
    output reg  [2:0]   latch_sw,       // 内容源/素材分区: 0菜单 1迎新 2会议 3抢答 4应急
    output reg          emergency,      // 1=应急中(场景号=3, 离开即解除)
    output reg  [1:0]   scene_id,       // 生效场景号 0..3(数码管第1位)
    output              slideshow_en,   // 底层轮播使能(菜单态=0; 四场景均=1)
    output reg          scene_change_pulse, // 内容源切换事件(单周期脉冲)
    output reg          emergency_pulse,    // 进入应急事件(单周期脉冲)
    output reg          alarm_clr_pulse,    // 退出应急事件(单周期脉冲)
    // ---- 系统运行时长(BCD) ----
    output              sec_tick,       // 1Hz 单周期脉冲
    output      [7:0]   run_hh,         // 时(BCD)
    output      [7:0]   run_mm,         // 分(BCD)
    output      [7:0]   run_ss          // 秒(BCD)
);

    //--------------------------------------------------------------
    // 场景号 localparam(与 top.v / ui_key_ctrl 保持一致)
    //--------------------------------------------------------------
    localparam [1:0] SCENE_WELCOME = 2'd0;  // 迎新
    localparam [1:0] SCENE_MEETING = 2'd1;  // 会议
    localparam [1:0] SCENE_QUIZ    = 2'd2;  // 抢答
    localparam [1:0] SCENE_ALARM   = 2'd3;  // 应急(最高优先级)

    // 内容源/素材分区号(3bit: 0菜单 1迎新 2会议 3抢答 4应急)
    localparam [2:0] SRC_MENU  = 3'd0;
    localparam [2:0] SRC_WEL   = 3'd1;
    localparam [2:0] SRC_MEET  = 3'd2;
    localparam [2:0] SRC_QUIZ  = 3'd3;
    localparam [2:0] SRC_ALARM = 3'd4;

    // 场景锁定源(2bit: 0=无(菜单) 1=SW1迎新 2=SW2会议 3=SW3抢答)
    //   ※ "先触发先锁定"用, 与场景号 0/1/2 一一对应但不是同一编码空间
    localparam [1:0] LK_NONE = 2'd0;
    localparam [1:0] LK_SW1  = 2'd1;
    localparam [1:0] LK_SW2  = 2'd2;
    localparam [1:0] LK_SW3  = 2'd3;

    //--------------------------------------------------------------
    // 内部信号
    //--------------------------------------------------------------
    wire        sw1_ls, sw2_ls, sw3_ls, sw4_ls;   // 去抖后"稳定低"指示
    wire        sw1_on, sw2_on, sw3_on, sw4_on;   // 极性校正后"ON 有效"电平
    reg  [1:0]  lock_scene;                        // 锁定场景源: 0=无 1=SW1 2=SW2 3=SW3
    reg  [2:0]  sw_on_d;                           // 上一拍 SW1~SW3 开关(触发沿检测)
    wire [1:0]  sel_scene;                         // 无应急时生效场景号
    wire [1:0]  scene_sel;                         // 最终生效场景号(应急优先)
    wire        scene_valid;                       // 1=有普通场景锁定
    wire        emerg_now;                         // 组合应急即时判定(SW4 电平)
    reg  [2:0]  latch_sw_d;                        // 上一拍内容源(边沿检测)
    reg         emergency_d;                       // 上一拍应急标志
    reg  [3:0]  ss0, ss1;                          // 秒 BCD 个/十位
    reg  [3:0]  mm0, mm1;                          // 分 BCD 个/十位
    reg  [3:0]  hh0, hh1;                          // 时 BCD 个/十位
    reg  [26:0] sec_cnt;                           // 1Hz 计数

    //--------------------------------------------------------------
    // 拨码消抖 ×4(两级同步+10ms 计数; 拨码虽为静态电平仍防手拨毛刺)
    //--------------------------------------------------------------
    key_debounce #(.DEB_MAX(DEB_MAX)) u_sw1_dbnc (
        .clk            (clk),
        .rst            (rst),
        .key_raw        (sw_raw[0]),
        .key_low_stable (sw1_ls),
        .negedge_pulse  ()
    );
    key_debounce #(.DEB_MAX(DEB_MAX)) u_sw2_dbnc (
        .clk            (clk),
        .rst            (rst),
        .key_raw        (sw_raw[1]),
        .key_low_stable (sw2_ls),
        .negedge_pulse  ()
    );
    key_debounce #(.DEB_MAX(DEB_MAX)) u_sw3_dbnc (
        .clk            (clk),
        .rst            (rst),
        .key_raw        (sw_raw[2]),
        .key_low_stable (sw3_ls),
        .negedge_pulse  ()
    );
    key_debounce #(.DEB_MAX(DEB_MAX)) u_sw4_dbnc (
        .clk            (clk),
        .rst            (rst),
        .key_raw        (sw_raw[3]),
        .key_low_stable (sw4_ls),
        .negedge_pulse  ()
    );

    //--------------------------------------------------------------
    // 极性校正: key_low_stable=1 表示稳定低; 根据 SW_ACTIVE_LOW 翻转
    //--------------------------------------------------------------
    assign sw1_on = (SW_ACTIVE_LOW == 1'b1) ? sw1_ls : ~sw1_ls;
    assign sw2_on = (SW_ACTIVE_LOW == 1'b1) ? sw2_ls : ~sw2_ls;
    assign sw3_on = (SW_ACTIVE_LOW == 1'b1) ? sw3_ls : ~sw3_ls;
    assign sw4_on = (SW_ACTIVE_LOW == 1'b1) ? sw4_ls : ~sw4_ls;

    //--------------------------------------------------------------
    // 场景锁定: "第一个被触发的场景为准"(先到先得), 见文件头规则 2/3
    //   · 触发 = 该 SW 由关变开(消抖后电平的上升沿)
    //   · lock_scene: 0=无(菜单) 1=SW1(迎新) 2=SW2(会议) 3=SW3(抢答)
    //   · 已锁定后被拨上的其它普通场景一律忽略(不抢占)
    //   · 持锁场景被拨回 → 让给仍开着的其它场景(优先 SW1>SW2>SW3)
    //   · 三路全关 → 解锁回菜单态, 等待下一次触发
    //   · 上电/复位时若 SW 已经拨上(错过上升沿), 直接按优先级补锁
    //--------------------------------------------------------------
    wire t1 = sw1_on & ~sw_on_d[0];      // SW1 触发沿
    wire t2 = sw2_on & ~sw_on_d[1];      // SW2 触发沿
    wire t3 = sw3_on & ~sw_on_d[2];      // SW3 触发沿

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            lock_scene <= LK_NONE;
            sw_on_d    <= 3'b000;
        end
        else begin
            sw_on_d <= {sw3_on, sw2_on, sw1_on};

            if (!sw1_on && !sw2_on && !sw3_on) begin
                lock_scene <= LK_NONE;                       // 三个全关 → 解锁
            end
            else if (lock_scene == LK_NONE) begin
                // 无锁: 取第一个被触发的(同拍多路按 SW1>SW2>SW3 硬件仲裁)
                if      (t1) lock_scene <= LK_SW1;
                else if (t2) lock_scene <= LK_SW2;
                else if (t3) lock_scene <= LK_SW3;
                else if (sw1_on) lock_scene <= LK_SW1;       // 上电已拨上(无沿可等)
                else if (sw2_on) lock_scene <= LK_SW2;
                else             lock_scene <= LK_SW3;
            end
            else begin
                // 持锁场景拨回 → 让给仍开着的其它场景(优先 SW1>SW2>SW3)
                case (lock_scene)
                    LK_SW1: if (!sw1_on) lock_scene <= sw2_on ? LK_SW2 : (sw3_on ? LK_SW3 : LK_NONE);
                    LK_SW2: if (!sw2_on) lock_scene <= sw1_on ? LK_SW1 : (sw3_on ? LK_SW3 : LK_NONE);
                    LK_SW3: if (!sw3_on) lock_scene <= sw1_on ? LK_SW1 : (sw2_on ? LK_SW2 : LK_NONE);
                    default: lock_scene <= LK_NONE;
                endcase
            end
        end
    end

    // 锁定场景源 → 场景号
    assign sel_scene   = (lock_scene == LK_SW1) ? SCENE_WELCOME :
                         (lock_scene == LK_SW2) ? SCENE_MEETING :
                         (lock_scene == LK_SW3) ? SCENE_QUIZ    : SCENE_WELCOME;
    assign scene_valid = (lock_scene != LK_NONE);

    // 生效场景号: 应急(SW4)电平直通优先, 否则取锁定场景(无锁时名义迎新)
    assign scene_sel = emerg_now ? SCENE_ALARM : sel_scene;
    assign emerg_now = sw4_on;

    //--------------------------------------------------------------
    // 菜单态: 无任何普通场景锁定(SW1~SW3 全关) 且非应急
    //   (上电默认=菜单; 拨上任一普通 SW 即退出并进对应场景)
    //--------------------------------------------------------------
    assign menu_active = ~scene_valid & ~emerg_now;

    //--------------------------------------------------------------
    // 应急锁存(寄存器输出供下游同步): 场景号=3 即应急, 离开即解除
    //--------------------------------------------------------------
    always @(posedge clk or posedge rst) begin
        if (rst)
            emergency <= 1'b0;
        else
            emergency <= emerg_now;
    end

    //--------------------------------------------------------------
    // 内容源 latch_sw(供顶层素材分区解码):
    //   0菜单 / 1迎新 / 2会议 / 3抢答 / 4应急
    //   · 菜单态(四 SW 全关) = 0
    //   · 应急(SW4) = 4 → 独立第 4 素材分区(应急告警素材轮播)
    //   · 其余 = 拨码所选场景 → 1/2/3
    //   任意变化都会产生 scene_change_pulse → 顶层 zone_load 重载分区
    //--------------------------------------------------------------
    always @(posedge clk or posedge rst) begin
        if (rst)
            latch_sw <= SRC_MENU;
        else if (menu_active)
            latch_sw <= SRC_MENU;                 // 菜单
        else if (emerg_now)
            latch_sw <= SRC_ALARM;                // 应急: 独立第 4 分区
        else begin
            case (scene_sel)
                SCENE_MEETING: latch_sw <= SRC_MEET;
                SCENE_QUIZ:    latch_sw <= SRC_QUIZ;
                default:       latch_sw <= SRC_WEL;
            endcase
        end
    end

    //--------------------------------------------------------------
    // 生效场景号输出(0..3, 数码管第1位显示)
    //--------------------------------------------------------------
    always @(posedge clk or posedge rst) begin
        if (rst)
            scene_id <= SCENE_WELCOME;
        else
            scene_id <= scene_sel;
    end

    //--------------------------------------------------------------
    // 底层轮播使能: 菜单态=0(全屏菜单已完全覆盖底层, 停轮播省 SD 功耗);
    //   四个场景(迎新/会议/抢答/应急)=1 各自分区轮播。
    //   ※ 应急不再冻结画面: 它有自己的第 4 分区素材, 与其它场景同等轮播。
    //--------------------------------------------------------------
    assign slideshow_en = ~menu_active;

    //--------------------------------------------------------------
    // 事件脉冲:
    //   scene_change_pulse = latch_sw 变化(菜单↔场景/场景间切换)
    //                        → 驱动 bmp 分区 restart 重载素材
    //   emergency_pulse / alarm_clr_pulse = 进入/退出应急沿
    //--------------------------------------------------------------
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            latch_sw_d         <= SRC_MENU;
            scene_change_pulse <= 1'b0;
        end
        else begin
            latch_sw_d         <= latch_sw;
            scene_change_pulse <= (latch_sw_d != latch_sw);
        end
    end

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            emergency_d      <= 1'b0;
            emergency_pulse  <= 1'b0;
            alarm_clr_pulse  <= 1'b0;
        end
        else begin
            emergency_d     <= emergency;
            emergency_pulse <= ~emergency_d &  emergency;  // 进入应急
            alarm_clr_pulse <=  emergency_d & ~emergency;  // 退出应急
        end
    end

    //--------------------------------------------------------------
    // 系统运行时长(BCD 时:分:秒), 自复位起计, 1Hz 更新
    //--------------------------------------------------------------
    always @(posedge clk or posedge rst) begin
        if (rst)
            sec_cnt <= 27'd0;
        else if (sec_cnt >= SEC_CNT_MAX)
            sec_cnt <= 27'd0;
        else
            sec_cnt <= sec_cnt + 27'd1;
    end
    assign sec_tick = (sec_cnt == SEC_CNT_MAX);

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            {ss0, ss1, mm0, mm1, hh0, hh1} <= 24'd0;
        end
        else if (sec_tick) begin
            // ---- 秒 ----
            if (ss0 == 4'd9) begin
                ss0 <= 4'd0;
                if (ss1 == 4'd5) begin
                    ss1 <= 4'd0;
                    // ---- 分 ----
                    if (mm0 == 4'd9) begin
                        mm0 <= 4'd0;
                        if (mm1 == 4'd5) begin
                            mm1 <= 4'd0;
                            // ---- 时(00~99) ----
                            if (hh0 == 4'd9) begin
                                hh0 <= 4'd0;
                                if (hh1 == 4'd9)
                                    hh1 <= 4'd0;   // 100 小时清零
                                else
                                    hh1 <= hh1 + 4'd1;
                            end
                            else
                                hh0 <= hh0 + 4'd1;
                        end
                        else
                            mm1 <= mm1 + 4'd1;
                    end
                    else
                        mm0 <= mm0 + 4'd1;
                end
                else
                    ss1 <= ss1 + 4'd1;
            end
            else
                ss0 <= ss0 + 4'd1;
        end
    end

    assign run_hh = {hh1, hh0};
    assign run_mm = {mm1, mm0};
    assign run_ss = {ss1, ss0};

endmodule


//====================================================================
// 子模块 : key_debounce.v —— 机械开关两级同步 + 计数器消抖
// 输入原始电平, 输出消抖后"稳定低"指示 + 按下(低有效)下降沿脉冲
//
// 消抖算法(2026-09-16 重修, 与 ui_key_dbnc 同法):
//   把"消抖后电平"(key_level)当作唯一基准 —— 输入(key_sync[1])只要与
//   基准一致就把计数器清零; 一旦偏离且**连续 DEB_MAX 拍(10ms)都不回来**
//   才采纳新电平。这样:
//     · 抖动(<10ms 的来回跳变)会被不断清零, 不会误触发;
//     · 只要按键/拨码的稳定段 ≥10ms 就一定被采纳 —— 旧版"20ms + 抖动
//       期间清零"会让快速点按(稳定段不足 20ms)整段丢失 = 偶发失灵。
//====================================================================
module key_debounce #(
    parameter [20:0] DEB_MAX = 21'd1_000_000   // 10ms@100MHz
)(
    input               clk,
    input               rst,            // 高有效复位
    input               key_raw,        // 输入原始电平(上拉高、ON拉低)
    output reg          key_low_stable, // 1=消抖后确认低电平(拨码 ON / 按键按下)
    output reg          negedge_pulse   // 稳定电平下降沿(单周期脉冲)
);

    reg [20:0]  sync_cnt;   // 消抖计数器
    reg [1:0]   key_sync;   // 两级同步器(防亚稳态)
    reg         key_level;  // 消抖后电平(1=高/释放)
    reg         key_d;      // 延迟一拍(边沿检测)

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            sync_cnt       <= 21'd0;
            key_sync       <= 2'b11;     // 释放(高)
            key_level      <= 1'b1;      // 稳定电平初值=高
            key_d          <= 1'b1;
            key_low_stable <= 1'b0;
            negedge_pulse  <= 1'b0;
        end
        else begin
            key_sync <= {key_sync[0], key_raw};      // 两级同步

            if (key_sync[1] == key_level) begin
                sync_cnt <= 21'd0;                   // 与基准一致 → 清零
            end
            else if (sync_cnt == DEB_MAX) begin
                key_level <= key_sync[1];            // 连续 10ms 偏离 → 采纳
                sync_cnt  <= 21'd0;
            end
            else
                sync_cnt <= sync_cnt + 21'd1;

            key_d          <= key_level;
            negedge_pulse  <= key_d & ~key_level;    // 下降沿: 稳定高→稳定低
            key_low_stable <= ~key_level;            // 低电平稳定指示
        end
    end

endmodule
