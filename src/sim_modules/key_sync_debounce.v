module key_sync_debounce #(
    parameter CLK_FREQ_HZ = 50_000_000,
    parameter DEBOUNCE_MS = 20,
    parameter ACTIVE_LOW  = 1
)(
    input  wire clk,
    input  wire rst_n,
    input  wire key_in,
    output reg  key_level
);

localparam integer DEBOUNCE_MAX = (CLK_FREQ_HZ / 1000) * DEBOUNCE_MS;
localparam integer CNT_WIDTH =
    (DEBOUNCE_MAX <= 1)       ? 1  :
    (DEBOUNCE_MAX <= 2)       ? 2  :
    (DEBOUNCE_MAX <= 4)       ? 3  :
    (DEBOUNCE_MAX <= 8)       ? 4  :
    (DEBOUNCE_MAX <= 16)      ? 5  :
    (DEBOUNCE_MAX <= 32)      ? 6  :
    (DEBOUNCE_MAX <= 64)      ? 7  :
    (DEBOUNCE_MAX <= 128)     ? 8  :
    (DEBOUNCE_MAX <= 256)     ? 9  :
    (DEBOUNCE_MAX <= 512)     ? 10 :
    (DEBOUNCE_MAX <= 1024)    ? 11 :
    (DEBOUNCE_MAX <= 2048)    ? 12 :
    (DEBOUNCE_MAX <= 4096)    ? 13 :
    (DEBOUNCE_MAX <= 8192)    ? 14 :
    (DEBOUNCE_MAX <= 16384)   ? 15 :
    (DEBOUNCE_MAX <= 32768)   ? 16 :
    (DEBOUNCE_MAX <= 65536)   ? 17 :
    (DEBOUNCE_MAX <= 131072)  ? 18 :
    (DEBOUNCE_MAX <= 262144)  ? 19 :
    (DEBOUNCE_MAX <= 524288)  ? 20 :
    (DEBOUNCE_MAX <= 1048576) ? 21 : 24;

reg key_meta;
reg key_sync;
reg key_pressed_raw;
reg key_pressed_last;
reg [CNT_WIDTH-1:0] stable_cnt;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        key_meta         <= ACTIVE_LOW ? 1'b1 : 1'b0;
        key_sync         <= ACTIVE_LOW ? 1'b1 : 1'b0;
        key_pressed_raw  <= 1'b0;
        key_pressed_last <= 1'b0;
        stable_cnt       <= {CNT_WIDTH{1'b0}};
        key_level        <= 1'b0;
    end else begin
        key_meta <= key_in;
        key_sync <= key_meta;

        key_pressed_raw <= ACTIVE_LOW ? ~key_sync : key_sync;

        if (key_pressed_raw == key_pressed_last) begin
            if (stable_cnt < (DEBOUNCE_MAX - 1))
                stable_cnt <= stable_cnt + 1'b1;
            else
                key_level <= key_pressed_raw;
        end else begin
            stable_cnt <= {CNT_WIDTH{1'b0}};
        end

        key_pressed_last <= key_pressed_raw;
    end
end

endmodule
