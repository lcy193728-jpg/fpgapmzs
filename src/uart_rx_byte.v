`timescale 1ns/1ps

// Based on the verified byte receiver from Xiaoe lesson 5.
module uart_rx_byte #(
    parameter integer CLKS_PER_BIT = 434
) (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       rx,
    output reg  [7:0] data,
    output reg        valid,
    output reg        framing_error
);
    localparam [2:0] ST_IDLE=0, ST_START=1, ST_DATA=2, ST_STOP=3;
    reg rx_meta, rx_sync;
    reg [2:0] state, bit_index;
    reg [31:0] count;
    reg [7:0] shift;

    initial begin
        if (CLKS_PER_BIT < 4) begin
            $display("UART_RX_BYTE_CONFIG_ERROR");
            $finish;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_meta<=1'b1; rx_sync<=1'b1; state<=ST_IDLE;
            count<=0; bit_index<=0; shift<=0;
            data<=0; valid<=0; framing_error<=0;
        end else begin
            rx_meta<=rx; rx_sync<=rx_meta; valid<=0; framing_error<=0;
            case (state)
                ST_IDLE: if (!rx_sync) begin count<=0; state<=ST_START; end
                ST_START: if (count+1 >= CLKS_PER_BIT/2) begin
                    count<=0;
                    if (!rx_sync) begin bit_index<=0; state<=ST_DATA; end
                    else state<=ST_IDLE;
                end else count<=count+1'b1;
                ST_DATA: if (count+1 >= CLKS_PER_BIT) begin
                    count<=0; shift[bit_index]<=rx_sync;
                    if (bit_index==7) state<=ST_STOP;
                    else bit_index<=bit_index+1'b1;
                end else count<=count+1'b1;
                ST_STOP: if (count+1 >= CLKS_PER_BIT) begin
                    count<=0; state<=ST_IDLE;
                    if (rx_sync) begin data<=shift; valid<=1'b1; end
                    else framing_error<=1'b1;
                end else count<=count+1'b1;
                default: state<=ST_IDLE;
            endcase
        end
    end
endmodule
