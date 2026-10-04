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
//      · 音量条   : 2026-09-28 新增。档位变化 / 切到音量模式 → 左上 16 档图形条
//                   (盒 x8..144, y56..63; 与亮度条完全同构, 仅行位不同,
//                    已生效档位填充色为绿, 与亮度(金)/缩放(青)区分)
//      · 对比度条 : 2026-10-02 新增。档位变化 / 切到"对比度复用槽"→ 左上 16 档条
//                   (盒 x8..144, y64..71; 与亮度/音量条完全同构,
//                    已生效档位填充色为品红, 与亮度(金)/缩放(青)/音量(绿)区分)
//      五个提示区在 y 方向互不重叠, 可同时出现;
//      优先级 亮度 > 缩放 > 音量 > 对比度 > 状态卡。
//      提示色固定, 不随本帧亮度/对比度增益变化, 保证可读。
//
//   4. ★分辨率字幕(2026-10-02 新增, 配合 bmp_read_auto 多分辨率支持):
//      当前显示图的**源**分辨率(320x240 / 640x480 / 1024x768 / 1280x960)
//      发生变化时, 在**右上角**弹出一块小字幕牌(内嵌 5×7 点阵, 显示"宽x高"),
//      默认 1 秒后自动消失(RESW_HOLD_FRAMES=60 帧 @60fps), 行为与左上角亮度条
//      一致(变化即弹)。四档字符串长度 6 或 8 字符, 由 resw_len 选择。
//      · 分辨率码 img_res[1:0] 来自 sd 域(bmp_read_auto 在整帧读完时锁存),
//        模块内两级同步后做边沿检测;
//        (注: sd 域 2bit 总线过域理论上可能采到中间态, 后果仅是 1 帧的字幕牌
//         文字为相邻档位 → 下一拍即自纠正, 且 resw_cnt 会重装; 源值每次跳变
//         间隔 ≥ 一个轮播周期(秒级), 实际不可见。原 1bit img_2x 亦同此结构。)
//      · 字幕牌与其余 HUD 在 x/y 上互不重叠(右上 x≈564..631, y=6..17),
//        凌驾于淡入淡出之上(与亮度条同层), 固定色不受亮度增益影响。
//
//   5. ★对比度调节(2026-10-02 新增, 补齐赛题扩展要求"亮度/对比度/OSD"):
//      16 档(con_level 0..15, 默认 8 = ×1.0), 绕 8bit 中点 128 旋转斜率,
//      与亮度(stage1, 整体增益)正交:
//        d = pixel - 128;   out = clamp(pixel + ((d * (c-8)) >>> 3))
//      c=8 → 系数 0 → 严格直通(无量化误差); c>8 反差增强; c<8 拉向中灰;
//      c=0 → 系数 -8/8 = -1 → 恒输出 128(全灰, 极端档可见)。
//      档位来自 sd 域 ui_key_ctrl 的"对比度复用槽"(迎新场景模式4 /
//      应急场景模式2; 见 ui_key_ctrl 文件头), 本模块两级同步。
//      有符号运算沿用 bmp_scale 的 $signed 写法(TD/ModelSim 均支持)。
//      HUD: 左上第 5 行 y64..71 的 16 档对比度条(品红, 与亮度/音量条同构)。
//
// 混合公式 :
//   stage1   亮度  : b1 = clamp((pix * g + 64) >> 7)
//   stage1.5 对比度: b2 = clamp(b1 + ((b1-128) * (con-8) >>> 3))  (con=8 → 严格直通)
//   stage2   淡入  : out = (b2 * alpha + 128) >> 8   (alpha 255=全显, 0=黑)
//   提示 HUD 在 stage2 之后叠加(固定色)。
// 数据管线 : 输入寄存 1 拍(da1/px1/sync1)后组合仲裁直接输出 →
//            整体恒定延迟 1 clk, 与 hs/vs/de 严格同拍。
// 控制输入 : menu_active/bmp_busy/bri_level/vol_level/con_level/res_level/
//            pic_manual/ui_mode 均来自 sd_card_clk(100MHz)域电平, 模块内两级同步器过域。
// 语言     : 纯 Verilog-2001(兼容 TD EDA 与 ModelSim)。
//====================================================================

