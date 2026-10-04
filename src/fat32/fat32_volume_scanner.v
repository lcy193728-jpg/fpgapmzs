`timescale 1ns/1ps

module fat32_volume_scanner (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        scan_start,
    output wire        scan_busy,
    output reg         scan_done,
    output reg  [7:0]  fs_error,
    output reg  [31:0] partition_lba,
    output reg  [7:0]  sectors_per_cluster,
    output reg  [2:0]  sectors_per_cluster_shift,   // log2(sectors_per_cluster), 供 streamer 移位代替乘法
    output reg  [31:0] fat_start_lba,
    output reg  [31:0] data_start_lba,
    output reg  [31:0] max_cluster,
    // 资源数组: 12 个素材(10 BMP + 会议配置 MTG1.CFG + 音乐 WEL.BIN)
    //   资源号约定(上层 sd_card_bmp 按此查表):
    //     0=1_MEET.BMP  1=2_QUIZ.BMP  2=3_EXTRA.BMP 3=4_EXTRA.BMP
    //     4=W1_320A.BMP 5=W2_640A.BMP 6=W3_1024A.BMP 7=W4_320B.BMP
    //     8=W5_640B.BMP 9=W6_1024B.BMP 10=MTG1.CFG 11=WEL.BIN
    output reg  [11:0] resource_valid,
    output reg  [31:0] resource0_cluster,
    output reg  [31:0] resource1_cluster,
    output reg  [31:0] resource2_cluster,
    output reg  [31:0] resource3_cluster,
    output reg  [31:0] resource4_cluster,
    output reg  [31:0] resource5_cluster,
    output reg  [31:0] resource6_cluster,
    output reg  [31:0] resource7_cluster,
    output reg  [31:0] resource8_cluster,
    output reg  [31:0] resource9_cluster,
    output reg  [31:0] resource10_cluster,
    output reg  [31:0] resource11_cluster,
    output reg  [31:0] resource0_size,
    output reg  [31:0] resource1_size,
    output reg  [31:0] resource2_size,
    output reg  [31:0] resource3_size,
    output reg  [31:0] resource4_size,
    output reg  [31:0] resource5_size,
    output reg  [31:0] resource6_size,
    output reg  [31:0] resource7_size,
    output reg  [31:0] resource8_size,
    output reg  [31:0] resource9_size,
    output reg  [31:0] resource10_size,
    output reg  [31:0] resource11_size,
    output reg         sector_req,
    output reg  [31:0] sector_lba,
    input  wire        sector_busy,
    input  wire        sector_valid,
    input  wire [7:0]  sector_byte,
    input  wire [8:0]  sector_byte_index,
    input  wire        sector_done,
    input  wire [7:0]  sector_error
);

    localparam ERR_NONE            = 8'h00;
    localparam ERR_SECTOR          = 8'h10;
    localparam ERR_BOOT_SIGNATURE  = 8'h20;
    localparam ERR_UNSUPPORTED_BPB = 8'h21;
    localparam ERR_RESOURCE_MISSING= 8'h22;

    localparam ST_IDLE       = 4'd0;
    localparam ST_READ0_REQ  = 4'd1;
    localparam ST_READ0_WAIT = 4'd2;
    localparam ST_BOOT_PARSE = 4'd3;
    localparam ST_BOOT_REQ   = 4'd4;
    localparam ST_BOOT_WAIT  = 4'd5;
    localparam ST_ROOT_REQ   = 4'd6;
    localparam ST_ROOT_WAIT  = 4'd7;
    localparam ST_DIR_SCAN   = 4'd8;
    localparam ST_FINISH     = 4'd9;
    localparam ST_BOOT_LAYOUT= 4'd10;
    localparam ST_BOOT_ROOT  = 4'd11;

    reg [3:0] state;
    // 原 sector_buffer[0:511] 改为"只存被 BPB/分区解析读到的字节"的命名寄存器。
    //   全部读取点都是常量偏移(见 le16/le32 与 0/13/16/450/510/511 检查),
    //   只有写入是动态索引(sector_byte_index), 故只需 30 个字节, 省 512×8bit 存储。
    //   读直接引用命名寄存器(零 mux), 写用 30 路 case 抽取。
    reg [7:0] sb_byte0;
    reg [7:0] sb_byte11;  reg [7:0] sb_byte12;
    reg [7:0] sb_byte13;  reg [7:0] sb_byte14;  reg [7:0] sb_byte15;
    reg [7:0] sb_byte16;  reg [7:0] sb_byte17;  reg [7:0] sb_byte18;
    reg [7:0] sb_byte22;  reg [7:0] sb_byte23;
    reg [7:0] sb_byte32;  reg [7:0] sb_byte33;  reg [7:0] sb_byte34;  reg [7:0] sb_byte35;
    reg [7:0] sb_byte36;  reg [7:0] sb_byte37;  reg [7:0] sb_byte38;  reg [7:0] sb_byte39;
    reg [7:0] sb_byte44;  reg [7:0] sb_byte45;  reg [7:0] sb_byte46;  reg [7:0] sb_byte47;
    reg [7:0] sb_byte450;
    reg [7:0] sb_byte454; reg [7:0] sb_byte455; reg [7:0] sb_byte456; reg [7:0] sb_byte457;
    reg [7:0] sb_byte510; reg [7:0] sb_byte511;
    reg [31:0] root_cluster;
    reg [31:0] total_sectors;
    reg [31:0] fat_sectors;
    reg [7:0] fat_count;
    reg [15:0] reserved_sectors;
    reg [31:0] data_sector_count;
    reg [31:0] fat_span;
    reg [7:0] dir_name0;
    reg [7:0] dir_name1;
    reg [7:0] dir_name2;
    reg [7:0] dir_name3;
    reg [7:0] dir_name4;
    reg [7:0] dir_name5;
    reg [7:0] dir_name6;
    reg [7:0] dir_name7;
    reg [7:0] dir_name8;
    reg [7:0] dir_name9;
    reg [7:0] dir_name10;
    reg       dir_entry_match;
    reg [3:0] dir_resource_index;
    reg [15:0] dir_cluster_high;
    reg [15:0] dir_cluster_low;
    reg [31:0] dir_file_size;

    // 12 素材名的组合匹配: name_match[i]=1 表示 dir_name0~10 匹配第 i 号素材
    //   (主名 8 字节不足补空格 + 扩展名 3 字节, FAT32 目录项为大写)
    wire       name_match0  = (dir_name0=="1" && dir_name1=="_" && dir_name2=="M" &&
                               dir_name3=="E" && dir_name4=="E" && dir_name5=="T" &&
                               dir_name6==" " && dir_name7==" " && dir_name8=="B" &&
                               dir_name9=="M" && dir_name10=="P");
    wire       name_match1  = (dir_name0=="2" && dir_name1=="_" && dir_name2=="Q" &&
                               dir_name3=="U" && dir_name4=="I" && dir_name5=="Z" &&
                               dir_name6==" " && dir_name7==" " && dir_name8=="B" &&
                               dir_name9=="M" && dir_name10=="P");
    wire       name_match2  = (dir_name0=="3" && dir_name1=="_" && dir_name2=="E" &&
                               dir_name3=="X" && dir_name4=="T" && dir_name5=="R" &&
                               dir_name6=="A" && dir_name7==" " && dir_name8=="B" &&
                               dir_name9=="M" && dir_name10=="P");
    wire       name_match3  = (dir_name0=="4" && dir_name1=="_" && dir_name2=="E" &&
                               dir_name3=="X" && dir_name4=="T" && dir_name5=="R" &&
                               dir_name6=="A" && dir_name7==" " && dir_name8=="B" &&
                               dir_name9=="M" && dir_name10=="P");
    wire       name_match4  = (dir_name0=="W" && dir_name1=="1" && dir_name2=="_" &&
                               dir_name3=="3" && dir_name4=="2" && dir_name5=="0" &&
                               dir_name6=="A" && dir_name7==" " && dir_name8=="B" &&
                               dir_name9=="M" && dir_name10=="P");
    wire       name_match5  = (dir_name0=="W" && dir_name1=="2" && dir_name2=="_" &&
                               dir_name3=="6" && dir_name4=="4" && dir_name5=="0" &&
                               dir_name6=="A" && dir_name7==" " && dir_name8=="B" &&
                               dir_name9=="M" && dir_name10=="P");
    wire       name_match6  = (dir_name0=="W" && dir_name1=="3" && dir_name2=="_" &&
                               dir_name3=="1" && dir_name4=="0" && dir_name5=="2" &&
                               dir_name6=="4" && dir_name7=="A" && dir_name8=="B" &&
                               dir_name9=="M" && dir_name10=="P");
    wire       name_match7  = (dir_name0=="W" && dir_name1=="4" && dir_name2=="_" &&
                               dir_name3=="3" && dir_name4=="2" && dir_name5=="0" &&
                               dir_name6=="B" && dir_name7==" " && dir_name8=="B" &&
                               dir_name9=="M" && dir_name10=="P");
    wire       name_match8  = (dir_name0=="W" && dir_name1=="5" && dir_name2=="_" &&
                               dir_name3=="6" && dir_name4=="4" && dir_name5=="0" &&
                               dir_name6=="B" && dir_name7==" " && dir_name8=="B" &&
                               dir_name9=="M" && dir_name10=="P");
    wire       name_match9  = (dir_name0=="W" && dir_name1=="6" && dir_name2=="_" &&
                               dir_name3=="1" && dir_name4=="0" && dir_name5=="2" &&
                               dir_name6=="4" && dir_name7=="B" && dir_name8=="B" &&
                               dir_name9=="M" && dir_name10=="P");
    wire       name_match10 = (dir_name0=="M" && dir_name1=="T" && dir_name2=="G" &&
                               dir_name3=="1" && dir_name4==" " && dir_name5==" " &&
                               dir_name6==" " && dir_name7==" " && dir_name8=="C" &&
                               dir_name9=="F" && dir_name10=="G");
    wire       name_match11 = (dir_name0=="W" && dir_name1=="E" && dir_name2=="L" &&
                               dir_name3==" " && dir_name4==" " && dir_name5==" " &&
                               dir_name6==" " && dir_name7==" " && dir_name8=="B" &&
                               dir_name9=="I" && dir_name10=="N");

    assign scan_busy = (state != ST_IDLE);

    // le16/le32 由"常量偏移读 512 字节数组"改为"直接引用命名寄存器"。
    //   用 wire 拼接直接给出各 BPB 字段的小端值(零 mux)。
    wire [15:0] le16_at11  = {sb_byte12, sb_byte11};
    wire [15:0] le16_at14  = {sb_byte15, sb_byte14};
    wire [15:0] le16_at17  = {sb_byte18, sb_byte17};
    wire [15:0] le16_at22  = {sb_byte23, sb_byte22};
    wire [31:0] le32_at32  = {sb_byte35, sb_byte34, sb_byte33, sb_byte32};
    wire [31:0] le32_at36  = {sb_byte39, sb_byte38, sb_byte37, sb_byte36};
    wire [31:0] le32_at44  = {sb_byte47, sb_byte46, sb_byte45, sb_byte44};
    wire [31:0] le32_at454 = {sb_byte457, sb_byte456, sb_byte455, sb_byte454};

    function valid_spc;
        input [7:0] value;
        begin
            valid_spc = value != 0 && ((value & (value - 1'b1)) == 0);
        end
    endfunction

    function [2:0] spc_shift;
        input [7:0] value;
        begin
            case (value)
                8'd2:   spc_shift = 3'd1;
                8'd4:   spc_shift = 3'd2;
                8'd8:   spc_shift = 3'd3;
                8'd16:  spc_shift = 3'd4;
                8'd32:  spc_shift = 3'd5;
                8'd64:  spc_shift = 3'd6;
                8'd128: spc_shift = 3'd7;
                default: spc_shift = 3'd0;
            endcase
        end
    endfunction

    task finish_with_error;
        input [7:0] code;
        begin
            fs_error <= code;
            state <= ST_FINISH;
        end
    endtask

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= ST_IDLE;
            scan_done <= 1'b0;
            fs_error <= ERR_NONE;
            partition_lba <= 32'd0;
            sectors_per_cluster <= 8'd0;
            fat_start_lba <= 32'd0;
            data_start_lba <= 32'd0;
            max_cluster <= 32'd0;
            resource_valid <= 12'd0;
            resource0_cluster <= 32'd0;
            resource1_cluster <= 32'd0;
            resource2_cluster <= 32'd0;
            resource3_cluster <= 32'd0;
            resource4_cluster <= 32'd0;
            resource5_cluster <= 32'd0;
            resource6_cluster <= 32'd0;
            resource7_cluster <= 32'd0;
            resource8_cluster <= 32'd0;
            resource9_cluster <= 32'd0;
            resource10_cluster <= 32'd0;
            resource11_cluster <= 32'd0;
            resource0_size <= 32'd0;
            resource1_size <= 32'd0;
            resource2_size <= 32'd0;
            resource3_size <= 32'd0;
            resource4_size <= 32'd0;
            resource5_size <= 32'd0;
            resource6_size <= 32'd0;
            resource7_size <= 32'd0;
            resource8_size <= 32'd0;
            resource9_size <= 32'd0;
            resource10_size <= 32'd0;
            resource11_size <= 32'd0;
            sector_req <= 1'b0;
            sector_lba <= 32'd0;
            directory_entry_index <= 5'd0;
            root_cluster <= 32'd0;
            total_sectors <= 32'd0;
            fat_sectors <= 32'd0;
            fat_count <= 8'd0;
            reserved_sectors <= 16'd0;
            data_sector_count <= 32'd0;
            fat_span <= 32'd0;
            sectors_per_cluster_shift <= 3'd0;
            dir_name0 <= 8'd0;
            dir_name1 <= 8'd0;
            dir_name2 <= 8'd0;
            dir_name3 <= 8'd0;
            dir_name4 <= 8'd0;
            dir_name5 <= 8'd0;
            dir_name6 <= 8'd0;
            dir_name7 <= 8'd0;
            dir_name8 <= 8'd0;
            dir_name9 <= 8'd0;
            dir_name10 <= 8'd0;
            dir_entry_match <= 1'b0;
            dir_resource_index <= 4'd12;   // 12=不匹配(超出 0~11)
            dir_cluster_high <= 16'd0;
            dir_cluster_low <= 16'd0;
            dir_file_size <= 32'd0;
        end else begin
            scan_done <= 1'b0;
            sector_req <= 1'b0;
            if (sector_valid && state != ST_ROOT_WAIT) begin
                // 动态写 512 字节数组 → 只把落入"被读到字节"的写入命名寄存器(30 路 case)
                case (sector_byte_index[8:0])
                    9'd0:   sb_byte0   <= sector_byte;
                    9'd11:  sb_byte11  <= sector_byte;
                    9'd12:  sb_byte12  <= sector_byte;
                    9'd13:  sb_byte13  <= sector_byte;
                    9'd14:  sb_byte14  <= sector_byte;
                    9'd15:  sb_byte15  <= sector_byte;
                    9'd16:  sb_byte16  <= sector_byte;
                    9'd17:  sb_byte17  <= sector_byte;
                    9'd18:  sb_byte18  <= sector_byte;
                    9'd22:  sb_byte22  <= sector_byte;
                    9'd23:  sb_byte23  <= sector_byte;
                    9'd32:  sb_byte32  <= sector_byte;
                    9'd33:  sb_byte33  <= sector_byte;
                    9'd34:  sb_byte34  <= sector_byte;
                    9'd35:  sb_byte35  <= sector_byte;
                    9'd36:  sb_byte36  <= sector_byte;
                    9'd37:  sb_byte37  <= sector_byte;
                    9'd38:  sb_byte38  <= sector_byte;
                    9'd39:  sb_byte39  <= sector_byte;
                    9'd44:  sb_byte44  <= sector_byte;
                    9'd45:  sb_byte45  <= sector_byte;
                    9'd46:  sb_byte46  <= sector_byte;
                    9'd47:  sb_byte47  <= sector_byte;
                    9'd450: sb_byte450 <= sector_byte;
                    9'd454: sb_byte454 <= sector_byte;
                    9'd455: sb_byte455 <= sector_byte;
                    9'd456: sb_byte456 <= sector_byte;
                    9'd457: sb_byte457 <= sector_byte;
                    9'd510: sb_byte510 <= sector_byte;
                    9'd511: sb_byte511 <= sector_byte;
                    default: begin end
                endcase
            end

            if (sector_valid && state == ST_ROOT_WAIT) begin
                case (sector_byte_index[4:0])
                    5'd0: begin
                        dir_name0 <= sector_byte;
                        dir_entry_match <= 1'b0;
                    end
                    5'd1:  dir_name1 <= sector_byte;
                    5'd2:  dir_name2 <= sector_byte;
                    5'd3:  dir_name3 <= sector_byte;
                    5'd4:  dir_name4 <= sector_byte;
                    5'd5:  dir_name5 <= sector_byte;
                    5'd6:  dir_name6 <= sector_byte;
                    5'd7:  dir_name7 <= sector_byte;
                    5'd8:  dir_name8 <= sector_byte;
                    5'd9:  dir_name9 <= sector_byte;
                    5'd10: dir_name10 <= sector_byte;
                    5'd11: begin
                        // 目录项属性字节: 0x20=归档普通文件; 0x0F=长文件名(LFN)项。
                        //   仅当"普通文件 且 名字命中 12 素材之一"才置匹配。
                        if (sector_byte == 8'h20 &&
                            (name_match0  || name_match1  || name_match2  ||
                             name_match3  || name_match4  || name_match5  ||
                             name_match6  || name_match7  || name_match8  ||
                             name_match9  || name_match10 || name_match11)) begin
                            dir_entry_match <= 1'b1;
                            // 优先编码: 按 name_match0..11 得到资源号
                            dir_resource_index <= name_match0  ? 4'd0  :
                                                  name_match1  ? 4'd1  :
                                                  name_match2  ? 4'd2  :
                                                  name_match3  ? 4'd3  :
                                                  name_match4  ? 4'd4  :
                                                  name_match5  ? 4'd5  :
                                                  name_match6  ? 4'd6  :
                                                  name_match7  ? 4'd7  :
                                                  name_match8  ? 4'd8  :
                                                  name_match9  ? 4'd9  :
                                                  name_match10 ? 4'd10 :
                                                  name_match11 ? 4'd11 :
                                                                 4'd12;
                        end
                    end
                    5'd20: dir_cluster_high[7:0] <= sector_byte;
                    5'd21: dir_cluster_high[15:8] <= sector_byte;
                    5'd26: dir_cluster_low[7:0] <= sector_byte;
                    5'd27: dir_cluster_low[15:8] <= sector_byte;
                    5'd28: dir_file_size[7:0] <= sector_byte;
                    5'd29: dir_file_size[15:8] <= sector_byte;
                    5'd30: dir_file_size[23:16] <= sector_byte;
                    5'd31: begin
                        dir_file_size[31:24] <= sector_byte;
                        if (dir_entry_match) begin
                            case (dir_resource_index)
                                4'd0: begin resource0_cluster <= {dir_cluster_high, dir_cluster_low}; resource0_size <= {sector_byte, dir_file_size[23:0]}; resource_valid[0] <= 1'b1; end
                                4'd1: begin resource1_cluster <= {dir_cluster_high, dir_cluster_low}; resource1_size <= {sector_byte, dir_file_size[23:0]}; resource_valid[1] <= 1'b1; end
                                4'd2: begin resource2_cluster <= {dir_cluster_high, dir_cluster_low}; resource2_size <= {sector_byte, dir_file_size[23:0]}; resource_valid[2] <= 1'b1; end
                                4'd3: begin resource3_cluster <= {dir_cluster_high, dir_cluster_low}; resource3_size <= {sector_byte, dir_file_size[23:0]}; resource_valid[3] <= 1'b1; end
                                4'd4: begin resource4_cluster <= {dir_cluster_high, dir_cluster_low}; resource4_size <= {sector_byte, dir_file_size[23:0]}; resource_valid[4] <= 1'b1; end
                                4'd5: begin resource5_cluster <= {dir_cluster_high, dir_cluster_low}; resource5_size <= {sector_byte, dir_file_size[23:0]}; resource_valid[5] <= 1'b1; end
                                4'd6: begin resource6_cluster <= {dir_cluster_high, dir_cluster_low}; resource6_size <= {sector_byte, dir_file_size[23:0]}; resource_valid[6] <= 1'b1; end
                                4'd7: begin resource7_cluster <= {dir_cluster_high, dir_cluster_low}; resource7_size <= {sector_byte, dir_file_size[23:0]}; resource_valid[7] <= 1'b1; end
                                4'd8: begin resource8_cluster <= {dir_cluster_high, dir_cluster_low}; resource8_size <= {sector_byte, dir_file_size[23:0]}; resource_valid[8] <= 1'b1; end
                                4'd9: begin resource9_cluster <= {dir_cluster_high, dir_cluster_low}; resource9_size <= {sector_byte, dir_file_size[23:0]}; resource_valid[9] <= 1'b1; end
                                4'd10: begin resource10_cluster <= {dir_cluster_high, dir_cluster_low}; resource10_size <= {sector_byte, dir_file_size[23:0]}; resource_valid[10] <= 1'b1; end
                                4'd11: begin resource11_cluster <= {dir_cluster_high, dir_cluster_low}; resource11_size <= {sector_byte, dir_file_size[23:0]}; resource_valid[11] <= 1'b1; end
                                default: begin end
                            endcase
                        end
                    end
                    default: begin end
                endcase
            end

            case (state)
                ST_IDLE: if (scan_start) begin
                    fs_error <= ERR_NONE;
                    partition_lba <= 32'd0;
                    resource_valid <= 12'd0;
                    state <= ST_READ0_REQ;
                end
                ST_READ0_REQ: if (!sector_busy) begin
                    sector_lba <= 32'd0;
                    sector_req <= 1'b1;
                    state <= ST_READ0_WAIT;
                end
                ST_READ0_WAIT: if (sector_done) begin
                    if (sector_error != 0)
                        finish_with_error(ERR_SECTOR);
                    else if (sb_byte510 != 8'h55 || sb_byte511 != 8'haa)
                        finish_with_error(ERR_BOOT_SIGNATURE);
                    else if (sb_byte0 == 8'heb || sb_byte0 == 8'he9) begin
                        partition_lba <= 32'd0;
                        state <= ST_BOOT_PARSE;
                    end else if (sb_byte450 == 8'h0b || sb_byte450 == 8'h0c) begin
                        partition_lba <= le32_at454;
                        sector_lba <= le32_at454;
                        state <= ST_BOOT_REQ;
                    end else begin
                        finish_with_error(ERR_UNSUPPORTED_BPB);
                    end
                end
                ST_BOOT_REQ: if (!sector_busy) begin
                    sector_req <= 1'b1;
                    state <= ST_BOOT_WAIT;
                end
                ST_BOOT_WAIT: if (sector_done) begin
                    if (sector_error != 0)
                        finish_with_error(ERR_SECTOR);
                    else if (sb_byte510 != 8'h55 || sb_byte511 != 8'haa)
                        finish_with_error(ERR_BOOT_SIGNATURE);
                    else
                        state <= ST_BOOT_PARSE;
                end
                ST_BOOT_PARSE: begin
                    if (le16_at11 != 16'd512 || !valid_spc(sb_byte13) ||
                        le16_at14 == 0 || (sb_byte16 != 1 && sb_byte16 != 2) ||
                        le16_at17 != 0 || le16_at22 != 0 || le32_at32 == 0 ||
                        le32_at36 == 0 || le32_at44 < 2) begin
                        finish_with_error(ERR_UNSUPPORTED_BPB);
                    end else begin
                        sectors_per_cluster <= sb_byte13;
                        reserved_sectors <= le16_at14;
                        fat_count <= sb_byte16;
                        total_sectors <= le32_at32;
                        fat_sectors <= le32_at36;
                        root_cluster <= le32_at44;
                        sectors_per_cluster_shift <= spc_shift(sb_byte13);
                        fat_span <= sb_byte16 == 2 ? (le32_at36 << 1) : le32_at36;
                        fat_start_lba <= partition_lba + le16_at14;
                        state <= ST_BOOT_LAYOUT;
                    end
                end
                ST_BOOT_LAYOUT: begin
                    data_start_lba <= partition_lba + reserved_sectors + fat_span;
                    data_sector_count <= total_sectors - reserved_sectors - fat_span;
                    state <= ST_BOOT_ROOT;
                end
                ST_BOOT_ROOT: begin
                    max_cluster <= (data_sector_count >> sectors_per_cluster_shift) + 1'b1;
                    // (root_lba 冗余寄存器已删: 与 sector_lba 同表达式, 且从未被读)
                    sector_lba <= data_start_lba
                                  + ((root_cluster - 2) << sectors_per_cluster_shift);
                    state <= ST_ROOT_REQ;
                end
                ST_ROOT_REQ: if (!sector_busy) begin
                    resource_valid <= 12'd0;
                    dir_entry_match <= 1'b0;
                    sector_req <= 1'b1;
                    state <= ST_ROOT_WAIT;
                end
                ST_ROOT_WAIT: if (sector_done) begin
                    if (sector_error != 0)
                        finish_with_error(ERR_SECTOR);
                    else begin
                        directory_entry_index <= 5'd0;
                        state <= ST_DIR_SCAN;
                    end
                end
                // 恢复小鹅通原版语义: 扫完根目录第一簇后, 校验"全部素材都命中"
                //   (resource_valid == 12'hfff), 否则报 ERR_RESOURCE_MISSING。
                //   (小鹅通原版是 resource_valid==4'hf 判 4 资源全命中; 本工程扩到 12)
                ST_DIR_SCAN: begin
                    if (resource_valid == 12'hfff)
                        state <= ST_FINISH;
                    else
                        finish_with_error(ERR_RESOURCE_MISSING);
                end
                ST_FINISH: begin
                    scan_done <= 1'b1;
                    state <= ST_IDLE;
                end
                default: state <= ST_IDLE;
            endcase
        end
    end
endmodule
