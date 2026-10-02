// ============================================================
// tb_meeting_scene.v —— 场景二「会议展示」组合自检 testbench
// 验证点：
//   [基础2/交互] 场景切换进入会议场景
//   [扩展1]      会议标题/时间/地点/页码 OSD 叠加
//   [基础2/扩展2]多页公告 手动+自动切换，翻页触发转场
//   [扩展2]      淡入淡出 alpha 0->255
//   [扩展1]      底部滚动字幕 scroll_x 移动 + scroll_hit
//   [扩展4]      亮度调节（变亮）、对比度调节（暗更暗/亮更亮）
// 运行：vlog 后 vsim -c -do "run -all; quit -f" work.tb_meeting_scene
// ============================================================
`timescale 1ns/1ps
module tb_meeting_scene;

// ---- DUT 接口 ----
reg         clk;
reg         rst_n;
reg         next_scene_pulse, prev_scene_pulse;
reg         direct_en;
reg  [1:0]  direct_scene;
reg         auto_enable;
reg         page_next_pulse, page_prev_pulse;
reg         scroll_enable;
reg  [3:0]  brightness_level, contrast_level;
reg         de;
reg  [10:0] x, y;
reg  [23:0] bg_rgb;

wire [23:0] out_rgb;
wire        osd_hit;
wire [1:0]  scene_current;
wire        scene_active;
wire [1:0]  page_index;
wire        page_changed;
wire        transition_busy;
wire        transition_done;
wire [7:0]  alpha;
wire [10:0] scroll_x;
wire        scroll_hit;

meeting_scene_top #(
    .PAGE_COUNT    (4),
    .AUTO_INTERVAL (16)
) dut (
    .clk              (clk),
    .rst_n            (rst_n),
    .next_scene_pulse (next_scene_pulse),
    .prev_scene_pulse (prev_scene_pulse),
    .direct_en        (direct_en),
    .direct_scene     (direct_scene),
    .auto_enable      (auto_enable),
    .page_next_pulse  (page_next_pulse),
    .page_prev_pulse  (page_prev_pulse),
    .scroll_enable    (scroll_enable),
    .brightness_level (brightness_level),
    .contrast_level   (contrast_level),
    .de               (de),
    .x                (x),
    .y                (y),
    .bg_rgb           (bg_rgb),
    .out_rgb          (out_rgb),
    .osd_hit          (osd_hit),
    .scene_current    (scene_current),
    .scene_active     (scene_active),
    .page_index       (page_index),
    .page_changed     (page_changed),
    .transition_busy  (transition_busy),
    .transition_done  (transition_done),
    .alpha            (alpha),
    .scroll_x         (scroll_x),
    .scroll_hit       (scroll_hit)
);

localparam [1:0] SCENE_WELCOME = 2'd0;
localparam [1:0] SCENE_MEETING = 2'd1;
localparam [1:0] SCENE_QUIZ    = 2'd2;

localparam [23:0] C_TITLE = 24'h0A_2E_6E;
localparam [23:0] C_TIME  = 24'h2F_80_FF;
localparam [23:0] C_LOC   = 24'h26_C2_81;
localparam [23:0] C_PAGE0 = 24'hFF_88_88;
localparam [23:0] C_PAGE1 = 24'h88_FF_88;
localparam [23:0] C_PAGE2 = 24'h88_88_FF;
localparam [23:0] C_PAGE3 = 24'hFF_FF_88;

integer errs;

// ---- 时钟 ----
initial clk = 1'b0;
always #5 clk = ~clk;

// ---- 工具 task ----
task wait_clks;
    input integer n;
    integer i;
begin
    for (i = 0; i < n; i = i + 1) @(posedge clk);
end
endtask

// 注意：task 的 output 参数是"结束时拷贝出去"，仿真中不能被 DUT 实时看到，
//       所以这里像团队 tb_scene_selector 那样，直接操作模块级信号。
task pulse_next_scene;
begin
    @(negedge clk); next_scene_pulse = 1'b1;
    @(negedge clk); next_scene_pulse = 1'b0;
end
endtask

task pulse_page_next;
begin
    @(negedge clk); page_next_pulse = 1'b1;
    @(negedge clk); page_next_pulse = 1'b0;
end
endtask

task check_px;          // 检查某像素点的 osd_hit 与 out_rgb
    input [10:0] px, py;
    input [0:0]  exp_hit;
    input [23:0] exp_rgb;
    input integer id;
begin
    @(negedge clk);
    de = 1'b1; x = px; y = py;
    #3;
    if (osd_hit !== exp_hit || out_rgb !== exp_rgb) begin
        $display("FAIL chk%0d x=%0d y=%0d : hit=%b exp=%b, rgb=%h exp=%h",
                 id, x, y, osd_hit, exp_hit, out_rgb, exp_rgb);
        errs = errs + 1;
    end else
        $display("PASS chk%0d x=%0d y=%0d rgb=%h", id, x, y, out_rgb);
end
endtask

task wait_transition_done;
    integer t;
begin
    t = 0;
    while (t < 4096 && transition_done !== 1'b1) begin
        @(posedge clk);
        t = t + 1;
    end
    if (transition_done !== 1'b1) begin
        $display("FAIL: transition_done timeout");
        errs = errs + 1;
    end else if (alpha !== 8'd255) begin
        $display("FAIL: alpha=%0d at done, exp 255", alpha);
        errs = errs + 1;
    end else
        $display("PASS: fade alpha=255, transition_done asserted");
end
endtask

// ---- 主流程 ----
initial begin
    errs = 0;

    // 初始化
    next_scene_pulse = 0; prev_scene_pulse = 0;
    direct_en = 0; direct_scene = 2'd0;
    auto_enable = 0;
    page_next_pulse = 0; page_prev_pulse = 0;
    scroll_enable = 0;
    brightness_level = 0; contrast_level = 0;
    de = 0; x = 0; y = 0; bg_rgb = 24'hFF_00_FF;
    rst_n = 0;

    wait_clks(5);
    rst_n = 1;
    wait_clks(2);

    // 1. 复位默认在欢迎场景，会议未激活
    if (scene_current !== SCENE_WELCOME) begin
        $display("FAIL: reset scene=%0d exp 0", scene_current); errs = errs + 1;
    end else $display("PASS: reset scene=WELCOME");
    if (scene_active !== 1'b0) begin
        $display("FAIL: meeting should be inactive at reset"); errs = errs + 1;
    end else $display("PASS: meeting inactive at reset");

    // 2. 按 next 进入会议场景
    pulse_next_scene();
    if (scene_current !== SCENE_MEETING) begin
        $display("FAIL: next -> scene=%0d exp 1", scene_current); errs = errs + 1;
    end else $display("PASS: next -> scene=MEETING");
    if (scene_active !== 1'b1) begin
        $display("FAIL: scene_active not asserted"); errs = errs + 1;
    end else $display("PASS: scene_active=1");

    wait_clks(1);

    // 3. 会议 OSD（亮度/对比度=0 时输出=纯色）
    check_px(11'd100, 11'd60,  1'b1, C_TITLE, 1); // 标题条
    check_px(11'd100, 11'd140, 1'b1, C_TIME,  2); // 时间
    check_px(11'd400, 11'd140, 1'b1, C_LOC,   3); // 地点
    check_px(11'd570, 11'd430, 1'b1, C_PAGE0, 4); // 页码(页0)
    check_px(11'd10,  11'd10,  1'b0, bg_rgb,  5); // 非OSD区透传

    // 4. 手动翻页：页 0 -> 1，页码颜色随之变化
    pulse_page_next();
    if (page_index !== 2'd1) begin
        $display("FAIL: manual next page=%0d exp 1", page_index); errs = errs + 1;
    end else $display("PASS: manual next -> page=1");
    check_px(11'd570, 11'd430, 1'b1, C_PAGE1, 6); // 页码(页1)

    // 5. 转场淡入淡出
    wait_transition_done();

    // 6. 自动轮播：页 1 -> 2 -> 3 -> 0 (AUTO_INTERVAL=16)
    //    在 negedge 同步使能/采样，避免异步 auto_enable 赋值与 posedge 采样 NBA 竞争
    @(negedge clk); auto_enable = 1'b1;
    wait_clks(16); @(negedge clk); if (page_index !== 2'd2) begin
        $display("FAIL: auto page after 16 clk =%0d exp 2", page_index); errs = errs + 1;
    end else $display("PASS: auto -> page=2");
    wait_clks(16); @(negedge clk); if (page_index !== 2'd3) begin
        $display("FAIL: auto page after 32 clk =%0d exp 3", page_index); errs = errs + 1;
    end else $display("PASS: auto -> page=3");
    wait_clks(16); @(negedge clk); if (page_index !== 2'd0) begin
        $display("FAIL: auto wrap page=%0d exp 0", page_index); errs = errs + 1;
    end else $display("PASS: auto wrap -> page=0");
    @(negedge clk); auto_enable = 1'b0;

    // 7. 滚动字幕
    scroll_enable = 1'b1;
    wait_clks(5);
    if (scroll_x >= 11'd640) begin
        $display("FAIL: scroll_x=%0d not moving", scroll_x); errs = errs + 1;
    end else $display("PASS: scroll_x=%0d moving left", scroll_x);
    x = 11'd650; y = 11'd440; #3;
    if (scroll_hit !== 1'b1) begin
        $display("FAIL: scroll_hit should be 1 at x=%0d", x); errs = errs + 1;
    end else $display("PASS: scroll_hit=1 in text band");
    x = 11'd100; #3;
    if (scroll_hit !== 1'b0) begin
        $display("FAIL: scroll_hit should be 0 at x=100"); errs = errs + 1;
    end else $display("PASS: scroll_hit=0 outside text");
    scroll_enable = 1'b0;

    // 8. 亮度：暗像素变亮
    brightness_level = 4'd4; contrast_level = 4'd0;
    de = 1'b1; x = 11'd10; y = 11'd10; bg_rgb = 24'h20_20_20; #3;
    if (out_rgb <= bg_rgb) begin
        $display("FAIL: brightness bg=%h out=%h not brighter", bg_rgb, out_rgb); errs = errs + 1;
    end else $display("PASS: brightness %h -> %h", bg_rgb, out_rgb);

    // 9. 对比度：暗更暗、亮更亮
    brightness_level = 4'd0; contrast_level = 4'd4;
    bg_rgb = 24'h20_20_20; #3;
    if (out_rgb >= 24'h20_20_20) begin
        $display("FAIL: contrast dark out=%h should be darker", out_rgb); errs = errs + 1;
    end else $display("PASS: contrast dark %h", out_rgb);
    bg_rgb = 24'hC8_C8_C8; #3;
    if (out_rgb <= 24'hC8_C8_C8) begin
        $display("FAIL: contrast bright out=%h should be brighter", out_rgb); errs = errs + 1;
    end else $display("PASS: contrast bright %h", out_rgb);

    // 汇总
    $display("=======================");
    if (errs == 0)
        $display("PASS: tb_meeting_scene ALL CHECKS OK");
    else
        $display("FAIL: %0d checks failed", errs);
    $stop;
end

endmodule