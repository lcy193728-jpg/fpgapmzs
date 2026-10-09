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
//      四个提示区在 y 方向互不重叠, 可同时出现;
//      优先级 亮度 > 缩放 > 音量 > 状态卡。
//      提示色固定, 不随本帧亮度增益变化, 保证可读。
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
//   5. ★中心扩散(iris)转场(2026-10-08 新增, 对照小鹅通第十讲"模式④ 从中心向外"):
//      切换那一刻, 屏幕中心"亮出"新图并逐帧向四周扩散, 直至覆盖全屏。
//        · 边界内 = 全亮新图; 边界外 = **新图压暗版**(>>2, 1/4 亮度)当幕布。
//        · 判据 = 距中心距离 dist < iris_r → **欧氏近似**(零乘法器):
//            dist ≈ max(|px-320|,|py-240|) + min(|dx|,|dy|)*3/8
//          (2026-10-08 由"切比雪夫 max"改为欧氏近似: 切比雪夫的等距线是
//           正方形, 方框上下边先贴屏幕上下沿 → 观感像"上/下扫"; 改欧氏后
//           等距线近圆, 是干净的"由中心向外"扩散。)
//        · iris_r 每帧递增(帧边界原子提交, 与 alpha 同机制, 防撕裂);
//          触发 = iris_trig **任意电平变化**(异步 toggle, 两级同步后检测)。
//      ★为什么边界外不显示"旧图":
//        本工程 SDRAM 帧缓存只用 bank0(见顶层 frame_fifo 例化: read/write
//        addr_index 均锁 2'd0) → 切换后旧图已被覆盖, 无第二张图可作旧图源。
//        故用"新图压暗版"当幕布: 零额外存储、零乘法器, 且观感平滑不闪
//        (对比: 淡入淡出必须经全黑, 轮播时每周期黑屏一次)。
//      ★只用于**抢答场景**(2026-10-08 改): 迎新轮播恢复原「淡入淡出」(经全黑),
//        故顶层 iris 触发源已收窄为"仅抢答 quiz_scene_ctrl.iris_trig"一路;
//        迎新切图走本模块 menu_evt → FOUT/FBLCK/FIN 淡入淡出状态机。
//      ★IRIS_FRAMES=0 时整体旁路(半径恒 = 上限 → 全亮新图), 行为逐位不变。
//
// 混合公式 :
//   stage1 亮度:  b1 = clamp((pix * g + 64) >> 7)
//   stage2 淡入:  out = (b1 * alpha + 128) >> 8   (alpha 255=全显, 0=黑)
//   stage3 扩散:  out = (dist < r) ? out : (out >> 2)   (仅 iris_run 时)
//                 dist = 欧氏近似 max(|dx|,|dy|) + min*3/8  (见 §5)
//   提示 HUD 在 stage3 之后叠加(固定色)。
// 数据管线 : 输入寄存 1 拍(da1/px1/sync1)后组合仲裁直接输出 →
//            整体恒定延迟 1 clk, 与 hs/vs/de 严格同拍。
// 控制输入 : menu_active/bmp_busy/bri_level/vol_level/res_level/pic_manual/ui_mode
//            /iris_trig 均来自 sd_card_clk(100MHz)域电平, 模块内两级同步器过域。
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
    parameter [2:0]  MODE_PIC = 3'd0,    // 与 ui_key_ctrl 一致的模式编码(复位用)
    parameter [2:0]  MODE_BRI = 3'd1,    // (以下 MODE_* 仅作文档参考; mode_map 已改用数字
    parameter [2:0]  MODE_RES = 3'd2,    //  功能类别 0..5 编码, 见 mode_map 段 2026-10-09f)
    parameter [2:0]  MODE_PERIOD = 3'd3, // 批次4: 轮播周期档(迎新 3 档; 不弹 HUD)
    parameter [2:0]  MODE_MEET = 3'd4,   // 迎新 4 档 = 对比度(抢答 4 档 = 计分)
    parameter [2:0]  MODE_CON  = 3'd3,   // 抢答 3 档 = 对比度(与 MODE_PERIOD 同值, 已弃用别名)
    parameter [2:0]  MODE_VOL  = 3'd5,   // 音量档(2026-09-28: 音量条 HUD)
    // ---- 分辨率字幕(2026-10-02, 配合 bmp_read_auto 多分辨率支持) ----
    // ★须 ≤62: 内部 resw_cnt 只保留 6 位(同其余 *_HOLD_FRAMES 前提)
    parameter [15:0] RESW_HOLD_FRAMES = 16'd60, // 分辨率变化后字幕保持帧数(≈1s @60fps)
    // ---- 抢答分数板(2026-10-09 新增) ----
    //   语义: 评委判对/判错时, 右上角弹出 4 队当前累计分, 保持约 1 秒后消失。
    //   ★须 ≤62: 内部 scb_cnt 只保留 6 位(同上限制)。
    parameter [15:0] SCB_HOLD_FRAMES = 16'd60,  // 分数板保持帧数(≈1s @60fps)
    // ---- 中心扩散(iris)转场(2026-10-08) ----
    //   语义: 切换瞬间, 屏幕中心"亮出"新图并逐帧向四周扩散, 直到覆盖全屏。
    //   边界内 = 全亮新图; 边界外 = 新图压暗版(>>2, 1/4 亮度)。
    //   为什么不用"边界外显示旧图": 本工程 SDRAM 帧缓存只用 bank0(单帧),
    //     切换后旧图已被覆盖, 无第二张图可作为"旧图"源(见模块头注释)。
    //     用"新图压暗版"当幕布 → 零额外存储、零乘法器, 观感平滑不闪。
    //   ★距离判据 = **欧氏距离**(近似): max(|dx|,|dy|) + min(|dx|,|dy|)*3/8。
    //     【2026-10-08 改】原先用切比雪夫 max(|dx|,|dy|) → 边界是【正方形】,
    //     正方形从中心向外扩时, 上下边比左右边更早贴到屏幕边缘, 视觉上会像
    //     "有东西往上/下扫", 与用户看到的"中心外散 + 向上切同时发生"吻合。
    //     改成欧氏近似后边界是无明显棱角的【近圆形】, 扩散是干净的"由中心向外"。
    //     零乘法器: |dx|,|dy| 求 max/min 后, min 只取 *3/8(移位+两级加法),
    //     与 640 级的 max 相加再比较。误差 ~6%(小鹅通第十讲也未用真平方根,
    //     官方/参考实现同样是"距离阈值"思路; 本项目取更接近圆的近似)。
    //   ★推进速度: IRIS_FRAMES=32 → 每帧 ≈IRIS_R_MAX/32 ≈12, 全程 ≈32 帧
    //     ≈0.53s@60fps。原先 16 帧(≈0.27s)太快, 人眼只看到"闪一下"而分不清
    //     是圆扩散还是竖切; 放慢后"中心亮斑逐步长大"的过程清晰可辨。
    //   FADE_FRAMES=0 时整体旁路(iris_step 无效, 保持硬切, 便于回归对照)。
    parameter [7:0]  IRIS_FRAMES = 8'd32,   // 扩散帧数(0=旁路; 32 帧 ≈0.53s@60fps)
    //   每帧半径增量 = IRIS_R_MAX / IRIS_FRAMES (编译期由下方 localparam 算)
    //   ★两个 *_STEP 必须为 2 的幂(用移位实现), 否则恢复乘法写法。
    parameter [11:0] IRIS_R_MAX  = 12'd400,  // 覆盖半径上限(>对角线半长 √(320²+240²)=400, 取 400)
    // ---- 左→右 Wipe 转场(2026-10-09j 新增, 对照小鹅通第十讲"模式② 从左到右") ----
    //   语义: 会议场景切图时, 新图从屏幕左侧"擦"出、逐帧向右揭示, 直到铺满。
    //   边界内(x < wipe_x) = 全亮新图; 边界外 = 新图压暗版(>>2, 与 iris 同幕布)。
    //   ★与 iris 同源同理: 单帧缓存无"旧图", 用"新图压暗版"当未揭示侧幕布,
    //     零额外存储、零乘法器。
    //   ★推进速度: WIPE_FRAMES=32 → 每帧 ≈640/32=20px, 全程 32 帧 ≈0.53s@60fps,
    //     与 iris 同节奏, 观感一致。
    parameter [7:0]  WIPE_FRAMES = 8'd32    // 擦除帧数(0=旁路; 32 帧 ≈0.53s@60fps)
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
    input                iris_trig,      // 中心扩散触发(异步电平, 每次事件翻转; 见下方同步)
    input                wipe_trig,      // ★左→右 Wipe 触发(会议切图, toggle 电平; 2026-10-09j)
    input        [3:0]   bri_level,      // 亮度档 0..15(默认 8)
    input        [3:0]   vol_level,      // 音量档 0..15(默认 8, 模式5 调; 仅用于音量条 HUD)
    input        [3:0]   res_level,      // 缩放档 0..7(默认 4=100%)
    input        [3:0]   con_level,      // ★对比度档 0..15(默认 8=×1.0; 2026-10-09c 新增)
    input        [1:0]   img_res,        // 当前显示图源分辨率码 0=320x240 1=640x480
                                         //                    2=1024x768 3=1280x960
                                         // (2026-10-02 由 1bit img_2x 扩为 2bit 四档)
    input                pic_manual,     // 1=手动单张 / 0=自动轮播
    input        [2:0]   ui_mode,        // 功能模式 0图片/1亮度/2缩放/3周期|对比度/4计分|对比度/5音量
                                         //   ★模式号含义随场景: 抢答场景 3=对比度;
                                         //     迎新/应急 4=对比度(由 ui_key_ctrl 决定)
    // ---- 抢答分数板(2026-10-09 新增; 异步电平, 内部两级同步) ----
    input                quiz_on,        // 1=处于抢答场景(非抢答场景不显示分数板)
    input                meeting_on,     // ★1=处于会议场景(2026-10-09j; 用于 mode_map 场景映射)
    input        [1:0]   q_state,        // 抢答状态(仅用于调试/扩展, 当前未直接参与显示)
    input                q_end,          // ★2026-10-09b: 1=抢答结束页(F_END) → 4 队总分常显
    input signed [7:0]   sc0, sc1, sc2, sc3,  // 4 队累计分(有符号)
    input                sc_evt,         // 判分动作脉冲(异步, 触发分数板弹出)
    input        [1:0]   sc_team,        // 本次被判队伍 0..3
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
    localparam [DATA_W-1:0] C_CON_FG = 24'hB4_7C_FF;  // ★对比度已生效档位(品红, 2026-10-09c)
    localparam [DATA_W-1:0] C_CARD_BG= 24'h0A_10_18;  // 状态卡底(更深的蓝黑)
    localparam [DATA_W-1:0] C_AUTO   = 24'h22_C5_5E;  // 自动轮播: 卡边 + 播放三角(绿)
    localparam [DATA_W-1:0] C_MAN    = 24'hFF_A0_28;  // 手动单张: 卡边 + 暂停双条(橙)
    localparam [DATA_W-1:0] C_RESW_TX= 24'hE4_F0_FF;  // 分辨率字幕文字(近白, 2026-10-02)
    localparam [DATA_W-1:0] C_SCB_TX = 24'hFF_D2_4A;  // 抢答分数板文字(金, 2026-10-09)
    // ★2026-10-09b: 结束页分数槽底色 —— 与 gen_quiz_set.py 里卡片填充 (24,40,78) 一致,
    //   用于盖住图片上预留的灰 "--" 占位。
    localparam [DATA_W-1:0] C_END_BG = 24'h18_28_4E;  // (24,40,78)

    //--------------------------------------------------------------
    // 控制电平过域(两级同步; bri_level 4bit)
    //--------------------------------------------------------------
    reg  m_s0, m_s1, e_s0, e_s1, b_s0, b_s1;
    reg  [3:0] l_s0, l_s1;
    reg  [3:0] r_s0, r_s1;      // 缩放(分辨率)档 0..7
    reg  [3:0] v_s0, v_s1;      // 音量档 0..15(2026-09-28)
    reg  [3:0] c_s0, c_s1;      // ★对比度档 0..15(2026-10-09c)
    reg        p_s0, p_s1;      // 轮播(0)/手动(1)
    reg  [2:0] u_s0, u_s1;      // 功能模式 0图片/1亮度/2缩放/3周期|对比度/4计分|对比度/5音量
    reg  [2:0] mm_s0, mm_s1;    // ★映射后模式号(mm, 2026-10-09e): 迎新恒 = ui_mode;
                                //   抢答/应急 3→4 档平移(见 mode_msel 段)
    reg  [1:0] x_s0, x_s1;      // 源分辨率码(2026-10-02; 原 1bit img_2x 扩为四档)
    reg        i_s0, i_s1;      // iris 触发电平(2026-10-08)
    reg        w_s0, w_s1;      // ★Wipe 触发电平(2026-10-09j)
    // ---- 抢答分数板(2026-10-09) ----
    reg        q_s0, q_s1;      // 抢答场景使能
    reg        mt_s0, mt_s1;    // ★会议场景使能(2026-10-09j)
    reg        qe_s0, qe_s1;    // ★2026-10-09b: 抢答结束页电平
    reg        cev_s0, cev_s1;  // 判分电平翻转(toggle)
    reg signed [7:0] sc0_s0, sc0_s1, sc1_s0, sc1_s1,
                     sc2_s0, sc2_s1, sc3_s0, sc3_s1;
    wire menu_s  = m_s1;
    wire emerg_s = e_s1;
    wire busy_s  = b_s1;
    wire [3:0] lvl_s  = l_s1;
    wire [3:0] res_s  = r_s1;
    wire [3:0] vol_s  = v_s1;
    wire [3:0] con_s  = c_s1;   // ★过域后的对比度档
    wire       man_s  = p_s1;
    wire [2:0] mode_s = u_s1;
    wire [1:0] imgres_s = x_s1;   // 过域后的源分辨率码(0..3)
    wire       iris_s   = i_s1;   // 过域后的 iris 触发电平
    wire       wipe_s   = w_s1;   // ★过域后的 Wipe 触发电平(2026-10-09j)
    wire       quiz_s   = q_s1;   // 过域后的抢答场景使能
    wire       meeting_s = mt_s1; // ★过域后的会议场景使能(2026-10-09j)
    // ★场景相关的"映射后模式号"(2026-10-09f 重写):
    //   上游 ui_key_ctrl 的 KEY1 循环序列与"各档功能"都随场景不同。
    //   display_adjust 位于 video_clk 域, 但已有 emerg_s(应急)/quiz_s(抢答)
    //   两个过域场景电平, 故**直接按场景精确映射**, 不再靠 mode 号猜场景
    //   (旧 scrape=(mm_s1==4) 推断法在"应急去缩放、档位前移"后已不可靠)。
    //   各场景 mode → 功能:
    //     迎新 : 0图片 1亮度 2缩放 3周期 4对比度 5音量
    //     抢答 : 0图片 1亮度 2缩放 3对比度 4计分 5音量
    //     应急 : 0图片 1亮度 2对比度 3音量 (无缩放/周期/计分)
    //   映射输出 = "功能类别": 0图片 1亮度 2缩放 3周期|计分(不弹) 4对比度 5音量,
    //   只驱动"切档时弹哪条 HUD", 不参与任何像素运算。
    wire [2:0] mode_map =
        emerg_s ? (                       // 应急场景
            (mm_s1 == 3'd2) ? 3'd4 :      // 2 = 对比度
            (mm_s1 == 3'd3) ? 3'd5 :      // 3 = 音量
            mm_s1                          // 0/1 原样(图片/亮度)
        ) : quiz_s ? (                    // 抢答场景
            (mm_s1 == 3'd3) ? 3'd4 :      // 3 = 对比度
            (mm_s1 == 3'd4) ? 3'd3 :      // 4 = 计分(不弹卡)
            mm_s1                          // 0/1/2/5 原样
        ) : meeting_s ? (                 // ★会议场景(2026-10-09j)
            (mm_s1 == 3'd3) ? 3'd4 :      // 3 = 对比度
            (mm_s1 == 3'd4) ? 3'd5 :      // 4 = 音量
            mm_s1                          // 0/1/2 原样(图片/亮度/缩放)
        ) : (                              // 迎新场景
            (mm_s1 == 3'd4) ? 3'd4 :      // 4 = 对比度
            mm_s1                          // 0/1/2/3(周期)/5 原样
        );
    wire       qend_s   = qe_s1;  // ★过域后的抢答结束页电平
    wire       scev_s   = cev_s1; // 过域后的判分电平翻转
    wire signed [7:0] scv0 = sc0_s1, scv1 = sc1_s1,
                      scv2 = sc2_s1, scv3 = sc3_s1;

    always @(posedge video_clk or posedge rst) begin
        if (rst) begin
            // 复位初值对齐系统默认态(菜单 active / 非应急 / 忙未知 / 亮度档8
            // / 缩放档4=100% / 自动轮播 / 图片模式), 防止上电同步过程产生
            // 假边沿(假淡出 / 假提示条)
            m_s0<=1'b1; m_s1<=1'b1; e_s0<=1'b0; e_s1<=1'b0;
            b_s0<=1'b0; b_s1<=1'b0; l_s0<=4'd8; l_s1<=4'd8;
            r_s0<=4'd4; r_s1<=4'd4;
            v_s0<=4'd8; v_s1<=4'd8;
            c_s0<=4'd8; c_s1<=4'd8;   // 对比度默认 ×1.0(与 bri/vol 同口径)
            p_s0<=1'b0; p_s1<=1'b0;
            u_s0<=MODE_PIC; u_s1<=MODE_PIC;
            x_s0<=2'd1; x_s1<=2'd1;   // 复位默认 640×480(码1), 防上电假字幕
            i_s0<=1'b0; i_s1<=1'b0;   // iris 触发默认无效, 防上电假扩散
            w_s0<=1'b0; w_s1<=1'b0;   // ★Wipe 触发默认无效, 防上电假擦除
            q_s0<=1'b0; q_s1<=1'b0;   // 抢答场景默认关
            mt_s0<=1'b0; mt_s1<=1'b0; // 会议场景默认关(2026-10-09j)
            qe_s0<=1'b0; qe_s1<=1'b0; // ★结束页默认关
            cev_s0<=1'b0; cev_s1<=1'b0;
            sc0_s0<=8'sd0; sc0_s1<=8'sd0; sc1_s0<=8'sd0; sc1_s1<=8'sd0;
            sc2_s0<=8'sd0; sc2_s1<=8'sd0; sc3_s0<=8'sd0; sc3_s1<=8'sd0;
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
            mm_s0<=ui_mode;    mm_s1<=mm_s0;
            x_s0<=img_res;     x_s1<=x_s0;
            i_s0<=iris_trig;   i_s1<=i_s0;
            w_s0<=wipe_trig;   w_s1<=w_s0;
            q_s0<=quiz_on;     q_s1<=q_s0;
            mt_s0<=meeting_on; mt_s1<=mt_s0;
            qe_s0<=q_end;      qe_s1<=qe_s0;
            cev_s0<=sc_evt;    cev_s1<=cev_s0;
            sc0_s0<=sc0; sc0_s1<=sc0_s0;
            sc1_s0<=sc1; sc1_s1<=sc1_s0;
            sc2_s0<=sc2; sc2_s1<=sc2_s0;
            sc3_s0<=sc3; sc3_s1<=sc3_s0;
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
    reg [3:0]  con_past;     // ★上一拍对比度档(变化 → 显示对比度条, 2026-10-09c)
    reg [5:0]  con_cnt;        // ★对比度条剩余显示帧数(0=隐藏)
    reg        man_past;      // 上一拍轮播/手动标志(变化 → 显示状态卡)
    reg [5:0]  man_cnt;        // 状态卡剩余显示帧数(0=隐藏)
    reg [2:0]  mode_mapd;     // ★上一拍"映射后模式号"(场景重映射后; 变化 → 弹对应 HUD)
                              //   见下方 mode_msel 段(2026-10-09e 新增)
    reg [1:0]  x_past;        // 上一拍分辨率码(变化 → 弹分辨率字幕, 2026-10-02)
    reg [5:0]  resw_cnt;       // 分辨率字幕剩余显示帧数(0=隐藏; ★只用 6 位 ≤62)
    // ---- 抢答分数板(2026-10-09) ----
    reg        scev_past;     // 上一拍判分电平(变化 → 弹分数板)
    reg [5:0]  scb_cnt;       // 分数板剩余显示帧数(0=隐藏; ★只用 6 位 ≤62)

    // ---- 中心扩散(iris)转场(2026-10-08) ----
    //   iris_s(过域 toggle 电平)**任意变化** → 粘性事件 iris_evt(逐拍捕获),
    //   帧边界消费。★用"任意变化"而非上升沿: 上游每次事件翻转一次电平, 方向
    //   交替, 只认上升沿会漏掉相邻两次中的一次。
    //   iris_run: 1=扩散进行中; iris_r: 当前半径(每帧递增 IS_OFFSET)。
    //   结束时 iris_r 顶到 IRIS_R_MAX, 显示回落到"全亮新图"(判据自然成立)。
    //   ★与淡入淡出互斥: 只有非应急时 iris 才可启动; 应急帧边界强制清 iris_run
    //     (与 fsm<-FIDLE 同处, 保证应急即刻响应、不留转场残留)。
    localparam [11:0] IRIS_R0    = 12'd6;                 // 起始半径(中心小圆)
    localparam [11:0] IS_OFFSET = (IRIS_FRAMES == 0) ? 12'd0
                                : (IRIS_R_MAX / {4'd0, IRIS_FRAMES}); // 每帧增量
    // ★Wipe 每帧边界增量(左→右): WIPE_FRAMES=32 → 640/32=20px/帧
    localparam [11:0] WIPE_STEP  = (WIPE_FRAMES == 0) ? 12'd0
                                : (H_ACT / {4'd0, WIPE_FRAMES});
    reg        iris_run;
    reg [11:0] iris_r;
    reg        iris_past;      // 上一拍 iris_s(边沿检测)
    reg        iris_evt;       // 粘性上升沿事件(帧边界消费)

    // ---- 左→右 Wipe 转场(2026-10-09j) ----
    //   wipe_s(过域 toggle 电平)任意变化 → 粘性事件 wipe_evt(逐拍捕获), 帧边界消费。
    //   wipe_run: 1=擦除进行中; wipe_x: 当前边界 x(每帧递增 WIPE_STEP, 左→右)。
    //   结束时 wipe_x 顶到 640, 显示回落到"全亮新图"(判据自然成立)。
    //   ★与 iris/淡入淡出互斥: 非应急才可启动; 应急帧边界强制清 wipe_run。
    reg        wipe_run;
    reg [11:0] wipe_x;
    reg        wipe_past;      // 上一拍 wipe_s(边沿检测)
    reg        wipe_evt;       // 粘性事件(帧边界消费)

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
            con_past   <= 4'd8;      // ★对比度默认 ×1.0, 防上电假提示条
            con_cnt    <= 6'd0;
            man_past   <= 1'b0;
            man_cnt    <= 6'd0;
            mode_mapd  <= MODE_PIC;
            x_past     <= 2'd1;      // 默认 640x480(码1), 防上电假字幕
            resw_cnt   <= 6'd0;
            scev_past  <= 1'b0;      // 默认无判分, 防上电假分数板
            scb_cnt    <= 6'd0;
            iris_run   <= 1'b0;
            iris_r     <= IRIS_R0;
            iris_past  <= 1'b0;      // 默认无效, 防上电假扩散
            iris_evt   <= 1'b0;
            wipe_run   <= 1'b0;
            wipe_x     <= 12'd0;
            wipe_past  <= 1'b0;      // 默认无效, 防上电假擦除
            wipe_evt   <= 1'b0;
        end
        else begin
            // ---- 事件锁存(逐拍检测, 与帧边界无关) ----
            if (menu_s != menu_past)
                menu_evt <= 1'b1;                 // 场景切换事件(粘性)
            menu_past <= menu_s;

            // iris 触发事件(粘性事件, 帧边界消费)
            //   ★上游给的是"电平翻转(toggle)", 故检测**任意变化**而不是上升沿:
            //     每次事件翻转一次电平 → 恰好产生一次变化 → 恰好触发一次转场。
            //     (若改成只认上升沿, 相邻两次事件方向相反时会漏一次。)
            if (iris_s != iris_past)
                iris_evt <= 1'b1;
            iris_past <= iris_s;

            // Wipe 触发事件(粘性事件, 帧边界消费; 同 iris 检测任意变化)
            if (wipe_s != wipe_past)
                wipe_evt <= 1'b1;
            wipe_past <= wipe_s;

            if (lvl_s != lvl_past)
                bar_cnt <= BAR_HOLD_FRAMES[5:0];   // 亮度档变化 → 显示亮度条
            lvl_past  <= lvl_s;

            if (res_s != res_past)
                res_cnt <= RES_HOLD_FRAMES[5:0];   // 缩放档变化 → 显示缩放条
            res_past  <= res_s;

            if (vol_s != vol_past)
                vol_cnt <= VOL_HOLD_FRAMES[5:0];   // 音量档变化 → 显示音量条
            vol_past  <= vol_s;

            // ★对比度档变化 → 显示对比度条(2026-10-09c; 复用音量条保持帧数)
            if (con_s != con_past)
                con_cnt <= VOL_HOLD_FRAMES[5:0];
            con_past  <= con_s;

            if (man_s != man_past)
                man_cnt <= MAN_HOLD_FRAMES[5:0];   // 轮播↔手动 → 显示状态卡
            man_past  <= man_s;

            // 源分辨率变化(320x240 / 640x480 / 1024x768 / 1280x960 四档)
            //   → 右上角字幕弹 1s(码变化即弹; 2026-10-02 由 1bit 扩为 2bit 四档)
            if (imgres_s != x_past)
                resw_cnt <= RESW_HOLD_FRAMES[5:0];
            x_past   <= imgres_s;

            // ---- 抢答分数板: 判分动作 → 弹 1 秒 (2026-10-09) ----
            //   上游 quiz_ctrl 给的是"电平翻转(toggle)"(每次判分翻转一次),
            //   故检测**任意变化**而不是上升沿 —— 与 iris 转场同一防漏采做法。
            if (scev_s != scev_past)
                scb_cnt <= SCB_HOLD_FRAMES[5:0];
            scev_past <= scev_s;

            // ---- 功能模式切换: 弹出"当前在调什么"的提示(便于现场确认) ----
            //   ★2026-10-09f 重写: mode_map 已是"功能类别"(见 mode_map 段), 直接
            //     按数字分支; 消除了旧 MODE_CON/MODE_PERIOD 同值(3'd3)的 case 别名
            //     冲突(那个别名会让"对比度档"切档时误走"不弹"分支)。
            //       0=图片→轮播/手动卡  1=亮度条  2=缩放条
            //       3=周期/计分(不弹)   4=对比度条  5=音量条
            if (mode_map != mode_mapd) begin
                case (mode_map)
                    3'd1: bar_cnt <= BAR_HOLD_FRAMES[5:0];  // 亮度 → 亮度条
                    3'd2: res_cnt <= RES_HOLD_FRAMES[5:0];  // 缩放 → 缩放条
                    3'd3: ;                                 // 周期/计分: 不弹卡
                    3'd4: con_cnt <= VOL_HOLD_FRAMES[5:0];  // 对比度 → 对比度条
                    3'd5: vol_cnt <= VOL_HOLD_FRAMES[5:0];  // 音量 → 音量条
                    default : man_cnt <= MAN_HOLD_FRAMES[5:0];  // 图片 → 轮播/手动卡
                endcase
            end
            mode_mapd <= mode_map;

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
                if (scb_cnt != 6'd0)
                    scb_cnt <= scb_cnt - 6'd1;

                if (emerg_s) begin
                    // 应急: 最高优先级即刻响应, 禁止淡出, 并丢弃待处理事件
                    fsm      <= FIDLE;
                    alpha    <= 8'd255;
                    blk_fr   <= 6'd0;
                    menu_evt <= 1'b0;
                    // iris 转场同样即刻终止(防应急图被扩散幕布遮挡)
                    iris_run <= 1'b0;
                    iris_r   <= IRIS_R_MAX;
                    iris_evt <= 1'b0;
                    // Wipe 转场同样即刻终止(防应急图被擦除幕布遮挡)
                    wipe_run <= 1'b0;
                    wipe_x   <= 12'd640;
                    wipe_evt <= 1'b0;
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

                // ---- 中心扩散(iris)半径推进(帧边界原子提交) ----
                //   优先于淡入淡出: iris 进行中不再响应 menu_evt(避免同时两种转场)。
                //   ★FADE_FRAMES=0(IRIS_FRAMES=0)时整体旁路: 不启动、半径恒为
                //     上限(判据恒真 → 全亮新图), 行为与改造前逐位一致。
                if (IRIS_FRAMES == 0) begin
                    iris_run <= 1'b0;
                    iris_r   <= IRIS_R_MAX;
                    iris_evt <= 1'b0;
                end
                else if (iris_run) begin
                    if (iris_r >= IRIS_R_MAX - IS_OFFSET) begin
                        iris_r   <= IRIS_R_MAX;   // 扩散完成 → 覆盖全屏
                        iris_run <= 1'b0;
                    end
                    else
                        iris_r <= iris_r + IS_OFFSET;
                end
                else if (iris_evt && !emerg_s) begin
                    // 新转场启动(未在应急): 从中心小半径重新扩散
                    iris_evt <= 1'b0;
                    iris_run <= 1'b1;
                    iris_r   <= IRIS_R0;
                    // 启动 iris 时抢占淡入淡出: 立即回全亮, 丢弃待处理的淡出事件
                    fsm      <= FIDLE;
                    alpha    <= 8'd255;
                    menu_evt <= 1'b0;
                end
                else begin
                    iris_evt <= 1'b0;             // 应急期间的触发直接丢弃
                end

                // ---- 左→右 Wipe 边界推进(帧边界原子提交, 2026-10-09j) ----
                if (WIPE_FRAMES == 0) begin
                    wipe_run <= 1'b0;
                    wipe_x   <= H_ACT;              // 旁路: 边界顶满 → 全亮
                    wipe_evt <= 1'b0;
                end
                else if (wipe_run) begin
                    if (wipe_x >= H_ACT - WIPE_STEP) begin
                        wipe_x   <= H_ACT;          // 擦除完成 → 铺满全屏
                        wipe_run <= 1'b0;
                    end
                    else
                        wipe_x <= wipe_x + WIPE_STEP;
                end
                else if (wipe_evt && !emerg_s) begin
                    // 新擦除启动(未在应急): 边界从左侧重新开始
                    wipe_evt <= 1'b0;
                    wipe_run <= 1'b1;
                    wipe_x   <= WIPE_STEP;
                    // 启动 wipe 时抢占淡入淡出(同 iris)
                    fsm      <= FIDLE;
                    alpha    <= 8'd255;
                    menu_evt <= 1'b0;
                end
                else begin
                    wipe_evt <= 1'b0;             // 应急期间的触发直接丢弃
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

    // stage2: 淡入淡出 alpha 混合(乘加取整)
    //   alpha==255 时直通(此时 FIDLE 稳态/淡入完成), 避免 (x*255+128)>>8
    //   对高亮像素产生 -1 量化误差, 保证平时显示与原像素完全一致
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
    // x_m = x_b * am (am≤4 → ≤1020, 10 位足够)
    wire [9:0]  r_m = am[2] ? {r_b, 2'b00} :
                      am[1] ? (am[0] ? ({r_b,1'b0} + {1'b0,r_b}) : {r_b,1'b0})
                            : (am[0] ? {1'b0,r_b} : 10'd0);
    wire [9:0]  g_m = am[2] ? {g_b, 2'b00} :
                      am[1] ? (am[0] ? ({g_b,1'b0} + {1'b0,g_b}) : {g_b,1'b0})
                            : (am[0] ? {1'b0,g_b} : 10'd0);
    wire [9:0]  b_m = am[2] ? {b_b, 2'b00} :
                      am[1] ? (am[0] ? ({b_b,1'b0} + {1'b0,b_b}) : {b_b,1'b0})
                            : (am[0] ? {1'b0,b_b} : 10'd0);
    // (x_m<<6) ≤ 1020*64 = 65280, 减 aodd*x_b 后再 +128 ≤ 65408 < 65536
    // → 16 位中间量不溢出, 与 (x_b*alpha + 128)>>8 逐位相同
    wire [15:0] r_f = (({6'b0,r_m} << 6) - (aodd ? {8'b0,r_b} : 16'd0) + 16'd128) >> 8;
    wire [15:0] g_f = (({6'b0,g_m} << 6) - (aodd ? {8'b0,g_b} : 16'd0) + 16'd128) >> 8;
    wire [15:0] b_f = (({6'b0,b_m} << 6) - (aodd ? {8'b0,b_b} : 16'd0) + 16'd128) >> 8;
    wire [7:0]  r_o = (alpha == 8'd255) ? r_b : r_f[7:0];
    wire [7:0]  g_o = (alpha == 8'd255) ? g_b : g_f[7:0];
    wire [7:0]  b_o = (alpha == 8'd255) ? b_b : b_f[7:0];

    //--------------------------------------------------------------
    // stage2b: 对比度(2026-10-09c 新增; ★2026-10-09e 按小鹅通口径重写)
    //   公式(与小鹅通 brightness_contrast_adjust.v 的 TODO 骨架逐字一致):
    //       center = x - 128;
    //       scaled = center * k / 128;     // k 即"对比度系数", 128 = 中性
    //       y      = scaled + 128;
    //       final  = saturate(y)           // y<0→0, y>255→255
    //   ★小鹅通口径: contrast ∈ [0,255], **128 为中性**(逐位不变),
    //     >128 增强(亮的更亮/暗的更暗), <128 减弱(拉向中灰, 灰蒙蒙)。
    //
    //   ★【本次修正的根因】旧实现 k = 4 + con*8 ∈ [4,124] —— **整段 < 128**,
    //     即永远只能"减弱", 而且默认档 con=8 算出 k=68(≠128), 全靠
    //     con_on 旁路才维持默认观感; 用户一旦调到任何非默认档, 画面都被
    //     强行拉向中灰 128 → 观感"到中间值往两边都是变模糊"。
    //
    //   ★新映射(16 档 → 对称覆盖"减弱/中性/增强"三段):
    //       k = 8 + con*15   (con:0..15 → k:8..233)
    //       · con=8  → k=128  **中性**, 与原画面逐位相同(不再需要旁路!)
    //       · con=0  → k=8    ≈ 0.06×, 最弱(几乎压成中灰)
    //       · con=15 → k=233  ≈ 1.82×, 最强增强(暗部压到黑、亮部推到白)
    //     为什么取 *15 而不是 *16: 要使 con=8 恰好等于中性 128, 需 a+8b=128;
    //       b=16 时 a=0(con=0 → k=0 全灰成一片, 手感极差);
    //       b=15 时 a=8(con=0 → k=8 仍保留极弱对比度, 不糊成纯灰) —— 最优。
    //     `con*15 = (con<<4) - con` 只需一个 4bit 减法, **零 DSP**;
    //       TD 会把常数乘法退化为移位+减法, 与纯移位面积几乎相同。
    //
    //   ★为什么可以撤掉 con_on 的"默认档旁路":
    //     旧旁路存在的唯一理由 = 旧 k(con=8)=68 不是中性, 必须短路才能保观感。
    //     k=128 时 (in-128)*128>>7 = in-128 → +128 = in, **数学上逐位恒等**,
    //     故 con=8 天然透传, 无需旁路; 少一个比较器与一条旁路选择, 逻辑更简。
    //     (唯一的例外见下方 alpha 门控 —— 黑场保护仍需保留。)
    //
    //   ★数值域(新 k ≤ 233, 全程有符号):
    //       in∈[0,255] → center∈[-128,127] → ×k(≤233) → ∈[-29824,29591] (16bit 够);
    //       >>7 后 ∈[-233,231]; +128 后 ∈[-105,359] → **必须饱和钳位**(旧 k 小
    //       时天然落在 [0,255] 内, 新 k 会越界, 故上下都要钳 —— 这正是小鹅通
    //       骨架里"final = saturate(y)"那一步的意义)。
    //       实现: 只判上溢/下溢两个边界, 中间取低 8 位。
    //       负值判定: 用位宽扩展后的补码比对, 避免有符号/无符号混用告警。
    //
    //   ★面积: 仍是 3 个乘法器(8bit 有符号 × 8bit → 16bit), 与旧版同量级;
    //     旧版是 9bit×7bit, 新版 9bit×8bit, DSP 占用不变(EG4S20 DSP 29 个,
    //     本工程用 14, 余量充足)。TD 会自动把常数乘法退化为移位+加法或映射 DSP。
    //
    //   ★位置: 放在 stage2(淡入淡出)之后、iris 之前 —— 见下方 alpha 门控讨论。
    //--------------------------------------------------------------
    // k = 8 + con*15  (8..233, 8bit; con*15 = (con<<4)-con, 零 DSP)
    //   ★位宽陷阱(2026-10-09e 仿真抓出, 与工程 §C11 同类): Verilog 的位宽
    //     传播是"上下文决定"的 —— 等号右端表达式的**整体位宽会被 LHS 拉窄**。
    //     若写成 `wire [4:0] x = {con,4'b0} - con;`, con=8 时 (8<<4)-8=120
    //     会被截成 5bit 得 24 → k=32(错), 把对比度永远压向中灰。
    //     ★正确做法: 把**每个操作数都显式扩到足够宽**(8bit), 让中间结果
    //       不被 LHS 截断, 最后由 8bit 的 con_k 承接。
    //       注意不能靠"把 LHS 加宽"解决 —— 必须加宽**操作数**。
    wire [3:0]  con_s4  = con_s;                        // 显式 4bit 源
    wire [7:0]  con_sh4 = {con_s4, 4'b0000};            // (con<<4), 8bit 无截断
    wire [7:0]  con_x15 = con_sh4 - {4'b0000, con_s4};  // con*15 = (con<<4) - con (0..225)
    wire [7:0]  con_k   = 8'd8 + con_x15;               // 8..233 (con=8 → 128 精确中性)
    // 有符号中心化: in - 128, 9bit 有符号
    wire signed [8:0] r_c = {1'b0, r_o} - 9'sd128;
    wire signed [8:0] g_c = {1'b0, g_o} - 9'sd128;
    wire signed [8:0] b_c = {1'b0, b_o} - 9'sd128;
    // × k(8bit 无符号, 补 1 位 0 变 9bit 有符号) → 16bit 有符号; 再 >>7 还原比例
    wire signed [16:0] r_ck = r_c * $signed({1'b0, con_k});
    wire signed [16:0] g_ck = g_c * $signed({1'b0, con_k});
    wire signed [16:0] b_ck = b_c * $signed({1'b0, con_k});
    // 还原: (x*k)/128 + 128。算术右移保留符号 → 负值向 -∞ 取整, 视觉无差。
    //   扩到 11bit 有符号, 保证 [-120, 374] 全域不溢
    wire signed [10:0] r_cq = $signed(r_ck[16:7]) + 11'sd128;
    wire signed [10:0] g_cq = $signed(g_ck[16:7]) + 11'sd128;
    wire signed [10:0] b_cq = $signed(b_ck[16:7]) + 11'sd128;
    // 对比度生效条件: 仅"淡入淡出已完成(alpha=255)" —— 见 alpha 门控讨论。
    //   ★旧版还要判 con_s != 8(旁路默认档), 新映射下 con=8 即中性, 该条件已无必要。
    wire con_on = (alpha == 8'd255);
    // saturate: y<0 → 0; y>255 → 255; 否则取低 8 位
    wire [7:0] r_cv = r_cq[10] ? 8'd0                    // 负数(bit10=1 为 11bit 补码符号) → 0
                   : (r_cq > 11'sd255) ? 8'd255 : r_cq[7:0];
    wire [7:0] g_cv = g_cq[10] ? 8'd0
                   : (g_cq > 11'sd255) ? 8'd255 : g_cq[7:0];
    wire [7:0] b_cv = b_cq[10] ? 8'd0
                   : (b_cq > 11'sd255) ? 8'd255 : b_cq[7:0];
    // 应用对比度(alpha!=255 时旁路, 保黑场纯黑 —— 见下)
    wire [7:0] r_co =  con_on ?  r_cv : r_o;
    wire [7:0] g_co =  con_on ?  g_cv : g_o;
    wire [7:0] b_co =  con_on ?  b_cv : b_o;

    //--------------------------------------------------------------
    // 中心扩散(iris)转场 · 像素级(2026-10-08)
    //   判据: 距中心距离 dist < iris_r ? 全亮新图 : 幕布
    //     · dx = 像素 x 到中心 320 的距离; dy 到中心 240。
    //   ★【2026-10-08 改】距离由切比雪夫 max(|dx|,|dy|) 改为欧氏近似:
    //       dist ≈ max(|dx|,|dy|) + min(|dx|,|dy|)*3/8
    //     原切比雪夫判据的等距线是正方形 → 露出区域是方框, 方框上下边先贴到
    //     屏幕上/下沿, 观感像"向上/下扫"。改用欧氏近似后等距线接近圆,
    //     扩散成为干净的"由中心向外"的圆形揭示, 消除"上切"感。
    //     误差 ~6%(≈admissible); 零乘法器: *3 = (x<<1)+x, 再 >>3。
    //   幕布 = 新图压暗版 (>>2, 1/4 亮度): 同一像素源右移, 零额外存储、无乘法器。
    //   iris_run=0 时 iris_out 直接等于 stage2 结果(逐位透传, 零行为变化)。
    //   坐标: de1=1 时 px1∈[0,639] py1∈[0,479](见上方坐标说明), 取窄位够用。
    //     ★中心常量按 H_ACT/V_ACT 参数化, 改分辨率不用改逻辑。
    //--------------------------------------------------------------
    localparam [9:0] IRIS_CX = H_ACT[9:0] >> 1;   // 320
    localparam [8:0] IRIS_CY = V_ACT[9:1];        // 240 (y 只用 9 位: 0..479)
    // |dx|: 10 位减法 + 绝对值(高位够用, 不会溢出)
    wire [9:0] iris_dxr = (px1[9:0] >= IRIS_CX) ? (px1[9:0] - IRIS_CX) : (IRIS_CX - px1[9:0]);
    wire [8:0] iris_dyr = (py1[8:0] >= IRIS_CY) ? (py1[8:0] - IRIS_CY) : (IRIS_CY - py1[8:0]);
    // max / min(|dx|,|dy|): 9 位与 10 位比较, 高位补零
    wire        dx_ge_dy = (iris_dxr >= {1'b0, iris_dyr});
    wire [9:0]  iris_dmax = dx_ge_dy ? iris_dxr : {1'b0, iris_dyr};
    wire [9:0]  iris_dmin = dx_ge_dy ? {1'b0, iris_dyr} : iris_dxr;
    // 欧氏近似: dist = max + min*3/8  (*3 = (min<<1)+min, 再 >>3) —— 零乘法器
    wire [11:0] iris_dt3   = {1'b0, iris_dmin} + {iris_dmin, 1'b0};   // min*3, 11 位
    wire [11:0] iris_dist  = {2'b0, iris_dmax} + (iris_dt3 >> 3);     // 12 位, 最大 ~400
    wire        iris_inside = (iris_dist < {1'b0, iris_r[10:0]});
    // 幕布色: 新图压暗 1/4 (>>2)。亮度级已含 stage1/2 结果, 直接取 r_o/g_o/b_o。
    //   ★对比度(2026-10-09c)作用在 iris **之前**: 幕布取"已含对比度"的 r_co,
    //     否则幕布与新图的对比度不一致, 扩散边界会出现色阶跳变。
    wire [7:0] iris_mr = r_co >> 2;
    wire [7:0] iris_mg = g_co >> 2;
    wire [7:0] iris_mb = b_co >> 2;
    // 合成: 扩散中 → 内全亮/外幕布; 非扩散 → 直接透传
    wire [7:0] ir_o = iris_run ? (iris_inside ? r_co : iris_mr) : r_co;
    wire [7:0] ig_o = iris_run ? (iris_inside ? g_co : iris_mg) : g_co;
    wire [7:0] ib_o = iris_run ? (iris_inside ? b_co : iris_mb) : b_co;

    //--------------------------------------------------------------
    // 左→右 Wipe 转场 · 像素级(2026-10-09j, 对照小鹅通第十讲"模式②")
    //   判据: 像素 x < wipe_x(当前边界) ? 全亮新图 : 幕布(压暗)
    //   幕布与 iris 共用(新图 >>2, 1/4 亮度), 零额外存储/乘法器。
    //   wipe_x 每帧递增(左→右), 新图自左向右"擦"出。
    //   ★与 iris 互斥(不同场景触发), 合成时 iris 优先、wipe 次之。
    //--------------------------------------------------------------
    wire        wipe_inside = (px1[9:0] < wipe_x[9:0]);
    wire [7:0] wr_o = wipe_run ? (wipe_inside ? ir_o : iris_mr) : ir_o;
    wire [7:0] wg_o = wipe_run ? (wipe_inside ? ig_o : iris_mg) : ig_o;
    wire [7:0] wb_o = wipe_run ? (wipe_inside ? ib_o : iris_mb) : ib_o;

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
    // ★对比度条区域命中(左上第 5 行 y64..71; 16 档, 2026-10-09c 新增)
    //   与亮度条/音量条完全同构(内宽 15*9=135px), 仅行位与填充色不同。
    //   行位取 y64..71: 在音量条(y56..63)正下方, 四/五块 HUD 互不重叠。
    //   填充色 = 品红 C_CON_FG, 与亮度(金)/缩放(青)/音量(绿)区分。
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
                4'd11: case (row)                       // '-' 负号(2026-10-09 分数板用)
                    3'd0: resw_glyph = 5'b00000;
                    3'd1: resw_glyph = 5'b00000;
                    3'd2: resw_glyph = 5'b00000;
                    3'd3: resw_glyph = 5'b01110;
                    3'd4: resw_glyph = 5'b00000;
                    3'd5: resw_glyph = 5'b00000;
                    default: resw_glyph = 5'b00000;
                endcase
                4'd12: case (row)                       // ':' 冒号(2026-10-09 分数板用)
                    3'd0: resw_glyph = 5'b00000;
                    3'd1: resw_glyph = 5'b00100;
                    3'd2: resw_glyph = 5'b00100;
                    3'd3: resw_glyph = 5'b00000;
                    3'd4: resw_glyph = 5'b00100;
                    3'd5: resw_glyph = 5'b00100;
                    default: resw_glyph = 5'b00000;
                endcase
                4'd13: case (row)                       // 'T' 队号前缀(2026-10-09b 分数板用)
                    3'd0: resw_glyph = 5'b11111;
                    3'd1: resw_glyph = 5'b00100;
                    3'd2: resw_glyph = 5'b00100;
                    3'd3: resw_glyph = 5'b00100;
                    3'd4: resw_glyph = 5'b00100;
                    3'd5: resw_glyph = 5'b00100;
                    default: resw_glyph = 5'b00100;
                endcase
                4'd14: case (row)                       // '=' 分隔符(2026-10-09b 分数板用)
                    3'd0: resw_glyph = 5'b00000;
                    3'd1: resw_glyph = 5'b00000;
                    3'd2: resw_glyph = 5'b11111;
                    3'd3: resw_glyph = 5'b00000;
                    3'd4: resw_glyph = 5'b11111;
                    3'd5: resw_glyph = 5'b00000;
                    default: resw_glyph = 5'b00000;
                endcase
                4'd15: case (row)                       // '+' 正号(2026-10-09b 分数板用)
                    3'd0: resw_glyph = 5'b00000;
                    3'd1: resw_glyph = 5'b00100;
                    3'd2: resw_glyph = 5'b00100;
                    3'd3: resw_glyph = 5'b11111;
                    3'd4: resw_glyph = 5'b00100;
                    3'd5: resw_glyph = 5'b00100;
                    default: resw_glyph = 5'b00000;
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
    // 抢答分数显示(2026-10-09 / 2026-10-09b 修 BUG-2)
    //   两种呈现共用同一套 5×7 点阵文字渲染:
    //   ① 判分弹窗(右上角浮层, 判分后弹 1 秒)—— 4 行紧凑排列在 1 个盒子里。
    //   ② 结束页常显 —— 4 队分数分别叠到 QUIZ8 图片上预留的 "--" 占位处
    //      (占位中心 (226,252)/(522,252)/(226,362)/(522,362), 由 gen_quiz_set.py 画)。
    //      结束页无弹窗 → 原先 scb_show 恒 0 → 图上只剩灰 "--" (用户反馈的 BUG-2)。
    //   为此把"盒式弹窗"与"散点常显"拆成两条独立几何, 文字生成逻辑复用。
    //--------------------------------------------------------------
    //   ★2026-10-09b 修 BUG-1: 原 W=180/H=64 内区 172×56, 单行文字 54px 尚可,
    //     但 scb_ci 只取 4 位(商最大 28 溢出回绕) → 行尾拖出一串个位数字。
    //     本次同时: ①ci 扩为 5 位并按本行文字宽度限幅; ②面积放大到够 4 行×14px。
    localparam [11:0] SCB_X0 = 12'd452;
    localparam [11:0] SCB_Y0 = 12'd26;
    localparam [11:0] SCB_W  = 12'd180;
    localparam [11:0] SCB_H  = 12'd64;
    localparam [11:0] SCB_R  = SCB_X0 + SCB_W;   // 632
    localparam [11:0] SCB_B  = SCB_Y0 + SCB_H;   // 90
    localparam [11:0] SCB_IL = SCB_X0 + 12'd4;   // 内区左(留 4px 边距)
    localparam [11:0] SCB_IT = SCB_Y0 + 12'd4;   // 内区上

    // ---- ① 弹窗式(右上角盒) ----
    //   ★2026-10-09b 修 BUG-1(第二处): 内区局部坐标必须**先判下界再相减**,
    //     否则边框 4px 边距内(px1n<SCB_IL 或 py1n<SCB_IT)算出负偏移 → 回绕成
    //     大数 → scb_r16/scb_ci 越界 → case 的 default 把整行画满数字(拖尾)。
    wire scb_pop    = quiz_s && (scb_cnt != 6'd0) && ~qend_s;  // 结束页不弹盒(改散点)
    wire scb_in     = de1 && (py1n >= SCB_IT) && (py1n < SCB_B) &&
                             (px1n >= SCB_IL) && (px1n < SCB_R);
    wire scb_region = scb_pop && (py1n >= SCB_Y0) && (py1n < SCB_B) &&
                                 (px1n >= SCB_X0) && (px1n < SCB_R);
    wire scb_border = scb_region &&
                      ((py1n == SCB_Y0) || (py1n == SCB_B - 12'd1) ||
                       (px1n == SCB_X0) || (px1n == SCB_R - 12'd1));

    // ---- ② 结束页散点(4 队分数叠到 QUIZ8 的 -- 占位) ----
    //   ★2026-10-09c 用户要求: 结束页**只显示分数**(如 "+2" / "-1"), 不带 "T1"/"T2"
    //     队号前缀(卡片上已印好队名), 且**字体放大一倍**。
    //   ⇒ 文字 = 符号 + 最多两位数字 = 3 字符; 字格 12×14(2× 于弹窗的 6×7)
    //     → 文字 36px 宽 × 14px 高。槽取 48×16(文字居中, 两侧/上下各留余量)。
    //   槽左上角 = 中心 - (24,8) → 左列 x=202, 右列 x=498; 上排 y=244, 下排 y=354。
    //   (底色 C_END_BG 与卡片填充同色, 盖住图片上预留的灰 "--"。)
    localparam [11:0] END_X0 = 12'd202;   // 226-24: 左列槽左
    localparam [11:0] END_X1 = 12'd498;   // 522-24: 右列槽左
    localparam [11:0] END_Y0 = 12'd244;   // 252-8 : 上排槽上
    localparam [11:0] END_Y1 = 12'd354;   // 362-8 : 下排槽上
    localparam [11:0] END_W  = 12'd48;    // 槽宽(容 3 字符 × 12px = 36px, 两侧各 6px)
    localparam [11:0] END_H  = 12'd16;    // 槽高(14px 字高 + 2px 余量)

    // 当前像素落在哪个槽(结束页才有效)
    wire end_row = (py1n >= END_Y1) ? 1'b1 : 1'b0;   // 0=上排 1=下排
    wire end_col = (px1n >= END_X1) ? 1'b1 : 1'b0;   // 0=左列 1=右列
    wire [11:0] end_sx = end_col ? END_X1 : END_X0;  // 本槽左
    wire [11:0] end_sy = end_row ? END_Y1 : END_Y0;  // 本槽上
    wire end_region = qend_s && de1 &&
                      ((py1n >= END_Y0) && (py1n < END_Y1 + END_H)) &&
                      ((px1n >= END_X0) && (px1n < END_X1 + END_W)) &&
                      // 必须落在"本槽"内(防跨槽串字)
                      (py1n >= end_sy) && (py1n < end_sy + END_H) &&
                      (px1n >= end_sx) && (px1n < end_sx + END_W);
    wire [1:0] end_team = {end_row, end_col};        // 队伍号 0..3

    // 两个几何的并集命中(文字像素共用一段渲染)
    wire scbx_region = scb_in || end_region;

    //--------------------------------------------------------------
    // 分数解码(★2026-10-09c: 提到几何之前 —— 结束页的"居中留白"依赖 scb_two,
    //   而 scb_two 依赖分数; Verilog 要求先声明后使用, 故先算分, 再算几何)。
    //   4 队分数各自独立解码, 再由 scb_team_sel 选出当前槽/行对应的那一路。
    //--------------------------------------------------------------
    function [3:0] dec10;   // 十位
        input [7:0] a;
        dec10 = (a >= 8'd100) ? 4'd9 : (a / 8'd10);
    endfunction
    function [3:0] dec01;   // 个位
        input [7:0] a;
        dec01 = (a >= 8'd100) ? 4'd9 : (a % 8'd10);
    endfunction
    function [7:0] absv;    // 有符号 → 绝对值(8bit 无符号, ≤127)
        input signed [7:0] v;
        absv = v[7] ? (8'd0 - v[7:0]) : v[7:0];
    endfunction

    // 结束页要居中 → 必须先知道"当前槽两位还是个位"。当前槽的队号 =
    //   · 弹窗模式: scb_r16(行号 0..3); 结束页: end_team。
    //   为打破"几何依赖 scb_two → scb_two 依赖行号 → 行号依赖几何"的环,
    //   这里**预览**本槽队号: 弹窗的 scb_r16 只依赖 scb_ly(盒子内 y), 结束页
    //   只依赖 end_team, 二者都不依赖左右方向的居中留白 → 无环。
    //   (scb_ly/scb_ly12 只减 SCB_IT / end_sy, 与 end_lpad 无关, 故可先用。)
    wire [11:0] scb_ly12_p = scb_in ? (py1n - SCB_IT) : (py1n - end_sy - 12'd1);
    wire [5:0]  scb_ly_p   = scb_ly12_p[5:0];
    wire [2:0]  scb_r16_p  = scb_in ? (scb_ly_p / 6'd14) : {1'b0, end_team};

    reg signed [7:0] scv_sel;
    always @* begin
        case (scb_r16_p)
            3'd0:    scv_sel = scv0;
            3'd1:    scv_sel = scv1;
            3'd2:    scv_sel = scv2;
            default: scv_sel = scv3;
        endcase
    end
    wire [7:0] scv_abs  = absv(scv_sel);
    wire       scv_neg  = scv_sel[7];
    wire [3:0] scv_d10  = dec10(scv_abs);
    wire [3:0] scv_d01  = dec01(scv_abs);
    wire       scv_two  = (scv_d10 != 4'd0);          // 是否两位数

    // ★弹窗模式下 lx 恒 ≥0(盒内偏移); 结束页模式需先减"水平居中留白" ——
    //   缩进前先判是否已进到文字区, 否则 px1n 落在槽左留白内时会算出负偏移(回绕)。
    //   结束页留白 = 6px(两位数, 3 格) / 12px(个位, 2 格), 见下方 end_lpad。
    //   ★2026-10-09c 修: 原写死 +12 → 两位数(lpad=6)时把首字符左半(lx 0..5)整段
    //     拦掉, 正号/负号被切掉一半(实测 "+12" 只有 104 点阵像素而非 132)。
    //     必须与本槽实际左留白 end_lpad 一致 → 用 end_sx + end_lpad。
    //     (end_in_txt 须在 end_lpad 之后声明 —— Verilog 先声明后使用。)

    // 内区局部坐标: 弹窗模式取盒内偏移(已保证 ≥0); 结束页模式取槽内偏移。
    //   ★结束页居中处理: 槽宽 48, 字格 12。
    //     两位数(符号+十位+个位 = 3 格 = 36px) → 左留白 6px;
    //     个位数(符号+个位    = 2 格 = 24px) → 左留白 12px(整体居中, 不留空档)。
    //   故结束页的"文字区起点" = end_sx + (scb_two ? 6 : 12), 且字数按 2/3 动态。
    wire [11:0] end_lpad = scv_two ? 12'd6 : 12'd12;   // 结束页左留白
    wire end_in_txt = end_region && (px1n >= end_sx + end_lpad);
    wire [11:0] scb_lx12 = scb_in ? (px1n - SCB_IL)
                                  : (px1n - end_sx - end_lpad);
    wire [11:0] scb_ly12 = scb_ly12_p;
    wire [6:0]  scb_lx   = scb_lx12[6:0];        // 0..172
    wire [5:0]  scb_ly   = scb_ly12[5:0];        // 0..55(内区高 64-8=56)

    // ★行高层级: 每行占 14px(7px 字高 + 7px 行距), 4 行 = 56px = 内区高。
    //   弹窗模式: 行号/行内 y 来自盒内 y 分层(14px 一层), 字格 6×7。
    //   结束页模式: 行号 = 本槽队伍号(固定一行); 行内 y = 槽内 y, 字格 12×14
    //     → scb_ry 取 0..13, grow = ry>>1(0..6) 实现纵向 2×放大。
    wire [2:0]  scb_r16  = scb_in ? (scb_ly / 6'd14) : {1'b0, end_team};
    wire [3:0]  scb_ry   = scb_in ? (scb_ly % 6'd14)
                                  : {1'b0, scb_ly[3:0]};   // 结束页: 0..15(字格 14 高)
    // ★2026-10-09b 修 BUG-1: ci 必须 5 位 —— 内区宽 172, /6 商最大 28, 4 位装不下
    //   (回绕成 0..12 重复) → case 的 default 把超出部分全画成个位数字 → 行尾拖一串。
    //   ★2026-10-09c: 结束页字格 12px 宽 → ci 用 /12; 仍需 5 位(槽宽 48,/12 商最大 3)。
    //   ci_sel 统一取"本模式下的字符序号", 供下方 case 选择字符。
    wire [4:0]  scb_ci   = scb_in ? (scb_lx / 7'd6) : (scb_lx / 7'd12);   // 字符序号
    // ★bc 必须 4 位: 结束页按 12px 取模 → 0..11, 3 位装不下(会回绕)。
    wire [3:0]  scb_bc   = scb_in ? {1'b0,(scb_lx % 7'd6)} : (scb_lx % 7'd12);  // 字内列 0..5 / 0..11
    // 字行: 弹窗直接取 ry(0..6); 结束页 ry(0..13) 折半 → 纵向 2× 放大
    //   ★ry 可达 14/15(槽高 16, ly 0..15), >>1 得 7 → 越界; 由 scb_row7_ok 拦掉。
    wire [2:0]  scb_grow = scb_in ? scb_ry[2:0] : scb_ry[3:1];

    // 取当前行/槽对应队的分数解码结果(已在几何之前算好, 见上方 scv_* 段)
    wire        scb_neg = scv_neg;
    wire [3:0]  scb_d10 = scv_d10;
    wire [3:0]  scb_d01 = scv_d01;
    wire        scb_two = scv_two;

    // ★字符布局:
    //   · 弹窗(2026-10-09b 定稿): "T1±D" —— ci 0='T' 1=队号 2=符号 3=十位 4=个位。
    //     5×7 点阵放不下 16×16 中文, 故用 'T'(Team)+队号数字承担 "N号队" 语义。
    //   · 结束页(★2026-10-09c 用户要求): "±D" / "±DD" —— **无队号前缀**
    //     (QUIZ8 卡片上已印好队名), 且字格 2× 放大。
    //     ci 0=符号 1=首位 2=次位; 个位数时**首位即个位**(不留空, 文字整体居中)。
    reg  [3:0] scb_ch;
    always @* begin
        if (scb_in) begin
            case (scb_ci)
                5'd0: scb_ch = 4'd13;                     // 'T'(队号前缀, 代 "N号队")
                5'd1: scb_ch = {1'b0,scb_r16} + 4'd1;     // 队号 1..4
                5'd2: scb_ch = scb_neg ? 4'd11 : 4'd15;   // '-' / '+'
                5'd3: scb_ch = scb_d10;                   // 十位
                default: scb_ch = scb_d01;                // 个位
            endcase
        end
        else begin
            // 结束页: 符号 + 分数字。个位时首位直接显示个位(文字居中, 不留空格)。
            case (scb_ci)
                5'd0: scb_ch = scb_neg ? 4'd11 : 4'd15;   // '-' / '+'
                5'd1: scb_ch = scb_two ? scb_d10 : scb_d01;  // 首位: 两位数→十位; 个位→个位
                default: scb_ch = scb_d01;                // 次位 = 个位
            endcase
        end
    end

    // 弹窗: 十位为 0 → 十位格留空(仅个位)。
    wire scb_blank10 = scb_in && (scb_ci == 5'd3) && ~scb_two;
    // 结束页: 个位数时次位(ci 2)留空(首位已显示个位)。
    wire scb_blank01 = ~scb_in && (scb_ci == 5'd2) && ~scb_two;
    wire scb_blank   = scb_blank10 || scb_blank01;
    // ★文字实际宽度门控 —— 必须用**未截断**的 12bit 局部坐标 scb_lx12!
    //   scb_lx 是 lx12[6:0](0..127 循环) → 用 scb_lx 判宽度时, 128px 之后的像素
    //   会以 (lx-128) 的低值"绕回"通过判断 → 在 x=584+ 处又画一遍文字(BUG-1 真因)。
    wire scb_txt_ok  = (scb_lx12 < 12'd30);      // 弹窗 "T1±DD" 最长 5 字符 × 6px
    //   结束页: 两位数 3 格 × 12 = 36px; 个位 2 格 × 12 = 24px。
    wire end_txt_ok  = (scb_lx12 < (scb_two ? 12'd36 : 12'd24));
    // ★行号门控: 只有 4 支队伍 → 内区只画 4 行。盒内高 60px → ly/14 可达 4
    //   (第 5 行, 落在 y86..88), 必须拦掉, 否则多画一行(207 vs 183 的差)。
    wire scb_row_ok  = scb_in ? (scb_r16 < 3'd4) : 1'b1;
    wire scb_xok     = scb_in ? scb_txt_ok : end_txt_ok;
    // ★字行门控: 弹窗字格 7 行(0..6); 结束页字格 14 行(0..13)。
    wire scb_row7_ok = scb_in ? (scb_ry < 4'd7) : (scb_ry < 4'd14);
    // ★字列门控: 弹窗字格 5 有效列(0..4); 结束页字格 12 列, 取左 5 列做 2× 放大
    //   → 有效列 = bc>>1 的 5 列内。bc(0..11) 折半 → 0..5, 取 <5。
    wire [2:0] scb_bc5 = scb_in ? scb_bc : scb_bc[3:1];
    wire scb_bc5_ok = (scb_bc5 < 3'd5);

    wire [4:0] scb_g = resw_glyph(scb_ch, scb_grow);
    wire [2:0] scb_bidx = 3'd4 - scb_bc5;
    //   ★文字像素: 弹窗/结束页两模式共用 (scbx_region 为二几何并集)
    //     结束页须再经 end_in_txt 门控(排除槽左留白的负偏移区)。
    wire scb_pix = scbx_region && ~scb_border &&
                   (scb_in || end_in_txt) &&
                   scb_row7_ok && scb_row_ok &&
                   scb_bc5_ok && scb_xok && ~scb_blank &&
                   scb_g[scb_bidx];

    //--------------------------------------------------------------
    // 输出仲裁: 亮度条 > 缩放条 > 音量条 > 状态卡 > 分辨率字幕 > 分数板 > 淡入×亮度像素
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
                fo = C_CON_FG;                       // 对比度已生效档位(品红, 2026-10-09c)
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
        else if (scb_region) begin
            if (scb_border)
                fo = C_BAR_BD;                       // 弹窗描边
            else if (scb_pix)
                fo = C_SCB_TX;                       // 分数文字(金)
            else
                fo = C_CARD_BG;                      // 弹窗内衬底
        end
        else if (end_region) begin
            // 结束页散点: 用底色盖住 QUIZ8 图上的灰色 "--" 占位, 再叠金色分数。
            //   ★底色取图片卡片同款深蓝(24,40,78), 与卡片融为一体不显突兀。
            if (scb_pix) fo = C_SCB_TX;
            else         fo = C_END_BG;
        end
        else begin
            if (de1) begin
                fo = {wr_o, wg_o, wb_o};             // 显示有效区: 亮度×淡入淡出×中心扩散×Wipe
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
