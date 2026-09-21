`timescale 1ns/1ps
//====================================================================
// 模块名 : meeting_fmt.v —— 会议场景"计时/进度"格式化(串行引擎)
//
// 为什么需要这个模块(上板必改项):
//   dev_sim(meeting_scene3_sim)的 meeting_osd.v 把 `t/60`、`uptime_view/3600`、
//   `next_duration%60`、`current*592/total`、`(px_y-140)/24` 直接写在
//   always @* 里 —— 那是纯仿真写法。上板时:
//     · 除以变量(total) 会综合出除法器;
//     · 除以常数(60/3600/600/24) 综合器一般走"乘倒数"法 → 要乘法器;
//     · 本板 EG4S20 的 DSP 已 29/29 用满, 也没有余量再放几百 LUT 的除法网络。
//   故这里用一个**串行(逐拍)引擎**在视频域后台把结果算好存寄存器,
//   像素通路里只剩"取数 + 比较", 完全没有 * 与 / (2 的幂除外)。
//
// 算法:
//   · 二进制→BCD: 双 dabble(shift + add-3), 32 拍, 无乘无除;
//   · 除法      : 移位减法(逐位比较-相减), 32 拍, 无除法器。
//     余数寄存器只需 6 位(rr<60), 比较/相减各 7 位, 逻辑量极小;
//     商的收集只是一个 32 位移位寄存器, 不含算术。
//
// ⚠ 关键: 显示的是"分:秒", 不是"总秒数的十进制位"。
//   dev_sim 里 `mins=t/60; secs=t%60;` —— 例如 t=5999s 应显示 99:59,
//   而 5999 的 BCD 是 5/9/9/9(千/百/十/个位), 直接取 BCD 会显示成 59:99。
//   所以三个计时量(remaining/overtime/next_duration)都必须先做 ÷60 分解,
//   再对"商(分)"与"余(秒)"各做一次 BCD; uptime 同理(÷60 两次得 时/分/秒)。
//
// 结果布局(每 4bit 一个十进制位, [3:0]=个位):
//   rem_bcd / ot_bcd / nd_bcd  [15:8]=分(个,十)   [7:0]=秒(个,十)
//   up_bcd  [7:0]=秒(个,十)  [15:8]=分(个,十)  [23:16]=时(个,十, = 小时%100)
//
// 刷新节奏: 15 个作业 × 34 拍 = 510 拍 @25MHz ≈ 20.4us,
//   远小于一帧(16.7ms), 显示上等同"实时"。
//
// 时钟域: video_clk(25MHz), 与 meeting_osd 同域, 无需握手。
// 语言: 纯 Verilog-2001。
//====================================================================

module meeting_fmt (
    input               clk,
    input               rst,            // 高有效(视频域)
    // ---- 待格式化的量(视频域寄存器, 缓变) ----
    input      [15:0]   remaining,      // 剩余秒(0..5999)
    input      [15:0]   overtime,       // 超时正计时秒(0..5999)
    input      [15:0]   next_duration,  // 下一项计划时长秒
    input      [31:0]   uptime,         // 会议已运行秒(自由计数)
    input      [3:0]    current,        // 当前项(0 起)
    input      [4:0]    total,          // 总项数(1..16)
    // ---- 格式化结果(全寄存器, 直接给 meeting_osd 取用) ----
    output reg [19:0]   rem_bcd,        // 剩余 分:秒
    output reg [19:0]   ot_bcd,         // 超时 分:秒
    output reg [19:0]   nd_bcd,         // 下一项时长 分:秒
    output reg [39:0]   up_bcd,         // 已运行 时:分:秒
    output reg [13:0]   progress        // 进度条已填充像素宽度 = 592*current/total
);

    //--------------------------------------------------------------
    // 作业编号: 除法作业(x_D / J_UP1 / J_UP2 / J_PRG)与其后的 dabble 作业
    // 交替排列 —— 除法的商(qt)/余(rr)在下一作业装载时被读走, 无需额外锁存
    // (唯一的例外: J_UP1 的余数"秒"会被 J_UP2 覆盖, 故另锁 up_sec)
    //--------------------------------------------------------------
    localparam [3:0] J_REM_D = 4'd0,    // 除法 remaining / 60
                     J_REM_M = 4'd1,    // dabble 商 → rem_bcd[15:8] 分
                     J_REM_S = 4'd2,    // dabble 余 → rem_bcd[7:0]  秒
                     J_OT_D  = 4'd3,    // 除法 overtime / 60
                     J_OT_M  = 4'd4,
                     J_OT_S  = 4'd5,
                     J_ND_D  = 4'd6,    // 除法 next_duration / 60
                     J_ND_M  = 4'd7,
                     J_ND_S  = 4'd8,
                     J_UP1   = 4'd9,    // 除法 uptime / 60   → 商(总分钟), 余(秒)
                     J_UP2   = 4'd10,   // 除法 上商 / 60     → 商(小时),   余(分)
                     J_UP_H  = 4'd11,   // dabble 商 → up_bcd[23:16] 时
                     J_UP_M  = 4'd12,   // dabble 余 → up_bcd[15:8]  分
                     J_UP_S  = 4'd13,   // dabble 锁存秒 → up_bcd[7:0]
                     J_PRG   = 4'd14;   // 除法 592*current / total → progress

    // 每个作业统一 34 拍: step=0 装载, 1..32 迭代, 33 收结果
    localparam [5:0] ST_LOAD = 6'd0,
                     ST_CAPT = 6'd33;

    reg  [3:0]  job;
    reg  [5:0]  step;
    // ---- dabble 通道 ----
    reg  [39:0] acc;        // BCD 累加器(10 位十进制, digit0 在 [3:0])
    reg  [31:0] src;        // 待转换二进制(MSB 先移出)
    // ---- 除法通道 ----
    reg  [31:0] dvd;        // 被除数移位寄存器
    reg  [6:0]  dr;         // 除数(≤60)
    reg  [5:0]  rr;         // 余数(恒 < 除数)
    reg  [31:0] qt;         // 商移位寄存器
    // ---- uptime 专用锁存 ----
    reg  [5:0]  up_sec;     // J_UP1 的余数(秒), 需在 J_UP2 前保存

    //--------------------------------------------------------------
    // dabble: add-3 —— 每位十进制 ≥5 时 +3(双 dabble 的核心)
    //--------------------------------------------------------------
    wire [39:0] a3;
    genvar gj;
    generate
        for (gj = 0; gj < 10; gj = gj + 1) begin : g_add3
            wire [3:0] dg = acc[gj*4 +: 4];
            assign a3[gj*4 +: 4] = (dg > 4'd4) ? (dg + 4'd3) : dg;
        end
    endgenerate

    wire [5:0]  bidx     = 6'd32 - step;            // step=1..32 → 31..0
    wire        bit_in   = src[bidx[4:0]];
    wire [39:0] acc_next = {a3[38:0], bit_in};      // 左移 1 位并移入新位

    //--------------------------------------------------------------
    // 除法: 移位减法(每拍处理被除数一位)
    //--------------------------------------------------------------
    wire [6:0]  rr_sh  = {rr, dvd[31]};                            // 移入被除数当前最高位
    wire        ge     = (rr_sh >= dr);                            // 够减?
    wire [5:0]  rr_nx  = ge ? (rr_sh[5:0] - dr[5:0]) : rr_sh[5:0]; // 恒 < dr ≤ 60
    wire [31:0] dvd_nx = {dvd[30:0], 1'b0};
    wire [31:0] qt_nx  = {qt[30:0], ge};

    // 迭代分支据此选择数据通路(除法作业 vs dabble 作业)
    wire        is_div = (job == J_REM_D) || (job == J_OT_D) || (job == J_ND_D) ||
                         (job == J_UP1  ) || (job == J_UP2 ) || (job == J_PRG );

    //--------------------------------------------------------------
    // 主序列
    //--------------------------------------------------------------
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            job      <= J_REM_D;
            step     <= ST_LOAD;
            acc      <= 40'd0;
            src      <= 32'd0;
            dvd      <= 32'd0;
            dr       <= 7'd1;
            rr       <= 6'd0;
            qt       <= 32'd0;
            up_sec   <= 6'd0;
            rem_bcd  <= 20'd0;
            ot_bcd   <= 20'd0;
            nd_bcd   <= 20'd0;
            up_bcd   <= 40'd0;
            progress <= 14'd0;
        end
        else if (step == ST_LOAD) begin
            // ---------------- 装载(所有作业共用) ----------------
            case (job)
            // 除法: 被除数 / 除数 = 60
            J_REM_D: begin dvd <= {16'd0, remaining    }; dr <= 7'd60; rr <= 6'd0; qt <= 32'd0; step <= 6'd1; end
            J_OT_D : begin dvd <= {16'd0, overtime     }; dr <= 7'd60; rr <= 6'd0; qt <= 32'd0; step <= 6'd1; end
            J_ND_D : begin dvd <= {16'd0, next_duration}; dr <= 7'd60; rr <= 6'd0; qt <= 32'd0; step <= 6'd1; end
            J_UP1  : begin dvd <= uptime; dr <= 7'd60; rr <= 6'd0; qt <= 32'd0; step <= 6'd1; end
            // 上一步的商(qt=总分钟)作被除数; 非阻塞赋值保证读到的仍是旧值
            J_UP2  : begin dvd <= qt    ; dr <= 7'd60; rr <= 6'd0; qt <= 32'd0; step <= 6'd1; end
            // dabble: 被转换值放入 src(高位补 0, 值域 ≤ 99 秒/分、≤ 2^32 小时)
            J_REM_M: begin acc <= 40'd0; src <= qt              ; step <= 6'd1; end
            J_REM_S: begin acc <= 40'd0; src <= {26'd0, rr}     ; step <= 6'd1; end
            J_OT_M : begin acc <= 40'd0; src <= qt              ; step <= 6'd1; end
            J_OT_S : begin acc <= 40'd0; src <= {26'd0, rr}     ; step <= 6'd1; end
            J_ND_M : begin acc <= 40'd0; src <= qt              ; step <= 6'd1; end
            J_ND_S : begin acc <= 40'd0; src <= {26'd0, rr}     ; step <= 6'd1; end
            J_UP_H : begin acc <= 40'd0; src <= qt              ; step <= 6'd1; end
            J_UP_M : begin acc <= 40'd0; src <= {26'd0, rr}     ; step <= 6'd1; end
            J_UP_S : begin acc <= 40'd0; src <= {26'd0, up_sec} ; step <= 6'd1; end
            default: begin  // J_PRG
                // 592 = 512 + 64 + 16 → 移位加, 不用乘法器
                dvd <= ({28'd0, current} << 9) +
                       ({28'd0, current} << 6) +
                       ({28'd0, current} << 4);
                dr  <= (total == 5'd0) ? 7'd1 : {2'd0, total};
                rr  <= 6'd0;
                qt  <= 32'd0;
                step <= 6'd1;
            end
            endcase
        end
        else if (step == ST_CAPT) begin
            // ---------------- 收结果 ----------------
            // ⚠ 2026-09-19 修正(ModelSim 回归抓到的真 bug): 原来 progress 写在
            //   `default:` 上, 而 default 会把 J_REM_D / J_OT_D / J_ND_D / J_UP2
            //   这几个**除法作业**也一起兜进去 —— 作业序是 …→J_UP_S→J_PRG→
            //   J_REM_D→…, 于是 J_PRG 刚写好的 progress(592*current/total) 立刻被
            //   紧随其后的 J_REM_D 商(remaining/60, 实测 = 2)覆盖, 进度条永远
            //   只显示 2 像素。现在改为显式列举: 只有 J_PRG 写 progress, 其余
            //   除法作业收结果时什么都不做(商/余由后续 dabble 作业取走)。
            case (job)
            J_REM_M: rem_bcd[15:8] <= {acc[7:4], acc[3:0]};   // 分 个/十位
            J_REM_S: rem_bcd[ 7:0] <= {acc[7:4], acc[3:0]};   // 秒 个/十位
            J_OT_M : ot_bcd [15:8] <= {acc[7:4], acc[3:0]};
            J_OT_S : ot_bcd [ 7:0] <= {acc[7:4], acc[3:0]};
            J_ND_M : nd_bcd [15:8] <= {acc[7:4], acc[3:0]};
            J_ND_S : nd_bcd [ 7:0] <= {acc[7:4], acc[3:0]};
            J_UP_H : up_bcd [23:16] <= {acc[7:4], acc[3:0]};  // 时(低 2 位十进制)
            J_UP_M : up_bcd [15:8]  <= {acc[7:4], acc[3:0]};  // 分
            J_UP_S : up_bcd [ 7:0]  <= {acc[7:4], acc[3:0]};  // 秒
            J_UP1  : up_sec <= rr[5:0];                       // 先存下"秒"
            J_PRG  : progress <= qt[13:0];                    // 进度条
            default: ;                                        // 其余除法作业不动作
            endcase
            step <= ST_LOAD;
            job  <= (job == J_PRG) ? J_REM_D : (job + 4'd1);
        end
        else begin
            // ---------------- 迭代 ----------------
            if (!is_div)
                acc <= acc_next;                            // dabble 作业
            else begin
                rr  <= rr_nx;                               // 除法作业
                qt  <= qt_nx;
                dvd <= dvd_nx;
            end
            step <= step + 6'd1;
        end
    end

endmodule
