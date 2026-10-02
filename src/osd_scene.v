//====================================================================
// 模块名 : osd_scene.v —— 会议 / 抢答 / 应急 三场景 OSD 叠加引擎
// 来源   : 移植 dev_sim 分支 meeting_scene2 / quiz / emergency 三组仿真
//          Overlay(色块占位版) → 按本项目决策改用**真汉字字库**
//          (tools/gen_osd_font.py 生成, 与 osd_menu/osd_welcome 同库)。
//
// 三场景互斥(SW 单选), 故合并为单模块共用一片字形 ROM, 省资源/低功耗:
//   · 会议(meeting_en): 顶部金线大标题条「校园会议信息公示」+
//     右上"已运行 HH:MM:SS"运行时长面板(BRD 数字 + RTL 画冒号)+
//     中部公告面板(4 页公告文字, 每 PAGE_FRAMES 帧自动翻页,
//     金色页码数字 1~4)+ 底部滚动会务提示。
//   · 抢答(quiz_en)  : 顶部标题条「抢答进行中」+ 中部状态面板
//     (等待开始 / 抢答中 / 选手N号抢答成功 / 时间到无人抢答, 随
//      quiz_ctrl.qstate 切换)+ 2× 倒计时数字与「秒」+ 底部滚动抢答须知。
//   · 应急(alarm_en) : 顶部 52 行**闪烁**红条(4Hz)+ 红条内警示三角图标
//     (RTL 绘制)+ 深红衬底标题「紧急情况 请立即疏散」+ 底部滚动疏散告警。
//     (按项目决策: 只做画面告警, 不加蜂鸣器/LED 声光)
//   OSD 区域以外像素**原样透传**; 三个使能全 0 时本模块纯透传。
//
// 数据管线(与 osd_menu / osd_welcome 同构):
//   {sync,data,px} 输入视为已对齐 → 三级移位寄存器统一延迟 3 拍;
//   A 级(px2/py2)按行窗分类并发 ROM 读请求(同步读晚 addr 一拍)
//   → q 与 px3/da3 对齐; B 级(px3/py3)判墨点 + 分区仲裁输出。
//   2× 放大在 RTL 端复制行列(ROM 只存 16×16 原字模);
//   滚动带按 (px+phase) 对带宽周期取模, phase 每帧 vsync 沿 +1。
//
// 几何/文案唯一数据源 = tools/gen_osd_font.py(改文案须两处同步并重跑
//   生成, 再跑 tb_osd_scene.v 像素级回归)。
// 时钟域 : 本模块 video_clk(≈25.175MHz); 各使能与 qstate/winner/
//   t_tens/t_ones/run_* 来自 sd_card_clk(100MHz) 域, 内部两级同步。
// 语言   : 纯 Verilog-2001(兼容 TD EDA 前台与 ModelSim)。
//====================================================================

