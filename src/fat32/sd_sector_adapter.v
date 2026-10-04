//====================================================================
// 模块名 : sd_sector_adapter.v —— SD 卡扇区读接口适配层
//
// 作用(照搬小鹅通第七讲 §5.3, 但适配本工程的 sd_card_top):
//   FAT32 模块(fat32_volume_scanner / fat32_file_streamer)使用 sector_*
//   接口(含 sector_busy / sector_byte_index / sector_error), 而本工程的
//   sd_card_top 只输出 sd_sec_read_data_valid / sd_sec_read_end, 缺这三根。
//   本适配层解决三个问题:
//     1. sector_busy      : 请求发出到读完成之间为 1
//     2. sector_byte_index: 官方不输出字节索引, 这里自计数(valid 时 +1, done 清零)
//     3. sector_error     : 官方无错误码, 固定输出 0
//
// 时序约定(实测 sd_card_sec_read_write.v 确认):
//   sd_sec_read 是【电平触发】: S_WAIT_READ_WRITE 态检测到 sd_sec_read==1
//   即锁存 addr 进入 S_CMD17 发起读; 读完回到 S_WAIT_READ_WRITE, 若 req 仍=1
//   会连续读下一扇区(addr 取新的 sd_sec_read_addr)。故:
//     · 单扇区读: req 拉高 → busy 期间等待 → 见到 sd_sec_read_end 拉低 req
//     · 连续读  : 保持 req=1 且持续更新 addr 即可(本适配层一次只服务一扇区,
//                 靠 sector_done 通知上层再发下一扇区, 不做自动连续)。
//====================================================================
`timescale 1ns/1ps

module sd_sector_adapter (
    input  wire        clk,
    input  wire        rst_n,               // 低有效复位
    input  wire        allow_req,           // 流控允许(1=可发请求; 0=暂停, 供 wav 水位流控)
    // === FAT32 模块侧(sector 接口) ===
    input  wire        sector_req,          // 读扇区请求(电平, req=1 请求读)
    input  wire [31:0] sector_lba,          // 扇区号
    output wire        sector_busy,         // 忙(正在读)
    output wire        sector_valid,        // 字节有效脉冲
    output wire [7:0]  sector_byte,         // 当前字节
    output wire [8:0]  sector_byte_index,   // 字节索引(0~511)
    output wire        sector_done,         // 读完成脉冲
    output wire [7:0]  sector_error,        // 错误码(官方无, 固定 0)
    // === sd_card_top 侧(sd_sec 接口) ===
    output reg         sd_sec_read,         // 读扇区请求(电平)
    output reg  [31:0] sd_sec_read_addr,    // 扇区号
    input  wire        sd_sec_read_data_valid,
    input  wire [7:0]  sd_sec_read_data,
    input  wire        sd_sec_read_end
);

    reg [8:0] byte_cnt;
    reg       busy_reg;

    // allow_req=0 时"假装忙": 让 streamer 停在 ST_DATA_REQ 不发起新扇区请求,
    //   等 allow 恢复后 sector_busy 拉低、streamer 继续。这是 wav 水位流控的关键:
    //   若只在发起侧门控(allow 且不置 busy), streamer 会误以为"请求已受理"而转
    //   ST_DATA_WAIT 死等 sector_done → 死锁。
    assign sector_busy       = busy_reg || ~allow_req;
    assign sector_valid      = sd_sec_read_data_valid;
    assign sector_byte       = sd_sec_read_data;
    assign sector_byte_index = byte_cnt;
    assign sector_done       = sd_sec_read_end;
    assign sector_error      = 8'd0;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sd_sec_read      <= 1'b0;
            sd_sec_read_addr <= 32'd0;
            byte_cnt         <= 9'd0;
            busy_reg         <= 1'b0;
        end else begin
            // 请求到来且不忙且被允许时, 锁存扇区号, 发出读请求
            if (sector_req && !busy_reg && allow_req) begin
                sd_sec_read      <= 1'b1;
                sd_sec_read_addr <= sector_lba;
                busy_reg         <= 1'b1;
                byte_cnt         <= 9'd0;
            end
            // 读完成: 撤销请求, 清计数器与忙
            else if (sd_sec_read_end) begin
                sd_sec_read <= 1'b0;
                busy_reg    <= 1'b0;
                byte_cnt    <= 9'd0;
            end
            // 读进行中: 字节有效时计数器递增
            else if (sd_sec_read_data_valid) begin
                byte_cnt <= byte_cnt + 9'd1;
            end
        end
    end

endmodule
