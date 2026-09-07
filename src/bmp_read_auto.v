//====================================================================
// 模块名 : bmp_read_auto.v
// 功能   : 迎新图文自动轮播状态机
//          ——在官方 bmp_read.v 基础上改造，实现"上电自动找图、多图循环轮播、扫到卡尾回卷"
// 改动点 :
//   1. 去掉外部按键触发 find，改为 SD 初始化完成后自动开始找第一张图
//   2. 新增 S_HOLD 状态：读完一张图后保持显示 SLIDE_INTERVAL 个时钟周期，
//      计时结束后自动找下一张（形成轮播）
//   3. 扫描地址超过 WRAP_SECTOR 时回卷到 START_SECTOR，实现循环轮播
//   4. 严格校验 BMP 头(宽640/高480/24bit/文件长921654)，过滤裸扫到的假"BM"干扰字节
//   5. 新增 MAX_IMAGES 计数：播满一圈后直接回卷 START_SECTOR，防止扫进卡内残留/已删除数据
// 底层原理(与官方一致)：
//   不解析 FAT 文件系统，从 START_SECTOR 开始每 8 扇区(4KB 簇)跳读一个扇区，
//   检查前 54 字节是否为 "BM"(0x42 0x4D) 且 宽度==bmp_width(640)，命中即整张读入 SDRAM
//====================================================================

