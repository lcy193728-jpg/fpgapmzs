//====================================================================
// 模块名 : tb_bmp_read_auto.v
// 功能   : bmp_read_auto 分区化自动轮播 + 场景分区切换 + 批次3 容错恢复仿真
// 卡模型 : 假 SD 卡, 各图 file_len=10000(便于加速), 第 0 扇区填完整 BMP 头
//          (含 pixel_offset/DIB/planes/compression, 供 9 项严格校验):
//           图A @扇区16000(像素h11)  图B @扇区16064(像素h22)
//           图C @扇区16128(像素h33)  图D @扇区16384(像素h44)
//           坏图 @扇区16256: 签名"BM"+尺寸合法, 但 planes=0 → 9 项校验必失败
//           卡死 @扇区16512: 头合法(能被命中), 但读第 16513 扇区起不再应答
// 分区   : 默认(菜单)分区 = start16000 wrap20000 max2 (图A/图B)
//          场景1 分区       = start16128 wrap20000 max1 (图C)
//          坏图 分区        = start16256 wrap20000 max1 (坏图 → 图D)
//          卡死 分区        = start16512 wrap20000 max1 (卡死 → 图F@16640)
// 验证   :
//   1. 上电默认分区自动找图轮播(A)
//   2. 按键手动切图(A->B), 校验读取入口地址 rd_base 与图序号 img_no
//   2b.手动"上一张"(B->A): 按序号目标从分区起点重扫, 读入口回到 IMG_A
//   3. S_HOLD 中 zone_load -> 切到场景1 分区并读入 C
//   4. 读图中 zone_load(延迟请求): 当前帧读完才切(帧写不中断),
//      进入 S_HOLD 后立即执行切换, 不等待轮播计时
//   5. reload_req(缩放档变化) -> 原地重读当前图, 图序号不变
//   6.(批次3)坏图快跳: 命中"BM"但 9 项校验不过 → 报 bmp_error=1 并按
//      file_len 折算的簇数(10000 字节 → 24 扇区)整文件跳过, 不停留重扫
//   7.(批次3)读卡死锁: 读途中无进展 → 报 bmp_error=2(超时) → 重试 1 次
//      (图序号不变) → 仍失败则跳过本张, 继续扫到后继正常图(显示通路不死)
//====================================================================

