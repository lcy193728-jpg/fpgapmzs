//====================================================================
// 模块名 : osd_welcome.v —— 校园迎新展示场景 OSD(信息叠加层)
// 功能   :
//   在"迎新展示"场景(SW1 选中)时, 于 osd_menu 输出的背景像素流之上
//   叠加顶部欢迎语 + 一条串口可配置的底部滚动通知:
//     · 顶部金底(50% 透)欢迎语  「热烈欢迎新同学」 2× 大标题
//     · 底部全宽暗带滚动通知: 内容/速度/暂停由 UART 上位机配置
//   OSD 区域(文字/色块/衬底带)以外像素**原样透传背景** —— 满足
//   "非 OSD 区域背景保持"。菜单态/应急态/其它场景 welcome_en=0, 本模块纯透传。
// 数据管线 :
//   输入 {hs/vs/de/data,px} 视为已对齐(osd_menu 输出); 三级移位寄存器
//   (da1/2/3 + px1/2/3 + sync1/2/3)统一延迟 3 拍后输出, 并把 px 一并传出,
//   供下游 display_adjust(亮度条 OSD 定位)继续使用。
//   字形 ROM(osd_font_rom, 同步读): A 级(px2/py2)发读请求, ROM 回读一拍
//   → q 恰与 px3/py3/da3 对齐, B 级(px3)判墨点并按 py3 区域仲裁颜色。
//   文字带行窗(py, 像素行):
//     · W_TITLE 2×: 行 14..45   x 208..431 (ROM base=1168, N=7, 格宽32)
//     · W_DICT  1×: 行 452..467，串口通知按字形 ID 查询(base=1792, N=45)
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
    input [191:0]        flow_ids,       // 32个×6bit字形id，index0在LSB
    input [5:0]          flow_length,    // 1..32
    input [5:0]          flow_speed,     // 每移1px间隔帧数 1..30
    input                flow_pause,
    // ---- 共享字形 ROM 接口(top 层统一例化一片, 三路 OSD 互斥使用) ----
    input  [31:0]        rom_q,          // ROM 读数据(晚 rom_addr_o 一拍)
    output               rom_en_o,       // ROM 读使能(本模块当拍读请求)
    output [12:0]        rom_addr_o,     // ROM 读地址
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
    localparam [DATA_W-1:0] C_TITLE_TX = 24'h14_2A_50;  // 欢迎语字形(深藏青, 衬金底)
    localparam [DATA_W-1:0] C_FLOW_TX  = 24'hFF_7A_1F;  // 底部流程滚动字(亮橙)

    //--------------------------------------------------------------
    // 几何常量(与 tools/gen_osd_font.py 迎新带同源, 勿单独改动)
    //--------------------------------------------------------------
    localparam [11:0] T_TY    = 12'd14;  // 欢迎语字形行起点(2×, 占 32 行)
    localparam [11:0] T_GX    = 12'd208; // 欢迎语字形 x 起点(7 格×32)
    localparam [4:0]  T_N     = 5'd7;
    localparam [10:0] T_BASE  = 11'd1568;
    localparam [11:0] TP_Y0   = 12'd8;   // 金底条: 行 8..51
    localparam [11:0] TP_Y1   = 12'd52;
    localparam [11:0] TP_X0   = 12'd168; // 金底条: x 168..471(左右各留 40px)
    localparam [11:0] TP_X1   = 12'd472;

    localparam [11:0] F_TY    = 12'd452; // 流程滚动字形行起点(1×)
    localparam [12:0] F_BASE  = 13'd1792; // 45字形字典，占用原三个迎新带区间
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
    // 滚动相位: 固定 640px 周期，文本最长 32×16=512px，至少留128px间隔。
    //--------------------------------------------------------------
    reg vsd;
    reg [9:0] phase;
    reg [5:0] speed_count;
    wire vs_rise = vs_i & ~vsd;
    always @(posedge video_clk or posedge rst) begin
        if (rst) begin
            vsd   <= 1'b0;
            phase <= 10'd0; speed_count <= 6'd0;
        end
        else begin
            vsd <= vs_i;
            if (vs_rise && !flow_pause) begin
                if (speed_count + 1'b1 >= flow_speed) begin
                    speed_count <= 0;
                    phase <= (phase==10'd639) ? 10'd0 : phase+1'b1;
                end else speed_count <= speed_count+1'b1;
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
    // 文字带分类(id): 1=标题2×  2=通知滚动1×
    //   ★2026-09-21 面积优化: 只在 A 级按 py2 分类; B 级改为把本结果打一拍
    //     (py3 ≡ py2 延迟 1 拍, 见第 160-161 行 px3<=px2; py3<=py2), 原先
    //     B 级把这套行窗比较重算了一遍, 等于 6 个 12bit 比较器白做两次。
    //   行窗上界写成常量(46/416/468), 不再现算 T_TY+32 / P_TY+16 / F_TY+16。
    //--------------------------------------------------------------
    reg [1:0] rid2;
    always @* begin
        rid2 = 2'd0;
        if      ((py2 >= T_TY) && (py2 < 12'd46))  rid2 = 2'd1;      // 欢迎语
        else if ((py2 >= F_TY) && (py2 < 12'd468)) rid2 = 2'd2;      // 流动通知
    end

    // A 级: px+phase 对固定640取模，只需一次常量减法。
    wire [11:0] wxx   = px2 + {2'b00, phase};
    wire [11:0] wx_m  = (wxx >= 12'd640) ? (wxx - 12'd640) : wxx;
    wire [9:0] flow_px = {flow_length,4'b0};
    wire flow_window = wx_m < flow_px;
    wire [5:0] flow_ci = wx_m[9:4];

    function [5:0] flow_glyph;
      input [191:0] ids; input [5:0] idx;
      begin
        case(idx)
          0:flow_glyph=ids[5:0];1:flow_glyph=ids[11:6];2:flow_glyph=ids[17:12];3:flow_glyph=ids[23:18];
          4:flow_glyph=ids[29:24];5:flow_glyph=ids[35:30];6:flow_glyph=ids[41:36];7:flow_glyph=ids[47:42];
          8:flow_glyph=ids[53:48];9:flow_glyph=ids[59:54];10:flow_glyph=ids[65:60];11:flow_glyph=ids[71:66];
          12:flow_glyph=ids[77:72];13:flow_glyph=ids[83:78];14:flow_glyph=ids[89:84];15:flow_glyph=ids[95:90];
          16:flow_glyph=ids[101:96];17:flow_glyph=ids[107:102];18:flow_glyph=ids[113:108];19:flow_glyph=ids[119:114];
          20:flow_glyph=ids[125:120];21:flow_glyph=ids[131:126];22:flow_glyph=ids[137:132];23:flow_glyph=ids[143:138];
          24:flow_glyph=ids[149:144];25:flow_glyph=ids[155:150];26:flow_glyph=ids[161:156];27:flow_glyph=ids[167:162];
          28:flow_glyph=ids[173:168];29:flow_glyph=ids[179:174];30:flow_glyph=ids[185:180];31:flow_glyph=ids[191:186];
          default:flow_glyph=0;
        endcase
      end
    endfunction
    wire [5:0] flow_gid = flow_glyph(flow_ids,flow_ci);

    // A 级: 行内偏移收窄 —— rid2 已保证 py2 落在本带行窗内(带宽 ≤32),
    //   模 2^k 减法逐位精确, 却把 12bit 减法器与 12bit×常量的乘法器一起收窄:
    //     欢迎语 dy∈[0,31]→5bit; 信息卡/流程 dy∈[0,15]→4bit。
    //   变量×小常量改用移位加(T_N=7 / L_N=10 / R_N=15 / F_N=20), 免乘法器。
    wire [4:0] dy_t = py2[4:0] - T_TY[4:0];
    wire [3:0] dy_f = py2[3:0] - F_TY[3:0];
    wire [7:0] row_t = ({3'b0, dy_t} << 3) - {3'b0, dy_t};         // dy*7
    wire [9:0] row_f = ({6'b0,dy_f}<<5)+({6'b0,dy_f}<<3)+({6'b0,dy_f}<<2)+dy_f; // dy*45

    // A 级: ROM 读请求(仅在字形窗内发, 省功耗)
    //   窗口右沿改用常量(432/245/595 = gx + N*格宽)。
    reg rom_en;
    reg [12:0] rom_addr;
    always @* begin
        rom_en   = 1'b0;
        rom_addr = 13'd0;
        if (w_ok && de2 && (rid2 != 2'd0)) begin
            case (rid2)
                2'd1: begin  // 欢迎语 2×(32×32 真字模 1:1, 不再 >>1 折叠)
                    if ((px2 >= T_GX) && (px2 < 12'd432)) begin
                        rom_en   = 1'b1;
                        rom_addr = T_BASE + row_t + ((px2 - T_GX) >> 5);
                    end
                end
                default: begin  // 动态流动通知，字典按 row×45+glyph_id 寻址
                    if(flow_window) begin
                      rom_en   = 1'b1;
                      rom_addr = F_BASE + row_f + flow_gid;
                    end
                end
            endcase
        end
    end

    // 字形 ROM(同步读, q 晚 addr 一拍; 与菜单/会议/抢答/应急共用同一生成文件)
    //   ★V3: 位宽 16→32, 深度 4608→5856(2× 带存 32×32 真字模; 1× 带用低 16 位)
    //   ★资源优化: ROM 实体移到 top 层统一例化(三路 OSD 互斥, 只占一份 BRAM)。
    assign rom_en_o   = rom_en;
    assign rom_addr_o = rom_addr;

    //--------------------------------------------------------------
    // B 级: 文字带 id / 滚动相位 —— 全部改为 A 级结果打一拍
    //   ★2026-09-21 面积优化: py3 ≡ py2 延迟 1 拍, 故 f(py3) 恒等于 f(py2)
    //     延迟 1 拍。原先 B 级把"按 py3 分类 3 个文字带"和"px3+phase 取模"
    //     整套重算了一遍(6 个 12bit 比较器 + 12bit 加法/减法/取模比较器链),
    //     是本模块进位链的主要来源。改为纯打拍后画面逐像素完全不变。
    //     (phase 只在 vsync 期间跳变, 此时 de3=0/带区不命中, 不影响可见像素)
    //--------------------------------------------------------------
    reg [1:0]  rid3;
    reg [11:0] wx3_m;
    reg flow_window3;
    always @(posedge video_clk or posedge rst) begin
        if (rst) begin
            rid3  <= 2'd0;
            wx3_m <= 12'd0; flow_window3<=1'b0;
        end
        else begin
            rid3  <= rid2;
            wx3_m <= wx_m; flow_window3<=flow_window;
        end
    end

    reg ink;
    always @* begin
        ink = 1'b0;
        if (w_ok && de3 && (rid3 != 2'd0)) begin
            case (rid3)
                2'd1: begin  // 欢迎语 2×: 32×32 真字模 1:1
                    if ((px3 >= T_GX) && (px3 < 12'd432))
                        ink = rom_q[31 - ((px3 - T_GX) & 12'd31)];
                end
                default: begin
                    if(flow_window3) ink = rom_q[15 - wx3_m[3:0]];
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
    wire [7:0] dark_r = bg_r9[8:2];   // 底部暗带: bg >> 2 = 25% 透显
    wire [7:0] dark_g = bg_g9[8:2];
    wire [7:0] dark_b = bg_b9[8:2];

    //--------------------------------------------------------------
    // 输出仲裁(组合): 暗带 > 金底条 > 背景透传
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
        end
    end

    assign hs_o   = hs3;
    assign vs_o   = vs3;
    assign de_o   = de3;
    assign data_o = fo;
    assign px_x_o = px3;
    assign px_y_o = py3;

endmodule
