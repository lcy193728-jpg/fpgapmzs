`timescale 1ns/1ps
//====================================================================
// 模块名 : fat32_lookup.v —— FAT32 文件名寻址层(v11)
//
// 目的(替代 top_final.v 里的硬编码 Z_* 分区常量):
//   上电 / 场景切换时读一次 TF 卡根目录, 按【文件名前缀】找出本场景的
//   BMP, 算出 bmp_read_auto 需要的三个数(zone_start / zone_wrap /
//   zone_max_img)。以后往卡上加/删/换图片, 只按约定改名即可 ——
//   不必再跑 find_bmp.py 重算扇区, 更不必重新综合生成位流。
//
// 与 10-4 版的关系:
//   10-4 版用的是"扫描工具算好的固定扇区常量"。本模块把这些常量换成
//   "目录查表"。改名不会移动簇 → 卡上文件物理位置不变 → 查表结果与
//   兜底常量一致(可交叉验证)。
//   万一查表失败(卡没改名 / 不是 FAT32 / 目录读不到), 自动回退到兜底
//   常量并置 zone_err=1 —— 行为绝不比改造前差。
//
// ★ 2026-10-07 卡侧整卡重排(用户要求"删掉没用的 + 加新队图 + 命名好"):
//   卡上 15 个旧名文件(1_MEET/2_QUIZ/3_EXTRA/4_EXTRA/W1_320A../MENU/EM_0..3)
//   已全部删除, 重写为 11 个规范短名, 由 FAT32 顺序分配 → 物理完全连续:
//     WEL1.BMP .. WEL6.BMP  = 物理 LBA  8512 .. 22591 (含 320/640/1024 多分辨率)
//     QUIZ1.BMP .. QUIZ5.BMP = 物理 LBA 22592 .. 31871
//       QUIZ1 = 抢答内容图, QUIZ2..5 = 1..4 号队伍图(红/蓝/绿/黄)
//       → 与 quiz_scene_ctrl 的 jump_idx = winner+1(0基) 对应
//   旧文件镜像备份在 _card_backup_20261007/all_bmp/(含 SHA256SUMS.txt)。
//
// 读卡流程(与 bmp_read_auto 共用 sd_card_top 那一条 SPI, 经 audio_sd_arbiter
// 的 A 侧逐扇区仲裁; 本模块读卡期间 sd_card_bmp 会把 bmp_go 钉 0, 即
// bmp_read_auto 停在 S_IDLE 安全窗口, 两者不会同时抢地址):
//   ① LBA0      → MBR 分区表(偏移 454..457) → 分区起始 LBA(part_lba)
//                  ※ 签名 0x55AA 不成立时按"超级软盘"处理: part_lba = 0
//   ② part_lba  → BPB: 字节/扇区、扇区/簇、保留扇区数、FAT 个数、
//                  FAT32 表长 → 数据区起始, 根目录首簇 → 根目录首扇区
//   ③ 根目录(最多 MAX_DIR_SEC 个扇区, 遇 0x00 目录项提前结束)
//        · 每 32B 一条目录项; 跳过 LFN(attr&0x0F==0x0F)、目录项、已删除(0xE5)
//        · 按前缀匹配 8.3 短名: WELd / QUIZd / ALMd(d=1..9) + 扩展名 BMP
//        · 命中: 物理起始 LBA = 数据区起始 + (首簇-2) * 扇区/簇
//        · 只累计 count / min / max(不排序, 轮播顺序 = 物理顺序)
//   ④ 产出 zone_start = min, zone_wrap = max + 8, zone_max_img = count
//
// ★ 为什么没有"虚拟扇区号 → 物理 LBA"翻译层(与方案 v11 原文的差异):
//   ① 仲裁器 audio_sd_arbiter 要求扇区地址在授权当拍【组合稳定】(其头注释
//      明确写"地址不能打拍")。翻译层必须组合插到 bmp_read_auto 的地址输出
//      上, 而 SD 域(clk1, 100MHz)余量恒在 +0.1x ns —— 那正是本工程历史上
//      "时序报告全绿、板上照样花屏"的位置。在它前面再叠"32bit 比较 +
//      多路选择 + 32bit 加法"是不可接受的时序风险。
//   ② 而且翻译层并不能解决"夹花": 扫描是在虚拟空间里连续前进的, 若两张
//      本场景图片之间物理上夹着别的 BMP, 扫描照样会把它当成下一张。翻译层
//      只能解决"物理顺序与文件名顺序不一致"这一种情形。
//   ③ 本模块改用 min/max ⇒ 轮播顺序 = 物理顺序(与 10-4 完全一致, 无功能回退)。
//   结论: 本模块【直接产出物理分区】, bmp_read_auto 一行未改, SD 地址通路
//         零新增组合逻辑。详见交付说明「与方案的差异」一节。
//
// 文件名约定(严格 8.3 大写短名, 放卡根目录):
//   迎新  WEL1.BMP … WEL8.BMP      抢答  QUIZ1.BMP …
//   应急  ALM1.BMP …                菜单/预留位复用迎新区素材作底图
//   ⚠ Windows 拷文件可能生成 WEL1~1.BMP 这类长名残留 → 匹配失败。
//     此时不静默黑屏: 置 zone_err=1 并回退 10-4 兜底常量。
//   ⚠ BMP 规格不变: 640×480(或 320×240 / 1024×768 / 1280×960) × 24bit、
//     非压缩、正高度 —— 多分辨率轮播能力原样保留。
//
// 语言: 纯 Verilog-2001。
//====================================================================

module fat32_lookup #(
    parameter [31:0] CLK_FREQ_HZ = 32'd100_000_000,   // 本模块时钟 = sd_card_clk
    parameter [31:0] TIMEOUT_MS  = 32'd100,           // 连续无字节进展超时(ms)
    parameter [31:0] MAX_DIR_SEC = 32'd32             // 根目录最多读几个扇区(32 扇区=512 项)
)(
    input               clk,                    // sd_card_clk(100MHz)
    input               rst,                    // 高有效复位
    input               sd_init_done,           // sd_card_top 原始初始化完成(未门控)
    input      [2:0]    zone_sel,               // 0菜单 1迎新 2预留 3抢答 4应急
    input               start_req,              // 单周期脉冲: 启动一次查找
    // ---- SD 扇区读口(接 sd_card_bmp 内的 audio_sd_arbiter A 侧) ----
    output reg          sd_sec_read,            // 读请求(电平, 保持整个扇区)
    output reg  [31:0]  sd_sec_read_addr,       // 扇区地址
    input      [7:0]    sd_sec_read_data,       // 扇区数据(字节)
    input               sd_sec_read_data_valid, // 数据有效
    input               sd_sec_read_end,        // 本扇区读完
    // ---- 结果(仅 tbl_ready=1 时有效) ----
    output reg  [31:0]  zone_start,             // 本场景扫描起点(物理 LBA)
    output reg  [31:0]  zone_wrap,              // 本场景扫描上限(= 最大起点 + 8)
    output reg  [31:0]  zone_max_img,           // 本场景图片张数
    output reg          tbl_ready,              // 段表已就绪(可下发 zone_load)
    output reg          zone_err,               // 1=未匹配到文件(已回退兜底常量)
    output              busy                    // 1=正在读卡(此时 bmp_go 被钉 0)
);

    localparam [31:0] TIMEOUT_CYCLES = TIMEOUT_MS * (CLK_FREQ_HZ / 32'd1000);

    localparam [2:0] S_IDLE = 3'd0,
                     S_MBR  = 3'd1,
                     S_BPB  = 3'd2,
                     S_ROOT = 3'd3,
                     S_FIN  = 3'd4;

    // ---- 兜底常量: 查表未命中时使用(正常走 FAT32 查表, 不取这里) ----
    //   ★ 2026-10-07 整卡重排后按【实测落点】更新(原为 10-4 口径 15936/10368):
    //     卡上 11 张图经"删除全部→按序拷入"后由 FAT32 顺序分配, 物理完全连续:
    //       WEL1..6  8512..22591   QUIZ1..5  22592..31871
    //     即使查表失败回退到这组常量, 也能正确扫到对应分区。
    //   ⚠ 换卡/重排素材后必须重跑 tools/find_bmp.py 并同步这四个值。
    localparam [31:0] FB_WEL_START = 32'd8512,  FB_WEL_WRAP = 32'd22592, FB_WEL_IMGS = 32'd6;
    localparam [31:0] FB_QZ_START  = 32'd22592, FB_QZ_WRAP  = 32'd31872, FB_QZ_IMGS  = 32'd5;

    reg  [2:0]  state;
    reg  [31:0] lba;
    reg  [31:0] to_cnt;
    reg  [9:0]  bidx;               // 扇区内字节序号 0..511
    reg  [31:0] w;                  // 最近 4 字节滑窗(小端拼接用)
    reg  [255:0] e_sh;              // 目录项 32B 移位寄存器
    reg  [255:0] ent;               // 组装完成的目录项
    reg         ent_v;              // 目录项完成标志(单拍)

    reg  [1:0]  pfx;                // 目标前缀: 0=WEL 1=QUIZ 2=ALM
    reg         alt_quiz;           // 应急区已回退用抢答区(防二次回退)
    reg         pend;               // 查找期间又来的请求(结束后补做一次)

    reg  [31:0] part_entry;         // MBR 分区项里的起始 LBA
    reg         mbr_sig;            // MBR 签名 0x55AA 有效
    reg  [31:0] data_start;         // FAT32 数据区起始扇区
    reg  [31:0] root_lba;           // 根目录首扇区
    reg  [4:0]  l2;                 // log2(扇区/簇), 物理簇号→扇区偏移用
    reg  [31:0] dsec;               // 已读根目录扇区数
    reg  [31:0] cnt, mn, mx;        // 命中张数 / 最小 LBA / 最大 LBA
    reg         dir_end;            // 遇到 0x00 目录项(目录结束)

    // ---- v11 时序流水寄存器(把两条 10 级组合长链拆开, 功能不变) ----
    reg  [31:0] bp_ft, bp_db, bp_rb;// S_BPB: fats_tot/data_base/root_base 三级流水
    reg  [31:0] data_adj;           // = data_start - (2<<l2): 把"簇号-2"并进基址
    reg  [31:0] phys_q;             // 目录项物理 LBA(打一拍)
    reg         hit_q;              // 目录项命中(打一拍, 与 phys_q 对齐)
    reg  [1:0]  bad;                // 0=正常 1=BPB 异常 2=超时

    // BPB 字段捕获
    reg  [31:0] bps;                // 字节/扇区(必须 512)
    reg  [7:0]  spc;                // 扇区/簇(必须 2 的幂)
    reg  [31:0] reserved;           // 保留扇区数
    reg  [7:0]  nfats;              // FAT 个数(1 或 2)
    reg  [31:0] fat_sz32;           // FAT32 表长(扇区)
    reg  [31:0] root_cluster;       // 根目录首簇(必须 >= 2)

    //--------------------------------------------------------------
    // 组合部分
    //--------------------------------------------------------------
    wire        byte_v = sd_sec_read_data_valid;
    wire [7:0]  din    = sd_sec_read_data;

    // log2(扇区/簇): 只支持 2 的幂(1..128), 由 bpb_ok 保证合法
    function [4:0] log2b;
        input [7:0] s;
        begin
            case (s)
                8'd1:   log2b = 5'd0;
                8'd2:   log2b = 5'd1;
                8'd4:   log2b = 5'd2;
                8'd8:   log2b = 5'd3;
                8'd16:  log2b = 5'd4;
                8'd32:  log2b = 5'd5;
                8'd64:  log2b = 5'd6;
                8'd128: log2b = 5'd7;
                default:log2b = 5'd0;
            endcase
        end
    endfunction

    // 8.3 短名的数字位(只认 '1'..'9'; '0' 不用, 避免 WEL0 造成歧义)
    function [0:0] dig;
        input [7:0] c;
        begin
            dig = (c >= 8'h31) && (c <= 8'h39);
        end
    endfunction

    wire        bpb_ok = (bps == 32'd512)
                      && (nfats == 8'd1 || nfats == 8'd2)
                      && (spc != 8'd0) && (spc <= 8'd128)
                      && ((spc & (spc - 8'd1)) == 8'd0)
                      && (fat_sz32 != 32'd0)
                      && (root_cluster >= 32'd2);

    //★ 时序: BPB 派生地址 nfats→fats_tot→data_base→root_base 原本是"32bit 加法×3"
    //   (Level 10 / ADDER=6), 直连 sd_sec_read_addr 的 D 必然违例。
    //   这里改成【S_BPB 期间按 byte_v 逐级推进的 3 级流水】, 每级 D 只接寄存器:
    //     级1 bp_ft ← fats_tot               (nfats/fat_sz32 已捕获于 bidx 16/39)
    //     级2 bp_db ← part_entry+reserved+bp_ft   (part_entry 来自 MBR, reserved 于 bidx 15)
    //     级3 bp_rb ← bp_db + ((root_cluster-2)<<l2) (root_cluster 于 bidx 47, spc 于 bidx 13)
    //   全部字段在 bidx=47 前就位 ⇒ 3 拍后(≈bidx 50)三级已稳定, 而 sd_sec_read_end
    //   要到 bidx 511 之后 ⇒ 取值时刻余量 460+ 字节, 与周期数无关, 稳健。
    wire [31:0] fats_tot  = (nfats == 8'd2) ? (fat_sz32 << 1) : fat_sz32;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            bp_ft <= 32'd0; bp_db <= 32'd0; bp_rb <= 32'd0;
        end
        else if (byte_v && (state == S_BPB)) begin
            bp_ft <= fats_tot;
            bp_db <= part_entry + reserved + bp_ft;
            bp_rb <= bp_db + ((root_cluster - 32'd2) << log2b(spc));
        end
    end

    // ---- 目录项字段(小端) ----
    //   e_sh 是【左移】寄存器: e_sh <= {e_sh[247:0], din} ⇒ 全部 32 字节装入后,
    //   第 i 字节落在 ent[255-8i -: 8] (第 0 字节在最高位)。
    //   多字节字段必须按【小端】显式拼: 低地址字节 = 低位。
    wire [7:0]  b00 = ent[255:248];   // 主名 [0..7]
    wire [7:0]  b01 = ent[247:240];
    wire [7:0]  b02 = ent[239:232];
    wire [7:0]  b03 = ent[231:224];
    wire [7:0]  b04 = ent[223:216];
    wire [7:0]  b05 = ent[215:208];
    wire [7:0]  b08 = ent[191:184];   // 扩展名 [8..10]
    wire [7:0]  b09 = ent[183:176];
    wire [7:0]  b10 = ent[175:168];
    wire [7:0]  b11 = ent[167:160];   // 属性
    wire [7:0]  b20 = ent[95:88];     // 首簇高 16 位 [20,21]
    wire [7:0]  b21 = ent[87:80];
    wire [7:0]  b26 = ent[47:40];     // 首簇低 16 位 [26,27]
    wire [7:0]  b27 = ent[39:32];
    wire [7:0]  b28 = ent[31:24];     // 文件长度 [28..31]
    wire [7:0]  b29 = ent[23:16];
    wire [7:0]  b30 = ent[15:8];
    wire [7:0]  b31 = ent[7:0];

    wire [7:0]  n0 = b00, n1 = b01, n2 = b02, n3 = b03, n4 = b04, n5 = b05;
    wire [7:0]  x0 = b08, x1 = b09, x2 = b10;
    wire [7:0]  at = b11;
    wire [15:0] cl_hi = {b21, b20};      // 16 位: 必须两字节都取
    wire [15:0] cl_lo = {b27, b26};
    wire [31:0] fsz   = {b31, b30, b29, b28};

    wire       name_ok = (x0==8'h42) && (x1==8'h4D) && (x2==8'h50);       // "BMP"
    wire       attr_ok = (at[3:0] != 4'hF) && (at[4] == 1'b0);            // 非 LFN / 非目录
    wire       live_ok = (n0 != 8'h00) && (n0 != 8'hE5);                  // 非结束 / 非已删除
    //   ★ 8.3 主名剩余位必须是空格: 既排除 Windows 自动编号产生的长名残留
    //     (WEL1~1.BMP 的短名是 "WEL1~1  ", n4='~' → 不匹配), 也排除了
    //     自定义后缀(WEL1A.BMP / WEL10.BMP, 本设计只支持 WEL1..WEL9)。
    wire       m_wel   = (n0==8'h57)&&(n1==8'h45)&&(n2==8'h4C)&& dig(n3) && (n4==8'h20); // "WEL"+d
    wire       m_quiz  = (n0==8'h51)&&(n1==8'h55)&&(n2==8'h49)&&(n3==8'h5A)&& dig(n4)
                       && (n5==8'h20);                                                  // "QUIZ"+d
    wire       m_alm   = (n0==8'h41)&&(n1==8'h4C)&&(n2==8'h4D)&& dig(n3) && (n4==8'h20); // "ALM"+d
    wire       m_sel   = (pfx==2'd0) ? m_wel :
                         (pfx==2'd1) ? m_quiz : m_alm;

    wire [31:0] cl  = {cl_hi, cl_lo};
    //★ 时序: 原式 phys = data_start + ((cl - 2) << l2) 是"32bit 借位链 + 桶形移位
    //   + 32bit 加法", 再加 hit 里的 (cl>=32'd2)/(fsz!=32'd0) 两个 32bit 比较,
    //   直连 mn/mx 的 .ce 共 10 级组合(6 ADDER), 超 C9(≤8 级)。改为:
    //     · 簇号减 2 事先并进 data_adj ⇒ phys 只剩【移位 + 一次加法】;
    //     · hit / phys 各打一拍, 下一拍再做 min/max 比较与计数 ⇒ .ce 只接寄存器。
    wire [31:0] phys = (cl << l2) + data_adj;

    wire       hit  = live_ok && name_ok && attr_ok && m_sel
                   && (fsz != 32'd0) && (cl >= 32'd2);

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            phys_q <= 32'd0;
            hit_q  <= 1'b0;
        end
        else begin
            phys_q <= phys;
            hit_q  <= ent_v && (state == S_ROOT) && hit;
        end
    end

    assign busy = (state != S_IDLE);

    //--------------------------------------------------------------
    // 时序部分
    //--------------------------------------------------------------
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state            <= S_IDLE;
            sd_sec_read      <= 1'b0;
            sd_sec_read_addr <= 32'd0;
            to_cnt           <= 32'd0;
            bidx             <= 10'd0;
            w                <= 32'd0;
            e_sh             <= 256'd0;
            ent              <= 256'd0;
            ent_v            <= 1'b0;
            pfx              <= 2'd0;
            alt_quiz         <= 1'b0;
            pend             <= 1'b0;
            part_entry       <= 32'd0;
            mbr_sig          <= 1'b0;
            data_start       <= 32'd0;
            data_adj         <= 32'd0;
            root_lba         <= 32'd0;
            l2               <= 5'd0;
            dsec             <= 32'd0;
            cnt              <= 32'd0;
            mn               <= 32'hFFFFFFFF;
            mx               <= 32'd0;
            dir_end          <= 1'b0;
            bad              <= 2'd0;
            bps              <= 32'd0;
            spc              <= 8'd0;
            reserved         <= 32'd0;
            nfats            <= 8'd0;
            fat_sz32         <= 32'd0;
            root_cluster     <= 32'd0;
            zone_start       <= FB_WEL_START;
            zone_wrap        <= FB_WEL_WRAP;
            zone_max_img     <= FB_WEL_IMGS;
            tbl_ready        <= 1'b0;
            zone_err         <= 1'b0;
        end
        else begin
            ent_v <= 1'b0;

            // 查找期间到来的请求: 结束后补做一次(避免用户切场景被吞掉)
            if (start_req && (state != S_IDLE))
                pend <= 1'b1;

            //--------------------------------------------------
            // 字节流: 4 字节滑窗 + 目录项装配 + 各阶段字段捕获
            //--------------------------------------------------
            if (byte_v) begin
                w <= {din, w[31:8]};

                if (state == S_ROOT) begin
                    e_sh <= {e_sh[247:0], din};
                    if (bidx[4:0] == 5'd31) begin
                        ent   <= {e_sh[247:0], din};   // 32 字节组装完成
                        ent_v <= 1'b1;
                    end
                end

                // MBR: 分区项 0 的起始 LBA(偏移 454..457, 小端)
                //   ※ w 是右移滑窗(w <= {din, w[31:8]}): 最新字节在 w[31:24],
                //     第 k-1 字节在 w[31:24], k-2 在 w[23:16], k-3 在 w[15:8]。
                //     故 4 字节小端量 = {din, w[31:8]}, 2 字节小端量 = {din, w[31:24]}
                if ((state == S_MBR) && (bidx == 10'd457))
                    part_entry <= {din, w[31:8]};
                // MBR: 签名 0x55AA(偏移 510,511)
                if ((state == S_MBR) && (bidx == 10'd511))
                    mbr_sig <= (w[31:24] == 8'h55) && (din == 8'hAA);

                // BPB 字段(2 字节小端量 = {din, w[31:24]})
                if (state == S_BPB) begin
                    case (bidx)
                        10'd12:  bps          <= {din, w[31:24]};     // 偏移 0x0B(2B 小端)
                        10'd13:  spc          <= din;                // 偏移 0x0D
                        10'd15:  reserved     <= {din, w[31:24]};     // 偏移 0x0E(2B 小端)
                        10'd16:  nfats        <= din;                // 偏移 0x10
                        10'd39:  fat_sz32     <= {din, w[31:8]};      // 偏移 0x24(4B 小端)
                        10'd47:  root_cluster <= {din, w[31:8]};      // 偏移 0x2C(4B 小端)
                        default: ;
                    endcase
                end

                // ★ 扇区内字节序号(★ 必须自增: 上面所有按偏移捕获都靠它定位)
                bidx <= bidx + 10'd1;
            end

            //--------------------------------------------------
            // 目录项判决(命中即累计 min/max/count)
            //   · dir_end 仍在 ent_v 当拍判定(n0 只有 8bit, 零成本、无时序压力)
            //   · 命中判决与物理 LBA 用上一拍打好的 hit_q/phys_q ⇒ .ce 与
            //     min/max 比较都只接寄存器输出, 不再是 10 级长链
            //--------------------------------------------------
            if (ent_v && (state == S_ROOT) && (n0 == 8'h00))
                dir_end <= 1'b1;                     // 目录结束标志

            if (hit_q) begin
                cnt <= cnt + 32'd1;
                if (phys_q < mn) mn <= phys_q;
                if (phys_q > mx) mx <= phys_q;
            end

            //--------------------------------------------------
            // 主状态机
            //--------------------------------------------------
            case (state)
            //------------------------------------------------
            // 空闲: 等初始化完成 + 启动请求
            //------------------------------------------------
            S_IDLE: begin
                if (sd_init_done && (start_req || pend)) begin
                    pend       <= 1'b0;
                    // 目标前缀: 抢答=QUIZ, 应急=ALM(无 ALM 素材时回退 QUIZ),
                    // 菜单(0)/迎新(1)/预留(2) 一律用迎新区素材作底图
                    pfx        <= (zone_sel == 3'd3) ? 2'd1 :
                                  (zone_sel == 3'd4) ? 2'd2 : 2'd0;
                    alt_quiz   <= 1'b0;
                    cnt        <= 32'd0;
                    mn         <= 32'hFFFFFFFF;
                    mx         <= 32'd0;
                    dir_end    <= 1'b0;
                    bad        <= 2'd0;
                    dsec       <= 32'd0;
                    to_cnt     <= 32'd0;
                    bidx       <= 10'd0;
                    w          <= 32'd0;
                    e_sh       <= 256'd0;
                    part_entry <= 32'd0;
                    mbr_sig    <= 1'b0;
                    lba              <= 32'd0;
                    sd_sec_read_addr <= 32'd0;
                    sd_sec_read      <= 1'b1;
                    tbl_ready        <= 1'b0;
                    zone_err         <= 1'b0;
                    state            <= S_MBR;
                end
            end

            //------------------------------------------------
            // MBR(LBA0): 取分区起始 LBA
            //------------------------------------------------
            S_MBR: begin
                if (to_cnt >= TIMEOUT_CYCLES) begin
                    bad <= 2'd2; sd_sec_read <= 1'b0; state <= S_FIN;
                end
                else if (sd_sec_read_end) begin
                    // 无有效 MBR 签名 → 按"超级软盘"处理(引导扇区就在 LBA0)
                    lba              <= mbr_sig ? part_entry : 32'd0;
                    sd_sec_read_addr <= mbr_sig ? part_entry : 32'd0;
                    to_cnt           <= 32'd0;
                    bidx             <= 10'd0;
                    w                <= 32'd0;
                    sd_sec_read      <= 1'b1;
                    state            <= S_BPB;
                end
                else begin
                    to_cnt      <= byte_v ? 32'd0 : (to_cnt + 32'd1);
                    sd_sec_read <= 1'b1;
                end
            end

            //------------------------------------------------
            // BPB(分区引导扇区): 算数据区起始与根目录首扇区
            //------------------------------------------------
            S_BPB: begin
                if (to_cnt >= TIMEOUT_CYCLES) begin
                    bad <= 2'd2; sd_sec_read <= 1'b0; state <= S_FIN;
                end
                else if (sd_sec_read_end) begin
                    if (!bpb_ok) begin
                        bad <= 2'd1; sd_sec_read <= 1'b0; state <= S_FIN;
                    end
                    else begin
                        data_start       <= bp_db;                  // 流水级2 = data_base
                        data_adj         <= bp_db - (32'd2 << log2b(spc));
                        root_lba         <= bp_rb;                  // 流水级3 = root_base
                        l2               <= log2b(spc);
                        lba              <= bp_rb;
                        sd_sec_read_addr <= bp_rb;
                        dsec             <= 32'd0;
                        to_cnt           <= 32'd0;
                        bidx             <= 10'd0;
                        w                <= 32'd0;
                        e_sh             <= 256'd0;
                        sd_sec_read      <= 1'b1;
                        state            <= S_ROOT;
                    end
                end
                else begin
                    to_cnt      <= byte_v ? 32'd0 : (to_cnt + 32'd1);
                    sd_sec_read <= 1'b1;
                end
            end

            //------------------------------------------------
            // 根目录: 顺序读扇区, 逐条 32B 目录项匹配文件名
            //   ※ 假定根目录物理连续(小容量卡根目录通常只占 1 个簇);
            //     遇 0x00 结束项立即收尾, 否则读到 MAX_DIR_SEC 为止。
            //------------------------------------------------
            S_ROOT: begin
                if (to_cnt >= TIMEOUT_CYCLES) begin
                    bad <= 2'd2; sd_sec_read <= 1'b0; state <= S_FIN;
                end
                else if (sd_sec_read_end) begin
                    to_cnt <= 32'd0;
                    bidx   <= 10'd0;
                    w      <= 32'd0;
                    e_sh   <= 256'd0;
                    if (dir_end || ((dsec + 32'd1) >= MAX_DIR_SEC)) begin
                        sd_sec_read <= 1'b0;
                        state       <= S_FIN;
                    end
                    else begin
                        lba              <= lba + 32'd1;
                        sd_sec_read_addr <= sd_sec_read_addr + 32'd1;
                        dsec             <= dsec + 32'd1;
                        sd_sec_read      <= 1'b1;
                    end
                end
                else begin
                    to_cnt      <= byte_v ? 32'd0 : (to_cnt + 32'd1);
                    sd_sec_read <= 1'b1;
                end
            end

            //------------------------------------------------
            // 收尾: 产出分区三参数; 应急区无素材则回退抢答区;
            //       仍未命中 → 回退 10-4 兜底常量(行为不回退)
            //------------------------------------------------
            S_FIN: begin
                if (cnt == 32'd0) begin
                    if ((pfx == 2'd2) && !alt_quiz) begin
                        // 应急区无专属素材: 沿用抢答区底图(与 10-4 的
                        // Z_ALARM_* = Z_QUIZ_* 口径一致)
                        pfx        <= 2'd1;
                        alt_quiz   <= 1'b1;
                        cnt        <= 32'd0;
                        mn         <= 32'hFFFFFFFF;
                        mx         <= 32'd0;
                        dir_end    <= 1'b0;
                        dsec       <= 32'd0;
                        to_cnt     <= 32'd0;
                        bidx       <= 10'd0;
                        w          <= 32'd0;
                        e_sh       <= 256'd0;
                        sd_sec_read_addr <= root_lba;
                        sd_sec_read      <= 1'b1;
                        state            <= S_ROOT;
                    end
                    else begin
                        zone_err <= 1'b1;
                        if (pfx == 2'd1) begin
                            zone_start   <= FB_QZ_START;
                            zone_wrap    <= FB_QZ_WRAP;
                            zone_max_img <= FB_QZ_IMGS;
                        end
                        else begin
                            zone_start   <= FB_WEL_START;
                            zone_wrap    <= FB_WEL_WRAP;
                            zone_max_img <= FB_WEL_IMGS;
                        end
                        tbl_ready   <= 1'b1;
                        sd_sec_read <= 1'b0;
                        state       <= S_IDLE;   // pend 未清 → S_IDLE 会立即补做
                    end
                end
                else begin
                    zone_err     <= 1'b0;
                    zone_start   <= mn;              // 最小物理 LBA = 扫描起点
                    zone_wrap    <= mx + 32'd8;      // 最大起点 + 8(与 10-4 口径同)
                    zone_max_img <= cnt;             // 动态张数: 扫到几张算几张
                    tbl_ready    <= 1'b1;
                    sd_sec_read  <= 1'b0;
                    state        <= S_IDLE;
                end
            end

            default: state <= S_IDLE;
            endcase
        end
    end

endmodule
