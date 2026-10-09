`timescale 1ns/1ps
//====================================================================
// tb_zone_launch.v —— FAT32 查表「停车 / 交棒」握手时序专项仿真
// 被测: src/zone_launch.v  (+ 真实 src/audio_sd_arbiter.v)
//
// 为什么要这个用例:
//   查表与 BMP 轮播共用仲裁器 A 侧、共用一套数据/结束广播口, 绝不能同时
//   发请求。改造前切场景**完全不读卡**(顶层直接把常量脉冲给 bmp_read_auto),
//   所以"停车/交棒"是 v11 新增的时序, 必须在综合前用仿真证明没有缺口。
//
// 三个断言(逐拍检查, 任一成立即记一处违例):
//   A1 交棒不留缝 : 绝不允许 lu_req 当拍 bmp_go 仍为 1
//                   (晚一拍钉 0 ⇒ bmp_read_auto 会先抢发一整个扇区)
//   A2 不双主设备 : 绝不允许 bmp_sec_read 与 lu_sec_read 同时为 1
//                   (A 侧只有一套 a_data_valid/a_end 广播口 ⇒ 同一扇区的
//                    512 字节会被两个状态机同时吞掉)
//   A3 数据归属   : 谁在等数据, 收到的字节就必须是**它自己请求的那个扇区**
//                   的内容。SD 模型把扇区号编进数据
//                   (byte = 扇区号低8位 + 扇区内偏移), 各消费者逐字节比对
//                   "我的请求地址 + 我的接收序号"。这是唯一能直接抓到
//                   "串扇区数据"的断言。
//   A4 放行不早于分区下发 : 段表就绪后、zone_load 首拍之前, bmp_go 必须保持 0。
//                   bmp_zone_load 是寄存输出(lu_ready 上升沿的下一拍), 而
//                   lu_busy 在 lu_ready 当拍就掉了 —— 若 bmp_go 只看 ~lu_busy
//                   就会早一拍放行, 引擎便拿【旧分区】从 S_IDLE 进 S_FIND 扫图
//                   (见 bmp_read_auto.v S_IDLE 注释"同一拍 zone_load + S_IDLE
//                   应用: 置位优先, 应用读的是 req_* 旧值"), 白扫一段卡、
//                   上电时先扫编译期默认地址 ⇒ 可能先载入错图。
//
//   ★ 为什么不写"扇区读期间地址必须稳定": sd_card_sec_read_write 是在
//     S_WAIT_READ_WRITE 那一拍把地址锁进 sec_addr, 之后与 sd_sec_read_addr
//     无关(其注释已明确) —— 地址后变并不会读错那一扇区, 不是致损机制。
//     A3 用数据内容比对, 直接对准后果。
//
// ★ 判别力自证(A/B 对照, 项目纪律):
//   同一场景跑两遍 —— 一遍用 zone_launch 的正确门控, 一遍用"朴素写法"
//   (bmp_go = sd_init_done & ~lu_busy, lu_start 不等总线空闲)。
//   朴素那遍**必须**暴露违例, 否则本用例无判别力, 直接判 FAIL。
//
// ★★ 本 TB 自身踩过的坑(写 SD 行为模型时务必注意, 否则会造出假违例):
//   最初把 sd_sec_read_end 放在 ST_WAIT(请求采样/锁地址那一拍)期间,
//   结果模型会在 owner 还没被 end 清掉的那一拍去锁地址 → 把"旧主的扇区"
//   又读一遍(幽灵重读), 与"新主已获授权"同拍发生, 凭空产生跨通路串数据
//   的 A3 假违例。真机时序是
//     S_WAIT_READ_WRITE(采样请求/锁地址) → S_READ(吐数据) → S_READ_END(end)
//   → 所以 end 必须出现在【锁地址那一拍之前】, 即 ST_DONE(=S_READ_END),
//     与 tb_fat32_lookup 的 `assign sd_end = (st == ST_DONE)` 完全一致。
//
// 场景设计(专挑最坏时刻):
//   上电 → BMP 主设备持续扫图(持 sd_sec_read 一整段, 模拟 S_FIND 的
//   "持续发读请求") → 在 SD 控制器【已深入某扇区中部】时突然来场景切换
//   请求, 同时音频(b_req)也在抢总线 —— 三重压力叠在一起。
//
// 语言: 纯 Verilog-2001。
//====================================================================
module tb_zone_launch;

    //--------------- 时钟 / 复位 ----------------
    reg clk, rst;
    initial clk = 1'b0;
    always #5 clk = ~clk;                  // 100 MHz

    integer viol_a1, viol_a2, viol_a3, viol_a4;
    integer fails;

    // SD 控制器模型输出(★ 必须在仲裁器例化之前声明:
    //   否则被当成隐式 1bit 网络 —— 与工程里"漏声明位宽导致上板花屏"同源)
    reg         sd_data_valid;
    reg         sd_end;
    reg  [7:0]  sd_byte;

    //--------------- DUT: zone_launch ----------------
    reg  sd_init_done, lu_req;
    wire lu_start_c, bmp_go_c, zone_load_c, first_tbl_done_c;
    wire lu_busy, lu_ready;
    wire bus_free;

    zone_launch u_dut (
        .clk            (clk),
        .rst            (rst),
        .sd_init_done   (sd_init_done),
        .lu_req         (lu_req),
        .lu_busy        (lu_busy),
        .lu_ready       (lu_ready),
        .bus_free       (bus_free),
        .lu_start       (lu_start_c),
        .bmp_go         (bmp_go_c),
        .bmp_zone_load  (zone_load_c),
        .first_tbl_done (first_tbl_done_c)
    );

    //--------------- 朴素写法对照(故意按"改造前的思维"写) ----------------
    reg  naive_mode;
    reg  pend_n;
    wire lu_start_n = (lu_req | pend_n);
    wire bmp_go_n   = sd_init_done & ~lu_busy;

    always @(posedge clk or posedge rst) begin
        if (rst)                     pend_n <= 1'b0;
        else if (lu_start_n)         pend_n <= 1'b0;
        else if (lu_req)             pend_n <= 1'b1;
    end

    wire        lu_start  = naive_mode ? lu_start_n : lu_start_c;
    wire        bmp_go    = naive_mode ? bmp_go_n   : bmp_go_c;
    wire        zone_load = zone_load_c;    // 分区下发两条路一致(朴素写法差在
                                            // bmp_go/lu_start, 不在 zone_load 本身)

    // A4 用: "本次段表已下发"指示(lu_ready 拉高期间有效, 新查表开始时清)
    reg  zone_pulsed;
    wire zone_seen = zone_pulsed | zone_load;
    always @(posedge clk or posedge rst) begin
        if (rst)                     zone_pulsed <= 1'b0;
        else if (!lu_ready)          zone_pulsed <= 1'b0;
        else if (zone_load)          zone_pulsed <= 1'b1;
    end

    //--------------- 主 A 侧: 模拟 bmp_read_auto 的请求行为 ----------------
    //   只保留与总线握手相关的部分(协议已从其源码核实):
    //     · sd_init_done(=bmp_go)=1 时持续发 sd_sec_read, 扫完一扇区立刻
    //       改地址继续发(见其 S_FIND 的 "持续发读请求");
    //     · sd_init_done=0 那一拍强制回 S_IDLE 并 sd_sec_read<=0 ——
    //       NBA 效果落在【下一拍】, 这就是 A2 隐患的来源。
    reg  [1:0]  bm_st;
    reg         bmp_sec_read;
    reg  [31:0] bmp_sec_read_addr;
    reg         bmp_go_d;

    localparam [1:0] B_IDLE = 2'd0, B_REQ = 2'd1;

    //--------------- 查表桩: 模拟 fat32_lookup 的总线侧行为 ----------------
    //   start → busy=1, 连读 3 个扇区(MBR+BPB+根目录), 读完 ready=1/busy=0
    reg  [1:0]  lu_st;
    reg         lu_sec_read;
    reg  [31:0] lu_sec_read_addr;
    reg  [3:0]  lu_left;
    reg         lu_busy_r, lu_ready_r;

    localparam [1:0] L_IDLE = 2'd0, L_READ = 2'd1;

    assign lu_busy  = lu_busy_r;
    assign lu_ready = lu_ready_r;

    //--------------- 仲裁器(真实模块) ----------------
    wire        sd_sec_read, a_end, a_data_valid, b_end, b_data_valid;
    wire [31:0] sd_sec_read_addr;
    wire        a_req  = bmp_sec_read | lu_sec_read;
    wire [31:0] a_addr = lu_sec_read ? lu_sec_read_addr : bmp_sec_read_addr;

    // B 侧(音频): 场景里用来抢总线
    reg         b_req;
    reg  [31:0] b_addr;

    audio_sd_arbiter u_arb (
        .clk                    (clk),
        .rst                    (rst),
        .sd_sec_read            (sd_sec_read),
        .sd_sec_read_addr       (sd_sec_read_addr),
        .sd_sec_read_data_valid (sd_data_valid),
        .sd_sec_read_end        (sd_end),
        .a_req                  (a_req),
        .a_addr                 (a_addr),
        .a_data_valid           (a_data_valid),
        .a_end                  (a_end),
        .b_req                  (b_req),
        .b_addr                 (b_addr),
        .b_data_valid           (b_data_valid),
        .b_end                  (b_end)
    );

    assign bus_free = ~sd_sec_read;

    //--------------- 简易 SD 控制器(按 sd_card_sec_read_write 行为建模) ----------
    //   与 tb_fat32_lookup 里已验证过的模型同构:
    //     · sd_sec_read 是电平; 在 WAIT 那拍把地址锁进 cur_lba 并开始吐数据;
    //     · sd_sec_read_data_valid 只在吐数据阶段拉高; sd_sec_read_end 单拍
    //       且在数据阶段【之后】、与 dvalid 不重叠(与真机一致)。
    //   ★ 数据内容 = 扇区号低 8 位 + 扇区内偏移 —— 供 A3 判"数据归属"。
    //
    //   ★★ sd_end 的位置(本 TB 踩过的坑, 必须与真机严格一致):
    //     真机时序是 S_WAIT_READ_WRITE(采样请求/锁地址) → S_READ(吐数据)
    //     → S_READ_END(sd_end 单拍) → 回到 S_WAIT_READ_WRITE。
    //     所以 sd_end 必须出现在【锁地址那一拍之前】的那个状态里 —— 即
    //     本模型的 ST_DONE（=S_READ_END），而【不能】落在 ST_WAIT。
    //     若把 sd_end 放在 ST_WAIT, 则:
    //       ST_WAIT 里既看到 sd_sec_read=1 去锁地址(此时仲裁器 owner 还
    //       没被 sd_end 清掉, 地址仍是旧主的) → 真机绝不会发生; 结果模型
    //       会拿旧地址"幽灵重读"一遍, 与"新主已获授权"同时发生,
    //       凭空造出跨通路串数据的假违例。
    //--------------------------------------------------------------
    localparam [2:0] ST_WAIT = 3'd0, ST_RD = 3'd1, ST_DONE = 3'd2;
    reg  [2:0]  st;
    reg  [31:0] cur_lba;
    reg  [8:0]  off;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            st            <= ST_WAIT;
            off           <= 9'd0;
            cur_lba       <= 32'd0;
            sd_byte       <= 8'h00;
            sd_data_valid <= 1'b0;
            sd_end        <= 1'b0;
        end
        else begin
            case (st)
            ST_WAIT: begin
                sd_data_valid <= 1'b0;
                sd_end        <= 1'b0;
                if (sd_sec_read) begin
                    cur_lba       <= sd_sec_read_addr;      // 同拍锁地址(真机行为)
                    off           <= 9'd0;
                    sd_data_valid <= 1'b1;
                    sd_byte       <= sd_sec_read_addr[7:0];  // 偏移 0
                    st            <= ST_RD;
                end
            end
            ST_RD: begin
                if (off == 9'd511) begin
                    sd_data_valid <= 1'b0;
                    sd_end        <= 1'b1;      // ★ 单拍结束脉冲, 落在 ST_DONE 期间
                    st            <= ST_DONE;   //   (锁地址之前那一拍, 与真机 S_READ_END 同位置)
                end
                else begin
                    off           <= off + 9'd1;
                    sd_data_valid <= 1'b1;
                    sd_byte       <= cur_lba[7:0] + off[7:0] + 8'd1;
                end
            end
            ST_DONE: begin
                sd_data_valid <= 1'b0;
                sd_end        <= 1'b0;
                st            <= ST_WAIT;
            end
            default: st <= ST_WAIT;
            endcase
        end
    end

    //--------------- BMP 主设备 / 查表桩 时序 ----------------
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            bm_st             <= B_IDLE;
            bmp_sec_read      <= 1'b0;
            bmp_sec_read_addr <= 32'd15936;
            bmp_go_d          <= 1'b0;
        end
        else begin
            bmp_go_d <= bmp_go;
            if (!bmp_go) begin
                // 与 bmp_read_auto 完全一致: 本拍看到 0 → 撤请求(下一拍生效)
                bm_st        <= B_IDLE;
                bmp_sec_read <= 1'b0;
            end
            else case (bm_st)
                B_IDLE: begin
                    if (bmp_go_d) begin
                        bmp_sec_read <= 1'b1;
                        bm_st        <= B_REQ;
                    end
                end
                B_REQ: begin
                    if (a_end) begin
                        bmp_sec_read_addr <= bmp_sec_read_addr + 32'd8; // 8 扇区跳步
                        bmp_sec_read      <= 1'b1;                     // 持续发请求
                    end
                end
                default: ;
            endcase
        end
    end

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            lu_st            <= L_IDLE;
            lu_sec_read      <= 1'b0;
            lu_sec_read_addr <= 32'd0;
            lu_left          <= 4'd0;
            lu_busy_r        <= 1'b0;
            lu_ready_r       <= 1'b0;
        end
        else case (lu_st)
            L_IDLE: begin
                lu_sec_read <= 1'b0;
                if (lu_start) begin
                    lu_st            <= L_READ;
                    lu_busy_r        <= 1'b1;
                    lu_ready_r       <= 1'b0;      // 与 fat32_lookup 一致: 开始即清就绪
                    lu_left          <= 4'd3;      // 读 3 个扇区
                    lu_sec_read_addr <= 32'd0;
                    lu_sec_read      <= 1'b1;
                end
            end
            L_READ: begin
                lu_sec_read <= 1'b1;
                if (a_end) begin
                    if (lu_left == 4'd1) begin
                        lu_sec_read <= 1'b0;
                        lu_busy_r   <= 1'b0;
                        lu_ready_r  <= 1'b1;
                        lu_st       <= L_IDLE;
                    end
                    else begin
                        lu_left          <= lu_left - 4'd1;
                        lu_sec_read_addr <= lu_sec_read_addr + 32'd1;
                    end
                end
            end
            default: lu_st <= L_IDLE;
        endcase
    end

    //--------------- 断言 + 数据归属校验 ----------------
    //   数据归属: SD 模型把扇区号编进数据, 于是"谁在等数据, 收到的字节
    //   就必须等于 (它请求的扇区号低8位 + 它的接收序号)"。
    //   各消费者用私有接收计数器(本拍读旧值, 与下面的推进同拍, 顺序无碍)。
    reg [9:0] bm_beat, lu_beat, au_beat;
    integer dbg_show;      // 只打印前若干条违例明细(计数仍然全量, 不受影响)

    always @(posedge clk) begin
        if (!rst) begin
            // A1: 交棒不留缝
            if (lu_req && bmp_go) begin
                viol_a1 = viol_a1 + 1;
                if (dbg_show < 10) begin
                    dbg_show = dbg_show + 1;
                    $display("  [VIOL-A1] t=%0t lu_req 当拍 bmp_go 仍为 1 (naive=%0d)",
                             $time, naive_mode);
                end
            end
            // A2: 不双主设备
            if (bmp_sec_read && lu_sec_read) begin
                viol_a2 = viol_a2 + 1;
                if (dbg_show < 10) begin
                    dbg_show = dbg_show + 1;
                    $display("  [VIOL-A2] t=%0t bmp 与 lu 同时请求总线 (naive=%0d)",
                             $time, naive_mode);
                end
            end
            // A3: 数据归属(BMP 通路)
            if (a_data_valid && bmp_sec_read &&
                (sd_byte !== (bmp_sec_read_addr[7:0] + bm_beat[7:0]))) begin
                viol_a3 = viol_a3 + 1;
                if (dbg_show < 10) begin
                    dbg_show = dbg_show + 1;
                    $display("  [VIOL-A3] t=%0t BMP 通路收到串扇区数据: 请求=%0d 序号=%0d 收到=%02x 应为=%02x (naive=%0d)",
                             $time, bmp_sec_read_addr, bm_beat, sd_byte,
                             bmp_sec_read_addr[7:0] + bm_beat[7:0], naive_mode);
                end
            end
            // A3: 数据归属(查表通路)
            if (a_data_valid && lu_sec_read &&
                (sd_byte !== (lu_sec_read_addr[7:0] + lu_beat[7:0]))) begin
                viol_a3 = viol_a3 + 1;
                if (dbg_show < 10) begin
                    dbg_show = dbg_show + 1;
                    $display("  [VIOL-A3] t=%0t 查表通路收到串扇区数据: 请求=%0d 序号=%0d 收到=%02x 应为=%02x (naive=%0d)",
                             $time, lu_sec_read_addr, lu_beat, sd_byte,
                             lu_sec_read_addr[7:0] + lu_beat[7:0], naive_mode);
                end
            end
            // A3: 数据归属(音频通路, B 侧)
            if (b_data_valid &&
                (sd_byte !== (b_addr[7:0] + au_beat[7:0]))) begin
                viol_a3 = viol_a3 + 1;
                if (dbg_show < 10) begin
                    dbg_show = dbg_show + 1;
                    $display("  [VIOL-A3] t=%0t 音频通路收到串扇区数据: 请求=%0d 序号=%0d 收到=%02x 应为=%02x (naive=%0d)",
                             $time, b_addr, au_beat, sd_byte,
                             b_addr[7:0] + au_beat[7:0], naive_mode);
                end
            end

            // A4: 放行不得早于分区下发
            if (lu_ready && !zone_seen && bmp_go) begin
                viol_a4 = viol_a4 + 1;
                if (dbg_show < 10) begin
                    dbg_show = dbg_show + 1;
                    $display("  [VIOL-A4] t=%0t 段表已就绪但 zone_load 未下发, bmp_go 却已放行 (naive=%0d)",
                             $time, naive_mode);
                end
            end

            // 接收序号推进
            bm_beat <= a_data_valid ? (bm_beat + 10'd1) : 10'd0;
            lu_beat <= a_data_valid ? (lu_beat + 10'd1) : 10'd0;
            au_beat <= b_data_valid ? (au_beat + 10'd1) : 10'd0;
        end
    end

    //--------------- 单次场景: 最坏时刻来场景切换请求 + 音频抢总线 ---------------
    task run_scenario;
        input naive;
        input [255:0] tag;
        integer v1, v2, v3, v4, tot;
        begin
            viol_a1 = 0; viol_a2 = 0; viol_a3 = 0; viol_a4 = 0;
            dbg_show = 0;
            naive_mode = naive;

            // 复位
            rst = 1'b1; lu_req = 1'b0; b_req = 1'b0; b_addr = 32'd300000;
            bm_beat = 0; lu_beat = 0; au_beat = 0;
            repeat (5) @(posedge clk);
            rst = 1'b0;
            sd_init_done = 1'b1;

            // 让 BMP 主设备先跑起来
            wait (bmp_sec_read === 1'b1);
            wait (st === ST_RD);
            // 深入到扇区中部再发切换请求(最坏时刻: 控制器已锁地址、正在吐数据)
            repeat (100) @(posedge clk);

            // 三重压力: 场景切换请求 + 音频也在抢总线
            //   音频(B 侧)严格优先且此刻持续请求 ⇒ 正确门控下查表必须一直等;
            //   先让音频占几个扇区再放开, 才能看出"② 等总线空闲"真的在起作用
            //   (也顺带验证查表不会被音频饿死)。
            @(negedge clk);
            lu_req = 1'b1;
            b_req  = 1'b1;

            repeat (3000) @(posedge clk);   // 音频连占约 6 个扇区
            b_req  = 1'b0;
            lu_req = 1'b0;

            wait (lu_ready === 1'b1);
            repeat (200) @(posedge clk);

            v1 = viol_a1; v2 = viol_a2; v3 = viol_a3; v4 = viol_a4;
            tot = v1 + v2 + v3 + v4;

            if (naive) begin
                // 朴素对照: 必须检出违例, 否则用例没有判别力
                if (tot > 0)
                    $display("[PASS] %0s 朴素写法检出 %0d 处违例(A1=%0d A2=%0d A3=%0d A4=%0d) → 用例有判别力",
                             tag, tot, v1, v2, v3, v4);
                else begin
                    fails = fails + 1;
                    $display("[FAIL] %0s 朴素写法竟 0 违例 → 本用例无判别力, 断言写错了",
                             tag);
                end
            end
            else begin
                if (tot == 0) begin
                    $display("[PASS] %0s 正确握手 0 违例(A1/A2/A3/A4 全过)",
                             tag);
                end
                else begin
                    fails = fails + 1;
                    $display("[FAIL] %0s 正确握手仍有 %0d 处违例(A1=%0d A2=%0d A3=%0d A4=%0d)",
                             tag, tot, v1, v2, v3, v4);
                end
            end
        end
    endtask

    //--------------- 主流程 ----------------
    initial begin
        viol_a1 = 0; viol_a2 = 0; viol_a3 = 0; viol_a4 = 0;
        bm_beat = 0; lu_beat = 0; au_beat = 0;
        dbg_show = 0;
        naive_mode = 1'b0;
        b_req = 1'b0; b_addr = 32'd300000;
        lu_req = 1'b0; sd_init_done = 1'b0;
        rst = 1'b1;
        fails = 0;

        #200;
        $display("");
        $display("========== zone_launch 停车/交棒握手专项仿真 ==========");

        run_scenario(1'b0, "正确门控(zone_launch)");
        run_scenario(1'b1, "朴素对照(sd_init_done&~lu_busy)");

        $display("");
        if (fails == 0) $display("==== 全部 PASS (0 FAIL) ====");
        else            $display("==== 有 %0d 项 FAIL ====", fails);
        $display("");
        $finish;
    end

    // 看门狗
    initial begin
        #5_000_000;
        $display("[WDOG] 仿真超时 —— 握手疑似卡死");
        $display("==== 有 %0d 项 FAIL (含超时) ====", fails + 1);
        $finish;
    end

endmodule
