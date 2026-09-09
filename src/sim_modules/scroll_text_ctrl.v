module scroll_text_ctrl #(
    parameter H_ACTIVE     = 640,
    parameter TEXT_WIDTH   = 260,
    parameter STEP_MAX     = 4
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        scroll_enable,
    input  wire [10:0] x,
    input  wire [10:0] y,
    output reg  [10:0] scroll_x,
    output wire        scroll_hit
);

localparam [10:0] START_X = H_ACTIVE;
localparam [10:0] END_X   = TEXT_WIDTH;

reg [15:0] step_cnt;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        scroll_x <= START_X;
        step_cnt <= 16'd0;
    end else if (!scroll_enable) begin
        scroll_x <= START_X;
        step_cnt <= 16'd0;
    end else if (step_cnt >= STEP_MAX - 1) begin
        step_cnt <= 16'd0;
        if (scroll_x == 11'd0)
            scroll_x <= START_X;
        else
            scroll_x <= scroll_x - 1'b1;
    end else begin
        step_cnt <= step_cnt + 1'b1;
    end
end

assign scroll_hit = scroll_enable &&
                    (y >= 11'd430 && y < 11'd456) &&
                    (x >= scroll_x) &&
                    (x < scroll_x + END_X);

endmodule
