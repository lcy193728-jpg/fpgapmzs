// ============================================================
// contrast_adjust.v —— 对比度调节（对应赛题 扩展4）
// 以 128 为中点：out = clamp(128 + (in-128)*(32+level)/32)
// level=0  -> 1.00x（不变）
// 暗像素(<128)更暗、亮像素(>128)更亮，对比度增强。
// 注意：增益用 integer 计算，避免 6bit 有符号数把 32 解释成 -32 的坑。
// ============================================================
module contrast_adjust (
    input  wire [23:0] rgb_in,
    input  wire [3:0]  contrast_level,
    output wire [23:0] rgb_out
);

function [7:0] contrast_ch;
    input [7:0] in;
    input [3:0] lvl;
    integer t;
    integer g;
    begin
        g = 32 + lvl;      // 增益 32..47
        t = in;            // 0..255
        t = t - 128;       // -128..127
        t = t * g;
        t = t / 32;
        t = t + 128;
        if (t < 0)        contrast_ch = 8'd0;
        else if (t > 255) contrast_ch = 8'd255;
        else              contrast_ch = t[7:0];
    end
endfunction

assign rgb_out = { contrast_ch(rgb_in[23:16], contrast_level),
                   contrast_ch(rgb_in[15:8],  contrast_level),
                   contrast_ch(rgb_in[7:0],   contrast_level) };

endmodule