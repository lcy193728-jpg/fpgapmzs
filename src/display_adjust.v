//====================================================================
// 模块名 : display_adjust.v —— 显示效果末级调节引擎
// 功能   (位于 osd_scene 之后、hdmi_tx 之前, 对整帧生效):
//   1. 亮度调节 : 16 档(bri_level 0..15, 默认 8 = ×1.0), 增益
//      g = 64 + L*8 (×0.5 .. ×1.44), 乘加取整并饱和钳位。
//      调节键来自 sd 域 ui_key_ctrl(key2=减 / key3=加), 本模块两级同步。
//   2. 场景切换淡入淡出 : 检测 menu_active(菜单态标志)电平翻转
//      (菜单↔场景 必经, "先开锁定"保证), 从 alpha=255 逐帧降到 0 黑场,
//      等 bmp 底层新分区图片写完(img_busy 释放 / 超时兜底)再逐帧升回 255。
//      应急(emerg)期间强制 alpha=255 不淡出(最高优先级即刻响应)。
//
//   3. ★操作提示 HUD(2026-09-16 新增, 全部"变化即弹、N 帧后自动消失"):
//      · 亮度条   : 档位变化 / 切到亮度模式 → 左上 16 档图形条
//                   (盒 x8..144, y4..11)
//      · 缩放条   : 档位变化 / 切到分辨率模式 → 8 段图形条
//                   (盒 x8..81, y16..23; 8 段×9px = 72px)
//      · 轮播/手动: KEY4 切换 / 切到图片模式 → 左侧状态卡
//                   (盒 x8..47, y28..51)
//                     ‣ 自动轮播 = 绿框 + 绿"播放三角 ▶"(8×16, 位于 x16..23)
//                     ‣ 手动单张 = 橙框 + 橙"暂停双竖条 ▮▮"(x18..21/x26..29)
//      三个提示区在 y 方向互不重叠, 可同时出现; 优先级 亮度>缩放>状态卡。
//      提示色固定, 不随本帧亮度增益变化, 保证可读。
//
// 混合公式 :
//   stage1 亮度:  b1 = clamp((pix * g + 64) >> 7)
//   stage2 淡入:  out = (b1 * alpha + 128) >> 8   (alpha 255=全显, 0=黑)
//   提示 HUD 在 stage2 之后叠加(固定色)。
// 数据管线 : 输入寄存 1 拍(da1/px1/sync1)后组合仲裁直接输出 →
//            整体恒定延迟 1 clk, 与 hs/vs/de 严格同拍。
// 控制输入 : menu_active/bmp_busy/bri_level/res_level/pic_manual/ui_mode
//            均来自 sd_card_clk(100MHz)域电平, 模块内两级同步器过域。
// 语言     : 纯 Verilog-2001(兼容 TD EDA 与 ModelSim)。
//====================================================================

