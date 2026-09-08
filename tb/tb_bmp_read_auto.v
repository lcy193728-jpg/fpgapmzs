//====================================================================
// 模块名 : tb_bmp_read_auto.v
// 功能   : bmp_read_auto 按键手动切图 真实场景仿真
// 场景   : 图1@扇区16000，图2@扇区18048(128KB簇，图1占2048扇区)，file_len=921654(真实)
// 验证   : 按键切图后，地址对齐到17808，扫描跳30个扇区能否找到图2@18048
//====================================================================

`timescale 1ns/1ps
module tb_bmp_read_auto;

    parameter CLK_PERIOD         = 10;         // 100MHz -> 10ns
    parameter SLIDE_INTERVAL_SIM = 10000000;   // 100ms，只测按键不测自动
    parameter BMP_FILE_LEN_SIM   = 921654;     // 真实文件长度

    reg         clk;
    reg         rst;
    reg         sd_init_done;
    reg         key_trigger;
    reg         write_req_ack;
    reg  [7:0]  sd_sec_read_data;
    reg         sd_sec_read_data_valid;
    reg         sd_sec_read_end;

    wire [3:0]  state_code;
    wire        write_req;
    wire        sd_sec_read;
    wire [31:0] sd_sec_read_addr;
    wire        bmp_data_wr_en;
    wire [23:0] bmp_data;

    bmp_read_auto #(
        .SLIDE_INTERVAL(SLIDE_INTERVAL_SIM),
        .START_SECTOR  (32'd16000),
        .WRAP_SECTOR   (32'd20000),
        .MAX_IMAGES    (32'd2),
        .BMP_FILE_LEN  (BMP_FILE_LEN_SIM)
    ) dut (
        .clk                     (clk),
        .rst                     (rst),
        .ready                   (),
        .sd_init_done            (sd_init_done),
        .key_trigger             (key_trigger),
        .state_code              (state_code),
        .bmp_width               (16'd640),
        .write_req               (write_req),
        .write_req_ack           (write_req_ack),
        .sd_sec_read             (sd_sec_read),
        .sd_sec_read_addr        (sd_sec_read_addr),
        .sd_sec_read_data        (sd_sec_read_data),
        .sd_sec_read_data_valid  (sd_sec_read_data_valid),
        .sd_sec_read_end         (sd_sec_read_end),
        .bmp_data_wr_en          (bmp_data_wr_en),
        .bmp_data                (bmp_data)
    );

    initial clk = 1'b0;
    always #(CLK_PERIOD/2) clk = ~clk;

    initial begin
        rst           = 1'b1;
        sd_init_done  = 1'b0;
        write_req_ack = 1'b0;
        key_trigger   = 1'b0;
        repeat(5) @(posedge clk);
        rst           = 1'b0;
        repeat(3) @(posedge clk);
        sd_init_done  = 1'b1;
    end

    always @(posedge clk) write_req_ack <= write_req;

    // key_trigger：第一次进入 S_HOLD(图1)后数 500 拍拉高一拍
    reg         key_sent;
    reg [9:0]   hold_cnt_mon;
    initial begin key_sent = 1'b0; hold_cnt_mon = 10'd0; end
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            key_trigger  <= 1'b0;
            key_sent     <= 1'b0;
            hold_cnt_mon <= 10'd0;
        end
        else begin
            key_trigger <= 1'b0;
            if (state_code == 4'd5 && !key_sent) begin
                hold_cnt_mon <= hold_cnt_mon + 10'd1;
                if (hold_cnt_mon == 10'd500) begin
                    key_trigger  <= 1'b1;
                    key_sent     <= 1'b1;
                    hold_cnt_mon <= 10'd0;
                end
            end
            else if (state_code != 4'd5)
                hold_cnt_mon <= 10'd0;
        end
    end

    // SD 扇区读模型
    reg [2:0]  sd_st;
    reg [31:0] sd_cur_addr;
    reg [9:0]  sd_byte_idx;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            sd_st <= 3'd0; sd_cur_addr <= 32'd0; sd_byte_idx <= 10'd0;
            sd_sec_read_data <= 8'd0; sd_sec_read_data_valid <= 1'b0; sd_sec_read_end <= 1'b0;
        end
        else begin
            sd_sec_read_end <= 1'b0;
            case (sd_st)
                3'd0: begin
                    sd_sec_read_data_valid <= 1'b0;
                    if (sd_sec_read) begin
                        sd_st <= 3'd1; sd_byte_idx <= 10'd0; sd_cur_addr <= sd_sec_read_addr;
                    end
                end
                3'd1: begin
                    sd_sec_read_data <= read_sd_byte(sd_cur_addr, sd_byte_idx);
                    sd_sec_read_data_valid <= 1'b1;
                    if (sd_byte_idx == 10'd511) sd_st <= 3'd2; else sd_byte_idx <= sd_byte_idx + 10'd1;
                end
                3'd2: begin
                    sd_sec_read_data_valid <= 1'b0; sd_sec_read_end <= 1'b1; sd_st <= 3'd3;
                end
                3'd3: sd_st <= 3'd0;
                default: sd_st <= 3'd0;
            endcase
        end
    end

    // 假 SD 卡：图1@16000，图2@17808，file_len=921654
    function [7:0] read_sd_byte;
        input [31:0] addr;
        input [9:0]  idx;
        reg [7:0] val;
        begin
            val = 8'h00;
            if (addr == 32'd16000 || addr == 32'd18048) begin
                case (idx)
                    10'd0:  val = "B";
                    10'd1:  val = "M";
                    10'd2:  val = 8'h36;   // file_len=921654=0xE1036 小端
                    10'd3:  val = 8'h10;
                    10'd4:  val = 8'h0E;
                    10'd5:  val = 8'h00;
                    10'd18: val = 8'h80;   // width=640
                    10'd19: val = 8'h02;
                    10'd20: val = 8'd0;
                    10'd21: val = 8'd0;
                    10'd22: val = 8'hE0;   // height=480
                    10'd23: val = 8'h01;
                    10'd24: val = 8'd0;
                    10'd25: val = 8'd0;
                    10'd28: val = 8'h18;   // bit_cnt=24
                    10'd29: val = 8'd0;
                    default: val = (addr == 32'd16000) ? 8'h11 : 8'h22;
                endcase
            end
            read_sd_byte = val;
        end
    endfunction

    // 状态码监控
    reg [3:0] prev_state;
    initial prev_state = 4'hF;
    always @(posedge clk) begin
        if (state_code !== prev_state) begin
            $display("t=%0t  state_code: %0d -> %0d, addr=%0d", $time, prev_state, state_code, sd_sec_read_addr);
            prev_state <= state_code;
        end
    end

    always @(posedge clk) if (key_trigger) $display("t=%0t  [KEY] key_trigger 拉高", $time);

    initial begin
        #30000000 $finish;   // 30ms，覆盖读图1(9.2ms)+按键切图+读图2
    end

endmodule
