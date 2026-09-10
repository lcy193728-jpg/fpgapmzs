// ============================================================
// meeting_page_ctrl.v —— 会议多页公告控制器（自研，对应赛题 基础要求2 + 扩展2）
//   auto_enable=1：每 AUTO_INTERVAL 拍自动翻页（循环回绕）
//   next_pulse/prev_pulse：手动上下翻页（同时复位自动计数）
//   任何翻页动作都输出 1 拍 page_changed 脉冲（可触发转场）。
// ============================================================
module meeting_page_ctrl #(
    parameter PAGE_COUNT    = 4,   // 公告页数（<=4，用 2bit 编码）
    parameter AUTO_INTERVAL = 16   // 自动翻页周期（clk 数），仿真用短值
)(
    input  wire clk,
    input  wire rst_n,
    input  wire auto_enable,
    input  wire next_pulse,
    input  wire prev_pulse,
    output reg  [1:0] page_index,
    output reg        page_changed
);

localparam [1:0] PAGE_MAX = PAGE_COUNT - 1;

reg [15:0] auto_cnt;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        page_index   <= 2'd0;
        page_changed <= 1'b0;
        auto_cnt     <= 16'd0;
    end else begin
        page_changed <= 1'b0;

        if (next_pulse && !prev_pulse) begin
            page_changed <= 1'b1;
            page_index   <= (page_index == PAGE_MAX) ? 2'd0 : page_index + 1'b1;
            auto_cnt     <= 16'd0;
        end else if (prev_pulse && !next_pulse) begin
            page_changed <= 1'b1;
            page_index   <= (page_index == 2'd0) ? PAGE_MAX : page_index - 1'b1;
            auto_cnt     <= 16'd0;
        end else if (auto_enable) begin
            if (auto_cnt >= AUTO_INTERVAL - 1) begin
                auto_cnt     <= 16'd0;
                page_changed <= 1'b1;
                page_index   <= (page_index == PAGE_MAX) ? 2'd0 : page_index + 1'b1;
            end else begin
                auto_cnt <= auto_cnt + 1'b1;
            end
        end
    end
end

endmodule