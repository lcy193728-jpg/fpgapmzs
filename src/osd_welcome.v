//====================================================================
// 模块名 : osd_welcome.v —— 校园迎新展示场景 OSD(信息叠加层)
// 功能   :
//   在"迎新展示"场景(SW1 选中)时, 于 osd_menu 输出的背景像素流之上
//   叠加三块真实汉字信息 + 一条底部滚动"报到流程":
//     · 顶部金底(50% 透)欢迎语  「热烈欢迎新同学」 2× 大标题
//     · 左下报到地点卡(75% 藏蓝衬底+左 4px 蓝强调): 「报到地点：东区体育馆」
//     · 右下联系方式卡(同上+青强调)          : 「新生QQ群：123456789」
//     · 底部全宽暗带滚动流程(每帧左移 1px): 「迎新报到流程 签到 领卡 入住 军训物资」
//   OSD 区域(文字/色块/衬底带)以外像素**原样透传背景** —— 满足
//   "非 OSD 区域背景保持"。菜单态/应急态/其它场景 welcome_en=0, 本模块纯透传。
// 数据管线 :
//   输入 {hs/vs/de/data,px} 视为已对齐(osd_menu 输出); 三级移位寄存器
//   (da1/2/3 + px1/2/3 + sync1/2/3)统一延迟 3 拍后输出, 并把 px 一并传出,
//   供下游 display_adjust(亮度条 OSD 定位)继续使用。
//   字形 ROM(osd_font_rom, 同步读): A 级(px2/py2)发读请求, ROM 回读一拍
//   → q 恰与 px3/py3/da3 对齐, B 级(px3)判墨点并按 py3 区域仲裁颜色。
//   文字带行窗(py, 像素行):
//     · W_TITLE 2×: 行 14..45   x 208..431    (ROM base=1168, N=7, 格宽32)
//     · W_INFO  1×: 行 400..415  左 x 85..244(N=10) / 右 x 355..594(N=15)
//     · W_FLOW  1×: 行 452..467  带宽 20 格(320px 周期, base=1680)
//   上述 base/文案与 tools/gen_osd_font.py 同源, 改动需两处同步并重跑生成。
// 时钟域 : 本模块 video_clk(≈25.175MHz); welcome_en 为 sd_card_clk(100MHz)
//          域电平, 内部两级同步器过域。
// 语言   : 纯 Verilog-2001(兼容 TD EDA 前台与 ModelSim)。
//====================================================================

