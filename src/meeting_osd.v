//====================================================================
// 模块名 : meeting_osd.v —— 会议场景 OSD 叠加(状态条 + 倒计时 + 进度条)
//          (2026-10-09j 新增; 2026-10-09n 倒计时改为 MM:SS 大字号)
//
// 定位: 在会议议程图(MEET*.BMP, 图上已有会议标题/时间/议程内容)之上叠加:
//   1. 顶部状态条(y=0..51): 红=会议中(RUN) / 黄=即将结束(WARN) / 绿=空闲(IDLE)
//   2. 右上角倒计时: MM:SS 格式(如 00:20), 4 位 7 段大数字 + 冒号,
//      置于半透明深色面板之上(白字 + 状态色描边), 远距离可读
//   3. 进度条: 剩余时间比例, 颜色随状态
//   全部由组合逻辑 + 1 拍输出寄存器实现, 恒定 1 拍延迟 + 坐标透传(与
//   其它 OSD 同构), 不读字库、零 BRAM、零 DSP。
//
// ★倒计时字形(2026-10-09n 重写):
//   上一版把数字画成 56x80 的"粗块 7 段", 实测远看糊成一团、认不出数字。
//   本版**直接沿用应急场景 emergency_multi_overlay.v 里已在板上长期验证
//   可读的 7 段几何**(24x32 字格 / 4px 段厚 / 冒号两点), 整数放大 2 倍
//   (48x64 字格 / 8px 段厚)保持线段对齐、边缘不毛。数字为纯白, 面板为
//   近黑 + 状态色描边, 对比度拉满 —— 这是"能不能看清"的关键。
//
// 时钟域: video_clk(≈25.175MHz); state/sec_left 来自 sd_card_clk(100MHz),
//   模块内两级同步(与 osd_scene 同法)。
// 语言: 纯 Verilog-2001。
//====================================================================
`timescale 1ns/1ps

module meeting_osd (
    input               video_clk,
    input               rst,                 // 高有效复位
    input               hs_i, vs_i, de_i,
    input  [23:0]       data_i,
    input  [11:0]       px_x, px_y,          // 与 data_i 同拍 0 基坐标
    input               meet_en,             // 会议场景使能(sd 域电平)
    input  [1:0]        m_state,             // 0=IDLE 1=RUN 2=WARN 3=NEXT
    input  [5:0]        m_sec,               // 剩余秒数 0..20
    output reg          hs_o, vs_o, de_o,
    output reg  [23:0]  data_o,
    output reg  [11:0]  px_x_o, px_y_o
);
    //============================================================
    // 场景使能/状态/秒数 两级同步(sd_card_clk → video_clk)
    //============================================================
    reg        en_s0, en_s1;
    reg [1:0]  st_s0, st_s1;
    reg [5:0]  sc_s0, sc_s1;
    always @(posedge video_clk or posedge rst) begin
        if (rst) begin
            en_s0 <= 1'b0; en_s1 <= 1'b0;
            st_s0 <= 2'd0; st_s1 <= 2'd0;
            sc_s0 <= 6'd0; sc_s1 <= 6'd0;
        end
        else begin
            en_s0 <= meet_en; en_s1 <= en_s0;
            st_s0 <= m_state; st_s1 <= st_s0;
            sc_s0 <= m_sec;   sc_s1 <= sc_s0;
        end
    end
    wire       en     = en_s1;
    wire [1:0] state  = st_s1;
    wire [5:0] sec    = sc_s1;

    //============================================================
    // 状态 → 颜色
    //   RUN=红 / WARN=黄 / IDLE=绿(其余同绿)
    //============================================================
    reg [23:0] bar_col;
    always @(*) begin
        case (state)
            2'd1:    bar_col = 24'hE24B4A;   // RUN 红
            2'd2:    bar_col = 24'hF0A020;   // WARN 黄
            default: bar_col = 24'h2FA84F;   // IDLE 绿
        endcase
    end

    //============================================================
    // 7 段字形: 位序 {g,f,e,d,c,b,a}, 即 bit0=a ... bit6=g, 1 = 点亮
    //   (与 emergency_multi_overlay.v 的 seg_on 完全等价, 已在板上验证可读)
    //   ⚠ 2026-10-09n 修正: 旧表把 bit0 当 g 编码, 导致数字 0 的"上横"不亮,
    //     画出来像 "U"/"C" 认不出 —— 这正是"看不出是几"的根因。
    //============================================================
    function [6:0] seg7;
        input [3:0] d;
        begin
            case (d)
                4'd0: seg7 = 7'b0111111;   // a b c d e f
                4'd1: seg7 = 7'b0000110;   // b c
                4'd2: seg7 = 7'b1011011;   // a b d e g
                4'd3: seg7 = 7'b1001111;   // a b c d g
                4'd4: seg7 = 7'b1100110;   // b c f g
                4'd5: seg7 = 7'b1101101;   // a c d f g
                4'd6: seg7 = 7'b1111101;   // a c d e f g
                4'd7: seg7 = 7'b0000111;   // a b c
                4'd8: seg7 = 7'b1111111;   // 全亮
                4'd9: seg7 = 7'b1101111;   // a b c d f g
                default: seg7 = 7'b0000000;
            endcase
        end
    endfunction

    //------------------------------------------------------------
    // 倒计时几何: 4 位数字 + 1 个冒号, MM:SS = "00:20"
    //   字格 48x64(紧急场景 24x32 的 2 倍), 段厚 8px(原 4px 的 2 倍)。
    //   dx∈[0,48) dy∈[0,64) 为单字内坐标。
    //   段(放大 2 倍, 与 emergency 段序严格一致):
    //     a 上横  dy<8   && dx∈[8,40)
    //     d 下横  dy>=56 && dx∈[8,40)
    //     g 中横  dy∈[28,36) && dx∈[8,40)
    //     f 左竖上 dx<8 && dy∈[8,30)
    //     e 左竖下 dx<8 && dy∈[34,56)
    //     b 右竖上 dx>=40 && dy∈[8,30)
    //     c 右竖下 dx>=40 && dy∈[34,56)
    //------------------------------------------------------------
    localparam [11:0] DW = 12'd48, DH = 12'd64;      // 单字尺寸
    localparam [11:0] DGAP = 12'd8;                  // 字间距
    localparam [11:0] CGAP = 12'd8;                  // 冒号左右与数字的间距
    localparam [11:0] CWD  = 12'd16;                 // 冒号占宽
    localparam [11:0] X0 = 12'd376, Y0 = 12'd64;     // 倒计时块左上角(面板顶 = 52, 恰在状态条之下)
    // 总宽 = 4*DW + 2*DGAP + 2*CGAP + CWD = 192+16+16+16 = 240 → x∈[376,616)
    // 各字左沿: d3=376, d2=432, 冒号=488, d1=512, d0=568 (右缘 616)
    localparam [11:0] X3 = X0;                                   // 分钟十位
    localparam [11:0] X2 = X0 + DW + DGAP;                       // 分钟个位
    localparam [11:0] XC = X2 + DW + CGAP;                       // 冒号
    localparam [11:0] X1 = XC + CWD + CGAP;                      // 秒十位
    localparam [11:0] X0D= X1 + DW + DGAP;                       // 秒个位

    // 单字命中: 给像素(x,y)、字左沿 x0、数字 d, 返回是否落在该字点亮段内
    function dig_hit;
        input [11:0] x, y, x0;
        input [3:0]  d;
        reg [11:0] dx, dy;
        reg [6:0]  s;
        begin
            s  = seg7(d);
            dx = x - x0;                 // 调用前已保证 x >= x0
            dy = y - Y0;                 // 调用前已保证 y >= Y0
            dig_hit = (s[0] && dy < 12'd8            && dx >= 12'd8 && dx < 12'd40) || // a
                      (s[3] && dy >= 12'd56 && dy < 12'd64 && dx >= 12'd8 && dx < 12'd40) || // d
                      (s[6] && dy >= 12'd28 && dy < 12'd36 && dx >= 12'd8 && dx < 12'd40) || // g
                      (s[5] && dx < 12'd8      && dy >= 12'd8 && dy < 12'd30) || // f
                      (s[4] && dx < 12'd8      && dy >= 12'd34 && dy < 12'd56) || // e
                      (s[1] && dx >= 12'd40    && dy >= 12'd8 && dy < 12'd30) || // b
                      (s[2] && dx >= 12'd40    && dy >= 12'd34 && dy < 12'd56);  // c
        end
    endfunction

    // MM:SS 各位(会议演示 20s, 分钟恒为 00, 仍按真实进制显示)
    wire [5:0] mm = sec / 6'd60;            // 分(0)
    wire [5:0] ss = sec % 6'd60;            // 秒(0..20)
    wire [3:0] m_ten = mm / 6'd10;
    wire [3:0] m_one = mm % 6'd10;
    wire [3:0] s_ten = ss / 6'd10;
    wire [3:0] s_one = ss % 6'd10;

    //============================================================
    // 倒计时区命中判定
    //============================================================
    wire in_dig_row = (px_y >= Y0) && (px_y < Y0 + DH);   // y∈[64,128)
    reg  dig_on;
    always @(*) begin
        dig_on = 1'b0;
        if (en && in_dig_row) begin
            if (px_x >= X3 && px_x < X3 + DW && dig_hit(px_x, px_y, X3, m_ten)) dig_on = 1'b1;
            if (px_x >= X2 && px_x < X2 + DW && dig_hit(px_x, px_y, X2, m_one)) dig_on = 1'b1;
            if (px_x >= X1 && px_x < X1 + DW && dig_hit(px_x, px_y, X1, s_ten)) dig_on = 1'b1;
            if (px_x >= X0D && px_x < X0D + DW && dig_hit(px_x, px_y, X0D, s_one)) dig_on = 1'b1;
        end
    end

    // 冒号: 两个 8x8 方块(x∈[XC,XC+8), 与 emergency 冒号同法 2 倍放大)
    wire colon_on = en && (px_x >= XC) && (px_x < XC + 12'd8) &&
                    (((px_y >= Y0 + 12'd20) && (px_y < Y0 + 12'd28)) ||
                     ((px_y >= Y0 + 12'd36) && (px_y < Y0 + 12'd44)));

    //============================================================
    // 倒计时深色面板(提升对比度: 白字压在照片上也能看清)
    //   面板 x∈[X0-12, X0D+DW+12) y∈[Y0-12, Y0+DH+12)
    //   边框 2px = 状态色; 内部近黑 0x0A1018
    //============================================================
    localparam [11:0] PX_L = X0 - 12'd12;
    localparam [11:0] PX_R = X0D + DW + 12'd12;
    localparam [11:0] PY_T = Y0 - 12'd12;
    localparam [11:0] PY_B = Y0 + DH + 12'd12;
    wire panel_on  = en && (px_x >= PX_L) && (px_x < PX_R) &&
                            (px_y >= PY_T) && (px_y < PY_B);
    wire panel_brd = panel_on && ((px_x < PX_L + 12'd2) || (px_x >= PX_R - 12'd2) ||
                                  (px_y < PY_T + 12'd2) || (px_y >= PY_B - 12'd2));

    //============================================================
    // 状态条命中(y=0..51)
    //============================================================
    wire bar_on = en && (px_y < 12'd52);

    //============================================================
    // 进度条: y=180..191, x=430..630, 剩余比例 = sec/20
    //============================================================
    localparam [11:0] PB_X0 = 12'd430, PB_W = 12'd200, PB_Y0 = 12'd180, PB_H = 12'd12;
    wire [11:0] pb_fill = (PB_W * sec) / 6'd20;
    wire pb_on  = en && (px_y >= PB_Y0) && (px_y < PB_Y0 + PB_H) &&
                  (px_x >= PB_X0) && (px_x < PB_X0 + PB_W);
    wire pb_filled = (px_x < PB_X0 + pb_fill);

    //============================================================
    // 输出(1 拍寄存器, 恒定 1 拍延迟 + 坐标透传)
    //   叠放优先级(低→高): 面板底 → 进度条 → 状态条 → 面板描边 → 数字/冒号
    //   数字/冒号最优先, 保证任何状态下都清晰可见。
    //============================================================
    always @(posedge video_clk or posedge rst) begin
        if (rst) begin
            hs_o <= 1'b0; vs_o <= 1'b0; de_o <= 1'b0;
            data_o <= 24'd0;
            px_x_o <= 12'd0; px_y_o <= 12'd0;
        end
        else begin
            hs_o <= hs_i; vs_o <= vs_i; de_o <= de_i;
            px_x_o <= px_x; px_y_o <= px_y;
            if (!en)
                data_o <= data_i;                       // 非会议场景: 纯透传
            else if (colon_on || dig_on)
                data_o <= 24'hFFFFFF;                   // 倒计时数字/冒号(白)
            else if (panel_brd)
                data_o <= bar_col;                      // 面板描边(状态色)
            else if (bar_on)
                data_o <= bar_col;                      // 状态条
            else if (panel_on)
                data_o <= 24'h0A1018;                   // 面板底(近黑)
            else if (pb_on)
                data_o <= pb_filled ? bar_col : 24'h384048;  // 进度条(已过=状态色, 未过=深灰)
            else
                data_o <= data_i;                       // 其余透传议程图
        end
    end

endmodule
