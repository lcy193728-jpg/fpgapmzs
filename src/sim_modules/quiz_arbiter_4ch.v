module quiz_arbiter_4ch(
    input  wire       clk,
    input  wire       rst_n,
    input  wire       quiz_enable,
    input  wire       quiz_clear,
    input  wire [3:0] player_pulse,
    output reg        locked,
    output reg  [1:0] winner_id,
    output reg  [3:0] winner_onehot
);

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        locked        <= 1'b0;
        winner_id     <= 2'd0;
        winner_onehot <= 4'b0000;
    end else if (quiz_clear) begin
        locked        <= 1'b0;
        winner_id     <= 2'd0;
        winner_onehot <= 4'b0000;
    end else if (quiz_enable && !locked) begin
        casez (player_pulse)
            4'b???1: begin
                locked        <= 1'b1;
                winner_id     <= 2'd0;
                winner_onehot <= 4'b0001;
            end
            4'b??10: begin
                locked        <= 1'b1;
                winner_id     <= 2'd1;
                winner_onehot <= 4'b0010;
            end
            4'b?100: begin
                locked        <= 1'b1;
                winner_id     <= 2'd2;
                winner_onehot <= 4'b0100;
            end
            4'b1000: begin
                locked        <= 1'b1;
                winner_id     <= 2'd3;
                winner_onehot <= 4'b1000;
            end
            default: begin
                locked        <= locked;
                winner_id     <= winner_id;
                winner_onehot <= winner_onehot;
            end
        endcase
    end
end

endmodule
