// ============================================================
// fade_transition_ctrl.v —— 淡入淡出转场 Alpha 发生器（复用自团队 dev_sim 分支）
// transition_start 脉冲触发后，alpha 以 16/STEP_MAX 节拍从 0 渐增到 255，
// ramp 过程中 transition_busy=1，到 255 后置 transition_done=1 一拍。
// → 对应赛题 扩展2「图片切换与转场特效」（配合双帧缓存做 Alpha 混合）。
// ============================================================
module fade_transition_ctrl #(
    parameter STEP_MAX = 8
)(
    input  wire       clk,
    input  wire       rst_n,
    input  wire       transition_start,
    output reg        transition_busy,
    output reg        transition_done,
    output reg  [7:0] alpha
);

reg [15:0] step_cnt;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        transition_busy <= 1'b0;
        transition_done <= 1'b0;
        alpha           <= 8'd0;
        step_cnt        <= 16'd0;
    end else begin
        transition_done <= 1'b0;

        if (transition_start && !transition_busy) begin
            transition_busy <= 1'b1;
            alpha           <= 8'd0;
            step_cnt        <= 16'd0;
        end else if (transition_busy) begin
            if (step_cnt >= STEP_MAX - 1) begin
                step_cnt <= 16'd0;
                if (alpha >= 8'd240) begin
                    alpha           <= 8'd255;
                    transition_busy <= 1'b0;
                    transition_done <= 1'b1;
                end else begin
                    alpha <= alpha + 8'd16;
                end
            end else begin
                step_cnt <= step_cnt + 1'b1;
            end
        end
    end
end

endmodule