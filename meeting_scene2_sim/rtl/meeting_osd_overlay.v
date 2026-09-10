// ============================================================
// meeting_osd_overlay.v —— 会议场景 OSD 图层叠加（自研，对应赛题 扩展1）
// 在 640x480 背景上叠加会议信息占位色块（真实系统换成字模 ROM 即可）：
//   标题条  /  时间  /  地点  /  右下角页码指示
// osd_hit=1 处 out_rgb 输出对应信息色，否则透传背景 bg_rgb。
// ============================================================
module meeting_osd_overlay (
    input  wire        de,
    input  wire [10:0] x,
    input  wire [10:0] y,
    input  wire [23:0] bg_rgb,
    input  wire        osd_enable,
    input  wire [1:0]  page_index,
    output reg  [23:0] out_rgb,
    output reg         osd_hit
);

localparam [23:0] RGB_TITLE = 24'h0A_2E_6E;  // 会议标题条
localparam [23:0] RGB_TIME  = 24'h2F_80_FF;  // 时间
localparam [23:0] RGB_LOC   = 24'h26_C2_81;  // 地点
localparam [23:0] RGB_PAGE0 = 24'hFF_88_88;  // 页码 0
localparam [23:0] RGB_PAGE1 = 24'h88_FF_88;  // 页码 1
localparam [23:0] RGB_PAGE2 = 24'h88_88_FF;  // 页码 2
localparam [23:0] RGB_PAGE3 = 24'hFF_FF_88;  // 页码 3

reg        hit_title, hit_time, hit_loc, hit_page;
reg [23:0] sel_rgb;

always @* begin
    hit_title = de && osd_enable && (y >= 11'd40  && y < 11'd100) && (x >= 11'd80  && x < 11'd560);
    hit_time  = de && osd_enable && (y >= 11'd120 && y < 11'd160) && (x >= 11'd80  && x < 11'd280);
    hit_loc   = de && osd_enable && (y >= 11'd120 && y < 11'd160) && (x >= 11'd300 && x < 11'd560);
    hit_page  = de && osd_enable && (y >= 11'd420 && y < 11'd452) && (x >= 11'd560 && x < 11'd620);

    osd_hit = hit_title | hit_time | hit_loc | hit_page;

    case (page_index)
        2'd0:    sel_rgb = RGB_PAGE0;
        2'd1:    sel_rgb = RGB_PAGE1;
        2'd2:    sel_rgb = RGB_PAGE2;
        default: sel_rgb = RGB_PAGE3;
    endcase

    out_rgb = hit_title ? RGB_TITLE :
              hit_time  ? RGB_TIME  :
              hit_loc   ? RGB_LOC   :
              hit_page  ? sel_rgb   : bg_rgb;
end

endmodule