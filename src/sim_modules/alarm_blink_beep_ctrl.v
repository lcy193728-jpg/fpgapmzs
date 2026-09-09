module alarm_blink_beep_ctrl #(
    parameter integer CLK_FREQ_HZ = 50000000,
    parameter integer BLINK_HZ    = 4,
    parameter integer BEEP_HZ     = 2
)(
    input  wire clk,
    input  wire rst_n,
    input  wire emergency_active,
    output reg  blink_on,
    output reg  led_flash,
    output reg  beep_en
);

localparam integer BLINK_HALF_CYCLES = CLK_FREQ_HZ / (BLINK_HZ * 2);
localparam integer BEEP_HALF_CYCLES  = CLK_FREQ_HZ / (BEEP_HZ * 2);

reg [31:0] blink_cnt;
reg [31:0] beep_cnt;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        blink_cnt <= 32'd0;
        blink_on  <= 1'b0;
    end else if (!emergency_active) begin
        blink_cnt <= 32'd0;
        blink_on  <= 1'b0;
    end else if (blink_cnt >= BLINK_HALF_CYCLES - 1) begin
        blink_cnt <= 32'd0;
        blink_on  <= ~blink_on;
    end else begin
        blink_cnt <= blink_cnt + 1'b1;
    end
end

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        beep_cnt <= 32'd0;
        beep_en  <= 1'b0;
    end else if (!emergency_active) begin
        beep_cnt <= 32'd0;
        beep_en  <= 1'b0;
    end else if (beep_cnt >= BEEP_HALF_CYCLES - 1) begin
        beep_cnt <= 32'd0;
        beep_en  <= ~beep_en;
    end else begin
        beep_cnt <= beep_cnt + 1'b1;
    end
end

always @(*) begin
    led_flash = emergency_active && blink_on;
end

endmodule