`timescale 1ns/1ps

module bmp_read_auto #(
    parameter [31:0] SLIDE_INTERVAL = 32'd300_000_000, // 轮播间隔(时钟周期)，100MHz 下 = 3 秒
    parameter [31:0] START_SECTOR   = 32'd16000,       // 扫描起始扇区
    parameter [31:0] WRAP_SECTOR    = 32'd400000,      // 扫描上限扇区，超过则回卷(约 200MB)
    parameter [31:0] MAX_IMAGES     = 32'd5            // 卡内图片总数(轮播一圈的张数)，改图数量需同步修改此值
)(
    input               clk,                       // SD 卡时钟(100MHz)
    input               rst,                       // 高电平有效复位
    output              ready,                     // 空闲标志(仅调试用)
    input               sd_init_done,              // SD 卡初始化完成标志(由 sd_card_top 给出)
    output reg  [3:0]   state_code,                // 状态码(数码管显示)
    input      [15:0]   bmp_width,                 // BMP 图像宽度(固定 640)
    output reg          write_req,                 // 写帧请求(启动写 SDRAM)
    input               write_req_ack,             // 写帧响应(写通路已就绪)
    output reg          sd_sec_read,               // SD 卡扇区读请求
    output reg  [31:0]  sd_sec_read_addr,          // SD 卡扇区读地址
    input      [7:0]    sd_sec_read_data,          // SD 卡扇区读数据(字节)
    input               sd_sec_read_data_valid,    // 扇区读数据有效
    input               sd_sec_read_end,           // 扇区读结束(一个扇区 512 字节读完)
    output reg          bmp_data_wr_en,            // BMP 像素数据写使能
    output reg  [23:0]  bmp_data                   // BMP 像素数据(24bit RGB)
);

    //--------------------------------------------------------------
    // 状态定义
    //--------------------------------------------------------------
    localparam [3:0] S_IDLE      = 4'd0;  // SD 初始化 / 空闲
    localparam [3:0] S_FIND      = 4'd1;  // 扫描查找 BMP 文件头
    localparam [3:0] S_READ_WAIT = 4'd2;  // 等待写通路(FIFO)就绪
    localparam [3:0] S_READ      = 4'd3;  // 读取图像像素数据
    localparam [3:0] S_HOLD      = 4'd4;  // 显示保持(轮播间隔)

    localparam [9:0] HEADER_SIZE = 10'd54; // BMP 文件头 54 字节

    //--------------------------------------------------------------
    // 内部寄存器
    //--------------------------------------------------------------
    reg [3:0]   state;
    reg [9:0]   rd_cnt;          // 扇区内字节计数(找图阶段)
    reg [7:0]   header_0;        // 文件头第 0 字节(应为 'B')
    reg [7:0]   header_1;        // 文件头第 1 字节(应为 'M')
    reg [31:0]  file_len;        // BMP 文件总长度(从头信息读取)
    reg [31:0]  width;           // BMP 宽度(从头信息读取)
    reg [31:0]  height;          // BMP 高度(从头信息读取，用于校验 480)
    reg [15:0]  bit_cnt;         // BMP 色深(从头信息读取，用于校验 24bit)
    reg [31:0]  bmp_len_cnt;     // 读图阶段的字节计数器
    reg         found;           // 命中标志(找到 "BM" + 宽度匹配)
    reg [1:0]   bmp_len_cnt_tmp; // RGB 三字节计数(0/1/2)
    reg [31:0]  hold_cnt;        // 轮播间隔计数器
    reg [31:0]  img_cnt;         // 已找到的图片计数(达到 MAX_IMAGES 后回卷，防止扫入残留数据)

    // BMP 像素数据有效：跳过前 54 字节文件头，且不超过文件长度
    wire bmp_data_valid = (sd_sec_read_data_valid && bmp_len_cnt > 32'd53 && bmp_len_cnt < file_len);
    assign ready = (state == S_IDLE);

    //--------------------------------------------------------------
    // 找图阶段字节计数(rd_cnt)
    //--------------------------------------------------------------
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            rd_cnt <= 10'd0;
        end
        else if (state == S_FIND) begin
            if (sd_sec_read_data_valid)
                rd_cnt <= rd_cnt + 10'd1;
            else if (sd_sec_read_end)
                rd_cnt <= 10'd0;
        end
        else begin
            rd_cnt <= 10'd0;
        end
    end

    //--------------------------------------------------------------
    // 文件头解析：在找图阶段读取每个扇区的前 54 字节，
    // 严格校验 "BM" + 宽640 + 高480 + 24bit + 文件长度921654，过滤假"BM"
    //--------------------------------------------------------------
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            header_0 <= 8'd0;
            header_1 <= 8'd0;
            file_len <= 32'd0;
            width    <= 32'd0;
            height   <= 32'd0;
            bit_cnt  <= 16'd0;
            found    <= 1'b0;
        end
        else if (state == S_FIND && sd_sec_read_data_valid) begin
            // 文件头
            if (rd_cnt == 10'd0)  header_0        <= sd_sec_read_data;
            if (rd_cnt == 10'd1)  header_1        <= sd_sec_read_data;
            // 文件长度(小端，第 2~5 字节)
            if (rd_cnt == 10'd2)  file_len[7:0]   <= sd_sec_read_data;
            if (rd_cnt == 10'd3)  file_len[15:8]  <= sd_sec_read_data;
            if (rd_cnt == 10'd4)  file_len[23:16] <= sd_sec_read_data;
            if (rd_cnt == 10'd5)  file_len[31:24] <= sd_sec_read_data;
            // 图像宽度(小端，第 18~21 字节)
            if (rd_cnt == 10'd18) width[7:0]      <= sd_sec_read_data;
            if (rd_cnt == 10'd19) width[15:8]     <= sd_sec_read_data;
            if (rd_cnt == 10'd20) width[23:16]    <= sd_sec_read_data;
            if (rd_cnt == 10'd21) width[31:24]    <= sd_sec_read_data;
            // 图像高度(小端，第 22~25 字节)
            if (rd_cnt == 10'd22) height[7:0]     <= sd_sec_read_data;
            if (rd_cnt == 10'd23) height[15:8]    <= sd_sec_read_data;
            if (rd_cnt == 10'd24) height[23:16]   <= sd_sec_read_data;
            if (rd_cnt == 10'd25) height[31:24]   <= sd_sec_read_data;
            // 色深(小端，第 28~29 字节)
            if (rd_cnt == 10'd28) bit_cnt[7:0]    <= sd_sec_read_data;
            if (rd_cnt == 10'd29) bit_cnt[15:8]   <= sd_sec_read_data;
            // 读完 54 字节头后严格校验：必须为 640×480×24bit 非压缩 BMP，
            // 且文件长度 = 54 + 640*480*3 = 921654，否则视为干扰数据(假"BM")丢弃，
            // 避免裸扇区扫描把残留字节误判成图片导致花屏
            if (rd_cnt == HEADER_SIZE && header_0 == "B" && header_1 == "M"
                && width[15:0] == bmp_width    // 宽 640
                && height        == 32'd480    // 高 480
                && bit_cnt       == 16'd24     // 24bit 真彩色
                && file_len      == 32'd921654)// 54 + 640*480*3
                found <= 1'b1;
        end
        else if (state != S_FIND) begin
            found <= 1'b0;
        end
    end

    //--------------------------------------------------------------
    // 读图阶段字节计数器(bmp_len_cnt)
    //--------------------------------------------------------------
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            bmp_len_cnt <= 32'd0;
        end
        else if (state == S_READ) begin
            if (sd_sec_read_data_valid)
                bmp_len_cnt <= bmp_len_cnt + 32'd1;
        end
        else if (state == S_HOLD) begin
            bmp_len_cnt <= 32'd0;   // 进入保持态时清零，准备下一次读图
        end
    end

    //--------------------------------------------------------------
    // RGB 三字节计数(用于把字节流拼接成 24bit 像素)
    //--------------------------------------------------------------
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            bmp_len_cnt_tmp <= 2'd0;
        end
        else if (state == S_READ) begin
            if (bmp_data_valid)
                bmp_len_cnt_tmp <= (bmp_len_cnt_tmp == 2'd2) ? 2'd0 : bmp_len_cnt_tmp + 2'd1;
        end
        else if (state == S_HOLD) begin
            bmp_len_cnt_tmp <= 2'd0;
        end
    end

    //--------------------------------------------------------------
    // BMP 像素数据拼接输出：每 3 字节(B,G,R)拼成一个 24bit 像素，
    // 在第三个字节(R)时给出写使能
    //--------------------------------------------------------------
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            bmp_data_wr_en <= 1'b0;
            bmp_data       <= 24'd0;
        end
        else if (state == S_READ) begin
            if (bmp_len_cnt_tmp == 2'd2 && bmp_data_valid) begin
                // 收到第三个字节 R，凑齐一个完整像素
                bmp_data_wr_en  <= 1'b1;
                bmp_data[23:16] <= sd_sec_read_data;   // R
            end
            else if (bmp_len_cnt_tmp == 2'd1 && bmp_data_valid) begin
                bmp_data_wr_en  <= 1'b0;
                bmp_data[15:8]  <= sd_sec_read_data;   // G
            end
            else if (bmp_len_cnt_tmp == 2'd0 && bmp_data_valid) begin
                bmp_data_wr_en  <= 1'b0;
                bmp_data[7:0]   <= sd_sec_read_data;   // B
            end
            else begin
                bmp_data_wr_en <= 1'b0;
            end
        end
        else begin
            bmp_data_wr_en <= 1'b0;
        end
    end

    //--------------------------------------------------------------
    // 轮播间隔计数器(在 S_HOLD 状态下计时)
    //--------------------------------------------------------------
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            hold_cnt <= 32'd0;
        end
        else if (state == S_HOLD) begin
            hold_cnt <= hold_cnt + 32'd1;
        end
        else begin
            hold_cnt <= 32'd0;
        end
    end

    //--------------------------------------------------------------
    // 主状态机
    //--------------------------------------------------------------
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state            <= S_IDLE;
            sd_sec_read      <= 1'b0;
            sd_sec_read_addr <= START_SECTOR[31:0];
            write_req        <= 1'b0;
            state_code       <= 4'd0;
            img_cnt          <= 32'd0;
        end
        else if (sd_init_done == 1'b0) begin
            // SD 卡尚未初始化完成，回到空闲等待
            state       <= S_IDLE;
            sd_sec_read <= 1'b0;
            state_code  <= 4'd0;
        end
        else begin
            case (state)
                //------------------------------------------------
                // 空闲/准备：初始化完成后自动开始找图
                //------------------------------------------------
                S_IDLE: begin
                    state_code       <= 4'd1;
                    // 扫描地址 8 对齐(4KB 簇边界)
                    sd_sec_read_addr <= {sd_sec_read_addr[31:3], 3'd0};
                    // SD 初始化完成后自动进入找图(不再等待按键)
                    state            <= S_FIND;
                end

                //------------------------------------------------
                // 扫描找图：逐扇区(每 8 扇区跳)检查文件头
                //------------------------------------------------
                S_FIND: begin
                    state_code <= 4'd2;
                    if (sd_sec_read_end) begin
                        state_code <= 4'd3;
                        if (found) begin
                            // 命中：进入读等待，并计数找到的图片
                            state        <= S_READ_WAIT;
                            sd_sec_read  <= 1'b0;
                            write_req    <= 1'b1;   // 启动写帧
                            img_cnt      <= img_cnt + 32'd1;
                        end
                        else begin
                            // 未命中：地址 +8 继续扫描，越界则回卷
                            if (sd_sec_read_addr >= WRAP_SECTOR)
                                sd_sec_read_addr <= START_SECTOR[31:0];
                            else
                                sd_sec_read_addr <= sd_sec_read_addr + 32'd8;
                        end
                    end
                    else begin
                        sd_sec_read <= 1'b1;   // 持续发读请求
                    end
                end

                //------------------------------------------------
                // 读等待：等写通路应答
                //------------------------------------------------
                S_READ_WAIT: begin
                    if (write_req_ack) begin
                        state     <= S_READ;
                        write_req <= 1'b0;
                    end
                end

                //------------------------------------------------
                // 读图数据：持续读扇区直到文件读完
                //------------------------------------------------
                S_READ: begin
                    state_code <= 4'd4;
                    if (sd_sec_read_end) begin
                        sd_sec_read_addr <= sd_sec_read_addr + 32'd1;
                        sd_sec_read      <= 1'b0;
                        if (bmp_len_cnt >= file_len) begin
                            // 本张图读完，进入显示保持(轮播间隔)
                            state       <= S_HOLD;
                            sd_sec_read <= 1'b0;
                        end
                    end
                    else begin
                        sd_sec_read <= 1'b1;
                    end
                end

                //------------------------------------------------
                // 显示保持：保持当前图，计时满后自动找下一张
                //------------------------------------------------
                S_HOLD: begin
                    state_code <= 4'd5;
                    if (hold_cnt >= SLIDE_INTERVAL) begin
                        if (img_cnt >= MAX_IMAGES) begin
                            // 已播完一圈：直接回卷到扫描起点，避免继续往前扫进残留/已删除数据区
                            sd_sec_read_addr <= START_SECTOR[31:0];
                            img_cnt          <= 32'd0;
                        end
                        else begin
                            // 向上对齐到下一个 8 扇区(4KB 簇)边界，避免错过簇边界上的下一张图
                            sd_sec_read_addr <= {sd_sec_read_addr[31:3] + 1'b1, 3'd0};
                        end
                        state <= S_FIND;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule