//====================================================================
// 模块名 : tb_bmp_read_auto.v
// 功能   : bmp_read_auto 分区化自动轮播 + 场景分区切换仿真
// 卡模型 : 假 SD 卡, 3 张图(file_len=10000, 便于加速):
//           图A @扇区16000(像素h11)  图B @扇区16064(像素h22)
//           图C @扇区16128(像素h33)
// 分区   : 默认(菜单)分区 = start16000 wrap20000 max2 (图A/图B)
//          场景1 分区       = start16128 wrap20000 max1 (图C)
// 验证   :
//   1. 上电默认分区自动找图轮播(A)
//   2. 按键手动切图(A->B), 校验读取入口地址 rd_base 与图序号 img_no
//   2b.手动"上一张"(B->A): 按序号目标从分区起点重扫, 读入口回到 IMG_A
//   3. S_HOLD 中 zone_load -> 切到场景1 分区并读入 C
//   4. 读图中 zone_load(延迟请求): 当前帧读完才切(帧写不中断),
//      进入 S_HOLD 后立即执行切换, 不等待轮播计时
//====================================================================

`timescale 1ns/1ps
module tb_bmp_read_auto;

    localparam CLK_PERIOD       = 10;              // 100MHz -> 10ns
    localparam SLIDE_INTERVAL_SIM = 32'd10_000_000;// 100ms(仅测按键/分区, 不触发)
    localparam BMP_FILE_LEN_SIM = 32'd10000;       // 假图文件长(卡头一致)

    // 图像地址(与假卡一致)
    localparam [31:0] IMG_A = 32'd16000;
    localparam [31:0] IMG_B = 32'd16064;
    localparam [31:0] IMG_C = 32'd16128;
    localparam [31:0] Z_END = 32'd20000;

    reg         clk;
    reg         rst;
    reg         sd_init_done;
    reg         key_trigger;
    reg         key_prev;
    reg         slide_en;
    reg         write_req_ack;
    reg  [7:0]  sd_sec_read_data;
    reg         sd_sec_read_data_valid;
    reg         sd_sec_read_end;
    reg  [31:0] zone_start;
    reg  [31:0] zone_wrap;
    reg  [31:0] zone_max_img;
    reg         zone_load;
    reg         reload_req;   // 原地重读当前图(缩放档变化时为 1 拍脉冲)

    wire [3:0]  state_code;
    wire        write_req;
    wire        sd_sec_read;
    wire [31:0] sd_sec_read_addr;
    wire        bmp_data_wr_en;
    wire [23:0] bmp_data;
    wire [7:0]  img_no;

    reg  [31:0] rd_base;      // 本次读图的入口地址(捕获 S_READ 入口的地址)
    reg  [3:0]  sc_d;         // state_code 上一拍
    integer     read_cnt = 0;  // 读图次数(S_READ 入口计数), 用于验证 reload
    integer     n0;            // reload 测试用: 重读前的读图次数快照

    integer     fail_cnt = 0;

    // 观测标志
    reg         imgA_seen, imgB_seen, imgC_seen;   // 扫描时命中过对应地址
    reg         defer_arm;                         // 读中 zone_load 后准备捕获
    reg         defer_hold_seen;                   // 捕获到进入 S_HOLD(延迟生效证明)

    bmp_read_auto #(
        .SLIDE_INTERVAL   (SLIDE_INTERVAL_SIM),
        .ZONE_START_SECTOR(IMG_A),
        .ZONE_WRAP_SECTOR (Z_END),
        .ZONE_MAX_IMAGES  (32'd2),
        .BMP_FILE_LEN     (BMP_FILE_LEN_SIM)
    ) dut (
        .clk                    (clk),
        .rst                    (rst),
        .ready                  (),
        .sd_init_done           (sd_init_done),
        .key_trigger            (key_trigger),
        .key_prev               (key_prev),
        .slide_en               (slide_en),
        .zone_start             (zone_start),
        .zone_wrap              (zone_wrap),
        .zone_max_img           (zone_max_img),
        .zone_load              (zone_load),
        .reload_req             (reload_req),
        .state_code             (state_code),
        .bmp_width              (16'd640),
        .write_req              (write_req),
        .write_req_ack          (write_req_ack),
        .sd_sec_read            (sd_sec_read),
        .sd_sec_read_addr       (sd_sec_read_addr),
        .sd_sec_read_data       (sd_sec_read_data),
        .sd_sec_read_data_valid (sd_sec_read_data_valid),
        .sd_sec_read_end        (sd_sec_read_end),
        .bmp_data_wr_en         (bmp_data_wr_en),
        .bmp_data               (bmp_data),
        .img_no                 (img_no),
        .img_busy               ()
    );

    initial clk = 1'b0;
    always #(CLK_PERIOD/2) clk = ~clk;
    always @(posedge clk) write_req_ack <= write_req;

    //--------------- 任务 -------------------
    task check(input cond, input [255:0] msg);
        begin
            if (cond) $display("t=%0t  [PASS] %0s", $time, msg);
            else begin
                fail_cnt = fail_cnt + 1;
                $display("t=%0t  [FAIL] %0s  (state=%0d addr=%0d)", $time, msg, state_code, sd_sec_read_addr);
            end
        end
    endtask

    // 等状态进入 st(带超时防死等)
    task wait_state(input [3:0] st);
        integer c;
        begin
            c = 0;
            while (state_code !== st) begin
                @(posedge clk);
                c = c + 1;
                if (c > 400000) begin
                    $display("t=%0t  [TIMEOUT] 等状态 %0d 超时(state=%0d addr=%0d)", $time, st, state_code, sd_sec_read_addr);
                    $finish;
                end
            end
        end
    endtask

    task fire_zone(input [31:0] s, input [31:0] w, input [31:0] m);
        begin
            zone_start <= s; zone_wrap <= w; zone_max_img <= m;
            @(posedge clk);
            zone_load  <= 1'b1;
            @(posedge clk);
            zone_load  <= 1'b0;
        end
    endtask

    //--------------- 观测 -------------------
    // 扫描中命中某图地址 => 置标志
    always @(posedge clk) begin
        if (state_code == 4'd2) begin
            if (sd_sec_read_addr == IMG_A) imgA_seen <= 1'b1;
            if (sd_sec_read_addr == IMG_B) imgB_seen <= 1'b1;
            if (sd_sec_read_addr == IMG_C) imgC_seen <= 1'b1;
        end
    end
    // 读图入口地址捕获(S_READ 入口的地址 = 本次读取图在卡内起始扇区)
    initial sc_d = 4'hF;
    always @(posedge clk) begin
        sc_d <= state_code;
        if (state_code == 4'd4 && sc_d != 4'd4) begin
            rd_base  <= sd_sec_read_addr;
            read_cnt <= read_cnt + 1;
        end
    end
    // 读中 zone_load 延迟生效捕获: arm 后见到 state==5 记录(证明读完才切)
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            defer_arm       <= 1'b0;
            defer_hold_seen <= 1'b0;
        end
        else begin
            if (zone_load && state_code == 4'd4) defer_arm <= 1'b1;
            if (defer_arm && state_code == 4'd5) begin
                defer_hold_seen <= 1'b1;
                defer_arm       <= 1'b0;
            end
        end
    end
    // 状态跳变日志
    reg [3:0] prev_state;
    initial prev_state = 4'hF;
    always @(posedge clk) begin
        if (state_code !== prev_state) begin
            $display("t=%0t  state: %0d -> %0d, addr=%0d", $time, prev_state, state_code, sd_sec_read_addr);
            prev_state <= state_code;
        end
    end

    //--------------- 假 SD 扇区模型 -------------------
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

    function [7:0] read_sd_byte;
        input [31:0] addr;
        input [9:0]  idx;
        reg [7:0] val;
        begin
            val = 8'h00;
            if (addr == IMG_A || addr == IMG_B || addr == IMG_C) begin
                case (idx)
                    10'd0:  val = "B";
                    10'd1:  val = "M";
                    10'd2:  val = 8'h10;   // file_len=10000=0x2710 小端
                    10'd3:  val = 8'h27;
                    10'd4:  val = 8'h00;
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
                    default: begin
                        if (addr == IMG_A) val = 8'h11;
                        else if (addr == IMG_B) val = 8'h22;
                        else val = 8'h33;
                    end
                endcase
            end
            read_sd_byte = val;
        end
    endfunction

    //--------------- 主流程 -------------------
    initial begin
        // 复位 & 初始化
        rst           = 1'b1;
        sd_init_done  = 1'b0;
        key_trigger   = 1'b0;
        key_prev      = 1'b0;
        slide_en      = 1'b1;
        zone_start    = IMG_A;
        zone_wrap     = Z_END;
        zone_max_img  = 32'd2;
        zone_load     = 1'b0;
        reload_req    = 1'b0;
        imgA_seen     = 1'b0;
        imgB_seen     = 1'b0;
        imgC_seen     = 1'b0;
        defer_hold_seen = 1'b0;
        defer_arm     = 1'b0;
        repeat (5) @(posedge clk);
        rst           = 1'b0;
        repeat (3) @(posedge clk);
        sd_init_done  = 1'b1;

        //-------- 1. 默认(菜单)分区: 上电自动找图A并进入保持 --------
        wait_state (4'd2);                      // 扫描
        wait_state (4'd5);                      // 图A读完进入保持
        check(imgA_seen, "默认分区上电 -> 扫描命中图A");
        $display("t=%0t  [STEP] 图A 显示保持中, addr=%0d", $time, sd_sec_read_addr);

        //-------- 2. 按键手动切图: A -> B(本分区 max=2 未回卷) --------
        key_trigger = 1'b1;
        @(posedge clk);
        key_trigger = 1'b0;
        wait_state (4'd2);
        wait_state (4'd5);
        check(imgB_seen, "按键切图 -> 扫描命中图B");
        check(rd_base == IMG_B, "下一张实际读取图B(读入口地址=IMG_B)");
        check(img_no == 8'd2, "下一张后图序号=2");

        //-------- 2b. 手动"上一张": B -> A(按序号目标从分区起点重扫) --------
        key_prev = 1'b1;
        @(posedge clk);
        key_prev = 1'b0;
        wait_state (4'd2);
        wait_state (4'd5);
        check(rd_base == IMG_A, "上一张实际重读图A(读入口地址=IMG_A)");
        check(img_no == 8'd1, "上一张后图序号回到 1(A)");

        //-------- 3. S_HOLD 中 zone_load -> 切换场景1分区(C) --------
        fire_zone (IMG_C, Z_END, 32'd1);
        wait_state (4'd1);                       // 回到空闲应用分区
        wait_state (4'd2);
        wait_state (4'd5);
        check(imgC_seen, "S_HOLD 中 zone_load -> 场景1分区扫描命中图C");

        //-------- 4. 读图中 zone_load(延迟请求, 帧写不中断) --------
        // 先从 C 保持态切回默认分区, 读到 A 进入保持
        fire_zone (IMG_A, Z_END, 32'd2);
        wait_state (4'd1);
        wait_state (4'd2);
        wait_state (4'd5);                       // A 保持
        // 按键触发读 B, 在读图(B, state==4)过程中打 zone_load 到 C
        key_trigger = 1'b1;
        @(posedge clk);
        key_trigger = 1'b0;
        wait_state (4'd2);                       // 扫描B
        wait_state (4'd4);                       // 进入读B
        repeat (3) @(posedge clk);               // 已在读图途中
        fire_zone (IMG_C, Z_END, 32'd1);         // 读中请求切换
        @(posedge clk);                          // 稳定一拍(pulse/标志同沿竞态规避)
        check(defer_arm, "读图中 zone_load -> 已置延迟切换标志");
        wait_state (4'd5);                       // 当前帧(B)先读完进入保持
        @(posedge clk);                          // 让延迟标志稳定一拍再断言
        check(defer_hold_seen, "延迟请求: B 完整读完才进入 S_HOLD(帧写未中断)");
        wait_state (4'd1);                       // 保持后立即应用新分区
        wait_state (4'd2);
        wait_state (4'd5);                       // 读入 C
        check(imgC_seen, "延迟请求生效 -> 已切换到图C分区并保持");

        //-------- 5. reload_req(缩放档变化) -> 原地重读当前图, 图序号不变 --------
        //  当前保持在图C(场景1分区 max=1): 重读应仍读到 C, 且"读图次数 +1"
        n0 = read_cnt;
        reload_req = 1'b1;
        @(posedge clk);
        reload_req = 1'b0;
        wait_state (4'd2);                       // 回分区起点重新扫描
        wait_state (4'd5);                       // 再次读完进入保持
        check(read_cnt == n0 + 1, "reload_req -> 确实重新读了一遍当前图(读次数 +1)");
        check(rd_base == IMG_C && img_no == 8'd1,
              "reload_req -> 仍读同一张图C(入口地址不变), 图序号保持 1");

        $display("=== bmp_read_auto(分区) 仿真结束,失败数=%0d ===", fail_cnt);
        $finish;
    end

    // 总超时兜底
    initial begin
        #3000000;   // 3ms
        $display("=== [TIMEOUT] 仿真超时,失败数=%0d ===", fail_cnt);
        $finish;
    end

endmodule
