module quiz_timer #(
    parameter CLK_FREQ_HZ = 50_000_000,
    parameter TIME_SEC    = 10
)(
    input  wire       clk,
    input  wire       rst_n,
    input  wire       start_pulse,
    input  wire       clear_pulse,
    input  wire       locked,
    output reg        running,
    output reg        quiz_enable,
    output reg        time_up,
    output reg  [7:0] time_left
);

localparam integer ONE_SEC_MAX = CLK_FREQ_HZ - 1;
localparam integer CNT_WIDTH =
    (ONE_SEC_MAX <= 1)       ? 1  :
    (ONE_SEC_MAX <= 2)       ? 2  :
    (ONE_SEC_MAX <= 4)       ? 3  :
    (ONE_SEC_MAX <= 8)       ? 4  :
    (ONE_SEC_MAX <= 16)      ? 5  :
    (ONE_SEC_MAX <= 32)      ? 6  :
    (ONE_SEC_MAX <= 64)      ? 7  :
    (ONE_SEC_MAX <= 128)     ? 8  :
    (ONE_SEC_MAX <= 256)     ? 9  :
    (ONE_SEC_MAX <= 512)     ? 10 :
    (ONE_SEC_MAX <= 1024)    ? 11 :
    (ONE_SEC_MAX <= 2048)    ? 12 :
    (ONE_SEC_MAX <= 4096)    ? 13 :
    (ONE_SEC_MAX <= 8192)    ? 14 :
    (ONE_SEC_MAX <= 16384)   ? 15 :
    (ONE_SEC_MAX <= 32768)   ? 16 :
    (ONE_SEC_MAX <= 65536)   ? 17 :
    (ONE_SEC_MAX <= 131072)  ? 18 :
    (ONE_SEC_MAX <= 262144)  ? 19 :
    (ONE_SEC_MAX <= 524288)  ? 20 :
    (ONE_SEC_MAX <= 1048576) ? 21 :
    (ONE_SEC_MAX <= 2097152) ? 22 :
    (ONE_SEC_MAX <= 4194304) ? 23 :
    (ONE_SEC_MAX <= 8388608) ? 24 :
    (ONE_SEC_MAX <= 16777216)? 25 :
    (ONE_SEC_MAX <= 33554432)? 26 : 27;

reg [CNT_WIDTH-1:0] sec_cnt;
localparam [CNT_WIDTH-1:0] ONE_SEC_TERM = ONE_SEC_MAX;
localparam [7:0] TIME_INIT = TIME_SEC;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        sec_cnt     <= {CNT_WIDTH{1'b0}};
        running     <= 1'b0;
        quiz_enable <= 1'b0;
        time_up     <= 1'b0;
        time_left   <= TIME_INIT;
    end else if (clear_pulse) begin
        sec_cnt     <= {CNT_WIDTH{1'b0}};
        running     <= 1'b0;
        quiz_enable <= 1'b0;
        time_up     <= 1'b0;
        time_left   <= TIME_INIT;
    end else if (start_pulse) begin
        sec_cnt     <= {CNT_WIDTH{1'b0}};
        running     <= 1'b1;
        quiz_enable <= 1'b1;
        time_up     <= 1'b0;
        time_left   <= TIME_INIT;
    end else if (locked) begin
        sec_cnt     <= sec_cnt;
        running     <= 1'b0;
        quiz_enable <= 1'b0;
        time_up     <= 1'b0;
        time_left   <= time_left;
    end else if (running) begin
        if (sec_cnt >= ONE_SEC_TERM) begin
            sec_cnt <= {CNT_WIDTH{1'b0}};
            if (time_left > 8'd1) begin
                time_left   <= time_left - 8'd1;
                running     <= 1'b1;
                quiz_enable <= 1'b1;
                time_up     <= 1'b0;
            end else begin
                time_left   <= 8'd0;
                running     <= 1'b0;
                quiz_enable <= 1'b0;
                time_up     <= 1'b1;
            end
        end else begin
            sec_cnt     <= sec_cnt + 1'b1;
            running     <= 1'b1;
            quiz_enable <= 1'b1;
            time_up     <= 1'b0;
            time_left   <= time_left;
        end
    end
end

endmodule