`timescale 1ns/1ps
module tb_bmp_read_auto;

    localparam CLK_PERIOD       = 10;              // 100MHz -> 10ns
    localparam SLIDE_INTERVAL_SIM = 32'd10_000_000;// 100ms(仅测按键/分区, 不触发)
    // 假图"像素字节数"= 3×floor((file_len-pixel_offset)/3) = 3×3315 = 9945
    //   → bmp_read_auto 内 BMP_PIXEL_COUNT=9945/3=3315, 读到 file_len 时
    //     像素数恰好达标, 不会误触 ERR_TRUNCATED(截断)
    localparam BMP_PIXEL_BYTES_SIM = 32'd9945;
    // 仿真用超时压缩: 2×1000 = 2000 周期(=20us@100MHz)
    //   注: 必须 > 假卡读一个扇区的耗时(约 515 周期), 否则正常扫图会误判超时
    localparam TIMEOUT_MS_SIM   = 16'd2;
    localparam CLK_FREQ_SIM     = 32'd1_000_000;

    // 图像地址(与假卡一致)
    localparam [31:0] IMG_A  = 32'd16000;
    localparam [31:0] IMG_B  = 32'd16064;
    localparam [31:0] IMG_C  = 32'd16128;
    localparam [31:0] IMG_BAD= 32'd16256;   // 坏图(planes=0)
    localparam [31:0] IMG_D  = 32'd16384;   // 坏图之后的第一张正常图
    localparam [31:0] IMG_STALL = 32'd16512; // 读卡死锁图
    localparam [31:0] IMG_F  = 32'd16640;   // 卡死图之后的第一张正常图
    localparam [31:0] Z_END = 32'd20000;
    // 坏图/卡死图的快跳步长: file_len=10000 → 扇区数20 → 对齐 8 → 24 扇区
    localparam [31:0] SKIP_24 = 32'd24;

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
    reg  [31:0] slide_interval; // 批次4 运行时轮播间隔(周期); 复位默认 = SLIDE_INTERVAL_SIM

    wire [3:0]  state_code;
    wire        write_req;
    wire        sd_sec_read;
    wire [31:0] sd_sec_read_addr;
    wire        bmp_data_wr_en;
    wire [23:0] bmp_data;
    wire [7:0]  img_no;
    wire [3:0]  bmp_error;    // 加载错误码(0无/1头校验/2超时/3截断)

    reg  [31:0] rd_base;      // 本次读图的入口地址(捕获 S_READ 入口的地址)
    reg  [3:0]  sc_d;         // state_code 上一拍
    integer     read_cnt = 0;  // 读图次数(S_READ 入口计数), 用于验证 reload
    integer     n0;            // reload 测试用: 重读前的读图次数快照

    integer     fail_cnt = 0;

    // 观测标志
    reg         imgA_seen, imgB_seen, imgC_seen;   // 扫描时命中过对应地址
    reg         defer_arm;                         // 读中 zone_load 后准备捕获
    reg         defer_hold_seen;                   // 捕获到进入 S_HOLD(延迟生效证明)
    reg         imgD_seen;                         // 坏图快跳后扫到图D
    reg         err_header_seen;                   // 见过 bmp_error=1(坏图)
    reg         err_timeout_seen;                  // 见过 bmp_error=2(读超时)
    reg         bad_skip_ok;                       // 坏图一次跳过 24 扇区(16256->16280)
    reg         stall_skip_ok;                     // 卡死图重试耗尽后跳过(16512->16536)
    reg  [31:0] stall_read_cnt = 32'd0;            // 卡死图的读图次数(应为 2: 首次+重试)
                                                  //   (仅由下方面板 S_READ 入口块驱动)

    bmp_read_auto #(
        .SLIDE_INTERVAL   (SLIDE_INTERVAL_SIM),
        .MIN_PERIOD_CYCLES(32'd1000),          //仿真压缩下限: 便于用小间隔测"运行时改档"
        .ZONE_START_SECTOR(IMG_A),
        .ZONE_WRAP_SECTOR (Z_END),
        .ZONE_MAX_IMAGES  (32'd2),
        .BMP_PIXEL_BYTES  (BMP_PIXEL_BYTES_SIM),
        .SD_READ_TIMEOUT_MS(TIMEOUT_MS_SIM),
        .CLK_FREQ_HZ      (CLK_FREQ_SIM),
        .MAX_RETRIES      (4'd1)
    ) dut (
        .clk                    (clk),
        .rst                    (rst),
        .ready                  (),
        .sd_init_done           (sd_init_done),
        .key_trigger            (key_trigger),
        .key_prev               (key_prev),
        .slide_en               (slide_en),
        .slide_interval         (slide_interval),
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
        .img_busy               (),
        .bmp_error              (bmp_error)
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
            if (sd_sec_read_addr == IMG_D) imgD_seen <= 1'b1;
        end
    end
    // 批次3 容错观测
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            err_header_seen  <= 1'b0;
            err_timeout_seen <= 1'b0;
            bad_skip_ok      <= 1'b0;
            stall_skip_ok    <= 1'b0;
        end
        else begin
            if (bmp_error == 4'd1) err_header_seen  <= 1'b1;   // ERR_HEADER
            if (bmp_error == 4'd2) err_timeout_seen <= 1'b1;   // ERR_TIMEOUT
            // 坏图: 报码后地址一次跳到 16256+24=16280(证明按 file_len 整文件跳过)
            if (state_code == 4'd2 && bmp_error == 4'd1 &&
                sd_sec_read_addr == (IMG_BAD + SKIP_24)) bad_skip_ok <= 1'b1;
            // 卡死图: 跳过地址 = 16512+24 = 16536
            if (state_code == 4'd2 && sd_sec_read_addr == (IMG_STALL + SKIP_24))
                stall_skip_ok <= 1'b1;
        end
    end
    // 读图入口地址捕获(S_READ 入口的地址 = 本次读取图在卡内起始扇区)
    initial sc_d = 4'hF;
    always @(posedge clk) begin
        sc_d <= state_code;
        if (state_code == 4'd4 && sc_d != 4'd4) begin
            rd_base  <= sd_sec_read_addr;
            read_cnt <= read_cnt + 1;
            if (sd_sec_read_addr == IMG_STALL) stall_read_cnt <= stall_read_cnt + 32'd1;
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
    reg [31:0] stall_sect = IMG_STALL + 32'd1;   // 读到该扇区起不再应答(模拟读卡死锁)
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
                    // 卡死扇区: 不发数据令牌, 也不回结束 → 上层只能靠超时退出
                    if (sd_sec_read && (sd_sec_read_addr != stall_sect)) begin
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

    // 假卡扇区 0 内容: 完整 BMP 头(满足 bmp_read_auto 的 9 项严格校验)
    //   file_len=10000, pixel_offset=54, DIB=40, 640×480×24, planes=1, 无压缩
    //   坏图(IMG_BAD)仅 planes=0 一项不合法 → 头校验必失败
    function [7:0] read_sd_byte;
        input [31:0] addr;
        input [9:0]  idx;
        reg [7:0] val;
        reg       bad;
        begin
            val = 8'h00;
            bad = (addr == IMG_BAD);
            if (addr == IMG_A || addr == IMG_B || addr == IMG_C ||
                addr == IMG_D || addr == IMG_F || addr == IMG_STALL || bad) begin
                // 数据区默认填充(每张图一个特征字节, 便于波形区分)
                if      (addr == IMG_A)     val = 8'h11;
                else if (addr == IMG_B)     val = 8'h22;
                else if (addr == IMG_C)     val = 8'h33;
                else if (addr == IMG_D)     val = 8'h44;
                else if (addr == IMG_F)     val = 8'h77;
                else if (addr == IMG_STALL) val = 8'h55;
                else                        val = 8'h66;   // 坏图
                case (idx)
                    10'd0:  val = "B";
                    10'd1:  val = "M";
                    10'd2:  val = 8'h10;   // file_len=10000=0x2710 小端
                    10'd3:  val = 8'h27;
                    10'd4:  val = 8'h00;
                    10'd5:  val = 8'h00;
                    10'd10: val = 8'h36;   // pixel_offset=54
                    10'd11: val = 8'h00;
                    10'd12: val = 8'h00;
                    10'd13: val = 8'h00;
                    10'd14: val = 8'h28;   // dib_size=40
                    10'd15: val = 8'h00;
                    10'd16: val = 8'h00;
                    10'd17: val = 8'h00;
                    10'd18: val = 8'h80;   // width=640
                    10'd19: val = 8'h02;
                    10'd20: val = 8'd0;
                    10'd21: val = 8'd0;
                    10'd22: val = 8'hE0;   // height=480
                    10'd23: val = 8'h01;
                    10'd24: val = 8'd0;
                    10'd25: val = 8'd0;
                    10'd26: val = bad ? 8'h00 : 8'h01;  // planes(坏图=0)
                    10'd27: val = 8'h00;
                    10'd28: val = 8'h18;   // bit_cnt=24
                    10'd29: val = 8'd0;
                    10'd30: val = 8'h00;   // compression=0
                    10'd31: val = 8'h00;
                    10'd32: val = 8'h00;
                    10'd33: val = 8'h00;
                    default: ;             // 其它字节保持上面的数据填充
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
        slide_interval= SLIDE_INTERVAL_SIM;   // 批次4: 复位默认间隔(3s 的仿真压缩值)
        imgA_seen     = 1'b0;
        imgB_seen     = 1'b0;
        imgC_seen     = 1'b0;
        imgD_seen     = 1'b0;
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

        //-------- 6.(批次3)坏图快跳: "BM"签名但 9 项校验不过 --------
        //  分区 [16256, 20000) max=1: 坏图在 16256, 之后第一张正常图 D=16384
        fire_zone (IMG_BAD, Z_END, 32'd1);
        wait_state (4'd1);                       // 空闲应用分区
        wait_state (4'd2);                       // 扫描
        wait_state (4'd5);                       // 跳过坏图后读到图D进入保持
        check(err_header_seen, "坏图(planes=0) -> 报 bmp_error=1(ERR_HEADER)");
        check(bad_skip_ok,     "坏图 -> 按 file_len 折算一次跳过 24 扇区(16256->16280)");
        check(imgD_seen && rd_base == IMG_D,
              "坏图不停留重扫 -> 越过整张坏图后读到图D(不粘死)");
        check(bmp_error == 4'd0, "图D完整读完后错误码清除为 0");
        check(img_no == 8'd1,   "坏图被跳过, 不占用轮播序号(图序号仍=1)");

        //-------- 7.(批次3)读卡死锁 -> 超时 -> 重试1次 -> 跳过本张 --------
        //  分区 [16512, 20000) max=1: 图16512 头合法(被命中), 但读第 16513
        //  扇区起假卡不再应答 → 连续无进展 → 报 ERR_TIMEOUT
        fire_zone (IMG_STALL, Z_END, 32'd1);
        wait_state (4'd1);
        wait_state (4'd2);
        wait_state (4'd4);                       // 首次读 16512(读到第2扇区卡死)
        wait_state (4'd1);                       // 超时 → 重试耗尽 → 跳过回空闲
        check(err_timeout_seen, "读卡死锁 -> 报 bmp_error=2(ERR_TIMEOUT)");
        wait_state (4'd2);
        wait_state (4'd5);                       // 扫到图F(16640)并读完
        check(stall_read_cnt == 32'd2,
              "卡死图 -> 读图尝试 2 次(首次 + 重试 1 次, MAX_RETRIES=1)");
        check(stall_skip_ok, "卡死图重试耗尽 -> 跳过本张(file_base+24=16536)继续扫");
        check(rd_base == IMG_F, "跳过后读到后继正常图F(显示通路未死锁)");

        //-------- 8.(批次4)运行时轮播间隔(slide_interval) --------
        //  回到 [IMG_A, Z_END) max=2 分区保持图A(自动轮播中, slide_en=1),
        //  先用非法值证明"不会被写成 0 就疯狂切图", 再用小值证明计时到即切。
        fire_zone (IMG_A, Z_END, 32'd2);
        wait_state (4'd1);
        wait_state (4'd2);
        wait_state (4'd5);
        check(rd_base == IMG_A && img_no == 8'd1 && state_code == 4'd5,
              "批次4 前置: 回到图A保持态(自动轮播, 默认间隔未到不切)");

        // (a) 非法值 0(<下限) → 忽略, 保持上一次有效间隔 → 短时间内绝不切图
        slide_interval = 32'd0;
        repeat (300) @(posedge clk);
        check(state_code == 4'd5 && rd_base == IMG_A,
              "slide_interval=0(非法) -> 被忽略, 仍停在图A(无 0 间隔疯狂切图)");

        // (b) 合法小间隔(5000 周期) → 计时到自动切下一张 A->B
        slide_interval = 32'd5000;
        wait_state (4'd2);
        wait_state (4'd5);
        check(rd_base == IMG_B, "运行时改小间隔 -> 计时到自动切到图B(新间隔生效)");
        check(img_no == 8'd2,   "自动切图后图序号=2");

        // (c) 改大间隔(20000 周期) → 短期内不切; 到点后再切(回卷到 A)
        slide_interval = 32'd20000;
        repeat (2000) @(posedge clk);
        check(state_code == 4'd5 && rd_base == IMG_B,
              "间隔改大 -> 2000 周期内不切图(新间隔已生效为大值)");
        wait_state (4'd2);
        wait_state (4'd5);
        check(rd_base == IMG_A, "大间隔到点 -> 播完一圈回卷读到图A");

        $display("=== bmp_read_auto(分区/容错) 仿真结束,失败数=%0d ===", fail_cnt);
        $finish;
    end

    // 总超时兜底
    initial begin
        #8000000;   // 8ms(含批次3 两处超时用例: 每次超时压缩为 2000 周期)
        $display("=== [TIMEOUT] 仿真超时,失败数=%0d ===", fail_cnt);
        $finish;
    end

endmodule
