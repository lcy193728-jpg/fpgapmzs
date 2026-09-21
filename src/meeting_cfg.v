`timescale 1ns/1ps
//====================================================================
// 模块名 : meeting_cfg.v —— 会议议程配置存储(BRAM 读口 + 时长短解算)
// 来源   : dev_sim(meeting_scene3_sim) 的 meeting_config.v
//
// 上板演进(两轮改写的来龙去脉, 便于回溯):
//   ① 仿真版 meeting_config.v 用 `generate` 对 1272 字节寄存器组做 324 路
//      "并行可变索引读"(text_mem[282+current*62+g] ...), 综合后是几万 LUT 的
//      巨型多路器, 上板放不下。
//      → 第一版改为 "真双口 BRAM + 视频域文本快照寄存器"(8 个 320bit + 2 个
//        160bit 快照, 外加 11 组脏位串行扫描状态机)。
//   ② 2026-09-21: 那 2673 个快照触发器成了全设计最大的单项 —— 整机
//      mslice 5453 > 器件上限 4900, TD 报 PHY-9009 直接中止布线。
//      → 本版**彻底取消文本快照**: 改为把 BRAM 读口直接开放给显示侧:
//        · meeting_osd 自己按"字段基址 + 字单元列号"发 11bit 读地址取字节;
//        · meeting_cfg 只负责 BRAM + 1 拍同步读 + 跨域同步 + 时长解算;
//        · 画面逐像素完全等价(meeting_osd 内的字段基址表与本文件 mem 布局
//          一一对应)。
//      本模块触发器 2673 → 约 60。
//
// BRAM 内容(原始 MTG1 字节流, 偏移与仿真版 text_mem 完全相同):
//   [0..39]     会议名称             [40..79]    主办单位      [80..119] 报到地点
//   [120..279]  注意事项 4 页(每页 40B, 第 p 页在 120+40p)
//   [280+i*62 .. 341+i*62]  第 i 项议程:
//                +0/+1 = 时长(秒, 大端)  +2..41 = 名称(40B)  +42..61 = 发言人(20B)
//
// 读口归属: 由 meeting_osd 驱动的取字读(rd_addr → rd_data, 晚一拍)。
//   时长字段只有 2 字节、却要参与计时运算(meeting_ctrl / meeting_fmt),
//   故本模块另用 4 拍小 FSM 在 current 变化或配置刚就绪时顺带解出
//   duration / next_duration(16bit 寄存器)。
//   ※ 该 FSM 会短暂借用读口 4 拍, 期间 meeting_osd 会取到 4 个错误字节 ——
//     只在 current 变化(按键切项)或配置刚就绪时发生, 画面影响是 1 帧内
//     几个像素, 可忽略; 换来的是不必再加仲裁/额外 BRAM(本板 BRAM 已满)。
//
// 时钟域: 写侧 sd_card_clk(100MHz, 与 SD 控制器同域); 读侧 video_clk(25MHz)。
//   配置状态(ready/error/total)在 sd 域产生, 本模块内部两级同步。
// 地址运算: current*62 只用移位加减(本板 DSP 29/29 已满, 不能用乘法器)。
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
    input      [3:0]    cfg_current,    // 当前项(meeting_ctrl 输出, 视频域)
    // ---- 读/显示侧: video_clk 域 ----
    input               clk,
    input               rst,            // 高有效
    input      [10:0]   rd_addr,        // 取字地址(meeting_osd 给出)
    output reg  [7:0]   rd_data,        // 取字数据(晚 rd_addr 一拍)
    output reg          ready,
    output reg          error,
    output reg  [4:0]   total,
    output reg  [15:0]  duration,       // 当前项时长(秒)
    output reg  [15:0]  next_duration   // 下一项时长(秒); 无下一项时 0
);

    //--------------------------------------------------------------
    // 配置字节存储(真双口: 写 sd 域 / 读 video 域)
    //   容量 1272 = 280 元数据 + 16 项 × 62 字节(与仿真版 text_mem 等大)
    //--------------------------------------------------------------
    reg [7:0] mem [0:1271]; /* fehdl force_ram=1, ram_style="bram" */

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
    // 时长解算: 4 拍借读口, 取 2 组"大端 2 字节"
    //   ld: 0=空闲(读口归 meeting_osd) 1..4=取字节中
    //--------------------------------------------------------------
    reg  [2:0]  ld;
    reg  [3:0]  cur_d;                     // 上拍 current(变化检测)
    reg         rdy_d;                     // 上拍 ready(上升沿检测)
    reg  [10:0] ld_addr;

    // current*62 —— 移位加减, 无乘法器
    wire [10:0] cu62 = ({7'd0, cur_v} << 6) - ({7'd0, cur_v} << 1);
    wire        ld_start = (cur_v != cur_d) | (cfg_rdy_v & ~rdy_d);

    always @(*) begin
        case (ld)
            3'd1:    ld_addr = 11'd280 + cu62;   // 当前项时长 高字节
            3'd2:    ld_addr = 11'd281 + cu62;   // 当前项时长 低字节
            3'd3:    ld_addr = 11'd342 + cu62;   // 下一项时长 高字节
            default: ld_addr = 11'd343 + cu62;   // 下一项时长 低字节
        endcase
    end

    // 借口时本模块地址优先(见文件头"读口归属"说明)
    wire [10:0] addr_now = (ld != 3'd0) ? ld_addr : rd_addr;

    // BRAM 同步读: 地址 addr_now → 下一拍 rd_data
    always @(posedge clk) rd_data <= mem[addr_now];

    // 有效下一项下标 = current+1 < total(与仿真版语义一致)
    wire has_next = ({1'b0, cur_v} + 5'd1) < tot_v;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            ld            <= 3'd0;
            cur_d         <= 4'd0;
            rdy_d         <= 1'b0;
            duration      <= 16'd0;
            next_duration <= 16'd0;
            ready         <= 1'b0;
            error         <= 1'b0;
            total         <= 5'd0;
        end
        else begin
            cur_d <= cur_v;
            rdy_d <= cfg_rdy_v;

            ready <= cfg_rdy_v;
            error <= cfg_err_v;
            total <= tot_v;

            case (ld)
                3'd0:    if (ld_start) ld <= 3'd1;
                3'd1: begin duration[15:8]      <= rd_data; ld <= 3'd2; end
                3'd2: begin duration[7:0]       <= rd_data; ld <= 3'd3; end
                3'd3: begin next_duration[15:8] <= rd_data; ld <= 3'd4; end
                default: begin
                    next_duration <= has_next ? {next_duration[15:8], rd_data}
                                              : 16'd0;
                    ld <= 3'd0;
                end
            endcase
        end
    end

endmodule
