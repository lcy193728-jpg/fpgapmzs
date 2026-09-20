`timescale 1ns/1ps
//====================================================================
// 模块名 : meeting_cfg.v —— 会议议程配置存储 + 视频域快照
// 来源   : dev_sim(meeting_scene3_sim) 的 meeting_config.v
//
// 为什么要改写(上板必改):
//   仿真版 meeting_config.v 用 `generate` 直接对 1272 字节寄存器组做
//   324 路"并行可变索引读"(text_mem[282+current*62+g] ...), 综合后会变成
//   几万 LUT 的巨型多路器, 上板放不下。
//   本版改为: **真双口 BRAM(写=sd 域 / 读=video 域) + 视频域快照寄存器**,
//   对外语义与仿真版**完全一致**(每个字段都是"当前 current / notice_sel /
//   overview_index 对应的那一份文本"), 使 meeting_ctrl / meeting_osd 可原样复用。
//
// 快照机制:
//   BRAM 里存原始 MTG1 字节流(偏移与仿真版 text_mem 完全相同):
//     [0..39]    会议名称        [40..79]   主办单位     [80..119] 报到地点
//     [120..279] 注意事项 4 页(每页 40B)
//     [280+i*62 .. 341+i*62] 第 i 项议程: +0/+1=时长(秒,大端) +2..41=名称 +42..61=发言人
//   一旦 current / notice_sel / overview_index 之一变化, 就把对应字段的字节
//   顺序读出并**移入**对应寄存器(先读到的字节落在高位), 与仿真版的位序一致。
//   分组扫描(1 字节/拍), 每组只在"脏"时执行一次:
//     g0  overview_title (40B)  ← 视频域逐像素变化, 放最前保证及时
//     g1  duration(2B) g2 title(40B) g3 speaker(20B)
//     g4  next_title(40B) g5 next_speaker(20B) g6 next_duration(2B)
//     g7/8/9 名称/主办/地点(40B each)   g10 notice(40B)
//   最坏一次全刷 324 拍 @25MHz ≈ 13us(不到 0.5 行), 且 gp0 单独只需 40 拍。
//
// 时钟域: 写侧 sd_card_clk(100MHz, 与 SD 控制器同域); 读侧 video_clk(25MHz)。
//   配置解析状态(ready/error/total/current)在 sd 域, 本模块内部两级同步。
// 语言: 纯 Verilog-2001。
//====================================================================

module meeting_cfg (
    // ---- 写入侧: sd_card_clk 域(meeting_sd_rd 的 MTG1 解析器驱动) ----
    input               wr_clk,
    input               wr_en,
    input      [10:0]   wr_addr,        // 0 .. 1271
    input      [7:0]    wr_data,
    // ---- 配置状态(sd_card_clk 域) ----
    input               cfg_ready,      // 解析完成且配置有效
    input               cfg_error,      // 配置无效(坏/截断)
    input      [4:0]    cfg_total,      // 议程项数 1..16
    input      [3:0]    cfg_current,    // 当前项(meeting_ctrl 输出)
    // ---- 显示侧: video_clk 域 ----
    input               clk,
    input               rst,            // 高有效
    input      [1:0]    notice_sel,     // 注意事项页选择(meeting_osd 产生, 视频域)
    input      [3:0]    overview_index, // 总览行号(meeting_osd 产生, 视频域)
    // ---- 输出(全视频域, 布局/位序与仿真版 meeting_config 相同) ----
    output reg          ready,
    output reg          error,
    output reg  [4:0]   total,
    output reg  [3:0]   current,
    output reg  [15:0]  duration,
    output wire [15:0]  next_duration,
    output reg  [319:0] title, meeting_name, organizer, venue,
    output reg  [319:0] notice, overview_title,
    output reg  [159:0] speaker,
    output wire [319:0] next_title,
    output wire [159:0] next_speaker
);

    // next_* 内部寄存器(有效性由 has_next 组合屏蔽, 见文件末)
    reg [15:0]  nd_r;
    reg [319:0] nt_r;
    reg [159:0] ns_r;

    //--------------------------------------------------------------
    // 配置字节存储(真双口 BRAM: 写 sd 域 / 读 video 域)
    //   容量 1272 = 280 元数据 + 16 项 × 62 字节(与仿真版 text_mem 等大)
    //--------------------------------------------------------------
    reg [7:0] mem [0:1271]; /* fehdl force_ram=1, ram_style="bram" */
    reg [7:0] rd_data;

    always @(posedge wr_clk) begin
        if (wr_en)
            mem[wr_addr] <= wr_data;
    end

    //--------------------------------------------------------------
    // sd→video 两级同步(配置状态都是"缓变"信号, 两级同步足够)
    //--------------------------------------------------------------
    reg [1:0] rdy_s, err_s;
    reg [4:0] tot_s0, tot_s1;
    reg [3:0] cur_s0, cur_s1;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            rdy_s  <= 2'b00;
            err_s  <= 2'b00;
            tot_s0 <= 5'd0; tot_s1 <= 5'd0;
            cur_s0 <= 4'd0; cur_s1 <= 4'd0;
        end
        else begin
            rdy_s  <= {rdy_s[0],  cfg_ready};
            err_s  <= {err_s[0],  cfg_error};
            tot_s0 <= cfg_total;    tot_s1 <= tot_s0;
            cur_s0 <= cfg_current;  cur_s1 <= cur_s0;
        end
    end

    wire        cfg_rdy_v = rdy_s[1];
    wire        cfg_err_v = err_s[1];
    wire [4:0]  tot_v     = tot_s1;
    wire [3:0]  cur_v     = cur_s1;

    //--------------------------------------------------------------
    // 组扫描地址计算(current*62 / overview_index*62 / notice_sel*40 全部用
    //   移位加减, 避免综合出乘法器 —— 板上 DSP 已 29/29 用满)
    //--------------------------------------------------------------
    wire [10:0] cu62 = ({7'd0, cur_v} << 6) - ({7'd0, cur_v} << 1);            // ×62
    wire [10:0] ov62 = ({7'd0, overview_index} << 6)
                     - ({7'd0, overview_index} << 1);                          // ×62
    wire [10:0] ns40 = ({7'd0, notice_sel} << 5) + ({7'd0, notice_sel} << 3);  // ×40

    //--------------------------------------------------------------
    // 状态机
    //--------------------------------------------------------------
    localparam [0:0] SN_ADDR = 1'b0,  // 发地址 / 空闲轮询
                     SN_CAP  = 1'b1;  // 收数据并移入寄存器(1 字节/拍)

    reg        sn;
    reg        prime;        // 1=本拍只等 BRAM 读数据到位, 不移位(见下)
    reg [3:0]  g;            // 当前组 0..10
    reg [5:0]  off;          // 组内字节偏移
    reg [10:0] rd_addr;
    reg [10:0] base_l;       // 本组 RAM 起始(组入口锁存)
    reg [5:0]  len_l;        // 本组字节数(组入口锁存)
    reg [3:0]  g_l;          // 本组编号(组入口锁存)
    reg [3:0]  c_l, o_l;
    reg [1:0]  n_l;          // 组入口时的 current/overview_index/notice_sel
    reg [10:0] dirty;        // 每组一个"待刷新"位

    // 组基址 / 组长度(组合, 只在组入口采一次)
    reg [10:0] gbase;
    reg [5:0]  glen;
    always @(*) begin
        case (g)
            4'd0:    gbase = 11'd282 + ov62;
            4'd1:    gbase = 11'd280 + cu62;
            4'd2:    gbase = 11'd282 + cu62;
            4'd3:    gbase = 11'd322 + cu62;
            4'd4:    gbase = 11'd344 + cu62;
            4'd5:    gbase = 11'd384 + cu62;
            4'd6:    gbase = 11'd342 + cu62;
            4'd7:    gbase = 11'd0;
            4'd8:    gbase = 11'd40;
            4'd9:    gbase = 11'd80;
            default: gbase = 11'd120 + ns40;   // g10 = 注意事项当前页
        endcase
    end
    always @(*) begin
        case (g)
            4'd1, 4'd6: glen = 6'd2;           // 时长(秒, 2 字节大端)
            4'd3, 4'd5: glen = 6'd20;          // 发言人(20 字节)
            default:    glen = 6'd40;          // 其余 40 字节
        endcase
    end

    // BRAM 同步读(地址 rd_addr → 下一拍 rd_data)
    always @(posedge clk) rd_data <= mem[rd_addr];

    // ---- 输入变化检测 → 置"脏" ----
    reg [3:0] c_d, o_d;
    reg [1:0] n_d;
    reg [4:0] t_d;
    reg       r_d;

    wire chg_item   = (cur_v != c_d) || (tot_v != t_d);
    wire chg_ov     = (overview_index != o_d);
    wire chg_notice = (notice_sel != n_d);
    wire chg_rdy    = cfg_rdy_v & ~r_d;

    wire [10:0] set_mask = (chg_item   ? 11'b000_0111_1111 : 11'b0) |
                           (chg_ov     ? 11'b000_0000_0001 : 11'b0) |
                           (chg_notice ? 11'b100_0000_0000 : 11'b0) |
                           (chg_rdy    ? 11'b111_1111_1111 : 11'b0);

    // ---- 本组收完且期间输入未再变化 → 才清脏(否则下一轮重扫) ----
    wire hold_ok   = (cur_v == c_l) && (overview_index == o_l) && (notice_sel == n_l);
    wire grp_done  = (sn == SN_CAP) && ((off + 6'd1) == len_l);
    wire [10:0] clr_mask = (grp_done && hold_ok) ? (11'd1 << g_l) : 11'b0;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            sn <= SN_ADDR; g <= 4'd0; off <= 6'd0; rd_addr <= 11'd0;
            prime <= 1'b0;
            base_l <= 11'd0; len_l <= 6'd40; g_l <= 4'd0;
            c_l <= 4'd0; o_l <= 4'd0; n_l <= 2'd0;
            dirty <= 11'd0;
            c_d <= 4'd0; o_d <= 4'd0; n_d <= 2'd0; t_d <= 5'd0; r_d <= 1'b0;
            ready <= 1'b0; error <= 1'b0; total <= 5'd0; current <= 4'd0;
            duration <= 16'd0; nd_r <= 16'd0;
            title <= 320'd0; nt_r <= 320'd0;
            meeting_name <= 320'd0; organizer <= 320'd0; venue <= 320'd0;
            notice <= 320'd0; overview_title <= 320'd0;
            speaker <= 160'd0; ns_r <= 160'd0;
        end
        else begin
            // 变化检测基线 + 状态输出(视频域)
            c_d <= cur_v;
            o_d <= overview_index;
            n_d <= notice_sel;
            t_d <= tot_v;
            r_d <= cfg_rdy_v;

            ready   <= cfg_rdy_v;
            error   <= cfg_err_v;
            total   <= tot_v;
            current <= cur_v;

            case (sn)
            //-----------------------------------------------
            // 发地址: 本组有脏才开工, 否则跳到下一组
            //-----------------------------------------------
            SN_ADDR: begin
                if (dirty[g]) begin
                    base_l <= gbase;
                    len_l  <= glen;
                    g_l    <= g;
                    off    <= 6'd0;
                    rd_addr <= gbase;
                    prime  <= 1'b1;
                    c_l <= cur_v; o_l <= overview_index; n_l <= notice_sel;
                    sn  <= SN_CAP;
                end
                else begin
                    g <= (g == 4'd10) ? 4'd0 : (g + 4'd1);
                end
            end
            //-----------------------------------------------
            // 收数据: rd_data 即 base_l+off 的字节; 移入高字节后前进
            //
            // ⚠ 2026-09-19 修正(ModelSim 回归抓到的真 bug: 每组快照整体错位 1 字节,
            //    首位是上一组的"残留读", 末位丢失):
            //    rd_data 是同步 BRAM 输出, 在 SN_ADDR 拍发出的 rd_addr 要到
            //    **下一拍**才出现在 rd_data 上。原实现从进入 SN_CAP 的第 1 拍
            //    就开始移位, 于是移进去的是上一组最后一次读的残留值, 而本组
            //    最后一个字节永远读不到 —— 实测: meeting_name 首字节变成了
            //    0x3C(上一组 next_duration 的末字节), 40 字节里最后 1 字节丢失。
            //    修法: 进入 SN_CAP 后先插 1 拍"预读等待"(prime=1, 只把 rd_addr
            //    推到 base+1, 不移位), 之后每拍移 1 字节, 并把 rd_addr 提前 2
            //    (off+2) 以补偿这一拍延迟。总拍数 = 1 + 1 + len。
            //    该错误在纯仿真蓝本里不存在(仿真版是并行读), 只在改成 BRAM
            //    双口+分组串行扫描后引入。
            //-----------------------------------------------
            SN_CAP: begin
                if (prime) begin
                    // 预读等待拍: 让 mem[base_l] 落到 rd_data 上
                    prime   <= 1'b0;
                    rd_addr <= base_l + 11'd1;
                end
                else begin
                case (g_l)
                    4'd0:    overview_title <= {overview_title[311:0], rd_data};
                    4'd1:    duration       <= {duration[7:0],       rd_data};
                    4'd2:    title          <= {title[311:0],        rd_data};
                    4'd3:    speaker        <= {speaker[151:0],      rd_data};
                    4'd4:    nt_r           <= {nt_r[311:0],        rd_data};
                    4'd5:    ns_r           <= {ns_r[151:0],        rd_data};
                    4'd6:    nd_r           <= {nd_r[7:0],          rd_data};
                    4'd7:    meeting_name   <= {meeting_name[311:0], rd_data};
                    4'd8:    organizer      <= {organizer[311:0],    rd_data};
                    4'd9:    venue          <= {venue[311:0],        rd_data};
                    default: notice         <= {notice[311:0],       rd_data};
                endcase

                if (grp_done) begin
                    g  <= (g_l == 4'd10) ? 4'd0 : (g_l + 4'd1);
                    sn <= SN_ADDR;
                end
                else begin
                    off     <= off + 6'd1;
                    rd_addr <= base_l + off + 6'd2;
                end
                end
            end
            endcase

            dirty <= (dirty | set_mask) & ~clr_mask;
        end
    end

    //--------------------------------------------------------------
    // next_* 有效性: 有效项下标 = current+1 < total, 否则给 0
    //   (与仿真版 meeting_config 的 `(current+1<total)? ... : 0` 等价)
    //--------------------------------------------------------------
    wire has_next = ({1'b0, cur_s1} + 5'd1) < {1'b0, tot_s1};

    assign next_duration = has_next ? nd_r : 16'd0;
    assign next_title    = has_next ? nt_r : 320'd0;
    assign next_speaker  = has_next ? ns_r : 160'd0;

endmodule