`timescale 1ns/1ps

module osd_scene #(
    parameter DATA_W     = 24,               // 像素位宽(RGB888)
    parameter H_ACT      = 640,              // 有效宽
    parameter V_ACT      = 480,              // 有效高
    parameter [21:0] BLINK_DIV   = 22'd3_146_875,  // 125ms@25.175MHz(4Hz 闪烁)
    parameter [11:0] PAGE_FRAMES = 12'd480         // 会议公告翻页周期(帧)
)(
    input                video_clk,          // 像素时钟(≈25.175MHz)
    input                rst,                // 高有效复位
    // ---- 输入: 上游 OSD(osd_welcome)输出(已对齐) ----
    input                hs_i, vs_i, de_i,
    input  [DATA_W-1:0]  data_i,
    input  [11:0]        px_x,               // 与 data_i 同拍 x(0 基)
    input  [11:0]        px_y,               // 与 data_i 同拍 y(0 基)
    // ---- 场景使能(sd 域组合电平, 模块内两级同步) ----
    input                meeting_en,         // 1=会议场景
    input                quiz_en,            // 1=抢答场景
    input                alarm_en,           // 1=应急中
    // ---- 抢答状态(quiz_ctrl 输出, sd 域) ----
    input        [1:0]   qstate,             // 0等待开始 1抢答中 2已锁定 3超时
    input        [1:0]   winner,             // 胜者 0..3(屏显 +1)
    input        [3:0]   t_tens,             // 剩余秒 BCD 十位
    input        [3:0]   t_ones,             // 剩余秒 BCD 个位
    // ---- 系统运行时长(BCD, sd 域) ----
    input        [7:0]   run_hh,
    input        [7:0]   run_mm,
    input        [7:0]   run_ss,
    // ---- 共享字形 ROM 接口(top 层统一例化一片, 三路 OSD 互斥使用) ----
    input  [31:0]        rom_q,              // ROM 读数据(晚 rom_addr_o 一拍)
    output               rom_en_o,           // ROM 读使能(本模块当拍读请求)
    output [12:0]        rom_addr_o,         // ROM 读地址
    // ---- 输出: 送 display_adjust ----
    output               hs_o, vs_o, de_o,
    output [DATA_W-1:0]  data_o,
    output [11:0]        px_x_o,
    output [11:0]        px_y_o
);

    //--------------------------------------------------------------
    // 颜色定义
    //--------------------------------------------------------------
    localparam [DATA_W-1:0] C_MT_TITLE = 24'hFF_D2_4A;  // 会议大标题(金)
    localparam [DATA_W-1:0] C_MT_RUN   = 24'h9D_CB_F2;  // "已运行"标签(浅钢蓝)
    localparam [DATA_W-1:0] C_MT_DIG   = 24'hFF_D2_4A;  // 数字(金)
    localparam [DATA_W-1:0] C_MT_ANN   = 24'hF5_FD_FF;  // 公告文字(近白)
    localparam [DATA_W-1:0] C_MT_FOOT  = 24'hFF_7A_1F;  // 底部滚动字(橙)
    localparam [DATA_W-1:0] C_QZ_TITLE = 24'hFF_D2_4A;  // 抢答标题(金)
    localparam [DATA_W-1:0] C_QZ_TXT   = 24'hF5_FD_FF;  // 抢答状态字(近白)
    localparam [DATA_W-1:0] C_QZ_DIG   = 24'hFF_D2_4A;  // 倒计时/胜者号(金)
    localparam [DATA_W-1:0] C_QZ_FOOT  = 24'hFF_7A_1F;  // 底部滚动字(橙)
    localparam [DATA_W-1:0] C_AL_BAR_A = 24'hFF_2A_2A;  // 应急红条(亮相)
    localparam [DATA_W-1:0] C_AL_BAR_B = 24'h8A_00_00;  // 应急红条(暗相)
    localparam [DATA_W-1:0] C_AL_ICO   = 24'hFF_D2_4A;  // 警示三角(黄)
    localparam [DATA_W-1:0] C_AL_TITLE = 24'hF5_FD_FF;  // 应急标题(近白)
    localparam [DATA_W-1:0] C_AL_FOOT  = 24'hFF_D2_4A;  // 底部滚动字(金)

    localparam [DATA_W-1:0] C_NAVY   = 24'h0A_26_47;    // 衬底藏蓝
    localparam [DATA_W-1:0] C_ALRED  = 24'h8A_00_00;    // 应急深红衬底

    //--------------------------------------------------------------
    // 几何常量(唯一数据源 tools/gen_osd_font.py, 勿单独改动)
    //   ★V3 字库: 2× 带存 32×32 真字模(1:1 显示, 物理尺寸/几何全不变);
    //     1× 带存 16×16 字模。ROM 位宽 32bit, 深度 5856; 取位 2× 用
    //     rom_q[31-...], 1× 用 rom_q[15-...]。
    //   会议: 标题2×(ty14,gx192,N8,base2512) / 公告1×(ty196,gx240,N10,
    //         base 2768+page*160) / 运行标签1×(ty76,gx396,N3,base3408)
    //         运行数字1×(NUM) / 页码1×(NUM) / 滚动(ty452,N20,base3456,周期320)
    //   抢答: 标题2×(ty20,gx240,N5,base3776) / 状态2×(ty96,base见下)
    //         / 倒计时数字2×(NUM) / 秒2×(ty180,gx336,base4640)
    //         / 滚动(ty452,N20,base4672,周期320)
    //   应急: 标题2×(ty82,gx160,N10,base4992) / 滚动(ty452,N24,base5312,周期384)
    //--------------------------------------------------------------
    localparam [12:0] NUM_BASE = 13'd5696;      // 数字带(N10, 1× 字模)

    localparam [11:0] MT_TY = 12'd14,  MT_GX = 12'd192;   // 会议大标题(2×)
    localparam [11:0] MR_TY = 12'd76,  MR_GX = 12'd396;   // "已运行"(1×,N3)
    localparam [11:0] MA_TY = 12'd196, MA_GX = 12'd240;   // 公告文字(1×,N10)
    localparam [12:0] MA_B0 = 13'd2768, MA_PG = 13'd160;  // 公告 4 页 base/步进
    localparam [11:0] MP_GX = 12'd424;                    // 页码数字 x(1×)
    localparam [12:0] MF_BASE = 13'd3456;                 // 会议滚动(1×,N20)

    localparam [11:0] QT_TY = 12'd20,  QT_GX = 12'd240;   // 抢答标题(2×,N5)
    localparam [11:0] QS_TY = 12'd96;                     // 状态行 ty(2×)
    localparam [12:0] QW_BASE = 13'd3936;                 // 等待开始(N4)
    localparam [12:0] QR_BASE = 13'd4064;                 // 抢答中(N3)
    localparam [12:0] QL_BASE = 13'd4160;                 // 选手(N2)
    localparam [12:0] QX_BASE = 13'd4224;                 // 号抢答成功(N5)
    localparam [12:0] QN_BASE = 13'd4384;                 // 时间到无人抢答(N8)
    localparam [11:0] QC_TY = 12'd180;                    // 倒计时行 ty(2×)
    localparam [12:0] QSEC_BASE = 13'd4640;               // "秒"(N1,2×)
    localparam [12:0] QF_BASE = 13'd4672;                 // 抢答滚动(1×,N20)

    localparam [11:0] AT_TY = 12'd82,  AT_GX = 12'd160;   // 应急标题(2×,N10)
    localparam [12:0] AF_BASE = 13'd5312;                 // 应急滚动(1×,N24)
    localparam [11:0] AL_BAR_ROWS = 12'd52;               // 顶部红条行数
    localparam [11:0] AL_TBY0 = 12'd74, AL_TBY1 = 12'd122;// 应急标题衬底带行窗
    localparam [11:0] AL_TBX0 = 12'd140, AL_TBX1 = 12'd500;
    localparam [11:0] FOOT_Y0 = 12'd438, FOOT_Y1 = 12'd480; // 底部暗带行窗
    localparam [11:0] BAND_Y0 = 12'd8,   BAND_Y1 = 12'd52;  // 会议标题衬底带

    //--------------------------------------------------------------
    // 场景使能 / 抢答状态 / 运行时长 过域(各两级同步)
    //   注: 这些量在 sd 域均为"慢变"(按键/1Hz 更新), 两级同步足够;
    //       数字为显示用途, 极端采样瞬间最多出现 1 帧非单调值。
    //--------------------------------------------------------------
    reg mt_s0, qz_s0, al_s0, mt_s1, qz_s1, al_s1;
    reg [1:0] qs_s0, qs_s1;
    reg [1:0] wn_s0, wn_s1;
    reg [3:0] tt_s0, tt_s1, to_s0, to_s1;
    reg [7:0] hh_s0, hh_s1, mm_s0, mm_s1, ss_s0, ss_s1;

    always @(posedge video_clk or posedge rst) begin
        if (rst) begin
            mt_s0 <= 1'b0; qz_s0 <= 1'b0; al_s0 <= 1'b0;
            mt_s1 <= 1'b0; qz_s1 <= 1'b0; al_s1 <= 1'b0;
            qs_s0 <= 2'd0; qs_s1 <= 2'd0;
            wn_s0 <= 2'd0; wn_s1 <= 2'd0;
            tt_s0 <= 4'd0; tt_s1 <= 4'd0; to_s0 <= 4'd0; to_s1 <= 4'd0;
            hh_s0 <= 8'd0; hh_s1 <= 8'd0;
            mm_s0 <= 8'd0; mm_s1 <= 8'd0;
            ss_s0 <= 8'd0; ss_s1 <= 8'd0;
        end
        else begin
            mt_s0 <= meeting_en; qz_s0 <= quiz_en;    al_s0 <= alarm_en;
            mt_s1 <= mt_s0;      qz_s1 <= qz_s0;     al_s1 <= al_s0;
            qs_s0 <= qstate;     qs_s1 <= qs_s0;
            wn_s0 <= winner;     wn_s1 <= wn_s0;
            tt_s0 <= t_tens;     tt_s1 <= tt_s0;
            to_s0 <= t_ones;     to_s1 <= to_s0;
            hh_s0 <= run_hh;     hh_s1 <= hh_s0;
            mm_s0 <= run_mm;     mm_s1 <= mm_s0;
            ss_s0 <= run_ss;     ss_s1 <= ss_s0;
        end
    end

    wire        mt_ok = mt_s1, qz_ok = qz_s1, al_ok = al_s1;
    wire [1:0]  qstate_s = qs_s1;
    wire [1:0]  winner_s = wn_s1;
    wire [3:0]  t_tens_s = tt_s1, t_ones_s = to_s1;
    wire [7:0]  hh_s = hh_s1, mm_s = mm_s1, ss_s = ss_s1;

    //--------------------------------------------------------------
    // 4Hz 闪烁基准(应急红条; 复位后为暗相)
    //--------------------------------------------------------------
    reg [21:0] bcnt;
    reg        blink;
    always @(posedge video_clk or posedge rst) begin
        if (rst) begin
            bcnt  <= 22'd0;
            blink <= 1'b0;
        end
        else if (bcnt >= (BLINK_DIV - 22'd1)) begin
            bcnt  <= 22'd0;
            blink <= ~blink;
        end
        else
            bcnt <= bcnt + 22'd1;
    end

    //--------------------------------------------------------------
    // 滚动相位(每帧 vsync 上升沿 +1; 按当前场景带宽周期回卷,
    //   会议/抢答周期 320px, 应急周期 384px)
    //--------------------------------------------------------------
    reg        vsd;
    reg [9:0]  phase;
    wire       vs_rise = vs_i & ~vsd;
    wire [11:0] act_per = al_ok ? 12'd384 : 12'd320;

    always @(posedge video_clk or posedge rst) begin
        if (rst) begin
            vsd   <= 1'b0;
            phase <= 10'd0;
        end
        else begin
            vsd <= vs_i;
            if (vs_rise) begin
                if (phase >= (act_per[9:0] - 10'd1))
                    phase <= 10'd0;
                else
                    phase <= phase + 10'd1;
            end
        end
    end

    //--------------------------------------------------------------
    // 会议公告页码(每 PAGE_FRAMES 帧 +1, 0..3; 仅会议场景计数)
    //--------------------------------------------------------------
    reg [11:0] pfcnt;
    reg [1:0]  page;
    always @(posedge video_clk or posedge rst) begin
        if (rst) begin
            pfcnt <= 12'd0;
            page  <= 2'd0;
        end
        else if (!mt_ok) begin
            pfcnt <= 12'd0;
            page  <= 2'd0;
        end
        else if (vs_rise) begin
            if (pfcnt >= (PAGE_FRAMES - 12'd1)) begin
                pfcnt <= 12'd0;
                page  <= (page == 2'd3) ? 2'd0 : (page + 2'd1);
            end
            else
                pfcnt <= pfcnt + 12'd1;
        end
    end

    //--------------------------------------------------------------
    // 三级移位管线(输入 → da3/px3/sync3 恒定延迟 3 拍)
    //--------------------------------------------------------------
    reg hs1, vs1, de1, hs2, vs2, de2, hs3, vs3, de3;
    reg [DATA_W-1:0] da1, da2, da3;
    reg [11:0] px1, py1, px2, py2, px3, py3;

    always @(posedge video_clk or posedge rst) begin
        if (rst) begin
            hs1<=1'b0; vs1<=1'b0; de1<=1'b0;
            hs2<=1'b0; vs2<=1'b0; de2<=1'b0;
            hs3<=1'b0; vs3<=1'b0; de3<=1'b0;
            da1<={DATA_W{1'b0}}; da2<={DATA_W{1'b0}}; da3<={DATA_W{1'b0}};
            px1<=12'd0; py1<=12'd0; px2<=12'd0; py2<=12'd0;
            px3<=12'd0; py3<=12'd0;
        end
        else begin
            hs1<=hs_i; hs2<=hs1; hs3<=hs2;
            vs1<=vs_i; vs2<=vs1; vs3<=vs2;
            de1<=de_i; de2<=de1; de3<=de2;
            da1<=data_i; da2<=da1; da3<=da2;
            px1<=px_x; py1<=px_y; px2<=px1; py2<=py1;
            px3<=px2;  py3<=py2;
        end
    end

    //--------------------------------------------------------------
    // A 级: 行窗分类(py2) → 文字带 id
    //--------------------------------------------------------------
    localparam [3:0]
        ID_NONE     = 4'd0,
        ID_MT_TITLE = 4'd1,
        ID_MT_RUN   = 4'd2,
        ID_MT_ANN   = 4'd3,
        ID_MT_FOOT  = 4'd4,
        ID_QZ_TITLE = 4'd5,
        ID_QZ_STAT  = 4'd6,
        ID_QZ_CNT   = 4'd7,
        ID_QZ_FOOT  = 4'd8,
        ID_AL_TITLE = 4'd9,
        ID_AL_FOOT  = 4'd10;

    reg [3:0] rid2;
    always @(*) begin
        rid2 = ID_NONE;
        if (al_ok) begin
            if      ((py2 >= 12'd82)  && (py2 < 12'd114)) rid2 = ID_AL_TITLE;
            else if ((py2 >= 12'd452) && (py2 < 12'd468)) rid2 = ID_AL_FOOT;
        end
        else if (mt_ok) begin
            if      ((py2 >= MT_TY) && (py2 < MT_TY + 12'd32)) rid2 = ID_MT_TITLE;
            else if ((py2 >= MR_TY) && (py2 < MR_TY + 12'd16)) rid2 = ID_MT_RUN;
            else if ((py2 >= MA_TY) && (py2 < MA_TY + 12'd16)) rid2 = ID_MT_ANN;
            else if ((py2 >= 12'd452) && (py2 < 12'd468))      rid2 = ID_MT_FOOT;
        end
        else if (qz_ok) begin
            if      ((py2 >= QT_TY) && (py2 < QT_TY + 12'd32)) rid2 = ID_QZ_TITLE;
            else if ((py2 >= QS_TY) && (py2 < QS_TY + 12'd32)) rid2 = ID_QZ_STAT;
            else if ((py2 >= QC_TY) && (py2 < QC_TY + 12'd32) &&
                     (qstate_s <= 2'd1))                       rid2 = ID_QZ_CNT;
            else if ((py2 >= 12'd452) && (py2 < 12'd468))      rid2 = ID_QZ_FOOT;
        end
    end

    // A 级: 滚动取模(px2 + phase, 先折 640 再按带宽周期取模)
    wire [11:0] wxx  = px2 + {2'b00, phase};
    wire [11:0] wx_1 = (wxx >= 12'd640) ? (wxx - 12'd640) : wxx;
    wire [11:0] mw_m = (wx_1 >= 12'd320) ? (wx_1 - 12'd320) : wx_1;  // 会议/抢答
    wire [11:0] aw_m = (wx_1 >= 12'd384) ? (wx_1 - 12'd384) : wx_1;  // 应急

    // A 级: 行内偏移收窄 + 变量×小常量改移位加(★2026-09-21 面积优化)
    //   rid2 已把 py2 限定在本带行窗内(带宽 ≤32), 模 2^k 减法逐位精确,
    //   却把 12bit 减法器与 12bit×常量乘法器一起收窄到 5/4 位。
    wire [4:0] dy_mt = py2[4:0] - 5'd14;   // 会议标题  [14,46)
    wire [4:0] dy_20 = py2[4:0] - 5'd20;   // 抢答标题[20,52) / 倒计时[180,212)
    wire [4:0] dy_at = py2[4:0] - 5'd18;   // 应急标题  [82,114)
    wire [4:0] dy_qs = py2[4:0];           // 抢答状态  [96,128)
    wire [3:0] dy_4  = py2[3:0] - 4'd4;    // 公告[196,212) / 底部滚动[452,468)
    wire [3:0] dy_12 = py2[3:0] - 4'd12;   // "已运行"[76,92)

    wire [7:0] r_mt8  = {dy_mt, 3'b0};                                          // *8
    wire [7:0] r_mr3  = ({2'b0, dy_12} << 1) + {2'b0, dy_12};                   // *3
    wire [7:0] r_mr10 = ({4'b0, dy_12} << 3) + ({4'b0, dy_12} << 1);            // *10
    wire [7:0] r_ma10 = ({4'b0, dy_4}  << 3) + ({4'b0, dy_4}  << 1);            // *10
    wire [8:0] r_ft20 = ({5'b0, dy_4}  << 4) + ({5'b0, dy_4}  << 2);            // *20
    wire [8:0] r_ft24 = ({5'b0, dy_4}  << 4) + ({5'b0, dy_4}  << 3);            // *24
    wire [7:0] r_qt5  = ({2'b0, dy_20} << 2) + {2'b0, dy_20};                   // *5
    wire [6:0] r_qs2  = {dy_qs, 1'b0};                                          // *2
    wire [6:0] r_qs3  = ({2'b0, dy_qs} << 1) + {2'b0, dy_qs};                   // *3
    wire [6:0] r_qs4  = {dy_qs, 2'b0};                                          // *4
    wire [7:0] r_qs5  = ({2'b0, dy_qs} << 2) + {2'b0, dy_qs};                   // *5
    wire [7:0] r_qs8  = {dy_qs, 3'b0};                                          // *8
    wire [7:0] r_qsd10= ({4'b0, dy_qs[4:1]} << 3) + ({4'b0, dy_qs[4:1]} << 1);  // (dy>>1)*10
    wire [7:0] r_qcd10= ({4'b0, dy_20[4:1]} << 3) + ({4'b0, dy_20[4:1]} << 1);  // (dy>>1)*10
    wire [8:0] r_at10 = ({4'b0, dy_at} << 3) + ({4'b0, dy_at} << 1);            // *10

    // A 级: 页码数字窗命中(px 的纯函数; B 级打拍复用, 右沿 = 424+16)
    wire mpg_a = (px2 >= MP_GX) && (px2 < 12'd440);


    // A 级: 会议运行时长数字窗(6 格 16px + 2 处 6px 冒号间隙)
    reg        mdg_a;                    // 命中某位数字
    reg [2:0]  mdg_p;                    // 数字位 0..5
    reg [11:0] mdg_x0;
    always @(*) begin
        mdg_a  = 1'b0;
        mdg_p  = 3'd0;
        mdg_x0 = 12'd452;
        if      ((px2 >= 12'd452) && (px2 < 12'd468)) begin mdg_a=1'b1; mdg_p=3'd0; mdg_x0=12'd452; end
        else if ((px2 >= 12'd468) && (px2 < 12'd484)) begin mdg_a=1'b1; mdg_p=3'd1; mdg_x0=12'd468; end
        else if ((px2 >= 12'd490) && (px2 < 12'd506)) begin mdg_a=1'b1; mdg_p=3'd2; mdg_x0=12'd490; end
        else if ((px2 >= 12'd506) && (px2 < 12'd522)) begin mdg_a=1'b1; mdg_p=3'd3; mdg_x0=12'd506; end
        else if ((px2 >= 12'd528) && (px2 < 12'd544)) begin mdg_a=1'b1; mdg_p=3'd4; mdg_x0=12'd528; end
        else if ((px2 >= 12'd544) && (px2 < 12'd560)) begin mdg_a=1'b1; mdg_p=3'd5; mdg_x0=12'd544; end
    end

    reg [3:0] mdg_dig;                   // 该位数字字符(BCD)
    always @(*) begin
        case (mdg_p)
            3'd0:    mdg_dig = hh_s[7:4];
            3'd1:    mdg_dig = hh_s[3:0];
            3'd2:    mdg_dig = mm_s[7:4];
            3'd3:    mdg_dig = mm_s[3:0];
            3'd4:    mdg_dig = ss_s[7:4];
            default: mdg_dig = ss_s[3:0];
        endcase
    end

    // A 级: ROM 读请求(仅在字形窗内发, 省功耗)
    reg        rom_en;
    reg [12:0] rom_addr;
    always @(*) begin
        rom_en   = 1'b0;
        rom_addr = 13'd0;
        if (de2) begin
            case (rid2)
                // ---- 会议 ----
                ID_MT_TITLE: begin
                    if ((px2 >= MT_GX) && (px2 < 12'd448)) begin
                        rom_en   = 1'b1;
                        rom_addr = 13'd2512 + r_mt8 + ((px2 - MT_GX) >> 5);   // 32×32 真字模
                    end
                end
                ID_MT_RUN: begin
                    if ((px2 >= MR_GX) && (px2 < 12'd444)) begin
                        rom_en   = 1'b1;
                        rom_addr = 13'd3408 + r_mr3 + ((px2 - MR_GX) >> 4);
                    end
                    else if (mdg_a) begin
                        rom_en   = 1'b1;
                        rom_addr = NUM_BASE + r_mr10 + mdg_dig;
                    end
                end
                ID_MT_ANN: begin
                    if ((px2 >= MA_GX) && (px2 < 12'd400)) begin
                        rom_en   = 1'b1;
                        rom_addr = MA_B0 + ({11'd0, page} * MA_PG)
                                 + r_ma10 + ((px2 - MA_GX) >> 4);
                    end
                    else if (mpg_a) begin
                        rom_en   = 1'b1;
                        rom_addr = NUM_BASE + r_ma10 + {2'd0, page} + 4'd1;
                    end
                end
                ID_MT_FOOT: begin
                    rom_en   = 1'b1;
                    rom_addr = MF_BASE + r_ft20 + (mw_m >> 4);
                end
                // ---- 抢答 ----
                ID_QZ_TITLE: begin
                    if ((px2 >= QT_GX) && (px2 < 12'd400)) begin
                        rom_en   = 1'b1;
                        rom_addr = 13'd3776 + r_qt5 + ((px2 - QT_GX) >> 5);   // 32×32 真字模
                    end
                end
                ID_QZ_STAT: begin
                    case (qstate_s)
                        2'd0: begin   // 等待开始(N4, gx256)
                            if ((px2 >= 12'd256) && (px2 < 12'd384)) begin
                                rom_en   = 1'b1;
                                rom_addr = QW_BASE + r_qs4 + ((px2 - 12'd256) >> 5);
                            end
                        end
                        2'd1: begin   // 抢答中(N3, gx272)
                            if ((px2 >= 12'd272) && (px2 < 12'd368)) begin
                                rom_en   = 1'b1;
                                rom_addr = QR_BASE + r_qs3 + ((px2 - 12'd272) >> 5);
                            end
                        end
                        2'd2: begin   // 选手(N2,192) + 号(NUM,256) + 号抢答成功(N5,288)
                            if ((px2 >= 12'd192) && (px2 < 12'd256)) begin
                                rom_en   = 1'b1;
                                rom_addr = QL_BASE + r_qs2 + ((px2 - 12'd192) >> 5);
                            end
                            else if ((px2 >= 12'd256) && (px2 < 12'd288)) begin
                                // NUM 数字带仍是 16×16 字模, 在此 2× 窗内由 RTL 行列折叠放大
                                rom_en   = 1'b1;
                                rom_addr = NUM_BASE + r_qsd10 + {1'b0, winner_s} + 3'd1;
                            end
                            else if ((px2 >= 12'd288) && (px2 < 12'd448)) begin
                                rom_en   = 1'b1;
                                rom_addr = QX_BASE + r_qs5 + ((px2 - 12'd288) >> 5);
                            end
                        end
                        default: begin // 时间到 无人抢答(N8, gx192)
                            if ((px2 >= 12'd192) && (px2 < 12'd448)) begin
                                rom_en   = 1'b1;
                                rom_addr = QN_BASE + r_qs8 + ((px2 - 12'd192) >> 5);
                            end
                        end
                    endcase
                end
                ID_QZ_CNT: begin
                    if ((px2 >= 12'd272) && (px2 < 12'd304) && (t_tens_s != 4'd0)) begin
                        rom_en   = 1'b1;      // 倒计时数字: NUM 16×16 字模 2× 折叠放大
                        rom_addr = NUM_BASE + r_qcd10 + t_tens_s;
                    end
                    else if ((px2 >= 12'd304) && (px2 < 12'd336)) begin
                        rom_en   = 1'b1;
                        rom_addr = NUM_BASE + r_qcd10 + t_ones_s;
                    end
                    else if ((px2 >= 12'd336) && (px2 < 12'd368)) begin
                        rom_en   = 1'b1;      // "秒" 为 2× 带 → 32×32 真字模
                        rom_addr = QSEC_BASE + {7'b0, dy_20};
                    end
                end
                ID_QZ_FOOT: begin
                    rom_en   = 1'b1;
                    rom_addr = QF_BASE + r_ft20 + (mw_m >> 4);
                end
                // ---- 应急 ----
                ID_AL_TITLE: begin
                    if ((px2 >= AT_GX) && (px2 < 12'd480)) begin
                        rom_en   = 1'b1;
                        rom_addr = 13'd4992 + r_at10 + ((px2 - AT_GX) >> 5);  // 32×32 真字模
                    end
                end
                ID_AL_FOOT: begin
                    rom_en   = 1'b1;
                    rom_addr = AF_BASE + r_ft24 + (aw_m >> 4);
                end
                default: ;
            endcase
        end
    end

    //--------------------------------------------------------------
    // 字形 ROM(同步读, q 晚 addr 一拍; 三场景与菜单/迎新共用同一生成文件)
    //   ★V3: 位宽 16→32, 深度 4608→5856(2× 带存 32×32 真字模; 1× 带用低 16 位)
    //   ★资源优化: ROM 实体移到 top 层统一例化(三路 OSD 互斥, 只占一份 BRAM)。
    //--------------------------------------------------------------
    assign rom_en_o   = rom_en;
    assign rom_addr_o = rom_addr;

    //--------------------------------------------------------------
    // B 级: 行窗分类 / 页码数字窗 / 滚动取模 —— 全部改为 A 级结果打一拍
    //   ★2026-09-21 面积优化: py3 ≡ py2 延迟 1 拍(第 265-266 行 px3<=px2;
    //     py3<=py2), 故 f(py3) 恒等于 f(py2) 延迟 1 拍。原先 B 级把
    //     "按 py3 分类 10 个文字带(10 个 12bit 比较器 + 优先链)"、
    //     "6 格运行数字窗(12 个 12bit 比较器)"、"px3+phase 两次取模
    //     (12bit 加法 + 4 个比较器 + 4 个减法器)"整套重算了一遍,
    //     是本模块 633 条进位链的首要来源。改为纯打拍后画面逐像素完全不变。
    //--------------------------------------------------------------
    reg [3:0]  rid3;
    reg        mdg_hit, mpg_hit;
    reg [11:0] mdg_bx0;
    reg [11:0] mw3_m, aw3_m;
    always @(posedge video_clk or posedge rst) begin
        if (rst) begin
            rid3    <= ID_NONE;
            mdg_hit <= 1'b0; mdg_bx0 <= 12'd452;
            mpg_hit <= 1'b0;
            mw3_m   <= 12'd0; aw3_m   <= 12'd0;
        end
        else begin
            rid3    <= rid2;
            mdg_hit <= mdg_a;  mdg_bx0 <= mdg_x0;
            mpg_hit <= mpg_a;
            mw3_m   <= mw_m;   aw3_m   <= aw_m;
        end
    end

    // B 级: 抢答动态数字格命中(倒计时两位 / 胜者号)
    //   这两处依赖 qstate_s(sd 域慢变), 保留组合判定以保证与当拍 qstate 严格
    //   同拍, 不作打拍(仅在 qstate 跳变的那个像素周期上可能差 1 拍, 不可见)。
    wire qcg_hit = (rid3 == ID_QZ_CNT) && (qstate_s <= 2'd1) &&
                   (((px3 >= 12'd272) && (px3 < 12'd304) && (t_tens_s != 4'd0)) ||
                    ((px3 >= 12'd304) && (px3 < 12'd336)));
    wire [11:0] qcg_bx0 = (px3 < 12'd304) ? 12'd272 : 12'd304;
    wire qwg_hit = (rid3 == ID_QZ_STAT) && (qstate_s == 2'd2) &&
                   (px3 >= 12'd256) && (px3 < 12'd288);

    // B 级: 字形墨点判定
    reg ink;
    always @(*) begin
        ink = 1'b0;
        if (de3) begin
            if (al_ok) begin
                case (rid3)
                    ID_AL_TITLE: begin
                        if ((px3 >= AT_GX) && (px3 < 12'd480))
                            ink = rom_q[31 - ((px3 - AT_GX) & 12'd31)];   // 32×32 真字模
                    end
                    ID_AL_FOOT:  ink = rom_q[15 - aw3_m[3:0]];
                    default: ;
                endcase
            end
            else if (mt_ok) begin
                case (rid3)
                    ID_MT_TITLE: begin
                        if ((px3 >= MT_GX) && (px3 < 12'd448))
                            ink = rom_q[31 - ((px3 - MT_GX) & 12'd31)];   // 32×32 真字模
                    end
                    ID_MT_RUN: begin
                        if ((px3 >= MR_GX) && (px3 < 12'd444))
                            ink = rom_q[15 - ((px3 - MR_GX) & 12'd15)];
                        else if (mdg_hit)
                            ink = rom_q[15 - ((px3 - mdg_bx0) & 12'd15)];
                    end
                    ID_MT_ANN: begin
                        if ((px3 >= MA_GX) && (px3 < 12'd400))
                            ink = rom_q[15 - ((px3 - MA_GX) & 12'd15)];
                        else if (mpg_hit)
                            ink = rom_q[15 - ((px3 - 12'd424) & 12'd15)];
                    end
                    ID_MT_FOOT:  ink = rom_q[15 - mw3_m[3:0]];
                    default: ;
                endcase
            end
            else if (qz_ok) begin
                case (rid3)
                    ID_QZ_TITLE: begin
                        if ((px3 >= QT_GX) && (px3 < 12'd400))
                            ink = rom_q[31 - ((px3 - QT_GX) & 12'd31)];   // 32×32 真字模
                    end
                    ID_QZ_STAT: begin
                        case (qstate_s)
                            2'd0: begin
                                if ((px3 >= 12'd256) && (px3 < 12'd384))
                                    ink = rom_q[31 - ((px3 - 12'd256) & 12'd31)];
                            end
                            2'd1: begin
                                if ((px3 >= 12'd272) && (px3 < 12'd368))
                                    ink = rom_q[31 - ((px3 - 12'd272) & 12'd31)];
                            end
                            2'd2: begin
                                if ((px3 >= 12'd192) && (px3 < 12'd256))
                                    ink = rom_q[31 - ((px3 - 12'd192) & 12'd31)];
                                else if (qwg_hit)
                                    // 胜者号仍为 NUM 16×16 字模, 2× 折叠 → 取第 15..0 位
                                    ink = rom_q[15 - (((px3 - 12'd256) & 12'd31) >> 1)];
                                else if ((px3 >= 12'd288) && (px3 < 12'd448))
                                    ink = rom_q[31 - ((px3 - 12'd288) & 12'd31)];
                            end
                            default: begin
                                if ((px3 >= 12'd192) && (px3 < 12'd448))
                                    ink = rom_q[31 - ((px3 - 12'd192) & 12'd31)];
                            end
                        endcase
                    end
                    ID_QZ_CNT: begin
                        if (qcg_hit)
                            // 倒计时数字仍是 NUM 16×16 字模, 2× 折叠 → 取第 15..0 位
                            ink = rom_q[15 - (((px3 - qcg_bx0) & 12'd31) >> 1)];
                        else if ((px3 >= 12'd336) && (px3 < 12'd368))
                            ink = rom_q[31 - ((px3 - 12'd336) & 12'd31)];   // "秒" 32×32
                    end
                    ID_QZ_FOOT:  ink = rom_q[15 - mw3_m[3:0]];
                    default: ;
                endcase
            end
        end
    end

    //--------------------------------------------------------------
    // B 级: 区域命中(衬底色块)
    //--------------------------------------------------------------
    wire mt_band  = (py3 >= BAND_Y0) && (py3 < BAND_Y1) &&
                    (px3 >= 12'd168) && (px3 < 12'd472);
    wire mt_runp  = (py3 >= 12'd68)  && (py3 < 12'd100) &&
                    (px3 >= 12'd388) && (px3 < 12'd568);
    wire mt_annp  = (py3 >= 12'd180) && (py3 < 12'd228) &&
                    (px3 >= 12'd208) && (px3 < 12'd456);
    wire qz_band  = (py3 >= 12'd12)  && (py3 < 12'd60)  &&
                    (px3 >= 12'd200) && (px3 < 12'd440);
    wire qz_panel = (py3 >= 12'd84)  && (py3 < 12'd228) &&
                    (px3 >= 12'd160) && (px3 < 12'd480);
    wire foot_band= (py3 >= FOOT_Y0) && (py3 < FOOT_Y1);
    wire al_tband = (py3 >= AL_TBY0) && (py3 < AL_TBY1) &&
                    (px3 >= AL_TBX0) && (px3 < AL_TBX1);

    // 会议运行时长冒号(RTL 绘制: 每处 4×4 两点)
    wire mt_colon_row = ((py3 >= 12'd80) && (py3 < 12'd84)) ||
                        ((py3 >= 12'd87) && (py3 < 12'd91));
    wire mt_colon_hit = mt_colon_row &&
                        (((px3 >= 12'd484) && (px3 < 12'd488)) ||
                         ((px3 >= 12'd522) && (px3 < 12'd526)));

    // 抢答倒计时单位"秒"命中(与数字同为金色; 否则会被当作状态文字着白色)
    wire qsec_hit = (rid3 == ID_QZ_CNT) &&
                    (px3 >= 12'd336) && (px3 < 12'd368);

    // 应急警示三角(顶条内, 尖角向上; 内部感叹号取暗红使其可见)
    wire [11:0] al_dy  = (py3 >= 12'd6) ? (py3 - 12'd6) : 12'd0;
    wire [11:0] al_dx  = (px3 > 12'd320) ? (px3 - 12'd320) : (12'd320 - px3);
    wire        al_row = (py3 >= 12'd6) && (py3 < 12'd46);
    wire [13:0] al_lhs = al_dx * 14'd5;                  // dx*5
    wire [13:0] al_rhs = al_dy * 14'd3;                  // (y-6)*3
    wire        al_tri = al_row && (al_lhs <= al_rhs);
    wire        al_exc = (px3 >= 12'd317) && (px3 < 12'd324) &&
                         (((py3 >= 12'd20) && (py3 < 12'd34)) ||
                          ((py3 >= 12'd38) && (py3 < 12'd45)));

    //--------------------------------------------------------------
    // B 级: 衬底混合色(衬底区外不输出, 逻辑可忽略)
    //   藏蓝 50%: (bg + NAVY) >> 1     藏蓝 75%: (bg + NAVY*3) >> 2
    //   暗带 25%: bg >> 2              应急深红 50%: (bg + ALRED) >> 1
    //--------------------------------------------------------------
    wire [8:0] bg_r9 = {1'b0, da3[23:16]};
    wire [8:0] bg_g9 = {1'b0, da3[15:8]};
    wire [8:0] bg_b9 = {1'b0, da3[7:0]};
    wire [7:0] navy50_r = (bg_r9 + 9'd10) >> 1;      // 0x0A
    wire [7:0] navy50_g = (bg_g9 + 9'd38) >> 1;      // 0x26
    wire [7:0] navy50_b = (bg_b9 + 9'd71) >> 1;      // 0x47
    wire [7:0] panel_r  = (bg_r9 + 3*9'd10) >> 2;
    wire [7:0] panel_g  = (bg_g9 + 3*9'd38) >> 2;
    wire [7:0] panel_b  = (bg_b9 + 3*9'd71) >> 2;
    wire [7:0] dark_r   = bg_r9[8:2];
    wire [7:0] dark_g   = bg_g9[8:2];
    wire [7:0] dark_b   = bg_b9[8:2];
    wire [7:0] alrd_r   = (bg_r9 + 9'd138) >> 1;     // 0x8A
    wire [7:0] alrd_g   = bg_g9 >> 1;
    wire [7:0] alrd_b   = bg_b9 >> 1;

    wire [DATA_W-1:0] c_navy50 = {navy50_r, navy50_g, navy50_b};
    wire [DATA_W-1:0] c_panel  = {panel_r,  panel_g,  panel_b};
    wire [DATA_W-1:0] c_dark   = {dark_r,   dark_g,   dark_b};
    wire [DATA_W-1:0] c_alred  = {alrd_r,   alrd_g,   alrd_b};

    //--------------------------------------------------------------
    // 输出仲裁(组合): 应急 > 会议 > 抢答 > 背景透传
    //--------------------------------------------------------------
    reg [DATA_W-1:0] fo;
    always @(*) begin
        fo = da3;                                       // 默认透传(背景保持)
        if (de3) begin
            if (al_ok) begin
                if (al_tri)
                    fo = al_exc ? C_AL_BAR_B : C_AL_ICO;      // 警示三角
                else if (py3 < AL_BAR_ROWS)
                    fo = blink ? C_AL_BAR_A : C_AL_BAR_B;     // 闪烁红条
                else if (al_tband)
                    fo = ink ? C_AL_TITLE : c_alred;          // 深红衬底标题
                else if (foot_band)
                    fo = ink ? C_AL_FOOT : c_dark;            // 底部滚动告警
            end
            else if (mt_ok) begin
                if (mt_band)
                    fo = ink ? C_MT_TITLE : c_navy50;         // 会议标题条
                else if (mt_runp) begin
                    if (mdg_hit)
                        fo = ink ? C_MT_DIG : c_panel;        // 运行时长数字
                    else if (mt_colon_hit)
                        fo = C_MT_DIG;                        // 冒号
                    else
                        fo = ink ? C_MT_RUN : c_panel;        // "已运行"
                end
                else if (mt_annp) begin
                    if (mpg_hit)
                        fo = ink ? C_MT_DIG : c_panel;        // 页码数字
                    else
                        fo = ink ? C_MT_ANN : c_panel;        // 公告文字
                end
                else if (foot_band)
                    fo = ink ? C_MT_FOOT : c_dark;            // 底部滚动提示
            end
            else if (qz_ok) begin
                if (qz_band)
                    fo = ink ? C_QZ_TITLE : c_navy50;         // 抢答标题条
                else if (qz_panel) begin
                    if (qcg_hit || qwg_hit || qsec_hit)
                        fo = ink ? C_QZ_DIG : c_panel;        // 倒计时/胜者号/秒
                    else
                        fo = ink ? C_QZ_TXT : c_panel;        // 状态文字
                end
                else if (foot_band)
                    fo = ink ? C_QZ_FOOT : c_dark;            // 底部滚动须知
            end
        end
    end

    assign hs_o   = hs3;
    assign vs_o   = vs3;
    assign de_o   = de3;
    assign data_o = fo;
    assign px_x_o = px3;
    assign px_y_o = py3;

endmodule
