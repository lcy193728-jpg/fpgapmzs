// ============================================================
// brightness_adjust.v —— 亮度调节（对应赛题 扩展4）
// out = clamp(rgb * (128 + level*8) / 128)
// level=0   -> 1.00x（不变）
// level=15  -> 1.94x（变亮，逐通道饱和到 255）
// ============================================================
module brightness_adjust (
    input  wire [23:0] rgb_in,
    input  wire [3:0]  brightness_level,
    output wire [23:0] rgb_out
);

wire [7:0] gain = 8'd128 + {brightness_level, 3'b0};

wire [15:0] r_mul = rgb_in[23:16] * gain;
wire [15:0] g_mul = rgb_in[15:8]  * gain;
wire [15:0] b_mul = rgb_in[7:0]   * gain;

// /128 = 右移 7 位，取 9 位结果再做饱和
wire [8:0] r_sc = r_mul[15:7];
wire [8:0] g_sc = g_mul[15:7];
wire [8:0] b_sc = b_mul[15:7];

assign rgb_out = { (r_sc > 9'd255 ? 8'd255 : r_sc[7:0]),
                   (g_sc > 9'd255 ? 8'd255 : g_sc[7:0]),
                   (b_sc > 9'd255 ? 8'd255 : b_sc[7:0]) };

endmodule