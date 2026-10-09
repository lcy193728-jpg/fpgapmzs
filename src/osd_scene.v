//====================================================================
// 模块名 : osd_scene.v —— 抢答 / 应急 两场景 OSD 叠加引擎
//
// 变更史 : v11(2026-10-07) 会议场景整体删除(用户决策: 丢会议主攻抢答)。
//          删除内容 —— meeting_en 端口 / mt_ok 同步链 / ID_MT_* 四个图元 /
//          MT_TY·MT_GX·MR_TY·MR_GX·MA_TY·MA_GX·MA_B0·MA_PG·MP_GX·
//          MF_BASE·BAND_Y0..Y1 常量 / 公告翻页计数器(page,pfcnt) /
//          运行时长数字窗(mdg_*) / 页码数字窗(mpg_*) / 会议滚动条与
//          会议整套配色(C_MT_*) / run_hh·run_mm·run_ss 输入(只服务会议)。
//          保留 —— 抢答与应急两路画面、滚动相位、三级流水骨架、共享字形
//          ROM 接口(顶层仍一片 ROM 供 osd_menu/osd_welcome/osd_scene 复用)。
//
// 两场景互斥(SW 单选):
//   · 抢答(quiz_en)  : 
//     ★2026-10-09 按用户要求重构显示条件(原版"进场景即叠标题+状态+倒计时"
//       会遮挡卡上题目图), 新规则:
//       - 题目页(qstate==IDLE): **不叠任何字** —— 题干/选项全在卡上 QUIZ[题号]
//         图里, 且图内自带「抢答题·第N/3题」标题; OSD 叠"抢答进行中"只有
//         遮挡副作用, 故整页透传。
//       - 抢答中(qstate==RUN): 只在**倒计时行**叠剩余秒(金色), 标题条亦不叠。
//       - 已锁定(qstate==LOCK)/超时(TIMEUP): **不叠任何字** —— 队伍图本身
//         已含队名与"N 号队伍·抢答成功", 再叠"选手N号抢答成功/抢答中"纯属
//         重复遮挡(用户明确要求隐藏)。
//       ⇒ 即: 抢答场景 OSD 只剩"倒计时秒数"一个动态元素, 其余全部透传。
//   · 应急(alarm_en) : 顶部 52 行**闪烁**红条(4Hz)+ 红条内警示三角图标
//     (RTL 绘制)+ 深红衬底标题「紧急情况 请立即疏散」+ 底部滚动疏散告警。
//     ※ 顶层实际把本层 alarm_en 接 1'b0 —— 四类应急画面由下级
//       emergency_multi_overlay 统一绘制; 本层保留该通路以兼容独立仿真。
//   OSD 区域以外像素**原样透传**; 两个使能全 0 时本模块纯透传。
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
//   t_tens/t_ones 来自 sd_card_clk(100MHz) 域, 内部两级同步。
// 语言   : 纯 Verilog-2001(兼容 TD EDA 前台与 ModelSim)。
//====================================================================