`timescale 1ns/1ps

module display_adjust #(
    parameter DATA_W         = 24,
    parameter H_ACT          = 640,
    parameter V_ACT          = 480,
    // ---- 淡入淡出 ----
    // ★FADE_STEP 必须为 64: stage2 的 alpha 混合已按"alpha 只取
    //   {0,63,64,127,128,191,192,255}"做了移位退化解码(见 stage2 处),
    //   改 FADE_STEP 会使该式不再等价, 必须同时恢复 8×8 乘法写法。
    parameter [7:0] FADE_STEP = 8'd64,   // 半程 4 帧(255→0 用 64/帧步进)
    // ★下列 4 个帧计数参数必须 ≤ 62: 内部 blk_fr/bar_cnt/res_cnt/man_cnt
    //   只保留 6 位(最大值 63)。若任一参数改到 ≥64, 必须同步加宽这 4 个 reg。
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
    // ---- 音量条(2026-09-28 新增) ----
    parameter [15:0] VOL_HOLD_FRAMES = 16'd30, // 音量档变化后条保持帧数
    // ---- 对比度条(2026-10-02 新增) ----
    // ★须 ≤62: 内部 con_cnt 只保留 6 位(同其余 *_HOLD_FRAMES 前提)
    parameter [15:0] CON_HOLD_FRAMES = 16'd30, // 对比度档变化后条保持帧数
    parameter [2:0]  MODE_PIC = 3'd0,    // 与 ui_key_ctrl 一致的模式编码
    parameter [2:0]  MODE_BRI = 3'd1,
    parameter [2:0]  MODE_RES = 3'd2,
    parameter [2:0]  MODE_PERIOD = 3'd3, // 批次4: 轮播周期档(不弹 HUD)
    parameter [2:0]  MODE_MEET = 3'd4,   // 会议计时档(2026-09-19: 不弹 HUD)
    parameter [2:0]  MODE_VOL  = 3'd5,   // 音量档(2026-09-28: 音量条 HUD)
    parameter [2:0]  MODE_CON  = 3'd6,   // 对比度档(2026-10-02: 对比度条 HUD;
                                         //   ui_key_ctrl 复用槽上报的 hud_mode)
    // ---- 分辨率字幕(2026-10-02, 配合 bmp_read_auto 多分辨率支持) ----
    // ★须 ≤62: 内部 resw_cnt 只保留 6 位(同其余 *_HOLD_FRAMES 前提)
    parameter [15:0] RESW_HOLD_FRAMES = 16'd60  // 分辨率变化后字幕保持帧数(≈1s @60fps)
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
    input        [3:0]   vol_level,      // 音量档 0..15(默认 8, 模式5 调; 仅用于音量条 HUD)
    input        [3:0]   con_level,      // 对比度档 0..15(默认 8=×1.0; 2026-10-02,
                                         //   ui_key_ctrl 复用槽: 迎新模式4/应急模式2)
    input        [3:0]   res_level,      // 缩放档 0..7(默认 4=100%)
    input        [1:0]   img_res,        // 当前显示图源分辨率码 0=320x240 1=640x480
                                         //                    2=1024x768 3=1280x960
                                         // (2026-10-02 由 1bit img_2x 扩为 2bit 四档)
    input                pic_manual,     // 1=手动单张 / 0=自动轮播
    input        [2:0]   ui_mode,        // 展示模式码(ui_key_ctrl 的 hud_mode):
                                         //   0图片/1亮度/2缩放/3周期/4会议/5音量/6对比度
                                         //   ★接 hud_mode 而非内部 mode, 否则复用槽
                                         //     (迎新模式4/应急模式2)调节时会弹错 HUD
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
    localparam [DATA_W-1:0] C_VOL_FG = 24'h35_D6_7A;  // 音量已生效档位(绿, 2026-09-28)
    localparam [DATA_W-1:0] C_CON_FG = 24'hB4_7C_FF;  // 对比度已生效档位(品红, 2026-10-02)
    localparam [DATA_W-1:0] C_CARD_BG= 24'h0A_10_18;  // 状态卡底(更深的蓝黑)
    localparam [DATA_W-1:0] C_AUTO   = 24'h22_C5_5E;  // 自动轮播: 卡边 + 播放三角(绿)
    localparam [DATA_W-1:0] C_MAN    = 24'hFF_A0_28;  // 手动单张: 卡边 + 暂停双条(橙)
    localparam [DATA_W-1:0] C_RESW_TX= 24'hE4_F0_FF;  // 分辨率字幕文字(近白, 2026-10-02)

    //--------------------------------------------------------------
    // 控制电平过域(两级同步; bri_level 4bit)
    //--------------------------------------------------------------
    reg  m_s0, m_s1, e_s0, e_s1, b_s0, b_s1;
    reg  [3:0] l_s0, l_s1;
    reg  [3:0] r_s0, r_s1;      // 缩放(分辨率)档 0..7
    reg  [3:0] v_s0, v_s1;      // 音量档 0..15(2026-09-28)
    reg  [3:0] c_s0, c_s1;      // 对比度档 0..15(2026-10-02)
    reg        p_s0, p_s1;      // 轮播(0)/手动(1)
    reg  [2:0] u_s0, u_s1;      // 展示模式码 0图片/1亮度/2缩放/3周期/4会议/5音量/6对比度
    reg  [1:0] x_s0, x_s1;      // 源分辨率码(2026-10-02; 原 1bit img_2x 扩为四档)
    wire menu_s  = m_s1;
    wire emerg_s = e_s1;
    wire busy_s  = b_s1;
    wire [3:0] lvl_s  = l_s1;
    wire [3:0] res_s  = r_s1;
    wire [3:0] vol_s  = v_s1;
    wire [3:0] con_s  = c_s1;
    wire       man_s  = p_s1;
    wire [2:0] mode_s = u_s1;
    wire [1:0] imgres_s = x_s1;   // 过域后的源分辨率码(0..3)

    always @(posedge video_clk or posedge rst) begin
        if (rst) begin
            // 复位初值对齐系统默认态(菜单 active / 非应急 / 忙未知 / 亮度档8
            // / 缩放档4=100% / 自动轮播 / 图片模式), 防止上电同步过程产生
            // 假边沿(假淡出 / 假提示条)
            m_s0<=1'b1; m_s1<=1'b1; e_s0<=1'b0; e_s1<=1'b0;
            b_s0<=1'b0; b_s1<=1'b0; l_s0<=4'd8; l_s1<=4'd8;
            r_s0<=4'd4; r_s1<=4'd4;
            v_s0<=4'd8; v_s1<=4'd8;
            c_s0<=4'd8; c_s1<=4'd8;
            p_s0<=1'b0; p_s1<=1'b0;
            u_s0<=MODE_PIC; u_s1<=MODE_PIC;
            x_s0<=2'd1; x_s1<=2'd1;   // 复位默认 640×480(码1), 防上电假字幕
        end
        else begin
            m_s0<=menu_active; m_s1<=m_s0;
            e_s0<=emerg;       e_s1<=e_s0;
            b_s0<=bmp_busy;    b_s1<=b_s0;
            l_s0<=bri_level;   l_s1<=l_s0;
            r_s0<=res_level;   r_s1<=r_s0;
            v_s0<=vol_level;   v_s1<=v_s0;
            c_s0<=con_level;   c_s1<=c_s0;
            p_s0<=pic_manual;  p_s1<=p_s0;
            u_s0<=ui_mode;     u_s1<=u_s0;
            x_s0<=img_res;     x_s1<=x_s0;
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
    // 帧计数只用 6 位: 上界分别由 TIMEOUT_FRAMES(45) / *_HOLD_FRAMES(30) 决定,
    // 均 ≤ 62 → 不会回绕, 与 16 位计数逐位等价(参数前提见模块头注释)。
    reg [5:0]  blk_fr;         // 黑场已等待帧数(超时计数)
    reg        menu_past;      // 上一拍 menu_active(同步域, 边沿检测)
    reg        menu_evt;       // 粘性翻转事件(帧边界消费)
    reg [3:0]  lvl_past;     // 上一拍亮度档(变化 → 显示亮度条)
    reg [5:0]  bar_cnt;        // 亮度条剩余显示帧数(0=隐藏)
    reg [3:0]  res_past;     // 上一拍缩放档(变化 → 显示缩放条)
    reg [5:0]  res_cnt;        // 缩放条剩余显示帧数(0=隐藏)
    reg [3:0]  vol_past;     // 上一拍音量档(变化 → 显示音量条, 2026-09-28)
    reg [5:0]  vol_cnt;        // 音量条剩余显示帧数(0=隐藏)
    reg [3:0]  con_past;     // 上一拍对比度档(变化 → 显示对比度条, 2026-10-02)
    reg [5:0]  con_cnt;        // 对比度条剩余显示帧数(0=隐藏)
    reg        man_past;      // 上一拍轮播/手动标志(变化 → 显示状态卡)
    reg [5:0]  man_cnt;        // 状态卡剩余显示帧数(0=隐藏)
    reg [2:0]  mode_past;     // 上一拍功能模式(切换 → 弹该模式的提示)
    reg [1:0]  x_past;        // 上一拍分辨率码(变化 → 弹分辨率字幕, 2026-10-02)
    reg [5:0]  resw_cnt;       // 分辨率字幕剩余显示帧数(0=隐藏; ★只用 6 位 ≤62)

    always @(posedge video_clk or posedge rst) begin
        if (rst) begin
            fsm        <= FIDLE;
            alpha      <= 8'd255;
            blk_fr     <= 6'd0;
            menu_past  <= 1'b1;       // 复位默认菜单态(与 scene_control 一致), 防上电假淡出
            menu_evt   <= 1'b0;
            lvl_past   <= 4'd8;
            bar_cnt    <= 6'd0;
            res_past   <= 4'd4;
            res_cnt    <= 6'd0;
            vol_past   <= 4'd8;
            vol_cnt    <= 6'd0;
            con_past   <= 4'd8;
            con_cnt    <= 6'd0;
            man_past   <= 1'b0;
            man_cnt    <= 6'd0;
            mode_past  <= MODE_PIC;
            x_past     <= 2'd1;      // 默认 640x480(码1), 防上电假字幕
            resw_cnt   <= 6'd0;
        end
        else begin
            // ---- 事件锁存(逐拍检测, 与帧边界无关) ----
            if (menu_s != menu_past)
                menu_evt <= 1'b1;                 // 场景切换事件(粘性)
            menu_past <= menu_s;

            if (lvl_s != lvl_past)
                bar_cnt <= BAR_HOLD_FRAMES[5:0];   // 亮度档变化 → 显示亮度条
            lvl_past  <= lvl_s;

            if (res_s != res_past)
                res_cnt <= RES_HOLD_FRAMES[5:0];   // 缩放档变化 → 显示缩放条
            res_past  <= res_s;

            if (vol_s != vol_past)
                vol_cnt <= VOL_HOLD_FRAMES[5:0];   // 音量档变化 → 显示音量条
            vol_past  <= vol_s;

            if (con_s != con_past)
                con_cnt <= CON_HOLD_FRAMES[5:0];   // 对比度档变化 → 显示对比度条
            con_past  <= con_s;

            if (man_s != man_past)
                man_cnt <= MAN_HOLD_FRAMES[5:0];   // 轮播↔手动 → 显示状态卡
            man_past  <= man_s;

            // 源分辨率变化(320x240 / 640x480 / 1024x768 / 1280x960 四档)
            //   → 右上角字幕弹 1s(码变化即弹; 2026-10-02 由 1bit 扩为 2bit 四档)
            if (imgres_s != x_past)
                resw_cnt <= RESW_HOLD_FRAMES[5:0];
            x_past   <= imgres_s;

            // ---- 功能模式切换: 弹出"当前在调什么"的提示(便于现场确认) ----
            if (mode_s != mode_past) begin
                case (mode_s)
                    MODE_BRI: bar_cnt <= BAR_HOLD_FRAMES[5:0];  // 切到亮度模式 → 亮度条
                    MODE_RES: res_cnt <= RES_HOLD_FRAMES[5:0];  // 切到分辨率模式 → 缩放条
                    MODE_PERIOD: ;                          // 周期档(批次4): 弹窗沿用
                                                            // 上一条提示, 不额外弹卡
                    MODE_MEET:   ;                          // 会议计时档: 不弹 HUD
                                                            // (会议画面自带完整面板)
                    MODE_VOL:  vol_cnt <= VOL_HOLD_FRAMES[5:0]; // 切到音量模式 → 音量条
                    MODE_CON:  con_cnt <= CON_HOLD_FRAMES[5:0]; // 切到对比度槽 → 对比度条
                                                                // (2026-10-02)
                    default : man_cnt <= MAN_HOLD_FRAMES[5:0];  // 切到图片模式 → 轮播/手动卡
                endcase
            end
            mode_past <= mode_s;

            if (vs_rise) begin
                // 提示条倒计时(每帧 -1)
                if (bar_cnt != 6'd0)
                    bar_cnt <= bar_cnt - 6'd1;
                if (res_cnt != 6'd0)
                    res_cnt <= res_cnt - 6'd1;
                if (vol_cnt != 6'd0)
                    vol_cnt <= vol_cnt - 6'd1;
                if (con_cnt != 6'd0)
                    con_cnt <= con_cnt - 6'd1;
                if (man_cnt != 6'd0)
                    man_cnt <= man_cnt - 6'd1;
                if (resw_cnt != 6'd0)
                    resw_cnt <= resw_cnt - 6'd1;

                if (emerg_s) begin
                    // 应急: 最高优先级即刻响应, 禁止淡出, 并丢弃待处理事件
                    fsm      <= FIDLE;
                    alpha    <= 8'd255;
                    blk_fr   <= 6'd0;
                    menu_evt <= 1'b0;
                end
                else begin
                    case (fsm)
                    FIDLE: begin
                        blk_fr <= 6'd0;
                        if (menu_evt) begin
                            menu_evt <= 1'b0;
                            fsm      <= FOUT;       // 场景切换事件 → 开始淡出
                        end
                    end
                    FOUT: begin
                        if (alpha <= FADE_STEP) begin
                            alpha <= 8'd0;       // 降到全黑
                            fsm   <= FBLCK;
                            blk_fr<= 6'd0;
                        end
                        else
                            alpha <= alpha - FADE_STEP;
                    end
                    FBLCK: begin
                        // 等底层新分区图写完(忙释放)或超时, 防呆黑
                        if (~busy_s || (blk_fr >= TIMEOUT_FRAMES[5:0])) begin
                            fsm <= FIN;
                        end
                        else
                            blk_fr <= blk_fr + 6'd1;
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
    // 区域命中比较用的窄化坐标(面积优化 2026-09-21)
    //   px_x/px_y 源头是 osd_engine 的像素计数器: de=1 时 x∈[0,639]、y∈[0,479];
    //   之后整条链(osd_menu/osd_welcome/osd_scene → meeting_osd →
    //   emergency_multi_overlay → audio_viz_overlay → diag_overlay)只把
    //   x/y/de 一起按时钟平移, 从不改写坐标值。故本模块 de1=1 时恒有
    //   px1[11:10]=0、py1[11:9]=0 → 用窄位比较与 12 位比较逐位等价,
    //   且比较器高位被综合按常量剪掉, 省 LUT/进位链。
    //   全部三块 HUD 的区域判断都含 de1 门控, 消隐期坐标被截也不参与命中。
    //   ★px1 绝不可只取 8 位: HUD 盒在 x<150, 而 x=400 截 8 位=144 会误命中。
    //--------------------------------------------------------------
    wire [9:0] px1n = px1[9:0];
    wire [8:0] py1n = py1[8:0];

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

    //--------------------------------------------------------------
    // stage1.5: 对比度(2026-10-02 新增; 档位来自 ui_key_ctrl 复用槽)
    //   out = clamp(in + ((in - 128) * (c - 8)) >>> 3)
    //     · c = 8 → 系数 0 → 严格直通(out == in, 与未加对比度逐位相同)
    //     · c > 8 → 绕中点 128 放大反差(斜率 >1, 暗部更暗/亮部更亮)
    //     · c < 8 → 斜率 <1, 拉向中灰(反差变弱)
    //     · c = 0 → 系数 -1 → 恒 128(全灰, 极端档, 用于直观确认"确实在作用")
    //   与 stage1 亮度正交: 亮度是整体增益(整条曲线平移/缩放),
    //   对比度是绕 128 的斜率旋转。两级串接顺序(先亮后对比)与 HUD 说明一致。
    //   有符号运算沿用 bmp_scale 的 $signed 写法(TD/ModelSim 均支持)。
    //   数值域: in-128 ∈ [-128,127]; c-8 ∈ [-8,+7]; 积 ∈ [-1024,896] (13bit 够);
    //           >>>3 后 ∈ [-128,112]; 加回 in(0..255) → [-128,367],
    //           10bit 有符号(±512)不溢出, 再饱和钳到 0..255。
    //--------------------------------------------------------------
    wire signed [8:0]  r_d = $signed({1'b0, r_b}) - 9'sd128;
    wire signed [8:0]  g_d = $signed({1'b0, g_b}) - 9'sd128;
    wire signed [8:0]  b_d = $signed({1'b0, b_b}) - 9'sd128;
    // ★位宽必须 5 位: con_s∈[0,15] 是"无符号 4 位", 若直接 $signed(con_s)
    //   会被当成 4 位有符号 → 8..15 变成 -8..-1, 档位整体错乱。
    //   先零扩展成 5 位再取有符号, 才能正确覆盖 -8..+7。
    wire signed [4:0]  con_off = $signed({1'b0, con_s}) - 5'sd8;   // -8..+7

    wire signed [12:0] r_cp = r_d * con_off;
    wire signed [12:0] g_cp = g_d * con_off;
    wire signed [12:0] b_cp = b_d * con_off;
    wire signed [12:0] r_cq = r_cp >>> 3;
    wire signed [12:0] g_cq = g_cp >>> 3;
    wire signed [12:0] b_cq = b_cp >>> 3;
    wire signed [9:0]  r_cs = $signed({1'b0, r_b}) + r_cq[9:0];
    wire signed [9:0]  g_cs = $signed({1'b0, g_b}) + g_cq[9:0];
    wire signed [9:0]  b_cs = $signed({1'b0, b_b}) + b_cq[9:0];
    wire [7:0]  r_c = (r_cs > 10'sd255) ? 8'd255 :
                      (r_cs < 10'sd0)   ? 8'd0   : r_cs[7:0];
    wire [7:0]  g_c = (g_cs > 10'sd255) ? 8'd255 :
                      (g_cs < 10'sd0)   ? 8'd0   : g_cs[7:0];
    wire [7:0]  b_c = (b_cs > 10'sd255) ? 8'd255 :
                      (b_cs < 10'sd0)   ? 8'd0   : b_cs[7:0];

    // stage2: 淡入淡出 alpha 混合(乘加取整)
    //   alpha==255 时直通(此时 FIDLE 稳态/淡入完成), 避免 (x*255+128)>>8
    //   对高亮像素产生 -1 量化误差, 保证平时显示与"亮度+对比度后"像素逐位一致
    //   (2026-10-02: 输入由 stage1 的 b 改为 stage1.5 的 c; α=255 时 c=8 档
    //    仍严格等于原始像素, 故"不加对比度时观感与之前完全一致"成立)
    //
    //   面积优化(2026-09-21): FADE_STEP=64 时 alpha 每帧按 64 步进, 实际取值
    //   只有 8 个: {0,63,64,127,128,191,192,255}。对这 8 个值有恒等式
    //       alpha = 64*am - aodd,   am = alpha[7:6] + alpha[0] (0..4),
    //                               aodd = alpha[0]            (α=0 时 am 自动为 0)
    //   逐个核对: 0→0*64-0, 63→1*64-1, 64→1*64-0, 127→2*64-1,
    //             128→2*64-0, 191→3*64-1, 192→3*64-0, 255→4*64-1  ✓
    //   于是 b*alpha = ((b*am)<<6) - aodd*b, 3bit×8bit 只需 1 个移位 + 1 个条件
    //   减法, 3 个通道共省下 3 个 8×8 乘法器。α=255 仍走原直通旁路(未变)。
    //   ★前提: FADE_STEP 必须为 64(见模块头注释)。
    wire [2:0]  am   = {1'b0, alpha[7:6]} + {2'b0, alpha[0]};   // 0..4
    wire        aodd = alpha[0];
    // x_m = x_c * am (am≤4 → ≤1020, 10 位足够)
    wire [9:0]  r_m = am[2] ? {r_c, 2'b00} :
                      am[1] ? (am[0] ? ({r_c,1'b0} + {1'b0,r_c}) : {r_c,1'b0})
                            : (am[0] ? {1'b0,r_c} : 10'd0);
    wire [9:0]  g_m = am[2] ? {g_c, 2'b00} :
                      am[1] ? (am[0] ? ({g_c,1'b0} + {1'b0,g_c}) : {g_c,1'b0})
                            : (am[0] ? {1'b0,g_c} : 10'd0);
    wire [9:0]  b_m = am[2] ? {b_c, 2'b00} :
                      am[1] ? (am[0] ? ({b_c,1'b0} + {1'b0,b_c}) : {b_c,1'b0})
                            : (am[0] ? {1'b0,b_c} : 10'd0);
    // (x_m<<6) ≤ 1020*64 = 65280, 减 aodd*x_c 后再 +128 ≤ 65408 < 65536
    // → 16 位中间量不溢出, 与 (x_c*alpha + 128)>>8 逐位相同
    wire [15:0] r_f = (({6'b0,r_m} << 6) - (aodd ? {8'b0,r_c} : 16'd0) + 16'd128) >> 8;
    wire [15:0] g_f = (({6'b0,g_m} << 6) - (aodd ? {8'b0,g_c} : 16'd0) + 16'd128) >> 8;
    wire [15:0] b_f = (({6'b0,b_m} << 6) - (aodd ? {8'b0,b_c} : 16'd0) + 16'd128) >> 8;
    wire [7:0]  r_o = (alpha == 8'd255) ? r_c : r_f[7:0];
    wire [7:0]  g_o = (alpha == 8'd255) ? g_c : g_f[7:0];
    wire [7:0]  b_o = (alpha == 8'd255) ? b_c : b_f[7:0];

    //--------------------------------------------------------------
    // 亮度条区域命中(左上角)
    //   盒 [X0, X0+2+INNER_W) × [Y0, Y0+BAR_H); 最外 1px=描边;
    //   内区宽 INNER_W = (BAR_MAXL-1)*UNIT = 15*9 = 135px = 15 个档位格
    //   (档 0..15, L=15 恰好填满整条; L=0 全空)。
    //   生效档位填充 [inner_l, inner_l + L*UNIT)。
    //--------------------------------------------------------------
    wire bar_show = (bar_cnt != 6'd0);
    localparam [11:0] BAR_INNER_W = 12'd135;   // (16-1)*9, 满档=15 格
    localparam [11:0] BAR_R = BAR_X0 + 12'd2 + BAR_INNER_W;  // 盒右(不含)
    localparam [11:0] inner_l = BAR_X0 + 12'd1;              // 内区左
    // 生效档右(不含): 原式 inner_l + lvl_s*BAR_UNIT。★前提: BAR_X0=8(→inner_l=9)
    // 且 BAR_UNIT=9(二者均为本模块参数默认值, 全工程例化未改写), 于是
    //   inner_l + lvl_s*9 = 9*(lvl_s+1) = 8*(lvl_s+1) + (lvl_s+1)
    // → 4bit×常量乘法退化为"移位+加", 且内区左偏移并入 +1, 少一级加法器。
    // 数值域: lvl_s∈[0,15] → fill_r∈[9,144], 9 位足够, 无溢出/截断。
    wire [4:0]  lvl_p1 = {1'b0, lvl_s} + 5'd1;              // 1..16
    wire [8:0]  fill_r = {lvl_p1, 3'b000} + {4'b0, lvl_p1}; // = 9*(lvl_s+1)

    wire bar_region = bar_show && de1 &&
                      (py1n >= BAR_Y0) && (py1n < BAR_Y0 + BAR_H) &&
                      (px1n >= BAR_X0) && (px1n < BAR_R);
    wire bar_border = bar_region &&
                      ((py1n == BAR_Y0) || (py1n == BAR_Y0 + BAR_H - 12'd1) ||
                       (px1n == BAR_X0) || (px1n == BAR_R - 12'd1));
    wire bar_active = bar_region && ~bar_border &&
                      (px1n < fill_r) && (px1n >= inner_l);

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

    // 生效档右(不含): 原式 res_inner_l + (res_s+1)*RES_UNIT。★前提: RES_X0=8
    // (→res_inner_l=9) 且 RES_UNIT=9(均为本模块 localparam 默认值), 于是
    //   res_inner_l + (res_s+1)*9 = 9*(res_s+2) = 8*(res_s+2) + (res_s+2)
    // → 级联乘法退化为"移位+加"。数值域: res_s∈[0,7] → 9*(res_s+2)∈[18,81],
    // 9 位足够, 无溢出(原 [12:0] 取值亦 ≤81, 截取 [11:0] 无损失)。
    wire [4:0]  res_p2 = {1'b0, res_s} + 5'd2;                 // 2..9
    wire [8:0]  res_fill_r = {res_p2, 3'b000} + {4'b0, res_p2}; // = 9*(res_s+2)

    wire res_region = (res_cnt != 6'd0) && de1 &&
                      (py1n >= RES_Y0) && (py1n < RES_Y0 + RES_H) &&
                      (px1n >= RES_X0) && (px1n < RES_R);
    wire res_border = res_region &&
                      ((py1n == RES_Y0) || (py1n == RES_Y0 + RES_H - 12'd1) ||
                       (px1n == RES_X0) || (px1n == RES_R - 12'd1));
    wire res_active = res_region && ~res_border &&
                      (px1n >= res_inner_l) && (px1n < res_fill_r);

    //--------------------------------------------------------------
    // 音量条区域命中(左上第 4 行 y56..63; 与亮度条完全同构, 2026-09-28)
    //   盒 [VOL_X0, VOL_R) × [VOL_Y0, VOL_Y0+VOL_H); 内宽 = 15*9 = 135px
    //   生效档右(不含) = 9*(vol_s+1) (同亮度条, 乘法退化为移位+加)
    //   行位取 y56..63: 在状态卡(y28..51)下方, 四块 HUD 互不重叠。
    //--------------------------------------------------------------
    localparam [11:0] VOL_X0      = 12'd8;
    localparam [11:0] VOL_Y0      = 12'd56;
    localparam [11:0] VOL_H       = 12'd8;
    localparam [11:0] VOL_INNER_W = 12'd135;                        // (16-1)*9
    localparam [11:0] VOL_R       = VOL_X0 + 12'd2 + VOL_INNER_W;   // 145
    localparam [11:0] vol_inner_l = VOL_X0 + 12'd1;                 // 9

    wire [4:0]  vol_p1 = {1'b0, vol_s} + 5'd1;                  // 1..16
    wire [8:0]  vol_fill_r = {vol_p1, 3'b000} + {4'b0, vol_p1}; // = 9*(vol_s+1)

    wire vol_show = (vol_cnt != 6'd0);
    wire vol_region = vol_show && de1 &&
                      (py1n >= VOL_Y0) && (py1n < VOL_Y0 + VOL_H) &&
                      (px1n >= VOL_X0) && (px1n < VOL_R);
    wire vol_border = vol_region &&
                      ((py1n == VOL_Y0) || (py1n == VOL_Y0 + VOL_H - 12'd1) ||
                       (px1n == VOL_X0) || (px1n == VOL_R - 12'd1));
    wire vol_active = vol_region && ~vol_border &&
                      (px1n >= vol_inner_l) && (px1n < vol_fill_r);

    //--------------------------------------------------------------
    // 对比度条区域命中(左上第 5 行 y64..71; 与亮度条同构, 2026-10-02)
    //   盒 [CON_X0, CON_R) × [CON_Y0, CON_Y0+CON_H); 内宽 = 15*9 = 135px
    //   生效档右(不含) = 9*(con_s+1) (同亮度/音量条, 乘法退化为移位+加)
    //   行位取 y64..71: 在音量条(y56..63)下方, 五块 HUD 互不重叠。
    //   ★画布高度: 本 HUD 使覆盖区下探到 y71 → 对应 TB 画布高须 ≥72。
    //--------------------------------------------------------------
    localparam [11:0] CON_X0      = 12'd8;
    localparam [11:0] CON_Y0      = 12'd64;
    localparam [11:0] CON_H       = 12'd8;
    localparam [11:0] CON_INNER_W = 12'd135;                        // (16-1)*9
    localparam [11:0] CON_R       = CON_X0 + 12'd2 + CON_INNER_W;   // 145
    localparam [11:0] con_inner_l = CON_X0 + 12'd1;                 // 9

    wire [4:0]  con_p1 = {1'b0, con_s} + 5'd1;                  // 1..16
    wire [8:0]  con_fill_r = {con_p1, 3'b000} + {4'b0, con_p1}; // = 9*(con_s+1)

    wire con_show = (con_cnt != 6'd0);
    wire con_region = con_show && de1 &&
                      (py1n >= CON_Y0) && (py1n < CON_Y0 + CON_H) &&
                      (px1n >= CON_X0) && (px1n < CON_R);
    wire con_border = con_region &&
                      ((py1n == CON_Y0) || (py1n == CON_Y0 + CON_H - 12'd1) ||
                       (px1n == CON_X0) || (px1n == CON_R - 12'd1));
    wire con_active = con_region && ~con_border &&
                      (px1n >= con_inner_l) && (px1n < con_fill_r);

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

    wire card_region = (man_cnt != 6'd0) && de1 &&
                       (py1n >= CARD_Y0) && (py1n < CARD_B) &&
                       (px1n >= CARD_X0) && (px1n < CARD_R);
    wire card_border = card_region &&
                       ((py1n == CARD_Y0) || (py1n == CARD_B - 12'd1) ||
                        (px1n == CARD_X0) || (px1n == CARD_R - 12'd1));

    // 播放三角: 行 y33..46 (14 行, 卡内垂直居中); 每行宽度 1+min(dr,13-dr)
    //   dr = 行内偏移 0..13; 宽度 1,2,...,7,7,...,2,1 → 右向三角
    //   (tri_pix/man_pix 只在 card_region 内被采用, 故同样可用窄化坐标)
    wire        tri_row = (py1n >= 9'd33) && (py1n <= 9'd46);
    wire [4:0]  tri_dr  = py1[4:0] - 5'd33;                    // 仅 tri_row 内有效
    wire [4:0]  tri_rem = 5'd13 - tri_dr;
    wire [4:0]  tri_w   = 5'd1 + ((tri_dr < tri_rem) ? tri_dr : tri_rem);
    wire        tri_pix = tri_row && (px1n >= 10'd24) && (px1n < (10'd24 + tri_w));

    // 暂停双竖条: 行 y34..45, 两根 4px 宽竖条(卡内水平居中)
    wire        man_pix = (py1n >= 9'd34) && (py1n <= 9'd45) &&
                          (((px1n >= 10'd22) && (px1n <= 10'd25)) ||
                           ((px1n >= 10'd30) && (px1n <= 10'd33)));

    wire        card_mark = man_s ? man_pix : tri_pix;
    wire [DATA_W-1:0] card_col = man_s ? C_MAN : C_AUTO;

    //--------------------------------------------------------------
    // 分辨率字幕内嵌 5×7 点阵(2026-10-02; 不占用共享 osd_font_rom/BRAM)
    //   字符码 ch: 0..9 = '0'..'9', 10 = 'x'; row 0..6(上→下)
    //   返回 5 位 = 该行 5 个像素, bit4 为最左像素
    //--------------------------------------------------------------
    function [4:0] resw_glyph;
        input [3:0] ch;
        input [2:0] row;
        begin
            case (ch)
                4'd0: case (row)                        // '0'
                    3'd0: resw_glyph = 5'b01110;
                    3'd1: resw_glyph = 5'b10001;
                    3'd2: resw_glyph = 5'b10011;
                    3'd3: resw_glyph = 5'b10101;
                    3'd4: resw_glyph = 5'b11001;
                    3'd5: resw_glyph = 5'b10001;
                    default: resw_glyph = 5'b01110;
                endcase
                4'd1: case (row)                        // '1'
                    3'd0: resw_glyph = 5'b00100;
                    3'd1: resw_glyph = 5'b01100;
                    3'd2: resw_glyph = 5'b00100;
                    3'd3: resw_glyph = 5'b00100;
                    3'd4: resw_glyph = 5'b00100;
                    3'd5: resw_glyph = 5'b00100;
                    default: resw_glyph = 5'b01110;
                endcase
                4'd2: case (row)                        // '2'
                    3'd0: resw_glyph = 5'b01110;
                    3'd1: resw_glyph = 5'b10001;
                    3'd2: resw_glyph = 5'b00001;
                    3'd3: resw_glyph = 5'b00010;
                    3'd4: resw_glyph = 5'b00100;
                    3'd5: resw_glyph = 5'b01000;
                    default: resw_glyph = 5'b11111;
                endcase
                4'd3: case (row)                        // '3'
                    3'd0: resw_glyph = 5'b11111;
                    3'd1: resw_glyph = 5'b00010;
                    3'd2: resw_glyph = 5'b00100;
                    3'd3: resw_glyph = 5'b00010;
                    3'd4: resw_glyph = 5'b00001;
                    3'd5: resw_glyph = 5'b10001;
                    default: resw_glyph = 5'b01110;
                endcase
                4'd4: case (row)                        // '4'
                    3'd0: resw_glyph = 5'b00010;
                    3'd1: resw_glyph = 5'b00110;
                    3'd2: resw_glyph = 5'b01010;
                    3'd3: resw_glyph = 5'b10010;
                    3'd4: resw_glyph = 5'b11111;
                    3'd5: resw_glyph = 5'b00010;
                    default: resw_glyph = 5'b00010;
                endcase
                4'd5: case (row)                        // '5'
                    3'd0: resw_glyph = 5'b11111;
                    3'd1: resw_glyph = 5'b10000;
                    3'd2: resw_glyph = 5'b11110;
                    3'd3: resw_glyph = 5'b00001;
                    3'd4: resw_glyph = 5'b00001;
                    3'd5: resw_glyph = 5'b10001;
                    default: resw_glyph = 5'b01110;
                endcase
                4'd6: case (row)                        // '6'
                    3'd0: resw_glyph = 5'b00110;
                    3'd1: resw_glyph = 5'b01000;
                    3'd2: resw_glyph = 5'b10000;
                    3'd3: resw_glyph = 5'b11110;
                    3'd4: resw_glyph = 5'b10001;
                    3'd5: resw_glyph = 5'b10001;
                    default: resw_glyph = 5'b01110;
                endcase
                4'd7: case (row)                        // '7'
                    3'd0: resw_glyph = 5'b11111;
                    3'd1: resw_glyph = 5'b00001;
                    3'd2: resw_glyph = 5'b00010;
                    3'd3: resw_glyph = 5'b00100;
                    3'd4: resw_glyph = 5'b01000;
                    3'd5: resw_glyph = 5'b01000;
                    default: resw_glyph = 5'b01000;
                endcase
                4'd8: case (row)                        // '8'
                    3'd0: resw_glyph = 5'b01110;
                    3'd1: resw_glyph = 5'b10001;
                    3'd2: resw_glyph = 5'b10001;
                    3'd3: resw_glyph = 5'b01110;
                    3'd4: resw_glyph = 5'b10001;
                    3'd5: resw_glyph = 5'b10001;
                    default: resw_glyph = 5'b01110;
                endcase
                4'd9: case (row)                        // '9'
                    3'd0: resw_glyph = 5'b01110;
                    3'd1: resw_glyph = 5'b10001;
                    3'd2: resw_glyph = 5'b10001;
                    3'd3: resw_glyph = 5'b01111;
                    3'd4: resw_glyph = 5'b00001;
                    3'd5: resw_glyph = 5'b00010;
                    default: resw_glyph = 5'b01100;
                endcase
                4'd10: case (row)                       // 'x'
                    3'd0: resw_glyph = 5'b00000;
                    3'd1: resw_glyph = 5'b00000;
                    3'd2: resw_glyph = 5'b10001;
                    3'd3: resw_glyph = 5'b01010;
                    3'd4: resw_glyph = 5'b00100;
                    3'd5: resw_glyph = 5'b01010;
                    default: resw_glyph = 5'b10001;
                endcase
                default: resw_glyph = 5'b00000;
            endcase
        end
    endfunction

    //--------------------------------------------------------------
    // 分辨率字幕区域命中(右上角; 2026-10-02)
    //   盒 [RESW_X0, RESW_R) × [RESW_Y0, RESW_B); 1px 描边;
    //   内区用 5×7 点阵拼 "640x480"(1× 源) 或 "1280x960"(2× 源),
    //   字符步距 6px(5px 字宽 + 1px 间隔), 与亮度条同层(后叠于淡入淡出)。
    //--------------------------------------------------------------
    localparam [11:0] RESW_X0 = 12'd564;
    localparam [11:0] RESW_Y0 = 12'd6;
    localparam [11:0] RESW_W  = 12'd68;
    localparam [11:0] RESW_H  = 12'd12;
    localparam [11:0] RESW_R  = RESW_X0 + RESW_W;   // 632
    localparam [11:0] RESW_B  = RESW_Y0 + RESW_H;   // 18
    localparam [11:0] RESW_IL = RESW_X0 + 12'd2;    // 566 内区左
    localparam [11:0] RESW_IT = RESW_Y0 + 12'd2;    // 8   内区上

    wire resw_show = (resw_cnt != 6'd0);
    wire resw_region = resw_show && de1 &&
                       (py1n >= RESW_Y0) && (py1n < RESW_B) &&
                       (px1n >= RESW_X0) && (px1n < RESW_R);
    wire resw_border = resw_region &&
                       ((py1n == RESW_Y0) || (py1n == RESW_B - 12'd1) ||
                        (px1n == RESW_X0) || (px1n == RESW_R - 12'd1));

    // 内区局部坐标(仅 resw_region 内被采用)
    wire [11:0] resw_lx12 = px1n - RESW_IL;
    wire [11:0] resw_ly12 = py1n - RESW_IT;
    wire [6:0]  resw_lx   = resw_lx12[6:0];     // 0..64
    wire [3:0]  resw_ly   = resw_ly12[3:0];     // 0..9

    wire [3:0]  resw_ci   = resw_lx / 7'd6;     // 字符序号 0..10
    wire [2:0]  resw_bc   = resw_lx % 7'd6;     // 字内列 0..5(5=间隔)
    wire [2:0]  resw_row  = resw_ly[2:0];       // 字行 0..6

    // 字符串长度 = 字符数×6: 320x240/640x480 各 7 字符(42); 1024x768/1280x960 各 8 字符(48)
    //   (内区可用宽 = RESW_W-4 = 64 ≥ 48, 两行都放得下)
    wire [6:0]  resw_len  = (imgres_s >= 2'd2) ? 7'd48 : 7'd42;

    // 按位置/分辨率取字符码(0..9 数字, 10='x')
    //   0="320x240" 1="640x480" 2="1024x768" 3="1280x960"
    reg [3:0] resw_ch;
    always @* begin
        case (imgres_s)
        2'd0: case (resw_ci)            // "320x240"
                4'd0: resw_ch = 4'd3;    // '3'
                4'd1: resw_ch = 4'd2;    // '2'
                4'd2: resw_ch = 4'd0;    // '0'
                4'd3: resw_ch = 4'd10;   // 'x'
                4'd4: resw_ch = 4'd2;    // '2'
                4'd5: resw_ch = 4'd4;    // '4'
                default: resw_ch = 4'd0; // '0'
            endcase
        2'd2: case (resw_ci)            // "1024x768"
                4'd0: resw_ch = 4'd1;    // '1'
                4'd1: resw_ch = 4'd0;    // '0'
                4'd2: resw_ch = 4'd2;    // '2'
                4'd3: resw_ch = 4'd4;    // '4'
                4'd4: resw_ch = 4'd10;   // 'x'
                4'd5: resw_ch = 4'd7;    // '7'
                4'd6: resw_ch = 4'd6;    // '6'
                default: resw_ch = 4'd8; // '8'
            endcase
        2'd3: case (resw_ci)            // "1280x960"
                4'd0: resw_ch = 4'd1;    // '1'
                4'd1: resw_ch = 4'd2;    // '2'
                4'd2: resw_ch = 4'd8;    // '8'
                4'd3: resw_ch = 4'd0;    // '0'
                4'd4: resw_ch = 4'd10;   // 'x'
                4'd5: resw_ch = 4'd9;    // '9'
                4'd6: resw_ch = 4'd6;    // '6'
                default: resw_ch = 4'd0; // '0'
            endcase
        default: case (resw_ci)         // 2'd1 = "640x480"
                4'd0: resw_ch = 4'd6;    // '6'
                4'd1: resw_ch = 4'd4;    // '4'
                4'd2: resw_ch = 4'd0;    // '0'
                4'd3: resw_ch = 4'd10;   // 'x'
                4'd4: resw_ch = 4'd4;    // '4'
                4'd5: resw_ch = 4'd8;    // '8'
                default: resw_ch = 4'd0; // '0'
            endcase
        endcase
    end

    wire [4:0] resw_grow = resw_glyph(resw_ch, resw_row);
    wire [2:0] resw_bidx = 3'd4 - resw_bc;      // bit4=最左; bc=5 时越界, 被门控
    wire resw_pix = resw_region && ~resw_border &&
                    (resw_lx < resw_len) && (resw_ly < 4'd7) &&
                    (resw_bc < 3'd5) && resw_grow[resw_bidx];

    //--------------------------------------------------------------
    // 输出仲裁: 亮度条 > 缩放条 > 音量条 > 对比度条 > 状态卡 > 分辨率字幕
    //           > 淡入×亮度×对比度像素
    //   (六块 HUD 在 x/y 上互不重叠, 但用 if-else 链明确优先级, 顺序稳定)
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
        else if (vol_region) begin
            if (vol_border)
                fo = C_BAR_BD;
            else if (vol_active)
                fo = C_VOL_FG;                       // 音量已生效档位(绿)
            else
                fo = C_BAR_BG;
        end
        else if (con_region) begin
            if (con_border)
                fo = C_BAR_BD;
            else if (con_active)
                fo = C_CON_FG;                       // 对比度已生效档位(品红)
            else
                fo = C_BAR_BG;
        end
        else if (card_region) begin
            if (card_border || card_mark)
                fo = card_col;                       // 卡边 / 播放-暂停图形
            else
                fo = C_CARD_BG;                      // 卡内衬底
        end
        else if (resw_region) begin
            if (resw_border)
                fo = C_BAR_BD;                       // 字幕牌描边
            else if (resw_pix)
                fo = C_RESW_TX;                      // 分辨率文字(近白)
            else
                fo = C_CARD_BG;                      // 牌内衬底
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
