module emergency_osd_overlay #(
    parameter H_ACTIVE = 640,
    parameter V_ACTIVE = 480
)(
    input  wire        de,
    input  wire [10:0] x,
    input  wire [10:0] y,
    input  wire [23:0] bg_rgb,
    input  wire        emergency_active,
    input  wire        blink_on,
    input  wire        scroll_hit,
    output reg  [23:0] out_rgb,
    output reg         alarm_osd_hit
);

wire top_bar_region;
wire bottom_bar_region;
wire icon_region;
wire title_region;

localparam [10:0] H_LIMIT      = H_ACTIVE;
localparam [10:0] V_LIMIT      = V_ACTIVE;
localparam [10:0] BOTTOM_START = V_ACTIVE - 48;

assign top_bar_region    = (x < H_LIMIT) && (y < 11'd48);
assign bottom_bar_region = (x < H_LIMIT) && (y >= BOTTOM_START) && (y < V_LIMIT);
assign icon_region       = (x >= 11'd24  && x < 11'd88  && y >= 11'd72 && y < 11'd136);
assign title_region      = (x >= 11'd110 && x < 11'd610 && y >= 11'd82 && y < 11'd124);

always @(*) begin
    alarm_osd_hit = 1'b0;
    out_rgb       = bg_rgb;

    if (de && emergency_active) begin
        if (scroll_hit) begin
            alarm_osd_hit = 1'b1;
            out_rgb       = 24'hffffff;
        end else if (top_bar_region || bottom_bar_region) begin
            alarm_osd_hit = 1'b1;
            out_rgb       = blink_on ? 24'hff2020 : 24'h8a0000;
        end else if (icon_region) begin
            alarm_osd_hit = 1'b1;
            out_rgb       = blink_on ? 24'hffd24a : 24'hff2020;
        end else if (title_region) begin
            alarm_osd_hit = 1'b1;
            out_rgb       = 24'hfff0f0;
        end
    end
end

endmodule