`timescale 1ns/1ps

module osd_scene #(
    parameter DATA_W     = 24,               // 像素位宽(RGB888)
    parameter H_ACT      = 640,              // 有效宽
    parameter V_ACT      = 480,              // 有效高
    parameter [21:0] BLINK_DIV   = 22'd3_146_875  // 125ms@25.175MHz(4Hz 闪烁)
)(
    input                video_clk,          // 像素时钟(≈25.175MHz)
    input                rst,                // 高有效复位
    // ---- 输入: 上游 OSD(osd_welcome)输出(已对齐) ----
    input                hs_i, vs_i, de_i,
    input  [DATA_W-1:0]  data_i,
    input  [11:0]        px_x,               // 与 data_i 同拍 x(0 基)
    input  [11:0]        px_y,               // 与 data_i 同拍 y(0 基)
    // ---- 场景使能(sd 域组合电平, 模块内两级同步) ----
    input                quiz_en,            // 1=抢答场景
    input                alarm_en,           // 1=应急中
    // ---- 抢答状态(quiz_ctrl 输出, sd 域) ----
    input        [1:0]   qstate,             // 0等待开始 1抢答中 2已锁定 3超时
    input        [1:0]   winner,             // 胜者 0..3(屏显 +1)
    input        [3:0]   t_tens,             // 剩余秒 BCD 十位
    input        [3:0]   t_ones,             // 剩余秒 BCD 个位
    // ---- 共享字形 ROM 接口(top 层统一例化一片, 各路 OSD 互斥使用) ----
    input  [31:0]        rom_q,              // ROM 读数据(晚 rom_addr_o 一拍)
    output               rom_en_o,           // ROM 读使能(本模块当拍读请求)
    output [12:0]        rom_addr_o,         // ROM 读地址
    // ---- 输出: 送 emergency_multi_overlay → display_adjust ----
    output               hs_o, vs_o, de_o,
    output [DATA_W-1:0]  data_o,
    output [11:0]        px_x_o,
    output [11:0]        px_y_o
);

    //--------------------------------------------------------------
    // 颜色定义
    //--------------------------------------------------------------
    localparam [DATA_W-1:0] C_QZ_TITLE = 24'hFF_D2_4A;  // 抢答标题(金)
    localparam [DATA_W-1:0] C_QZ_TXT   = 24'hF5_FD_FF;  // 抢答状态字(近白)
    localparam [DATA_W-1:0] C_QZ_DIG   = 24'hFF_D2_4A;  // 倒计时/胜者号(金)
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
    //   抢答: 标题2×(ty20,gx240,N5,base3776) / 状态2×(ty96,base见下)
    //         / 倒计时数字2×(NUM) / 秒2×(ty180,gx336,base4640)
    //         (原 滚动 ty452,N20,base4672 已于 2026-10-09 按用户要求移除)
    //   应急: 标题2×(ty82,gx160,N10,base4992) / 滚动(ty452,N24,base5312,周期384)
    //   ※ 会议带(2512/2768/3408/3456)自 v11 起不再被本模块引用。
    //--------------------------------------------------------------
    localparam [12:0] NUM_BASE = 13'd5696;      // 数字带(N10, 1× 字模)

    localparam [11:0] QT_TY = 12'd20,  QT_GX = 12'd240;   // 抢答标题(2×,N5)
    localparam [11:0] QS_TY = 12'd96;                     // 状态行 ty(2×)
    localparam [12:0] QW_BASE = 13'd3936;                 // 等待开始(N4)
    localparam [12:0] QR_BASE = 13'd4064;                 // 抢答中(N3)
    localparam [12:0] QL_BASE = 13'd4160;                 // 选手(N2)
    localparam [12:0] QX_BASE = 13'd4224;                 // 号抢答成功(N5)
    localparam [12:0] QN_BASE = 13'd4384;                 // 时间到无人抢答(N8)
    localparam [11:0] QC_TY = 12'd180;                    // 倒计时行 ty(2×)
    localparam [12:0] QSEC_BASE = 13'd4640;               // "秒"(N1,2×)
    // QF_BASE(4672 抢答滚动 1×,N20) 已随"抢答底部滚动须知"一并移除(2026-10-09)

    localparam [11:0] AT_TY = 12'd82,  AT_GX = 12'd160;   // 应急标题(2×,N10)
    localparam [12:0] AF_BASE = 13'd5312;                 // 应急滚动(1×,N24)
    localparam [11:0] AL_BAR_ROWS = 12'd52;               // 顶部红条行数
    localparam [11:0] AL_TBY0 = 12'd74, AL_TBY1 = 12'd122;// 应急标题衬底带行窗
    localparam [11:0] AL_TBX0 = 12'd140, AL_TBX1 = 12'd500;
    localparam [11:0] FOOT_Y0 = 12'd438, FOOT_Y1 = 12'd480; // 底部暗带行窗

    //--------------------------------------------------------------
    // 场景使能 / 抢答状态 过域(各两级同步)
    //   注: 这些量在 sd 域均为"慢变"(按键/1Hz 更新), 两级同步足够;
    //       数字为显示用途, 极端采样瞬间最多出现 1 帧非单调值。
    //--------------------------------------------------------------
    reg qz_s0, al_s0, qz_s1, al_s1;
    reg [1:0] qs_s0, qs_s1;
    reg [1:0] wn_s0, wn_s1;
    reg [3:0] tt_s0, tt_s1, to_s0, to_s1;

    always @(posedge video_clk or posedge rst) begin
        if (rst) begin
            qz_s0 <= 1'b0; al_s0 <= 1'b0;
            qz_s1 <= 1'b0; al_s1 <= 1'b0;
            qs_s0 <= 2'd0; qs_s1 <= 2'd0;
            wn_s0 <= 2'd0; wn_s1 <= 2'd0;
            tt_s0 <= 4'd0; tt_s1 <= 4'd0; to_s0 <= 4'd0; to_s1 <= 4'd0;
        end
        else begin
            qz_s0 <= quiz_en;    al_s0 <= alarm_en;
            qz_s1 <= qz_s0;      al_s1 <= al_s0;
            qs_s0 <= qstate;     qs_s1 <= qs_s0;
            wn_s0 <= winner;     wn_s1 <= wn_s0;
            tt_s0 <= t_tens;     tt_s1 <= tt_s0;
            to_s0 <= t_ones;     to_s1 <= to_s0;
        end
    end

    wire        qz_ok = qz_s1, al_ok = al_s1;
    wire [1:0]  qstate_s = qs_s1;
    wire [1:0]  winner_s = wn_s1;
    wire [3:0]  t_tens_s = tt_s1, t_ones_s = to_s1;

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
    // 滚动相位(每帧 vsync 上升沿 +1; 按当前场景带宽周期回卷。
    //   v11 起只剩应急(384px)一种周期; 抢答滚动带已于 2026-10-09 移除)
    //--------------------------------------------------------------
    reg        vsd;
    reg [9:0]  phase;
    wire       vs_rise = vs_i & ~vsd;
    wire [11:0] act_per = 12'd384;

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
        ID_QZ_TITLE = 4'd1,
        ID_QZ_STAT  = 4'd2,
        ID_QZ_CNT   = 4'd3,
        ID_AL_TITLE = 4'd5,
        ID_AL_FOOT  = 4'd6;

    reg [3:0] rid2;
    always @(*) begin
        rid2 = ID_NONE;
        if (al_ok) begin
            if      ((py2 >= 12'd82)  && (py2 < 12'd114)) rid2 = ID_AL_TITLE;
            else if ((py2 >= 12'd452) && (py2 < 12'd468)) rid2 = ID_AL_FOOT;
        end
        else if (qz_ok) begin
            // ★2026-10-09: 抢答场景只保留"抢答中"态的倒计时行;
            //   标题条/状态行/队伍图上的文字一律不叠(见文件头说明)。
            if ((py2 >= QC_TY) && (py2 < QC_TY + 12'd32) &&
                (qstate_s == 2'd1))                       rid2 = ID_QZ_CNT;
        end
    end

    // A 级: 滚动取模(px2 + phase, 先折 640 再按带宽周期取模)
    wire [11:0] wxx  = px2 + {2'b00, phase};
    wire [11:0] wx_1 = (wxx >= 12'd640) ? (wxx - 12'd640) : wxx;
    wire [11:0] aw_m = (wx_1 >= 12'd384) ? (wx_1 - 12'd384) : wx_1;  // 应急

    // A 级: 行内偏移收窄 + 变量×小常量改移位加(★2026-09-21 面积优化)
    //   rid2 已把 py2 限定在本带行窗内(带宽 ≤32), 模 2^k 减法逐位精确,
    //   却把 12bit 减法器与 12bit×常量乘法器一起收窄到 5/4 位。
    wire [4:0] dy_20 = py2[4:0] - 5'd20;   // 抢答标题[20,52) / 倒计时[180,212)
    wire [4:0] dy_at = py2[4:0] - 5'd18;   // 应急标题  [82,114)
    wire [4:0] dy_qs = py2[4:0];           // 抢答状态  [96,128)
    wire [3:0] dy_4  = py2[3:0] - 4'd4;    // 底部滚动[452,468)(仅应急)

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

    // A 级: ROM 读请求(仅在字形窗内发, 省功耗)
    reg        rom_en;
    reg [12:0] rom_addr;
    always @(*) begin
        rom_en   = 1'b0;
        rom_addr = 13'd0;
        if (de2) begin
            case (rid2)
                // ---- 抢答(仅倒计时行; 标题/状态/队伍图文字已移除 2026-10-09) ----
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
    // 字形 ROM(同步读, q 晚 addr 一拍; 与菜单/迎新共用同一生成文件)
    //   ★V3: 位宽 16→32, 深度 4608→5856(2× 带存 32×32 真字模; 1× 带用低 16 位)
    //   ★资源优化: ROM 实体移到 top 层统一例化(各路 OSD 互斥, 只占一份 BRAM)。
    //--------------------------------------------------------------
    assign rom_en_o   = rom_en;
    assign rom_addr_o = rom_addr;

    //--------------------------------------------------------------
    // B 级: 行窗分类 / 滚动取模 —— 全部改为 A 级结果打一拍
    //   ★2026-09-21 面积优化: py3 ≡ py2 延迟 1 拍(px3<=px2; py3<=py2),
    //     故 f(py3) 恒等于 f(py2) 延迟 1 拍。原先 B 级把"按 py3 分类
    //     文字带"、"数字格窗"、"px3+phase 两次取模"整套重算了一遍,
    //     是本模块 633 条进位链的首要来源。改为纯打拍后画面逐像素完全不变。
    //--------------------------------------------------------------
    reg [3:0]  rid3;
    reg [11:0] aw3_m;
    always @(posedge video_clk or posedge rst) begin
        if (rst) begin
            rid3    <= ID_NONE;
            aw3_m   <= 12'd0;
        end
        else begin
            rid3    <= rid2;
            aw3_m   <= aw_m;
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
            else if (qz_ok) begin
                case (rid3)
                    ID_QZ_CNT: begin
                        if (qcg_hit)
                            // 倒计时数字仍是 NUM 16×16 字模, 2× 折叠 → 取第 15..0 位
                            ink = rom_q[15 - (((px3 - qcg_bx0) & 12'd31) >> 1)];
                        else if ((px3 >= 12'd336) && (px3 < 12'd368))
                            ink = rom_q[31 - ((px3 - 12'd336) & 12'd31)];   // "秒" 32×32
                    end
                    default: ;
                endcase
            end
        end
    end

    //--------------------------------------------------------------
    // B 级: 区域命中(衬底色块)
    //--------------------------------------------------------------
    wire qz_band  = (py3 >= 12'd12)  && (py3 < 12'd60)  &&
                    (px3 >= 12'd200) && (px3 < 12'd440);
    wire qz_panel = (py3 >= 12'd84)  && (py3 < 12'd228) &&
                    (px3 >= 12'd160) && (px3 < 12'd480);
    wire foot_band= (py3 >= FOOT_Y0) && (py3 < FOOT_Y1);
    wire al_tband = (py3 >= AL_TBY0) && (py3 < AL_TBY1) &&
                    (px3 >= AL_TBX0) && (px3 < AL_TBX1);

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
    // 输出仲裁(组合): 应急 > 抢答 > 背景透传
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
            else if (qz_ok) begin
                // ★2026-10-09: 抢答场景只剩倒计时一个元素(其余全部透传);
                //   倒计时文字直接叠在背景上(不再画状态面板衬底)。
                if (qcg_hit || qsec_hit)
                    fo = ink ? C_QZ_DIG : da3;            // 倒计时数字/秒(金色)
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
