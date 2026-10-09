`timescale 1ns/1ps
//====================================================================
// tb_fat32_lookup.v —— fat32_lookup 专项仿真(v11)
//
// 目的: 不接真实 SD 控制器, 用一份【手工构造的假卡镜像】驱动被测模块的
//       扇区读口, 验证:
//         ① MBR → 分区起始 LBA 解析(含"无 MBR 超级软盘"路径留给上板)
//         ② BPB → 扇区/簇、数据区起始、根目录首扇区 计算
//         ③ 根目录逐条 32B 目录项扫描: 跳过 LFN(0x0F)/目录/已删除(0xE5),
//            按 WELd / QUIZd / ALMd 前缀匹配 + ".BMP" 扩展名
//         ④ 物理起始 LBA = 数据区起始 + (首簇-2)*扇区/簇
//         ⑤ 产出 zone_start = min, zone_wrap = max+8, zone_max_img = count
//         ⑥ 应急区无 ALM*.BMP → 自动回退抢答区(与 10-4 口径 Z_ALARM=Z_QUIZ 一致)
//         ⑦ 完全没匹配到 → zone_err=1 且回退 10-4 兜底常量(行为不回退)
//         ⑧ 负例: Windows 长名残留 "WEL1~1.BMP" 的 8.3 短名 "WEL1~1  "
//            必须【不匹配】(若去掉 n4==空格 的过滤, 本用例会 FAIL)
//
// 假卡几何(8KB 簇 = 16 扇区/簇, 与真实卡一致):
//   分区起始 LBA = 64, 保留扇区 32, 1 个 FAT, FAT32 表长 1000 扇区
//   → 数据区起始 = 64+32+1000 = 1096, 根目录首簇 = 2 → 根目录首扇区 1096
//
//   目录项        主名(8.3)      首簇    物理 LBA = 1096+(簇-2)*16
//   WEL1.BMP      "WEL1    "      2       1096
//   WEL2.BMP      "WEL2    "     31       1560
//   WEL3.BMP      "WEL3    "    144       3368
//   WEL4.BMP      "WEL4    "    433       7992
//   WEL5.BMP      "WEL5    "    462       8456
//   WEL6.BMP      "WEL6    "    575      10264
//   QUIZ1.BMP     "QUIZ1   "    700      12264
//   → WEL 区: start=1096  wrap=10264+8=10272  max=6
//   → QUIZ 区: start=12264 wrap=12272          max=1
//
// 语言: 纯 Verilog-2001; 无厂商原语依赖。
//====================================================================
module tb_fat32_lookup;

    reg         clk;
    reg         rst;
    reg         sd_init_done;
    reg  [2:0]  zone_sel;
    reg         start_req;

    wire        sd_sec_read;
    wire [31:0] sd_sec_read_addr;
    reg  [7:0]  sd_data;
    reg         sd_dvalid;
    wire        sd_end;                 // 由 SD 模型组合产生(单拍, 与 dvalid 不重叠)

    wire [31:0] zone_start, zone_wrap, zone_max_img;
    wire        tbl_ready, zone_err, busy;

    integer     fails;

    //--------------------------------------------------------------
    // 时钟 / 复位
    //--------------------------------------------------------------
    initial clk = 1'b0;
    always #5 clk = ~clk;               // 100 MHz

    //--------------------------------------------------------------
    // DUT
    //--------------------------------------------------------------
    fat32_lookup #(
        .CLK_FREQ_HZ (32'd100_000_000),
        .TIMEOUT_MS  (32'd100),
        .MAX_DIR_SEC (32'd32)
    ) dut (
        .clk                    (clk              ),
        .rst                    (rst              ),
        .sd_init_done           (sd_init_done     ),
        .zone_sel               (zone_sel         ),
        .start_req              (start_req        ),
        .sd_sec_read            (sd_sec_read      ),
        .sd_sec_read_addr       (sd_sec_read_addr ),
        .sd_sec_read_data       (sd_data          ),
        .sd_sec_read_data_valid (sd_dvalid        ),
        .sd_sec_read_end        (sd_end           ),
        .zone_start             (zone_start       ),
        .zone_wrap              (zone_wrap        ),
        .zone_max_img           (zone_max_img     ),
        .tbl_ready              (tbl_ready        ),
        .zone_err               (zone_err         ),
        .busy                   (busy             )
    );

    //--------------------------------------------------------------
    // 假卡镜像
    //--------------------------------------------------------------
    reg [7:0] mbr [0:511];
    reg [7:0] bpb [0:511];
    reg [7:0] root[0:1023];             // 根目录 2 个扇区
    reg       nomatch;                  // 1 = 换成"卡上没有任何合规素材"

    localparam [31:0] PART_LBA   = 32'd64;
    localparam [31:0] DATA_START = 32'd1096;
    localparam [31:0] ROOT_LBA   = 32'd1096;

    // 写一条 32B 目录项到 root[] 偏移 base
    task put_ent;
        input integer    base;
        input [63:0]     nm;            // 8 字节主名(nm[63:56] = 第 0 字节)
        input [23:0]     ext;           // 3 字节扩展名(ext[23:16] = 第 0 字节)
        input [7:0]      attr;
        input [15:0]     clhi;
        input [15:0]     cllo;
        input [31:0]     size;
        integer i;
        begin
            for (i = 0; i < 32; i = i + 1) root[base + i] = 8'h00;
            for (i = 0; i < 8;  i = i + 1) root[base + i]     = nm[8*(7-i) +: 8];
            for (i = 0; i < 3;  i = i + 1) root[base + 8 + i] = ext[8*(2-i) +: 8];
            root[base + 11] = attr;
            root[base + 20] = clhi[7:0];
            root[base + 21] = clhi[15:8];
            root[base + 26] = cllo[7:0];
            root[base + 27] = cllo[15:8];
            root[base + 28] = size[7:0];
            root[base + 29] = size[15:8];
            root[base + 30] = size[23:16];
            root[base + 31] = size[31:24];
        end
    endtask

    // 写一条"占位"目录项(主名以空格开头, 绝不会被匹配, 但也不是 0x00 结束项)
    task put_filler;
        input integer base;
        integer i;
        begin
            for (i = 0; i < 32; i = i + 1) root[base + i] = 8'h00;
            root[base + 0]  = 8'h20;
            root[base + 11] = 8'h20;
        end
    endtask

    // 构造假卡
    task build_card;
        integer i;
        begin
            for (i = 0; i < 512;  i = i + 1) begin mbr[i] = 8'h00; bpb[i] = 8'h00; end
            for (i = 0; i < 1024; i = i + 1) root[i] = 8'h00;

            // ---- MBR: 分区项 0 的起始 LBA(偏移 454..457, 小端) + 签名 0x55AA ----
            mbr[446] = 8'h80;                       // bootable(仅示意)
            mbr[450] = 8'h0C;                       // 类型 FAT32 LBA
            mbr[454] = PART_LBA[7:0];
            mbr[455] = PART_LBA[15:8];
            mbr[456] = PART_LBA[23:16];
            mbr[457] = PART_LBA[31:24];
            mbr[510] = 8'h55;
            mbr[511] = 8'hAA;

            // ---- BPB(分区引导扇区) ----
            bpb[11] = 8'h00; bpb[12] = 8'h02;       // 512 字节/扇区
            bpb[13] = 8'd16;                        // 16 扇区/簇 = 8KB
            bpb[14] = 8'd32; bpb[15] = 8'h00;       // 保留扇区数 = 32
            bpb[16] = 8'd1;                         // FAT 个数 = 1
            bpb[36] = 8'hE8; bpb[37] = 8'h03;       // FAT32 表长 = 1000 扇区
            bpb[38] = 8'h00; bpb[39] = 8'h00;
            bpb[44] = 8'd2;                         // 根目录首簇 = 2
            bpb[45] = 8'h00; bpb[46] = 8'h00; bpb[47] = 8'h00;

            if (nomatch) begin
                // 卡上一个合规素材都没有
                put_ent   (0*32, "README  ", "TXT", 8'h20, 16'd0, 16'd3, 32'd40);
                // 其余保持 0x00 → 第 1 条之后立即遇结束项
            end
            else begin
                // ---- 根目录: 第 0 条故意放 LFN(必须被跳过) ----
                put_ent   (0*32, "AAAAAAA ", "   ", 8'h0F, 16'd0, 16'd0, 32'd0);
                // ---- WEL1..WEL6(簇号均 < 65536, 故高位恒 0, 全部落在 cllo) ----
                put_ent   (1*32, "WEL1    ", "BMP", 8'h20, 16'd0, 16'd2,   32'd921654); // → 1096
                put_ent   (2*32, "README  ", "TXT", 8'h20, 16'd0, 16'd9,   32'd40    );
                // 负例: Windows 长名残留 → 短名 "WEL1~1  " 必须不匹配
                put_ent   (3*32, "WEL1~1  ", "BMP", 8'h20, 16'd0, 16'd999, 32'd921654);
                put_ent   (4*32, "WEL2    ", "BMP", 8'h20, 16'd0, 16'd31,  32'd921654); // → 1560
                put_ent   (5*32, "WEL3    ", "BMP", 8'h20, 16'd0, 16'd144, 32'd2359350); // → 3368
                put_ent   (6*32, "WEL4    ", "BMP", 8'h20, 16'd0, 16'd433, 32'd230454); // → 7992
                put_ent   (7*32, "WEL5    ", "BMP", 8'h20, 16'd0, 16'd462, 32'd921654); // → 8456
                put_ent   (8*32, "WEL6    ", "BMP", 8'h20, 16'd0, 16'd575, 32'd2359350);// → 10264
                put_ent   (9*32, "QUIZ1   ", "BMP", 8'h20, 16'd0, 16'd700, 32'd921654); // → 12264
                // ---- 第 10..19 条占位(保证扫描跨到第 2 个扇区) ----
                for (i = 10; i < 20; i = i + 1) put_filler(i*32);
                // 第 20 条: 目录结束项(全 0) —— root[] 已清零, 无需再写
            end
        end
    endtask

    // 假卡按 (LBA, 扇区内偏移) 取字节
    function [7:0] card_byte;
        input [31:0] lba;
        input integer off;
        begin
            card_byte = 8'h00;
            if (lba == 32'd0)
                card_byte = mbr[off];
            else if (lba == PART_LBA)
                card_byte = bpb[off];
            else if ((lba >= ROOT_LBA) && (lba < (ROOT_LBA + 32'd2)))
                card_byte = root[(lba - ROOT_LBA)*512 + off];
        end
    endfunction

    //--------------------------------------------------------------
    // 简易 SD 扇区读模型 —— 【按真机 sd_card_sec_read_write 的行为建模】
    //
    //   真机(sd_card_sec_read_write.v):
    //     · sd_sec_read 是【电平】, 一直在拉高就表示"还要下一个扇区";
    //     · S_WAIT_READ_WRITE 在 sd_sec_read=1 那拍把 sd_sec_read_addr
    //       锁进 sec_addr, 然后走 CMD17 → S_READ(吐 512B) → S_READ_END;
    //     · sd_sec_read_end = (state==S_READ_END), 单拍, 且该拍 dvalid=0
    //       (dvalid 只在 S_READ)。两者【绝不重叠】;
    //     · 读完固定回 S_WAIT_READ_WRITE —— 请求仍为高就立刻读下一扇区,
    //       请求撤销就停在那等。
    //
    //   ★ 两条必须照抄的细节(本 tb 曾因此连挂三轮):
    //     ① 地址是"进入读状态那一拍"锁的 ⇒ 请求方在 end 那拍更新地址,
    //        本模型必须在【end 之后的下一拍】才锁, 同拍锁会拿到旧地址;
    //     ② end 必须与该扇区最后一字节【错开一拍】, 不能同拍(真机不同拍)。
    //       一旦叠在一拍, DUT 会同时看到 byte_v 与 read_end。
    //   ★ 另一条同样关键: 绝不能因为"请求撤销"就中途丢弃已开始的扇区 ——
    //     真机一旦 S_CMD17 发出就必定读完 512B 再回 WAIT。本模型照做。
    //--------------------------------------------------------------
    localparam [2:0] ST_WAIT = 3'd0, ST_RD = 3'd1, ST_DONE = 3'd2;
    reg  [2:0]  st;
    reg  [31:0] cur_lba;
    integer     off;

    assign sd_end = (st == ST_DONE);        // 单拍, 与 dvalid 不重叠

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            st        <= ST_WAIT;
            sd_dvalid <= 1'b0;
            off       <= 0;
            cur_lba   <= 32'd0;
            sd_data   <= 8'h00;
        end
        else begin
            case (st)
            // 真机 S_WAIT_READ_WRITE: 请求电平为高 → 同拍锁地址, 开始读
            ST_WAIT: begin
                sd_dvalid <= 1'b0;
                if (sd_sec_read) begin
                    cur_lba   <= sd_sec_read_addr;
                    off       <= 0;
                    sd_dvalid <= 1'b1;
                    sd_data   <= card_byte(sd_sec_read_addr, 0);
                    st        <= ST_RD;
                end
            end
            // 真机 S_READ: 连续吐 512 字节(第 off 字节在本拍)
            ST_RD: begin
                if (off == 511) begin
                    sd_dvalid <= 1'b0;
                    st        <= ST_DONE;
                end
                else begin
                    off       <= off + 1;
                    sd_dvalid <= 1'b1;
                    sd_data   <= card_byte(cur_lba, off + 1);
                end
            end
            // 真机 S_READ_END: 单拍 end
            ST_DONE: begin
                sd_dvalid <= 1'b0;
                st        <= ST_WAIT;
            end
            default: st <= ST_WAIT;
            endcase
        end
    end

    //--------------------------------------------------------------
    // 诊断轨迹: 逐条打印"读了哪个扇区 + 由哪个状态发起"
    //   正常一次查找应为:
    //     迎新区  lba=0(S_MBR) → 64(S_BPB) → 1096,1097(S_ROOT)
    //     抢答区  同上(S_ROOT 内容不同)
    //     应急区  先 ALM 扫一遍 → 无命中再重扫 QUIZ(故 S_ROOT 出现两组)
    //   若出现 S_ROOT 重入而实际没命中、或读到与预期无关的 LBA,
    //   都是寻址层故障的直接证据。
    //--------------------------------------------------------------
    initial begin
        forever begin
            @(posedge clk);
            if ((st === ST_WAIT) && (sd_sec_read === 1'b1))
                $display("  [RD] lba=%0d  dut_st=%0d", sd_sec_read_addr, dut.state);
        end
    end

    //--------------------------------------------------------------
    // 检查任务
    //--------------------------------------------------------------
    task check;
        input [255:0] tag;
        input [31:0]  e_start, e_wrap, e_max, e_err;
        begin
            $display("       dbg: part=%0d mbrsig=%0d data_start=%0d root_lba=%0d l2=%0d bad=%0d cnt=%0d mn=%0d mx=%0d",
                     dut.part_entry, dut.mbr_sig, dut.data_start, dut.root_lba,
                     dut.l2, dut.bad, dut.cnt, dut.mn, dut.mx);
            if ((zone_start === e_start) && (zone_wrap === e_wrap) &&
                (zone_max_img === e_max) && (zone_err === e_err)) begin
                $display("[PASS] %0s  start=%0d wrap=%0d max=%0d err=%0d",
                         tag, zone_start, zone_wrap, zone_max_img, zone_err);
            end
            else begin
                fails = fails + 1;
                $display("[FAIL] %0s", tag);
                $display("        got start=%0d wrap=%0d max=%0d err=%0d",
                         zone_start, zone_wrap, zone_max_img, zone_err);
                $display("        exp start=%0d wrap=%0d max=%0d err=%0d",
                         e_start, e_wrap, e_max, e_err);
            end
        end
    endtask

    // 触发一次查找并等它收尾
    task run_lookup;
        input [2:0] sel;
        begin
            @(negedge clk);
            zone_sel  = sel;
            start_req = 1'b1;
            @(negedge clk);
            start_req = 1'b0;
            wait (busy === 1'b1);
            while (busy === 1'b1) @(posedge clk);
            @(negedge clk);
        end
    endtask

    //--------------------------------------------------------------
    // 看门狗: 任何卡死(状态机不进、握手不完成)都在 2ms 内收尾,
    //         保证批处理仿真不会挂在 ModelSim 提示符上
    //--------------------------------------------------------------
    initial begin
        #2_000_000;
        $display("[WDOG] 仿真超时 —— 状态机疑似卡死");
        $display("==== 有 %0d 项 FAIL (含超时) ====", fails + 1);
        $finish;
    end

    //--------------------------------------------------------------
    // 主流程
    //--------------------------------------------------------------
    initial begin
        fails       = 0;
        rst         = 1'b1;
        sd_init_done= 1'b0;
        zone_sel    = 3'd0;
        start_req   = 1'b0;
        nomatch     = 1'b0;

        build_card();

        #200;
        rst          = 1'b0;
        #100;
        sd_init_done = 1'b1;
        #100;

        $display("");
        $display("========== fat32_lookup 专项仿真 ==========");

        // ---- 正常卡 ----
        run_lookup(3'd1); check("WEL  迎新区(sel=1)",       32'd1096,  32'd10272, 32'd6, 1'b0);
        run_lookup(3'd0); check("WEL  菜单位(sel=0)",       32'd1096,  32'd10272, 32'd6, 1'b0);
        run_lookup(3'd2); check("WEL  预留位(sel=2)",       32'd1096,  32'd10272, 32'd6, 1'b0);
        run_lookup(3'd3); check("QUIZ 抢答区(sel=3)",       32'd12264, 32'd12272, 32'd1, 1'b0);
        run_lookup(3'd4); check("ALM  应急区→回退抢答区",   32'd12264, 32'd12272, 32'd1, 1'b0);

        // ---- 换成"没有任何合规素材"的卡: 必须回退兜底常量 ----
        //   ★ 2026-10-07: 兜底常量随卡侧整卡重排更新, 断言同步(原 15936/25352/6
        //     与 10368/12224/1 → 8512/22592/6 与 22592/31872/5)。
        nomatch = 1'b1;
        build_card();                       // ★ 必须重建: build_card 用 nomatch 决定目录内容
        run_lookup(3'd1); check("兜底 迎新区(无素材)",      32'd8512,  32'd22592, 32'd6, 1'b1);
        run_lookup(3'd3); check("兜底 抢答区(无素材)",      32'd22592, 32'd31872, 32'd5, 1'b1);
        run_lookup(3'd4); check("兜底 应急区(无素材)",      32'd22592, 32'd31872, 32'd5, 1'b1);

        // ---- 汇总 ----
        $display("");
        if (fails == 0) $display("==== 全部 PASS (0 FAIL) ====");
        else            $display("==== 有 %0d 项 FAIL ====", fails);
        $display("");
        $finish;
    end

endmodule
