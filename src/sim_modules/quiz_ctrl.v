module quiz_ctrl #(
    parameter CLK_FREQ_HZ = 50_000_000,
    parameter TIME_SEC    = 10
)(
    input  wire       clk,
    input  wire       rst_n,
    input  wire       start_pulse,
    input  wire       clear_pulse,
    input  wire [3:0] player_pulse,
    output wire       running,
    output wire       quiz_enable,
    output wire       time_up,
    output wire [7:0] time_left,
    output wire       locked,
    output wire [1:0] winner_id,
    output wire [3:0] winner_onehot
);

quiz_timer #(
    .CLK_FREQ_HZ(CLK_FREQ_HZ),
    .TIME_SEC(TIME_SEC)
) u_quiz_timer (
    .clk         (clk),
    .rst_n       (rst_n),
    .start_pulse (start_pulse),
    .clear_pulse (clear_pulse),
    .locked      (locked),
    .running     (running),
    .quiz_enable (quiz_enable),
    .time_up     (time_up),
    .time_left   (time_left)
);

quiz_arbiter_4ch u_quiz_arbiter_4ch (
    .clk           (clk),
    .rst_n         (rst_n),
    .quiz_enable   (quiz_enable),
    .quiz_clear    (clear_pulse),
    .player_pulse  (player_pulse),
    .locked        (locked),
    .winner_id     (winner_id),
    .winner_onehot (winner_onehot)
);

endmodule
