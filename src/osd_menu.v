//====================================================================
// 模块名 : osd_menu.v —— 全屏矢量首页菜单 + 应急叠加引擎(V2)
// 功能   :
//   在 osd_engine 输出(重建 0 基坐标 px_x/px_y, 与 data_i 严格同拍)
//   之上叠加画面, 输出送 hdmi_tx:
//     · 应急红条 : emerg 期间顶部 0~(EMERG_ROWS-1) 行铺满警示红
//                  (最高优先级; 底层画面保留不清屏)
//     · 全屏菜单 : menu 期间【整帧由本模块自绘, 不透传背景】——
//                  深蓝底色 + 顶部 2×放大标题 + 金色标题线 +
//                  4 张场景卡(左侧强调色块/描边/2×卡标题) +
//                  底部黑色滚动宣传语条(每帧左移 1px, 平滑滚动)
//                  ★2026-09-21: 按需求去掉 4 张卡下的 1× 副标题(小字),
//                    做法是只把 TG0~TG3 从扫描链摘除(分类/几何/取色三处),
//                    字模 ROM 不动(base 偏移不变, 其它 OSD 模块零影响)。
//     · 其余       : 原样透传背景(各场景轮播画面)
// 数据管线 :
//   {sync,data,px} 输入视为已对齐; 模块内三级移位寄存器(da1/2/3 +
//   px1/2/3 + sync1/2/3)统一延迟 3 拍; 输出为组合仲裁(恒定延迟 3 clk)。
//   字形 ROM(osd_font_rom, 同步读, 晚 addr 一拍): A 级(px2)发地址,
//   ROM 回读一拍 → q 恰与 px3/da3 对齐; 仲裁在 da3 节拍用 px3 + q 判定。
//   · 2× 带(标题/卡标题): A 级 row=py-ty, col=(px-gx)>>5, 取位 rom_q[31-((px-gx)&31)]
//     —— ROM 里直接存 32×32 真字模, 1:1 显示(物理尺寸 = 原 16×16 放大 2 倍)。
//   · 1× 带(副标题): A 级 row=py-ty, col=(px-gx)>>4, 取位 rom_q[15-((px-gx)&15)]。
//     ★2026-09-21 卡副标题下线后, 已无字带走这条"非滚动 1×"通路(滚动条自己
//       走下面的独立分支), 该通路按最小改动原则保留未删, 仅不再被选到。
//   · 滚动条 : A 级按 (px+phase) 对 320px 取模得到单元内偏移, phase 在
//     每帧 vsync 上升沿 +1(0..319), 实现整行平滑左移, 无缝循环。
// 时钟域 : 本模块 video_clk(≈25.175MHz); menu_en/emerg_en 为
//          sd_card_clk(100MHz) 域电平, 模块内两级同步器过域。
// 语言   : 纯 Verilog-2001(兼容 TD EDA 前台与 ModelSim)。
// 注意   : 几何/文案与 tools/gen_osd_font.py 同源; 修改需两处同步并
//           重新生成字形 ROM 后跑 tb_osd_menu.v 像素级回归。
//====================================================================