`timescale 1ns/1ps

module osd_welcome #(
    parameter DATA_W = 24,               // 像素位宽(RGB888)
    parameter H_ACT  = 640,              // 有效宽
    parameter V_ACT  = 480               // 有效高
)(
    input                video_clk,      // 像素时钟(≈25.175MHz)
    input                rst,            // 高有效复位
    // ---- 输入: osd_menu 输出(已对齐) ----
    input                hs_i, vs_i, de_i,
    input  [DATA_W-1:0]  data_i,
    input  [11:0]        px_x,           // 与 data_i 同拍 x(0 基)
    input  [11:0]        px_y,           // 与 data_i 同拍 y(0 基)
    // ---- 控制(异步电平, 模块内两级同步) ----
    input                welcome_en,     // 1=迎新场景(叠加本层)
    // ---- 输出: 送 display_adjust ----
    output               hs_o, vs_o, de_o,
    output [DATA_W-1:0]  data_o,
    output [11:0]        px_x_o,         // 与 data_o 同拍坐标(透传下游)
    output [11:0]        px_y_o
);

    //--------------------------------------------------------------
    // 颜色定义
    //--------------------------------------------------------------
    localparam [DATA_W-1:0] C_GOLD     = 24'hFF_D2_4A;  // 顶部欢迎语金底(50% 混)
    localparam [DATA_W-1:0] C_NAVY     = 24'h0A_26_47;  // 信息卡藏蓝衬底(75% 混)
    localparam [DATA_W-1:0] C_ACC_L    = 24'h2E_7C_F6;  // 报到地点卡左强调(蓝)
    localparam [DATA_W-1:0] C_ACC_R    = 24'h18_C9_9E;  // 联系方式卡左强调(青)
    localparam [DATA_W-1:0] C_TITLE_TX = 24'h14_2A_50;  // 欢迎语字形(深藏青, 衬金底)
    localparam [DATA_W-1:0] C_INFO_TX  = 24'hF5_FD_FF;  // 信息卡字形(近白, 衬藏蓝)
    localparam [DATA_W-1:0] C_FLOW_TX  = 24'hFF_7A_1F;  // 底部流程滚动字(亮橙)

    //--------------------------------------------------------------
    // 几何常量(与 tools/gen_osd_font.py 迎新带同源, 勿单独改动)
    //--------------------------------------------------------------
    localparam [11:0] T_TY    = 12'd14;  // 欢迎语字形行起点(2×, 占 32 行)
    localparam [11:0] T_GX    = 12'd208; // 欢迎语字形 x 起点(7 格×32)
    localparam [4:0]  T_N     = 5'd7;
    localparam [10:0] T_BASE  = 11'd1168;
    localparam [11:0] TP_Y0   = 12'd8;   // 金底条: 行 8..51
    localparam [11:0] TP_Y1   = 12'd52;
    localparam [11:0] TP_X0   = 12'd168; // 金底条: x 168..471(左右各留 40px)
    localparam [11:0] TP_X1   = 12'd472;

    localparam [11:0] P_TY    = 12'd400; // 信息卡字形行起点(1×)
    localparam [11:0] L_GX    = 12'd85;  // 报到地点 x 起点(10 格×16)
    localparam [4:0]  L_N     = 5'd10;
    localparam [10:0] L_BASE  = 11'd1280;
    localparam [11:0] R_GX    = 12'd355; // 联系方式 x 起点(15 格×16)
    localparam [4:0]  R_N     = 5'd15;
    localparam [10:0] R_BASE  = 11'd1440;
    localparam [11:0] CD_Y0   = 12'd392; // 信息卡: 行 392..431
    localparam [11:0] CD_Y1   = 12'd432;
    localparam [11:0] L_X0    = 12'd24;  // 报到地点卡 x 24..305
    localparam [11:0] L_X1    = 12'd306;
    localparam [11:0] L_A0    = 12'd24;  // 左 4px 强调带 x 24..27
    localparam [11:0] L_A1    = 12'd28;
    localparam [11:0] R_X0    = 12'd334; // 联系方式卡 x 334..615
    localparam [11:0] R_X1    = 12'd616;
    localparam [11:0] R_A0    = 12'd334;
    localparam [11:0] R_A1    = 12'd338;

    localparam [11:0] F_TY    = 12'd452; // 流程滚动字形行起点(1×)
    localparam [4:0]  F_N     = 5'd20;   // 带宽 20 格
    localparam [11:0] F_PER   = 12'd320; // 周期 = F_N*16
    localparam [10:0] F_BASE  = 11'd1680;
    localparam [11:0] F_Y0    = 12'd438; // 暗带: 行 438..479
    localparam [11:0] F_Y1    = 12'd480;

    //--------------------------------------------------------------
    // 控制标志过域(两级同步)
    //--------------------------------------------------------------
    reg w_s0, w_s1;
    wire w_ok = w_s1;
    always @(posedge video_clk or posedge rst) begin
        if (rst) begin
            w_s0 <= 1'b0; w_s1 <= 1'b0;
        end
        else begin
            w_s0 <= welcome_en; w_s1 <= w_s0;
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
                if (phase >= (F_PER - 10'd1))
                    phase <= 10'd0;
                else
                    phase <= phase + 10'd1;
            end
        end
    end

    //--------------------------------------------------------------
    // 三级移位管线(输入 → da3/px3/py3/sync3, 恒定延迟 3 拍)
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
    // 文字带分类(id): 1=标题2×  2=信息卡1×(左右共用行窗)  3=流程滚动1×
    //   A 级按 py2 分类(发 ROM 读请求), B 级按 py3 分类(判墨点颜色)
    //--------------------------------------------------------------
    reg [1:0] rid2;
    always @* begin
        rid2 = 2'd0;
        if      ((py2 >= T_TY) && (py2 < T_TY + 12'd32)) rid2 = 2'd1;      // 欢迎语
        else if ((py2 >= P_TY) && (py2 < P_TY + 12'd16)) rid2 = 2'd2;      // 信息卡行
        else if ((py2 >= F_TY) && (py2 < F_TY + 12'd16)) rid2 = 2'd3;      // 流程滚动
    end

    // A 级: 滚动窗口取模(px+phase 对 320 取模)
    wire [11:0] wxx   = px2 + {2'b00, phase};
    wire [11:0] wx_1  = (wxx >= 12'd640) ? (wxx - 12'd640) : wxx;
    wire [11:0] wx_m  = (wx_1 >= F_PER)  ? (wx_1 - F_PER)  : wx_1;

    // A 级: ROM 读请求(仅在字形窗内发, 省功耗)
    reg rom_en;
    reg [12:0] rom_addr;
    always @* begin
        rom_en   = 1'b0;
        rom_addr = 13'd0;
        if (w_ok && de2 && (rid2 != 2'd0)) begin
            case (rid2)
                2'd1: begin  // 欢迎语 2×
                    if ((px2 >= T_GX) && (px2 < T_GX + ({1'b0, T_N} << 5))) begin
                        rom_en   = 1'b1;
                        rom_addr = T_BASE + (((py2 - T_TY) >> 1) * {1'b0, T_N})
                                 + ((px2 - T_GX) >> 5);
                    end
                end
                2'd2: begin  // 信息卡 1×: 报到地点(左) / 联系方式(右)
                    if ((px2 >= L_GX) && (px2 < L_GX + ({1'b0, L_N} << 4))) begin
                        rom_en   = 1'b1;
                        rom_addr = L_BASE + ((py2 - P_TY) * {1'b0, L_N})
                                 + ((px2 - L_GX) >> 4);
                    end
                    else if ((px2 >= R_GX) && (px2 < R_GX + ({1'b0, R_N} << 4))) begin
                        rom_en   = 1'b1;
                        rom_addr = R_BASE + ((py2 - P_TY) * {1'b0, R_N})
                                 + ((px2 - R_GX) >> 4);
                    end
                end
                default: begin  // 流程滚动 1×
                    rom_en   = 1'b1;
                    rom_addr = F_BASE + ((py2 - F_TY) * {1'b0, F_N}) + (wx_m >> 4);
                end
            endcase
        end
    end

    // 字形 ROM(同步读, q 晚 addr 一拍; 与菜单/会议/抢答/应急共用同一生成文件)
    wire [15:0] rom_q;
    osd_font_rom #(
        .ADDR_W (13),
        .DEPTH  (4608)
    ) u_font_rom (
        .clk    (video_clk),
        .rst    (rst),
        .rd_en  (rom_en),
        .addr   (rom_addr),
        .q      (rom_q)
    );

    //--------------------------------------------------------------
    // B 级: 文字带分类(按 py3) + 墨点判定
    //--------------------------------------------------------------
    reg [1:0] rid3;
    always @* begin
        rid3 = 2'd0;
        if      ((py3 >= T_TY) && (py3 < T_TY + 12'd32)) rid3 = 2'd1;
        else if ((py3 >= P_TY) && (py3 < P_TY + 12'd16)) rid3 = 2'd2;
        else if ((py3 >= F_TY) && (py3 < F_TY + 12'd16)) rid3 = 2'd3;
    end

    wire [11:0] wxx3  = px3 + {2'b00, phase};
    wire [11:0] wx3_1 = (wxx3 >= 12'd640) ? (wxx3 - 12'd640) : wxx3;
    wire [11:0] wx3_m = (wx3_1 >= F_PER)  ? (wx3_1 - F_PER)  : wx3_1;

    reg ink;
    always @* begin
        ink = 1'b0;
        if (w_ok && de3 && (rid3 != 2'd0)) begin
            case (rid3)
                2'd1: begin  // 欢迎语 2×: 相邻两物理列同一位
                    if ((px3 >= T_GX) && (px3 < T_GX + ({1'b0, T_N} << 5)))
                        ink = rom_q[15 - (((px3 - T_GX) & 12'd31) >> 1)];
                end
                2'd2: begin  // 信息卡 1×: 左(报到地点)/右(联系方式)
                    if ((px3 >= L_GX) && (px3 < L_GX + ({1'b0, L_N} << 4)))
                        ink = rom_q[15 - ((px3 - L_GX) & 12'd15)];
                    else if ((px3 >= R_GX) && (px3 < R_GX + ({1'b0, R_N} << 4)))
                        ink = rom_q[15 - ((px3 - R_GX) & 12'd15)];
                end
                default: begin  // 流程滚动: 取模后格内列 = 低 4 位
                    ink = rom_q[15 - wx3_m[3:0]];
                end
            endcase
        end
    end

    //--------------------------------------------------------------
    // 区域命中(B 级, 按 py3/px3; 供衬底/色块仲裁)
    //--------------------------------------------------------------
    wire t_panel = (py3 >= TP_Y0) && (py3 < TP_Y1) &&
                   (px3 >= TP_X0) && (px3 < TP_X1);
    wire f_band  = (py3 >= F_Y0)  && (py3 < F_Y1);
    wire info_ro = (py3 >= CD_Y0) && (py3 < CD_Y1);
    wire l_card  = info_ro && (px3 >= L_X0) && (px3 < L_X1);
    wire r_card  = info_ro && (px3 >= R_X0) && (px3 < R_X1);

    //--------------------------------------------------------------
    // 衬底混合色(按输入像素逐通道计算; 底色区外不输出, 省资源可忽略)
    //   金底 50%: out = (bg + GOLD) >> 1
    //   卡底 75%: out = (bg + NAVY*3) >> 2
    //   暗带 25%: out = bg >> 2
    //--------------------------------------------------------------
    wire [8:0] bg_r9 = {1'b0, da3[23:16]};
    wire [8:0] bg_g9 = {1'b0, da3[15:8]};
    wire [8:0] bg_b9 = {1'b0, da3[7:0]};
    wire [7:0] gold_r = (bg_r9 + 9'd255)  >> 1;
    wire [7:0] gold_g = (bg_g9 + 9'd210)  >> 1;   // 0xD2
    wire [7:0] gold_b = (bg_b9 + 9'd74)   >> 1;   // 0x4A
    wire [7:0] card_r = (bg_r9 + 3*9'd10) >> 2;   // 3*0x0A
    wire [7:0] card_g = (bg_g9 + 3*9'd38) >> 2;   // 3*0x26
    wire [7:0] card_b = (bg_b9 + 3*9'd71) >> 2;   // 3*0x47
    wire [7:0] dark_r = bg_r9[8:2];   // 底部暗带: bg >> 2 = 25% 透显
    wire [7:0] dark_g = bg_g9[8:2];
    wire [7:0] dark_b = bg_b9[8:2];

    //--------------------------------------------------------------
    // 输出仲裁(组合): 暗带 > 金底条 > 左信息卡 > 右信息卡 > 背景透传
    //   墨点落在对应带内时以字形色覆盖衬底
    //--------------------------------------------------------------
    reg [DATA_W-1:0] fo;
    always @* begin
        fo = da3;                                      // 默认透传(背景保持)
        if (de3 && w_ok) begin
            if (f_band) begin
                fo = {dark_r, dark_g, dark_b};         // 底部暗带
                if (ink) fo = C_FLOW_TX;               // 滚动流程字
            end
            else if (t_panel) begin
                fo = {gold_r, gold_g, gold_b};         // 金底条
                if (ink) fo = C_TITLE_TX;              // 欢迎语字
            end
            else if (l_card) begin
                if ((px3 >= L_A0) && (px3 < L_A1))
                    fo = C_ACC_L;                      // 左强调
                else begin
                    fo = {card_r, card_g, card_b};     // 藏蓝衬底
                    if (ink) fo = C_INFO_TX;           // 报到地点字
                end
            end
            else if (r_card) begin
                if ((px3 >= R_A0) && (px3 < R_A1))
                    fo = C_ACC_R;
                else begin
                    fo = {card_r, card_g, card_b};
                    if (ink) fo = C_INFO_TX;
                end
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
