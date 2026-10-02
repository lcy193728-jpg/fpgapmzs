module welcome_osd_overlay #(
    parameter H_ACTIVE = 640,
    parameter V_ACTIVE = 480
)(
    input  wire        de,
    input  wire [10:0] x,
    input  wire [10:0] y,
    input  wire [23:0] bg_rgb,
    input  wire        osd_enable,
    output reg  [23:0] out_rgb,
    output reg         osd_hit
);

wire title_region;
wire place_region;
wire contact_region;

assign title_region   = (x >= 11'd40  && x < 11'd600 && y >= 11'd30  && y < 11'd72);
assign place_region   = (x >= 11'd40  && x < 11'd360 && y >= 11'd380 && y < 11'd412);
assign contact_region = (x >= 11'd380 && x < 11'd600 && y >= 11'd380 && y < 11'd412);

always @(*) begin
    osd_hit = 1'b0;
    out_rgb = bg_rgb;

    if (de && osd_enable) begin
        if (title_region) begin
            osd_hit = 1'b1;
            out_rgb = 24'hffd24a;
        end else if (place_region) begin
            osd_hit = 1'b1;
            out_rgb = 24'h2f80ff;
        end else if (contact_region) begin
            osd_hit = 1'b1;
            out_rgb = 24'h26c281;
        end
    end
end

endmodule
