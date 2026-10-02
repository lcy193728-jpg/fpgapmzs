module brightness_adjust(
    input  wire [23:0] rgb_in,
    input  wire [3:0]  brightness_level,
    output wire [23:0] rgb_out
);

wire [7:0] r_in;
wire [7:0] g_in;
wire [7:0] b_in;
wire [8:0] gain;
wire [16:0] r_mul;
wire [16:0] g_mul;
wire [16:0] b_mul;
wire [8:0] r_tmp;
wire [8:0] g_tmp;
wire [8:0] b_tmp;

assign r_in = rgb_in[23:16];
assign g_in = rgb_in[15:8];
assign b_in = rgb_in[7:0];

assign gain = 9'd128 + ({5'd0, brightness_level} * 9'd8);

assign r_mul = r_in * gain;
assign g_mul = g_in * gain;
assign b_mul = b_in * gain;

assign r_tmp = r_mul[16:7];
assign g_tmp = g_mul[16:7];
assign b_tmp = b_mul[16:7];

assign rgb_out[23:16] = r_tmp[8] ? 8'hff : r_tmp[7:0];
assign rgb_out[15:8]  = g_tmp[8] ? 8'hff : g_tmp[7:0];
assign rgb_out[7:0]   = b_tmp[8] ? 8'hff : b_tmp[7:0];

endmodule
