module key_edge_detect(
    input  wire clk,
    input  wire rst_n,
    input  wire key_level,
    output reg  key_pos_pulse,
    output reg  key_neg_pulse
);

reg key_level_d1;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        key_level_d1  <= 1'b0;
        key_pos_pulse <= 1'b0;
        key_neg_pulse <= 1'b0;
    end else begin
        key_level_d1  <= key_level;
        key_pos_pulse <=  key_level & ~key_level_d1;
        key_neg_pulse <= ~key_level &  key_level_d1;
    end
end

endmodule