`timescale 1ns/1ps

module display_adjust #(
    parameter DATA_W         = 24,
    parameter H_ACT          = 640,
    parameter V_ACT          = 480,
    // ---- 淡入淡出 ----
    parameter [7:0] FADE_STEP = 8'd64,   // 半程 4 帧(255→0 用 64/帧步进)
    parameter [15:0] TIMEOUT_FRAMES = 16'd45, // 黑场最长等待(帧); 超时兜底防呆黑
    // ---- 亮度条 ----
    parameter [15:0] BAR_HOLD_FRAMES = 16'd30, // 亮度档变化后条保持帧数
    parameter [11:0] BAR_X0 = 12'd8,     // 条盒左
    parameter [11:0] BAR_Y0 = 12'd4,     // 条盒上
    parameter [11:0] BAR_H  = 12'd8,     // 盒高(含 1px 边框)
    parameter [11:0] BAR_UNIT = 12'd9,   // 每档 9px, 16 档 → 内宽 144px
    parameter [11:0] BAR_MAXL = 12'd16,  // 总档数
    // ---- 缩放(分辨率)条 + 轮播/手动状态卡 ----
    parameter [15:0] RES_HOLD_FRAMES = 16'd30, // 缩放档变化后条保持帧数
    parameter [15:0] MAN_HOLD_FRAMES = 16'd30, // 轮播/手动状态卡保持帧数
    parameter [1:0]  MODE_PIC = 2'd0,    // 与 ui_key_ctrl 一致的模式编码
    parameter [1:0]  MODE_BRI = 2'd1,
    parameter [1:0]  MODE_RES = 2'd2,
    parameter [1:0]  MODE_PERIOD = 2'd3  // 批次4: 轮播周期档(不弹 HUD)
)(
    input                video_clk,      // 像素时钟(≈25.175MHz)
    input                rst,            // 高有效复位
    // ---- 输入: osd_scene 输出(已对齐) ----
    input                hs_i, vs_i, de_i,
    input  [DATA_W-1:0]  data_i,
    input  [11:0]        px_x,           // 与 data_i 同拍 x(0 基)
    input  [11:0]        px_y,           // 与 data_i 同拍 y(0 基)
    // ---- 控制(异步电平, sd_card_clk 域) ----
    input                menu_active,    // 菜单态(边沿触发淡入淡出)
    input                emerg,          // 应急中(强制不淡出)
    input                bmp_busy,       // 底层 BMP 加载忙(1=扫描/读图中)
    input        [3:0]   bri_level,      // 亮度档 0..15(默认 8)
    input        [3:0]   res_level,      // 缩放档 0..7(默认 4=100%)
    input                pic_manual,     // 1=手动单张 / 0=自动轮播
    input        [1:0]   ui_mode,        // 功能模式 0图片/1亮度/2缩放
    // ---- 输出: 送 hdmi_tx ----
    output               hs_o, vs_o, de_o,
    output [DATA_W-1:0]  data_o
);

    //--------------------------------------------------------------
    // 提示 HUD 颜色(固定色, 后叠不受亮度增益影响)
    //--------------------------------------------------------------
    localparam [DATA_W-1:0] C_BAR_BD = 24'hE4_F0_FF;  // 条/卡描边(近白) 亮度条/缩放条共用
    localparam [DATA_W-1:0] C_BAR_FG = 24'hFF_C9_3C;  // 亮度已生效档位(金)
    localparam [DATA_W-1:0] C_BAR_BG = 24'h10_14_18;  // 未生效档位(深灰) 两条共用
    localparam [DATA_W-1:0] C_RES_FG = 24'h22_D3_EE;  // 缩放已生效档位(青)
    localparam [DATA_W-1:0] C_CARD_BG= 24'h0A_10_18;  // 状态卡底(更深的蓝黑)
    localparam [DATA_W-1:0] C_AUTO   = 24'h22_C5_5E;  // 自动轮播: 卡边 + 播放三角(绿)
    localparam [DATA_W-1:0] C_MAN    = 24'hFF_A0_28;  // 手动单张: 卡边 + 暂停双条(橙)

    //--------------------------------------------------------------
    // 控制电平过域(两级同步; bri_level 4bit)
    //--------------------------------------------------------------
    reg  m_s0, m_s1, e_s0, e_s1, b_s0, b_s1;
    reg  [3:0] l_s0, l_s1;
    reg  [3:0] r_s0, r_s1;      // 缩放(分辨率)档 0..7
    reg        p_s0, p_s1;      // 轮播(0)/手动(1)
    reg  [1:0] u_s0, u_s1;      // 功能模式 0图片/1亮度/2缩放
    wire menu_s  = m_s1;
    wire emerg_s = e_s1;
    wire busy_s  = b_s1;
    wire [3:0] lvl_s  = l_s1;
    wire [3:0] res_s  = r_s1;
    wire       man_s  = p_s1;
    wire [1:0] mode_s = u_s1;

    always @(posedge video_clk or posedge rst) begin
        if (rst) begin
            // 复位初值对齐系统默认态(菜单 active / 非应急 / 忙未知 / 亮度档8
            // / 缩放档4=100% / 自动轮播 / 图片模式), 防止上电同步过程产生
            // 假边沿(假淡出 / 假提示条)
            m_s0<=1'b1; m_s1<=1'b1; e_s0<=1'b0; e_s1<=1'b0;
            b_s0<=1'b0; b_s1<=1'b0; l_s0<=4'd8; l_s1<=4'd8;
            r_s0<=4'd4; r_s1<=4'd4;
            p_s0<=1'b0; p_s1<=1'b0;
            u_s0<=MODE_PIC; u_s1<=MODE_PIC;
        end
        else begin
            m_s0<=menu_active; m_s1<=m_s0;
            e_s0<=emerg;       e_s1<=e_s0;
            b_s0<=bmp_busy;    b_s1<=b_s0;
            l_s0<=bri_level;   l_s1<=l_s0;
            r_s0<=res_level;   r_s1<=r_s0;
            p_s0<=pic_manual;  p_s1<=p_s0;
            u_s0<=ui_mode;     u_s1<=u_s0;
        end
    end

    //--------------------------------------------------------------
    // 帧边界检测(与 osd_menu/osd_welcome 同法: vs 上升沿)
    //--------------------------------------------------------------
    reg vsd;
    wire vs_rise = vs_i & ~vsd;
    always @(posedge video_clk or posedge rst) begin
        if (rst)      vsd <= 1'b0;
        else          vsd <= vs_i;
    end

    //--------------------------------------------------------------
    // 淡入淡出状态机(alpha 每帧 vs 边沿步进, 帧内恒定 → 无抖动)
    //   FIDLE: 透明(255)。检测到 menu_active 翻转事件(非应急)→ FOUT。
    //   FOUT : alpha 逐帧降 64 直到 0 → FBLCK。
    //   FBLCK: 黑场等待 bmp_busy 释放(底层新分区图写完)或超时 → FIN。
    //   FIN  : alpha 逐帧升 64 直到 255 → FIDLE。
    //   menu_active 翻转 → 粘性事件 menu_evt(逐拍捕获), 帧边界消费,
    //   避免"帧内翻转、帧边界检测时电平已复原"导致丢触发。
    //--------------------------------------------------------------
    localparam [1:0] FIDLE = 2'd0, FOUT = 2'd1, FBLCK = 2'd2, FIN = 2'd3;

    reg [1:0]  fsm;
    reg [7:0]  alpha;
    reg [15:0] blk_fr;         // 黑场已等待帧数(超时计数)
    reg        menu_past;      // 上一拍 menu_active(同步域, 边沿检测)
    reg        menu_evt;       // 粘性翻转事件(帧边界消费)
    reg [3:0]  lvl_past;     // 上一拍亮度档(变化 → 显示亮度条)
    reg [15:0] bar_cnt;        // 亮度条剩余显示帧数(0=隐藏)
    reg [3:0]  res_past;     // 上一拍缩放档(变化 → 显示缩放条)
    reg [15:0] res_cnt;        // 缩放条剩余显示帧数(0=隐藏)
    reg        man_past;      // 上一拍轮播/手动标志(变化 → 显示状态卡)
    reg [15:0] man_cnt;        // 状态卡剩余显示帧数(0=隐藏)
    reg [1:0]  mode_past;     // 上一拍功能模式(切换 → 弹该模式的提示)

    always @(posedge video_clk or posedge rst) begin
        if (rst) begin
            fsm        <= FIDLE;
            alpha      <= 8'd255;
            blk_fr     <= 16'd0;
            menu_past  <= 1'b1;       // 复位默认菜单态(与 scene_control 一致), 防上电假淡出
            menu_evt   <= 1'b0;
            lvl_past   <= 4'd8;
            bar_cnt    <= 16'd0;
            res_past   <= 4'd4;
            res_cnt    <= 16'd0;
            man_past   <= 1'b0;
            man_cnt    <= 16'd0;
            mode_past  <= MODE_PIC;
        end
        else begin
            // ---- 事件锁存(逐拍检测, 与帧边界无关) ----
            if (menu_s != menu_past)
                menu_evt <= 1'b1;                 // 场景切换事件(粘性)
            menu_past <= menu_s;

            if (lvl_s != lvl_past)
                bar_cnt <= BAR_HOLD_FRAMES;        // 亮度档变化 → 显示亮度条
            lvl_past  <= lvl_s;

            if (res_s != res_past)
                res_cnt <= RES_HOLD_FRAMES;        // 缩放档变化 → 显示缩放条
            res_past  <= res_s;

            if (man_s != man_past)
                man_cnt <= MAN_HOLD_FRAMES;        // 轮播↔手动 → 显示状态卡
            man_past  <= man_s;

            // ---- 功能模式切换: 弹出"当前在调什么"的提示(便于现场确认) ----
            if (mode_s != mode_past) begin
                case (mode_s)
                    MODE_BRI: bar_cnt <= BAR_HOLD_FRAMES;   // 切到亮度模式 → 亮度条
                    MODE_RES: res_cnt <= RES_HOLD_FRAMES;   // 切到分辨率模式 → 缩放条
                    MODE_PERIOD: ;                          // 周期档(批次4): 弹窗沿用
                                                            // 上一条提示, 不额外弹卡
                    default : man_cnt <= MAN_HOLD_FRAMES;   // 切到图片模式 → 轮播/手动卡
                endcase
            end
            mode_past <= mode_s;

            if (vs_rise) begin
                // 提示条倒计时(每帧 -1)
                if (bar_cnt != 16'd0)
                    bar_cnt <= bar_cnt - 16'd1;
                if (res_cnt != 16'd0)
                    res_cnt <= res_cnt - 16'd1;
                if (man_cnt != 16'd0)
                    man_cnt <= man_cnt - 16'd1;

                if (emerg_s) begin
                    // 应急: 最高优先级即刻响应, 禁止淡出, 并丢弃待处理事件
                    fsm      <= FIDLE;
                    alpha    <= 8'd255;
                    blk_fr   <= 16'd0;
                    menu_evt <= 1'b0;
                end
                else begin
                    case (fsm)
                    FIDLE: begin
                        blk_fr <= 16'd0;
                        if (menu_evt) begin
                            menu_evt <= 1'b0;
                            fsm      <= FOUT;       // 场景切换事件 → 开始淡出
                        end
                    end
                    FOUT: begin
                        if (alpha <= FADE_STEP) begin
                            alpha <= 8'd0;       // 降到全黑
                            fsm   <= FBLCK;
                            blk_fr<= 16'd0;
                        end
                        else
                            alpha <= alpha - FADE_STEP;
                    end
                    FBLCK: begin
                        // 等底层新分区图写完(忙释放)或超时, 防呆黑
                        if (~busy_s || (blk_fr >= TIMEOUT_FRAMES)) begin
                            fsm <= FIN;
                        end
                        else
                            blk_fr <= blk_fr + 16'd1;
                    end
                    FIN: begin
                        if (alpha >= (8'd255 - FADE_STEP)) begin
                            alpha <= 8'd255;     // 恢复全显
                            fsm   <= FIDLE;
                        end
                        else
                            alpha <= alpha + FADE_STEP;
                    end
                    default: fsm <= FIDLE;
                    endcase
                end
            end
        end
    end

    //--------------------------------------------------------------
    // 一级输入寄存(1 拍; 同步/数据/坐标一致平移)
    //--------------------------------------------------------------
    reg hs1, vs1, de1;
    reg [DATA_W-1:0] da1;
    reg [11:0] px1, py1;
    always @(posedge video_clk or posedge rst) begin
        if (rst) begin
            hs1<=1'b0; vs1<=1'b0; de1<=1'b0;
            da1<={DATA_W{1'b0}};
            px1<=12'd0; py1<=12'd0;
        end
        else begin
            hs1<=hs_i; vs1<=vs_i; de1<=de_i;
            da1<=data_i;
            px1<=px_x; py1<=px_y;
        end
    end

    //--------------------------------------------------------------
    // 亮度增益 g = 64 + L*8  (L:0..15 → 0.5×..1.44×)
    //--------------------------------------------------------------
    wire [8:0] gain = 9'd64 + ({4'b0, lvl_s} << 3);

    // stage1: 亮度乘加(半进位)+饱和钳位;  8bit×8bit 积 < 65536, 无溢出
    wire [15:0] r_g = da1[23:16] * gain[7:0];
    wire [15:0] g_g = da1[15:8]  * gain[7:0];
    wire [15:0] b_g = da1[7:0]   * gain[7:0];
    wire [15:0] r_p = r_g + 16'd64;
    wire [15:0] g_p = g_g + 16'd64;
    wire [15:0] b_p = b_g + 16'd64;
    wire [8:0]  r_q = r_p >> 7;
    wire [8:0]  g_q = g_p >> 7;
    wire [8:0]  b_q = b_p >> 7;
    wire [7:0]  r_b = (r_q > 9'd255) ? 8'd255 : r_q[7:0];
    wire [7:0]  g_b = (g_q > 9'd255) ? 8'd255 : g_q[7:0];
    wire [7:0]  b_b = (b_q > 9'd255) ? 8'd255 : b_q[7:0];

    // stage2: 淡入淡出 alpha 混合(乘加取整)
    //   alpha==255 时直通(此时 FIDLE 稳态/淡入完成), 避免 (x*255+128)>>8
    //   对高亮像素产生 -1 量化误差, 保证平时显示与原像素完全一致
    wire [15:0] r_f = r_b * alpha;
    wire [15:0] g_f = g_b * alpha;
    wire [15:0] b_f = b_b * alpha;
    wire [7:0]  r_o = (alpha == 8'd255) ? r_b : ((r_f + 16'd128) >> 8);
    wire [7:0]  g_o = (alpha == 8'd255) ? g_b : ((g_f + 16'd128) >> 8);
    wire [7:0]  b_o = (alpha == 8'd255) ? b_b : ((b_f + 16'd128) >> 8);

    //--------------------------------------------------------------
    // 亮度条区域命中(左上角)
    //   盒 [X0, X0+2+INNER_W) × [Y0, Y0+BAR_H); 最外 1px=描边;
    //   内区宽 INNER_W = (BAR_MAXL-1)*UNIT = 15*9 = 135px = 15 个档位格
    //   (档 0..15, L=15 恰好填满整条; L=0 全空)。
    //   生效档位填充 [inner_l, inner_l + L*UNIT)。
    //--------------------------------------------------------------
    wire bar_show = (bar_cnt != 16'd0);
    localparam [11:0] BAR_INNER_W = 12'd135;   // (16-1)*9, 满档=15 格
    localparam [11:0] BAR_R = BAR_X0 + 12'd2 + BAR_INNER_W;  // 盒右(不含)
    localparam [11:0] inner_l = BAR_X0 + 12'd1;              // 内区左
    wire [11:0] fill_r = inner_l + (lvl_s * BAR_UNIT);       // 生效档右(不含)

    wire bar_region = bar_show && de1 &&
                      (py1 >= BAR_Y0) && (py1 < BAR_Y0 + BAR_H) &&
                      (px1 >= BAR_X0) && (px1 < BAR_R);
    wire bar_border = bar_region &&
                      ((py1 == BAR_Y0) || (py1 == BAR_Y0 + BAR_H - 12'd1) ||
                       (px1 == BAR_X0) || (px1 == BAR_R - 12'd1));
    wire bar_active = bar_region && ~bar_border &&
                      (px1 < fill_r) && (px1 >= inner_l);

    //--------------------------------------------------------------
    // 缩放(分辨率)条区域命中(左上第 2 行 y16..23; 8 档)
    //   盒 [RES_X0, RES_R) × [RES_Y0, RES_Y0+RES_H); 内宽 = 8 段×9px = 72px
    //   生效格数 = res_s + 1 (档 0=25% 也点亮 1 格 → 肉眼可确认"确实有反应")
    //--------------------------------------------------------------
    localparam [11:0] RES_X0      = 12'd8;
    localparam [11:0] RES_Y0      = 12'd16;
    localparam [11:0] RES_H       = 12'd8;
    localparam [11:0] RES_UNIT    = 12'd9;
    localparam [11:0] RES_INNER_W = 12'd72;                        // 8*9
    localparam [11:0] RES_R       = RES_X0 + 12'd2 + RES_INNER_W;  // 82
    localparam [11:0] res_inner_l = RES_X0 + 12'd1;                // 9

    wire [12:0] res_fill_r = res_inner_l +
                             (({9'd0, res_s} + 13'd1) * RES_UNIT);  // 9 .. 81

    wire res_region = (res_cnt != 16'd0) && de1 &&
                      (py1 >= RES_Y0) && (py1 < RES_Y0 + RES_H) &&
                      (px1 >= RES_X0) && (px1 < RES_R);
    wire res_border = res_region &&
                      ((py1 == RES_Y0) || (py1 == RES_Y0 + RES_H - 12'd1) ||
                       (px1 == RES_X0) || (px1 == RES_R - 12'd1));
    wire res_active = res_region && ~res_border &&
                      (px1 >= res_inner_l) && (px1 < res_fill_r[11:0]);

    //--------------------------------------------------------------
    // 轮播/手动 状态卡区域命中(左上第 3 行 y28..51; 40×24)
    //   自动轮播 = 绿框 + 绿"播放三角 ▶"(左底边 x24 固定, 最宽 7px, 14 行)
    //   手动单张 = 橙框 + 橙"暂停双竖条 ▮▮"(x22..25 / x30..33, 12 行)
    //--------------------------------------------------------------
    localparam [11:0] CARD_X0 = 12'd8;
    localparam [11:0] CARD_Y0 = 12'd28;
    localparam [11:0] CARD_W  = 12'd40;
    localparam [11:0] CARD_H  = 12'd24;
    localparam [11:0] CARD_R  = CARD_X0 + CARD_W;   // 48
    localparam [11:0] CARD_B  = CARD_Y0 + CARD_H;   // 52

    wire card_region = (man_cnt != 16'd0) && de1 &&
                       (py1 >= CARD_Y0) && (py1 < CARD_B) &&
                       (px1 >= CARD_X0) && (px1 < CARD_R);
    wire card_border = card_region &&
                       ((py1 == CARD_Y0) || (py1 == CARD_B - 12'd1) ||
                        (px1 == CARD_X0) || (px1 == CARD_R - 12'd1));

    // 播放三角: 行 y33..46 (14 行, 卡内垂直居中); 每行宽度 1+min(dr,13-dr)
    //   dr = 行内偏移 0..13; 宽度 1,2,...,7,7,...,2,1 → 右向三角
    wire        tri_row = (py1 >= 12'd33) && (py1 <= 12'd46);
    wire [4:0]  tri_dr  = py1[4:0] - 5'd33;                    // 仅 tri_row 内有效
    wire [4:0]  tri_rem = 5'd13 - tri_dr;
    wire [4:0]  tri_w   = 5'd1 + ((tri_dr < tri_rem) ? tri_dr : tri_rem);
    wire        tri_pix = tri_row && (px1 >= 12'd24) && (px1 < (12'd24 + tri_w));

    // 暂停双竖条: 行 y34..45, 两根 4px 宽竖条(卡内水平居中)
    wire        man_pix = (py1 >= 12'd34) && (py1 <= 12'd45) &&
                          (((px1 >= 12'd22) && (px1 <= 12'd25)) ||
                           ((px1 >= 12'd30) && (px1 <= 12'd33)));

    wire        card_mark = man_s ? man_pix : tri_pix;
    wire [DATA_W-1:0] card_col = man_s ? C_MAN : C_AUTO;

    //--------------------------------------------------------------
    // 输出仲裁: 亮度条 > 缩放条 > 状态卡 > 淡入淡出×亮度像素
    //   (三块 HUD 在 y 方向互不重叠, 但用 if-else 链明确优先级, 顺序稳定)
    //--------------------------------------------------------------
    reg [DATA_W-1:0] fo;
    always @* begin
        if (bar_region) begin
            if (bar_border)
                fo = C_BAR_BD;
            else if (bar_active)
                fo = C_BAR_FG;
            else
                fo = C_BAR_BG;                       // 未生效档位空槽
        end
        else if (res_region) begin
            if (res_border)
                fo = C_BAR_BD;
            else if (res_active)
                fo = C_RES_FG;                       // 缩放已生效档位(青)
            else
                fo = C_BAR_BG;
        end
        else if (card_region) begin
            if (card_border || card_mark)
                fo = card_col;                       // 卡边 / 播放-暂停图形
            else
                fo = C_CARD_BG;                      // 卡内衬底
        end
        else begin
            if (de1) begin
                fo = {r_o, g_o, b_o};                // 显示有效区: 亮度×淡入淡出
            end
            else begin
                fo = da1;                            // 消隐区: 维持原值即可(不关心)
            end
        end
    end

    assign hs_o   = hs1;
    assign vs_o   = vs1;
    assign de_o   = de1;
    assign data_o = fo;

endmodule
