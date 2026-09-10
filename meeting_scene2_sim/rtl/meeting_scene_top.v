// ============================================================
// meeting_scene_top.v —— 场景二「会议展示」顶层（自研，用于仿真集成）
// 组合：scene_selector -> meeting_page_ctrl -> fade_transition_ctrl
//       -> meeting_osd_overlay -> brightness/contrast 处理
// 仅当 scene_normal == SCENE_MEETING 时激活会议功能，否则透传背景。
// 对应赛题：基础1/2、扩展1(OSD)、扩展2(转场)、扩展4(亮度/对比度)、交互控制
// ============================================================
module meeting_scene_top #(
    parameter PAGE_COUNT    = 4,
    parameter AUTO_INTERVAL = 16,
    parameter SCROLL_STEP   = 4,
    parameter FADE_STEP     = 8
)(
    input  wire        clk,
    input  wire        rst_n,
    // 场景选择
    input  wire        next_scene_pulse,
    input  wire        prev_scene_pulse,
    input  wire        direct_en,
    input  wire [1:0]  direct_scene,
    // 会议页面控制
    input  wire        auto_enable,
    input  wire        page_next_pulse,
    input  wire        page_prev_pulse,
    input  wire        scroll_enable,
    // 调节参数
    input  wire [3:0]  brightness_level,
    input  wire [3:0]  contrast_level,
    // 像素流
    input  wire        de,
    input  wire [10:0] x,
    input  wire [10:0] y,
    input  wire [23:0] bg_rgb,
    // 输出
    output wire [23:0] out_rgb,
    output wire        osd_hit,
    output wire [1:0]  scene_current,
    output wire        scene_active,
    output wire [1:0]  page_index,
    output wire        page_changed,
    output wire        transition_busy,
    output wire        transition_done,
    output wire [7:0]  alpha,
    output wire [10:0] scroll_x,
    output wire        scroll_hit
);

localparam [1:0] SCENE_MEETING = 2'd1;

// 1. 场景选择
wire [1:0] scene_normal;
wire       scene_changed;
scene_selector u_scene_sel (
    .clk          (clk),
    .rst_n        (rst_n),
    .next_pulse   (next_scene_pulse),
    .prev_pulse   (prev_scene_pulse),
    .direct_en    (direct_en),
    .direct_scene (direct_scene),
    .scene_normal (scene_normal),
    .scene_changed(scene_changed)
);
assign scene_current = scene_normal;
assign scene_active  = (scene_normal == SCENE_MEETING);

// 2. 会议页面控制器（仅在会议场景内响应）
wire [1:0] page_index_w;
wire       page_changed_w;
meeting_page_ctrl #(
    .PAGE_COUNT    (PAGE_COUNT),
    .AUTO_INTERVAL (AUTO_INTERVAL)
) u_page (
    .clk         (clk),
    .rst_n       (rst_n),
    .auto_enable (auto_enable & scene_active),
    .next_pulse  (page_next_pulse & scene_active),
    .prev_pulse  (page_prev_pulse & scene_active),
    .page_index  (page_index_w),
    .page_changed(page_changed_w)
);
assign page_index   = page_index_w;
assign page_changed = page_changed_w;

// 3. 转场：翻页触发淡入淡出
fade_transition_ctrl #(.STEP_MAX(FADE_STEP)) u_fade (
    .clk             (clk),
    .rst_n           (rst_n),
    .transition_start(page_changed_w & scene_active),
    .transition_busy (transition_busy),
    .transition_done (transition_done),
    .alpha           (alpha)
);

// 4. 会议 OSD 叠加
wire [23:0] osd_rgb;
wire        osd_hit_w;
meeting_osd_overlay u_osd (
    .de         (de & scene_active),
    .x          (x),
    .y          (y),
    .bg_rgb     (bg_rgb),
    .osd_enable (1'b1),
    .page_index (page_index_w),
    .out_rgb    (osd_rgb),
    .osd_hit    (osd_hit_w)
);
assign osd_hit = osd_hit_w;

// 5. 底部滚动字幕
wire [10:0] scroll_x_w;
wire        scroll_hit_w;
scroll_text_ctrl #(
    .H_ACTIVE  (640),
    .TEXT_WIDTH(260),
    .STEP_MAX  (SCROLL_STEP)
) u_scroll (
    .clk          (clk),
    .rst_n        (rst_n),
    .scroll_enable(scroll_enable & scene_active),
    .x            (x),
    .y            (y),
    .scroll_x     (scroll_x_w),
    .scroll_hit   (scroll_hit_w)
);
assign scroll_x   = scroll_x_w;
assign scroll_hit = scroll_hit_w;

// 6. 亮度/对比度处理
wire [23:0] bright_rgb;
wire [23:0] contrast_rgb;
brightness_adjust u_bright (
    .rgb_in          (osd_rgb),
    .brightness_level(brightness_level),
    .rgb_out         (bright_rgb)
);
contrast_adjust u_contrast (
    .rgb_in        (bright_rgb),
    .contrast_level(contrast_level),
    .rgb_out       (contrast_rgb)
);

assign out_rgb = scene_active ? contrast_rgb : bg_rgb;

endmodule