//====================================================================
// 模块名 : osd_engine.v —— OSD 像素叠加底座(阶段2a, 骨架)
// 功能   :
//   1. 在 video_delay 输出的已对齐像素流上，重建 0 基像素坐标
//      (px_x 0~639 / px_y 0~479, 与 data_o 严格同拍)
//   2. 提供通用叠加仲裁口(ovl_en/ovl_rgb)，供后续菜单/时钟/告警调用
//   3. 内置"测试矩形"叠加(TEST_RECT_EN=1 生效)，用于仿真/上板核坐标
// 插入点 : top.v 中 video_delay → osd_engine → hdmi_tx
// 管线   : A 级(输入锁存+坐标快照) → B 级(叠加仲裁+输出)
//          输出相对输入整体延迟 2 个 video_clk，hs/vs/de 与 data 同步后移
// 极性   : 沿用 VGA 640×480: hs/vs 负脉冲, de 有效区拉高(每行连续640像素)
// 时序要点: 像素流与 de 同拍进入; x 每行从0计; y 在每行结束后+1,
//           vsync 下降沿(负脉冲进入)时 y 归零——保证帧首行 y=0
//====================================================================

`timescale 1ns/1ps

module osd_engine #(
    parameter DATA_WIDTH  = 24,          // 像素位宽(当前 RGB888)
    parameter H_ACTIVE    = 16'd640,     // 水平有效像素
    parameter V_ACTIVE    = 16'd480,     // 垂直有效行
    parameter TEST_RECT_EN = 1'b0,       // 1=叠加测试矩形(坐标核验用)
    parameter TEST_X0     = 12'd160,     // 测试矩形: 左 x(含)
    parameter TEST_Y0     = 12'd120,     // 测试矩形: 上 y(含)
    parameter TEST_X1     = 12'd480,     // 测试矩形: 右 x(不含)
    parameter TEST_Y1     = 12'd360      // 测试矩形: 下 y(不含)
)(
    input                       video_clk,   // 像素时钟(≈25.175MHz)
    input                       rst,         // 高有效复位
    // ---- 输入: video_delay 输出(已对齐) ----
    input                       hs_i,
    input                       vs_i,
    input                       de_i,
    input   [DATA_WIDTH-1:0]    data_i,
    // ---- 通用叠加仲裁口(后续菜单/时钟/告警 OSD 驱动) ----
    input                       ovl_en,      // 1=本拍用 ovl_rgb 覆盖背景
    input   [DATA_WIDTH-1:0]    ovl_rgb,     // 覆盖色(与 data_i 同格式)
    // ---- 输出: 送入 hdmi_tx ----
    output                      hs_o,
    output                      vs_o,
    output                      de_o,
    output  [DATA_WIDTH-1:0]    data_o,
    // ---- 调试: 与 data_o 对齐的像素坐标 ----
    output  [11:0]              px_x,
    output  [11:0]              px_y
);

    //--------------------------------------------------------------
    // 内部寄存器
    //--------------------------------------------------------------
    reg                         hs_a, vs_a, de_a;      // A级: 输入锁存
    reg [DATA_WIDTH-1:0]        data_a;
    reg [11:0]                  x_a, y_a;              // A级: 像素坐标快照
    reg [11:0]                  cnt_x;                 // 下一像素的 x(0基)
    reg [11:0]                  cnt_y;                 // 下一行的 y(0基)
    reg                         de_d, vs_d;            // 输入沿检测用延迟

    wire                        vs_fall;               // vsync 负脉冲进入(下降沿)

    assign vs_fall = vs_d & ~vs_i;

    //--------------------------------------------------------------
    // 输入沿检测延迟
    //--------------------------------------------------------------
    always @(posedge video_clk or posedge rst) begin
        if (rst) begin
            de_d <= 1'b0;
            vs_d <= 1'b1;        // 常态 vs=高(负脉冲);复位视作未进入同步期
        end
        else begin
            de_d <= de_i;
            vs_d <= vs_i;
        end
    end

    //--------------------------------------------------------------
    // 像素坐标计数器(下一拍语义)
    //   cnt_x: 每行从0计, 有 de 才推进; 无 de 立即清0 → 行首像素 x=0
    //   cnt_y: 每行结束(de高→低)后+1; vsync 下降沿归零 → 帧首行 y=0
    //--------------------------------------------------------------
    always @(posedge video_clk or posedge rst) begin
        if (rst)
            cnt_x <= 12'd0;
        else if (de_i) begin
            if (de_d)
                cnt_x <= cnt_x + 12'd1;   // 行内连续像素
            else
                cnt_x <= 12'd1;           // 行首像素计 0, 拍一拍后 cnt_x=1
        end
        else
            cnt_x <= 12'd0;
    end

    always @(posedge video_clk or posedge rst) begin
        if (rst)
            cnt_y <= 12'd0;
        else if (vs_fall)
            cnt_y <= 12'd0;               // 帧同步 → 下一帧首行 y=0
        else if (de_d && ~de_i)
            cnt_y <= cnt_y + 12'd1;       // 一行结束 → 下一行行号+1
        else
            cnt_y <= cnt_y;
    end

    //--------------------------------------------------------------
    // A级: 输入锁存 + 坐标快照(与 data_a 同拍)
    //--------------------------------------------------------------
    always @(posedge video_clk or posedge rst) begin
        if (rst) begin
            hs_a   <= 1'b0;
            vs_a   <= 1'b0;
            de_a   <= 1'b0;
            data_a <= {DATA_WIDTH{1'b0}};
            x_a    <= 12'd0;
            y_a    <= 12'd0;
        end
        else begin
            hs_a   <= hs_i;
            vs_a   <= vs_i;
            de_a   <= de_i;
            data_a <= data_i;
            if (de_i) begin
                x_a <= cnt_x;            // 快照本像素 x(计0基)
                y_a <= cnt_y;            // 快照本像素所在行
            end
            else begin
                x_a <= 12'd0;
                y_a <= 12'd0;
            end
        end
    end

    //--------------------------------------------------------------
    // 测试矩形命中(仅调试/坐标核验)
    //--------------------------------------------------------------
    wire test_rect_hit = (de_a && TEST_RECT_EN
                          && x_a >= TEST_X0 && x_a <  TEST_X1
                          && y_a >= TEST_Y0 && y_a <  TEST_Y1);

    //--------------------------------------------------------------
    // B级: 叠加仲裁(先测试矩形, 后通用 ovl) + 输出
    //--------------------------------------------------------------
    reg  hs_o_r, vs_o_r, de_o_r;
    reg [DATA_WIDTH-1:0] data_o_r;
    reg [11:0] px_x_r, px_y_r;

    always @(posedge video_clk or posedge rst) begin
        if (rst) begin
            hs_o_r   <= 1'b0;
            vs_o_r   <= 1'b0;
            de_o_r   <= 1'b0;
            data_o_r <= {DATA_WIDTH{1'b0}};
            px_x_r   <= 12'd0;
            px_y_r   <= 12'd0;
        end
        else begin
            hs_o_r   <= hs_a;
            vs_o_r   <= vs_a;
            de_o_r   <= de_a;
            px_x_r   <= x_a;
            px_y_r   <= y_a;
            if (test_rect_hit)
                data_o_r <= 24'hFFA000;              // 测试: 橙色矩形
            else if (ovl_en)
                data_o_r <= ovl_rgb;
            else
                data_o_r <= data_a;
        end
    end

    assign hs_o   = hs_o_r;
    assign vs_o   = vs_o_r;
    assign de_o   = de_o_r;
    assign data_o = data_o_r;
    assign px_x   = px_x_r;
    assign px_y   = px_y_r;

endmodule