`timescale 1ns/1ps

module osd_menu #(
    parameter DATA_W     = 24,               // 像素位宽(RGB888)
    parameter H_ACT      = 640,              // 有效宽
    parameter V_ACT      = 480,              // 有效高
    parameter EMERG_ROWS = 52                // 应急红条行数(顶部)
)(
    input                video_clk,          // 像素时钟(≈25.175MHz)
    input                rst,                // 高有效复位
    // ---- 输入: osd_engine 输出(已对齐) ----
    input                hs_i, vs_i, de_i,
    input  [DATA_W-1:0]  data_i,
    input  [11:0]        px_x,               // 与 data_i 同拍 x(0 基)
    input  [11:0]        px_y,               // 与 data_i 同拍 y(0 基)
    // ---- 控制(异步电平, 模块内同步) ----
    input                menu_en,            // 1=菜单态
    input                emerg_en,           // 1=应急中
    // ---- 共享字形 ROM 接口(top 层统一例化一片, 三路 OSD 互斥使用) ----
    input  [31:0]        rom_q,          // ROM 读数据(晚 rom_addr_o 一拍)
    output               rom_en_o,       // ROM 读使能(本模块当拍读请求)
    output [12:0]        rom_addr_o,     // ROM 读地址
    // ---- 输出: 送 osd_welcome(再经 display_adjust 后送 hdmi_tx) ----
    output               hs_o, vs_o, de_o,
    output [DATA_W-1:0]  data_o,
    output [11:0]        px_x_o,         // 与 data_o 同拍坐标(透传下游)
    output [11:0]        px_y_o
);

    //--------------------------------------------------------------
    // 颜色定义
    //--------------------------------------------------------------
    localparam [DATA_W-1:0] C_RED    = 24'hFF_2A_2A;   // 应急红条
    localparam [DATA_W-1:0] C_BG_FULL= 24'h0A_12_20;   // 全屏底色(深藏青)
    localparam [DATA_W-1:0] C_ULINE  = 24'hFF_D2_4A;   // 标题下金色强调线
    localparam [DATA_W-1:0] C_CARD   = 24'h15_27_42;   // 卡片内衬(藏蓝)
    localparam [DATA_W-1:0] C_BD     = 24'h2F_A9_E8;   // 卡片描边(亮钢蓝)
    localparam [DATA_W-1:0] C_ACC0   = 24'h2E_7C_F6;   // 卡1 左色块(迎新-蓝)
    localparam [DATA_W-1:0] C_ACC1   = 24'h18_C9_9E;   // 卡2 左色块(会议-青)
    localparam [DATA_W-1:0] C_ACC2   = 24'hF5_A6_23;   // 卡3 左色块(抢答-橙)
    localparam [DATA_W-1:0] C_ACC3   = 24'hE8_4A_4A;   // 卡4 左色块(应急-红)
    localparam [DATA_W-1:0] C_TEXT_W = 24'hF5_FD_FF;   // 大标题/卡标题(近白)
    localparam [DATA_W-1:0] C_MARQ   = 24'hFF_7A_1F;   // 滚动宣传语(亮橙, 与金线异色便于 TB 计数)
    localparam [DATA_W-1:0] C_MQ_BG  = 24'h00_00_00;   // 宣传语黑底

    //--------------------------------------------------------------
    // 几何常量(与 tools/gen_osd_font.py BANDS 表一致, 勿单独改动)
    //   顶部大标题(2×)      : 行 28..60   x 176..464   9 格  base    0
    //   卡1..4 标题(2×)     : 行 92/182/272/362..+32 x 98..226 4 格
    //                            base 288/416/544/672
    //   卡1..4 副标题(1×)   : 【2026-09-21 已下线, 不再显示】
    //                            原行 132/222/312/402..+16 x 98..210 7 格,
    //                            base 800/912/1024/1136 在 ROM 里仍保留
    //                            (不动 ROM 就不必重算所有 base)。
    //   滚动宣传语(1×,20格) : 行 451..467  base 1248 (每行 20 字周期 320px)
    //   卡区                : x 70..570, top 80/170/260/350, 高 80, 距 10
    //   ★字模分辨率(字库 V3): 2× 带存 32×32 真字模(1:1 显示, 物理尺寸不变);
    //     1× 带存 16×16 字模。ROM 位宽 32bit, 深度 5856。
    //     2× 带取位用 rom_q[31-...], 1× 带用 rom_q[15-...]。
    //--------------------------------------------------------------
    localparam [11:0] T_TY   = 12'd28;
    localparam [11:0] T_GX   = 12'd176;
    localparam [4:0]  T_N    = 5'd9;
    localparam [11:0] CX0    = 12'd70;         // 卡左
    localparam [11:0] CX1    = 12'd570;        // 卡右(不含)
    localparam [11:0] ACC_W  = 12'd8;          // 左强调色块宽
    localparam [11:0] CARD_H = 12'd80;         // 卡高
    localparam [11:0] TOP0   = 12'd80;         // 卡1 top
    localparam [11:0] GAP    = 12'd10;         // 卡间距
    localparam [11:0] TX     = 12'd98;         // 卡内文字 x(标题与副标题同)
    localparam [10:0] MQ_BASE= 11'd1248;       // 滚动条 ROM base
    localparam [11:0] MQ_TY  = 12'd451;        // 滚动条字形行起点
    localparam [11:0] MQ_Y0  = 12'd438;        // 黑底上边
    localparam [4:0]  MQ_P   = 5'd20;          // 每行格数
    localparam [11:0] MQ_PER = 12'd320;        // 周期 = MQ_P*16 px

    // 分区 id(★2026-09-21: ID_TG0~3 随卡副标题一并下线)
    localparam [3:0] ID_TITLE = 4'd0, ID_CT0 = 4'd1, ID_CT1 = 4'd2,
                     ID_CT2   = 4'd3, ID_CT3 = 4'd4,
                     ID_MARQ  = 4'd9, ID_NONE= 4'd15;

    //--------------------------------------------------------------
    // 控制标志过域(两级同步)
    //--------------------------------------------------------------
    reg m_s0, m_s1, e_s0, e_s1;
    wire menu_ok  = m_s1;
    wire emerg_ok = e_s1;

    always @(posedge video_clk or posedge rst) begin
        if (rst) begin
            m_s0 <= 1'b0; m_s1 <= 1'b0;
            e_s0 <= 1'b0; e_s1 <= 1'b0;
        end
        else begin
            m_s0 <= menu_en;  m_s1 <= m_s0;
            e_s0 <= emerg_en; e_s1 <= e_s0;
        end
    end

    //--------------------------------------------------------------
    // 滚动相位(每帧 vsync 上升沿 +1, 0..319)
    //--------------------------------------------------------------
    reg vsd;
    reg [9:0] phase;
    wire vs_rise = vs_i & ~vsd;
    always @(posedge video_clk or posedge rst) begin
        if (rst) begin
            vsd   <= 1'b0;
            phase <= 10'd0;
        end
        else begin
            vsd <= vs_i;
            if (vs_rise) begin
                if (phase >= (MQ_PER - 10'd1))
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
    // A 级(读请求): 按 py2 分类所在文字带
    //   ★2026-09-21: 卡副标题的 4 个分支(原行 132/222/312/402)已删除 ——
    //     这些行不再归属任何文字带, 逐像素判定与 ROM 读请求都不会产生,
    //     卡内下半部自然落到"卡内衬"底色。比较器由 10 级缩短为 6 级。
    //--------------------------------------------------------------
    reg [3:0] rid2;
    always @* begin
        rid2 = ID_NONE;
        if      ((py2 >= 12'd28)  && (py2 < 12'd60))  rid2 = ID_TITLE; // 大标题
        else if ((py2 >= 12'd92)  && (py2 < 12'd124)) rid2 = ID_CT0;   // 卡1标题
        else if ((py2 >= 12'd182) && (py2 < 12'd214)) rid2 = ID_CT1;   // 卡2标题
        else if ((py2 >= 12'd272) && (py2 < 12'd304)) rid2 = ID_CT2;   // 卡3标题
        else if ((py2 >= 12'd362) && (py2 < 12'd394)) rid2 = ID_CT3;   // 卡4标题
        else if ((py2 >= 12'd451) && (py2 < 12'd467)) rid2 = ID_MARQ;  // 滚动条
    end

    // A 级: 几何表(字带)
    //   xr2 = 字窗右沿(不含) = gx2 + n2*(s2?32:16), 直接列常量:
    //     标题 176+9*32=464 / 卡标题 98+4*32=226 / 滚动条 320。
    //   ★2026-09-21: 原先在窗口判定里现算 `gx2 + (s2 ? n2<<5 : n2<<4)`,
    //     每处都生成"变长移位 + 12bit 加法器 + 12bit 比较器"(A/B 级各一份),
    //     改为常量表后这些逻辑全部消失。
    reg [11:0] gx2, ty2, xr2;
    reg [4:0]  n2;
    reg [10:0] b2;
    reg        s2;      // 1=2×放大
    reg        mq2;     // 1=滚动条
    always @* begin
        gx2 = 12'd0; ty2 = 12'd0; xr2 = 12'd0; n2 = 5'd0; b2 = 11'd0; s2 = 1'b0; mq2 = 1'b0;
        case (rid2)
            ID_TITLE: begin gx2=12'd176; ty2=12'd28;  xr2=12'd464; n2=5'd9;  b2=11'd0;    s2=1'b1; end
            ID_CT0:   begin gx2=12'd98;  ty2=12'd92;  xr2=12'd226; n2=5'd4;  b2=11'd288;  s2=1'b1; end
            ID_CT1:   begin gx2=12'd98;  ty2=12'd182; xr2=12'd226; n2=5'd4;  b2=11'd416;  s2=1'b1; end
            ID_CT2:   begin gx2=12'd98;  ty2=12'd272; xr2=12'd226; n2=5'd4;  b2=11'd544;  s2=1'b1; end
            ID_CT3:   begin gx2=12'd98;  ty2=12'd362; xr2=12'd226; n2=5'd4;  b2=11'd672;  s2=1'b1; end
            ID_MARQ:  begin gx2=12'd0;   ty2=12'd451; xr2=12'd320; n2=5'd20; b2=11'd1248; s2=1'b0; mq2=1'b1; end
            default:  ;
        endcase
    end

    // A 级: 滚动条相位取模(px+phase 对 320 取模; max≈958 两次减法足够)
    wire [11:0] wxx  = px2 + {2'b00, phase};
    wire [11:0] wx_1 = (wxx >= 12'd640) ? (wxx - 12'd640) : wxx;
    wire [11:0] wx_m = (wx_1 >= MQ_PER) ? (wx_1 - MQ_PER) : wx_1;

    // A 级: ROM 读请求(字形窗内才发, 省功耗)
    //   ★2026-09-21: 行偏移 `py2 - ty2` 只取低 6 位 —— rid2 已保证 py2 落在
    //     该带内(带宽 ≤32), 真实差值 ∈[0,31] ⊂ [0,63], 模 64 减法逐位精确,
    //     却把 12bit 减法器收窄成 6bit(乘法器操作数也随之变窄)。
    //     窗口右沿改用几何表常量 xr2, 不再现算 gx2 + (n2<<5|n2<<4)。
    reg rom_en;
    reg [12:0] rom_addr;
    wire [5:0]  dy2   = py2[5:0] - ty2[5:0];
    wire [11:0] xoff2 = px2 - gx2;
    always @* begin
        rom_en   = 1'b0;
        rom_addr = 13'd0;
        if (menu_ok && de2 && (rid2 != ID_NONE)) begin
            if (mq2) begin
                rom_en   = 1'b1;
                rom_addr = b2 + ({6'b0, dy2} * {1'b0, n2}) + (wx_m >> 4);  // cell=(wx_m>>4)
            end
            else begin
                if ((px2 >= gx2) && (px2 < xr2)) begin
                    rom_en   = 1'b1;
                    // 行号 = py2-ty2(2× 带存 32×32 真字模, 不再 >>1 折叠)
                    rom_addr = b2 + ({6'b0, dy2} * {1'b0, n2})
                                 + (xoff2 >> (s2 ? 5'd5 : 5'd4));
                end
            end
        end
    end

    // 字形 ROM(同步读, q 晚 addr 一拍; 深度=全部场景字模(osd_scene 同库, gen 生成)
    //   ★V3: 位宽 16→32(2× 带每行一个 32bit word 存 32×32 字模;
    //        1× 带仍每行一个 word 但只用低 16 位), 深度 4608→5856。
    //   ★资源优化: ROM 实体移到 top 层统一例化(三路 OSD 互斥, 只占一份 BRAM),
    //     本模块只把读请求/地址送出, 并接收共享读数据 rom_q。
    assign rom_en_o   = rom_en;
    assign rom_addr_o = rom_addr;

    //--------------------------------------------------------------
    // B 级(仲裁): 文字带 id / 几何 / 滚动相位 —— 全部改为 A 级结果打一拍
    //   ★2026-09-21 面积优化: py3 ≡ py2 延迟 1 拍(第 172-173 行 px3<=px2;
    //     py3<=py2), 因此 f(py3) 恒等于 f(py2) 延迟 1 拍。原先 B 级又把
    //     "按 py3 分类 10 个文字带"和"按 rid3 查几何表"整套重算了一遍,
    //     等于把 20 个 12bit 比较器 + 10 路优先链 + 10 路 case mux 白做两次,
    //     是本模块 261 条进位链的首要来源。改为纯打拍后画面逐像素完全不变
    //     (仍是恒定延迟 3 拍), 且 B 级组合路径显著变短(利于时序)。
    //--------------------------------------------------------------
    reg [3:0]  rid3;
    reg [11:0] gx3, xr3;
    reg        s3, mq3;
    reg [11:0] wx3_m;

    always @(posedge video_clk or posedge rst) begin
        if (rst) begin
            rid3  <= ID_NONE;
            gx3   <= 12'd0; xr3 <= 12'd0; s3 <= 1'b0; mq3 <= 1'b0;
            wx3_m <= 12'd0;
        end
        else begin
            rid3  <= rid2;
            gx3   <= gx2;  xr3 <= xr2;  s3 <= s2;  mq3 <= mq2;
            wx3_m <= wx_m;
        end
    end

    // B 级: 字形墨点判定(当前像素处字形是否落墨)
    reg ink;
    always @* begin
        ink = 1'b0;
        if (menu_ok && de3 && (rid3 != ID_NONE)) begin
            if (mq3) begin
                ink = rom_q[15 - wx3_m[3:0]];   // 字内列 = wx3_m 低 4 位
            end
            else if ((px3 >= gx3) && (px3 < xr3)) begin
                // 字内列号: 2× 带 = 32×32 字模 1:1(取第 31..0 位);
                //           1× 带 = 16×16 字模(取第 15..0 位)
                if (s3)
                    ink = rom_q[31 - ((px3 - gx3) & 12'd31)];
                else
                    ink = rom_q[15 - ((px3 - gx3) & 12'd15)];
            end
        end
    end

    //--------------------------------------------------------------
    // B 级: 卡区定位(确定落在哪张卡及其局部纵坐标)
    //--------------------------------------------------------------
    reg        incard;
    reg [11:0] ctop;
    always @* begin
        incard = 1'b0;
        ctop   = 12'd0;
        if ((px3 >= CX0) && (px3 < CX1)) begin
            if      ((py3 >= TOP0)             && (py3 < TOP0 + CARD_H))
                begin incard = 1'b1; ctop = TOP0; end
            else if ((py3 >= TOP0 + CARD_H + GAP) && (py3 < TOP0 + 2*CARD_H + GAP))
                begin incard = 1'b1; ctop = TOP0 + CARD_H + GAP; end
            else if ((py3 >= TOP0 + 2*(CARD_H+GAP)) && (py3 < TOP0 + 2*(CARD_H+GAP) + CARD_H))
                begin incard = 1'b1; ctop = TOP0 + 2*(CARD_H+GAP); end
            else if ((py3 >= TOP0 + 3*(CARD_H+GAP)) && (py3 < TOP0 + 3*(CARD_H+GAP) + CARD_H))
                begin incard = 1'b1; ctop = TOP0 + 3*(CARD_H+GAP); end
        end
    end

    // 卡内局部纵坐标(仅 incard 有效)
    wire [11:0] loc_y = py3 - ctop;
    // 左强调色块按卡取色
    reg [DATA_W-1:0] accent_c;
    always @* begin
        accent_c = C_ACC0;
        case (ctop)
            TOP0:                     accent_c = C_ACC0;
            TOP0 + CARD_H + GAP:      accent_c = C_ACC1;
            TOP0 + 2*(CARD_H+GAP):    accent_c = C_ACC2;
            TOP0 + 3*(CARD_H+GAP):    accent_c = C_ACC3;
            default:                  accent_c = C_ACC0;
        endcase
    end

    //--------------------------------------------------------------
    // B 级: 全屏矢量底色(文字带互不依赖; 卡片 色块/描边/内衬 细分)
    //--------------------------------------------------------------
    reg [DATA_W-1:0] base_c;
    always @* begin
        base_c = C_BG_FULL;
        if ((py3 >= MQ_Y0) && (py3 < V_ACT)) begin
            // 底部滚动宣传语黑底(全区宽)
            base_c = C_MQ_BG;
        end
        else if ((py3 >= 12'd64) && (py3 < 12'd66) &&
                 (px3 >= T_GX) && (px3 < T_GX + ({1'b0, T_N} << 5))) begin
            // 标题下金色强调线
            base_c = C_ULINE;
        end
        else if (incard) begin
            if (px3 < CX0 + ACC_W)
                base_c = accent_c;                          // 左强调色块
            else if ((loc_y < 12'd2) || (loc_y >= CARD_H - 12'd2)
                     || (px3 >= CX1 - 12'd2))
                base_c = C_BD;                              // 上/下/右描边
            else
                base_c = C_CARD;                            // 卡内衬
        end
    end

    //--------------------------------------------------------------
    // B 级: 字形颜色(按文字带类型; ★2026-09-21 副标题下线后只剩两档)
    //--------------------------------------------------------------
    reg [DATA_W-1:0] tcol;
    always @* begin
        tcol = C_TEXT_W;
        case (rid3)
            ID_MARQ: tcol = C_MARQ;
            default: tcol = C_TEXT_W;
        endcase
    end

    //--------------------------------------------------------------
    // 输出仲裁(组合): 应急红条 > 全屏菜单(字形墨点/底色) > 背景透传
    //--------------------------------------------------------------
    reg [DATA_W-1:0] fo;
    always @* begin
        fo = da3;                                           // 默认透传
        if (de3) begin
            if (emerg_ok && (py3 < EMERG_ROWS)) begin
                fo = C_RED;                                 // 应急顶部红条
            end
            else if (menu_ok) begin
                fo = ink ? tcol : base_c;                   // 全屏菜单自绘
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
