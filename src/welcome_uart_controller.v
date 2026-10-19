`timescale 1ns/1ps

// UART ticker controller: welcome and emergency share one physical UART.
// RX frame: A5 5A CMD LEN PAYLOAD... XOR(CMD,LEN,PAYLOAD)
//   01=set glyph IDs(1..32 bytes, each 0..44)
//   02=set speed(1 byte, frames/pixel 1..30)
//   03=pause(1 byte, 0=run/1=pause)
//   04=restore default(0 byte)
//   11=set emergency glyph IDs(1..32 bytes, each 0..115)
//   12=set emergency speed(1 byte, frames/pixel 1..30)
//   13=pause emergency(1 byte, 0=run/1=pause)
//   14=restore type-specific emergency default(0 byte)
// Reply: A5 5A (80|CMD) 01 STATUS XOR(80|CMD,01,STATUS), STATUS 0=OK.
module welcome_uart_controller #(
    parameter integer CLKS_PER_BIT=434
)(
    input wire clk,input wire rst_n,input wire uart_rx,output wire uart_tx,
    output reg cfg_update,output reg [191:0] cfg_ids,output reg [5:0] cfg_length,
    output reg [5:0] cfg_speed,output reg cfg_pause,
    output reg emergency_update,output wire [223:0] emergency_ids,
    output reg [5:0] emergency_length,output reg [5:0] emergency_speed,
    output reg emergency_pause,output reg emergency_override
);
    localparam [191:0] DEFAULT_IDS=192'h0000000000000000003ce34c00b2802480041c0185103081;
    localparam [2:0] RX_H0=0,RX_H1=1,RX_CMD=2,RX_LEN=3,RX_PAY=4,RX_CRC=5;
    reg [2:0] rx_state;
    reg [7:0] rx_cmd,rx_len,rx_index,rx_crc;
    reg [191:0] payload;
    reg [223:0] emergency_payload;
    // A failed emergency-text frame must never become visible later when a
    // valid speed/pause command arrives.  Keep the staging-buffer validity
    // explicit; the video-domain copy is only updated while it is valid.
    reg emergency_payload_valid;
    assign emergency_ids=emergency_payload;
    wire [7:0] rx_data;
    wire rx_valid,rx_frame_error;
    reg payload_good;

    uart_rx_byte #(.CLKS_PER_BIT(CLKS_PER_BIT)) u_rx(
        .clk(clk),.rst_n(rst_n),.rx(uart_rx),.data(rx_data),
        .valid(rx_valid),.framing_error(rx_frame_error));

    reg resp_pending;
    reg [7:0] resp_cmd,resp_status;
    reg [2:0] tx_index;
    reg tx_launch_wait;
    reg tx_start;
    reg [7:0] tx_data;
    wire tx_busy,tx_done;
    uart_tx_byte #(.CLKS_PER_BIT(CLKS_PER_BIT)) u_tx(
        .clk(clk),.rst_n(rst_n),.start(tx_start),.data(tx_data),
        .tx(uart_tx),.busy(tx_busy),.done(tx_done));

    function [7:0] response_byte;
        input [2:0] idx; input [7:0] cmd; input [7:0] status;
        begin
            case(idx)
              0:response_byte=8'hA5; 1:response_byte=8'h5A;
              2:response_byte=cmd|8'h80; 3:response_byte=8'h01;
              4:response_byte=status;
              default:response_byte=(cmd|8'h80)^8'h01^status;
            endcase
        end
    endfunction

    task queue_response;
        input [7:0] cmd; input [7:0] status;
        begin
            if(!resp_pending) begin
                resp_cmd<=cmd;resp_status<=status;resp_pending<=1'b1;tx_index<=0;
            end
        end
    endtask

    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            rx_state<=RX_H0;rx_cmd<=0;rx_len<=0;rx_index<=0;rx_crc<=0;
            // emergency_payload is don't-care while emergency_override=0 and
            // is cleared before every 0x11 reception.  Deliberately do not
            // reset this wide data bank: on FPGA this removes 224 reset pins
            // and lets TD pack the configuration registers more efficiently.
            emergency_payload_valid<=1'b0;payload_good<=1'b1;
            // payload 在 RX_LEN 状态、接收任一负载前必定整体清零，且只有
            // CRC 校验通过后才会提交；复位期间/帧头阶段均不可见。因此不
            // 给这 192bit 暂存区挂复位，减少宽复位网及控制脚占用。
            cfg_update<=0;cfg_ids<=DEFAULT_IDS;cfg_length<=6'd20;cfg_speed<=6'd1;cfg_pause<=0;
            emergency_update<=0;emergency_length<=0;emergency_speed<=1;
            emergency_pause<=0;emergency_override<=0;
            resp_pending<=0;resp_cmd<=0;resp_status<=0;tx_index<=0;tx_launch_wait<=0;tx_start<=0;tx_data<=0;
        end else begin
            cfg_update<=0;emergency_update<=0;tx_start<=0;
            if(resp_pending && !tx_busy && !tx_launch_wait) begin
                tx_data<=response_byte(tx_index,resp_cmd,resp_status);
                tx_start<=1'b1;
                tx_launch_wait<=1'b1;
            end
            if(tx_launch_wait && tx_busy) begin
                tx_launch_wait<=1'b0;
                if(tx_index==3'd5) begin resp_pending<=0;tx_index<=0;end
                else tx_index<=tx_index+1'b1;
            end

            if(rx_frame_error) begin
                rx_state<=RX_H0;queue_response(8'h00,8'h04);
            end else if(rx_valid) begin
                case(rx_state)
                  RX_H0: if(rx_data==8'hA5) rx_state<=RX_H1;
                  RX_H1: begin
                      if(rx_data==8'h5A) rx_state<=RX_CMD;
                      else rx_state<=(rx_data==8'hA5)?RX_H1:RX_H0;
                  end
                  RX_CMD: begin rx_cmd<=rx_data;rx_crc<=rx_data;rx_state<=RX_LEN;end
                  RX_LEN: begin
                      rx_len<=rx_data;rx_index<=0;payload<=0;payload_good<=1'b1;rx_crc<=rx_crc^rx_data;
                      if(rx_cmd==8'h11) begin
                          emergency_payload<=0;
                          emergency_payload_valid<=1'b0;
                      end
                      if(rx_data>32) begin rx_state<=RX_H0;queue_response(rx_cmd,8'h02);end
                      else rx_state<=(rx_data==0)?RX_CRC:RX_PAY;
                  end
                  RX_PAY: begin
                      // 上位机按逆序发送字形。这里用固定移位代替 192 bit
                      // 可变位选写入，避免综合器展开成大规模选择网络。
                      if(rx_cmd==8'h11)
                        emergency_payload<={emergency_payload[216:0],rx_data[6:0]};
                      else
                        payload<={payload[185:0],rx_data[5:0]};
                      if((rx_cmd==8'h01 && rx_data>=8'd45) ||
                         (rx_cmd==8'h11 && rx_data>=8'd116)) payload_good<=1'b0;
                      rx_crc<=rx_crc^rx_data;rx_index<=rx_index+1'b1;
                      if(rx_index+1>=rx_len) rx_state<=RX_CRC;
                  end
                  RX_CRC: begin
                      rx_state<=RX_H0;
                      if(rx_data!=rx_crc) queue_response(rx_cmd,8'h01);
                      else begin
                          case(rx_cmd)
                            8'h01: if(rx_len>=1 && rx_len<=32 && payload_good) begin
                                cfg_ids<=payload;cfg_length<=rx_len[5:0];cfg_update<=1;
                                queue_response(rx_cmd,0);
                            end else queue_response(rx_cmd,8'h03);
                            8'h02: if(rx_len==1 && payload[5:0]>=1 && payload[5:0]<=30) begin
                                cfg_speed<=payload[5:0];cfg_update<=1;queue_response(rx_cmd,0);
                            end else queue_response(rx_cmd,8'h03);
                            8'h03: if(rx_len==1 && payload[5:0]<=1) begin
                                cfg_pause<=payload[0];cfg_update<=1;queue_response(rx_cmd,0);
                            end else queue_response(rx_cmd,8'h03);
                            8'h04: if(rx_len==0) begin
                                cfg_ids<=DEFAULT_IDS;cfg_length<=20;cfg_speed<=1;cfg_pause<=0;
                                cfg_update<=1;queue_response(rx_cmd,0);
                            end else queue_response(rx_cmd,8'h03);
                            8'h11: if(rx_len>=1 && rx_len<=32 && payload_good) begin
                                emergency_length<=rx_len[5:0];emergency_override<=1;
                                emergency_payload_valid<=1'b1;
                                emergency_update<=1;queue_response(rx_cmd,0);
                            end else queue_response(rx_cmd,8'h03);
                            8'h12: if(rx_len==1 && payload[5:0]>=1 && payload[5:0]<=30) begin
                                emergency_speed<=payload[5:0];
                                if(!emergency_override || emergency_payload_valid)
                                    emergency_update<=1;
                                queue_response(rx_cmd,0);
                            end else queue_response(rx_cmd,8'h03);
                            8'h13: if(rx_len==1 && payload[5:0]<=1) begin
                                emergency_pause<=payload[0];
                                if(!emergency_override || emergency_payload_valid)
                                    emergency_update<=1;
                                queue_response(rx_cmd,0);
                            end else queue_response(rx_cmd,8'h03);
                            8'h14: if(rx_len==0) begin
                                emergency_length<=0;emergency_speed<=1;emergency_pause<=0;
                                emergency_override<=0;emergency_update<=1;queue_response(rx_cmd,0);
                            end else queue_response(rx_cmd,8'h03);
                            default:queue_response(rx_cmd,8'h05);
                          endcase
                      end
                  end
                  default:rx_state<=RX_H0;
                endcase
            end
        end
    end
endmodule
