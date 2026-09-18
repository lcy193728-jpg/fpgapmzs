//====================================================================
// 模块名 : bmp_scale.v
// 功能   : 双线性插值(Bilinear)缩放引擎 —— 插入"TF 读图 → SDRAM 写"通路
//
// 通路位置:
//   sd_card_bmp(源像素 640x480, {R,G,B,8'b0}) → bmp_scale → frame_read_write(写FIFO)
//
// 为什么放在写通路(而不是显示读通路):
//   显示侧 frame_fifo_read 是"整帧连续突发读", 地址由硬件顺序推进, 无法逐像素
//   改地址; 而写通路是"逐像素流入", 且 SD/SPI 读图速率(~100 时钟/像素)远慢于
//   本模块输出速率(约 6 时钟/像素), 在行缓存上做插值有充足时间余量。
//
// 输出画布固定 640x480(与 SDRAM 帧完全一致 → 帧长/写地址/行翻转逻辑都不用改):
//   · 图像区以外一律填黑(32'h0)。
//   · 水平方向**居中**(x0 = (CANV_W-dstw)/2); 放大档 x0<0 → 左右按中心裁剪。
//   · 垂直方向: 缩小档(dsth<=480)**顶部对齐**(y0=0, 下方留黑); 放大档
//     中心裁剪(y0<0)。※ 缩小档不能垂直居中, 原因见下方"行缓存"说明。
//
// 双线性做法(可分离, 先水平后垂直):
//   rowA = A[x0] + ((A[x1]-A[x0]) * fx) >> 8      上行水平插值
//   rowB = B[x0] + ((B[x1]-B[x0]) * fx) >> 8      下行水平插值
//   out  = rowA + ((rowB-rowA) * fy) >> 8         垂直插值
//   fx/fy = 源坐标映射小数部分(8bit 权重), x1=min(x0+1,639), y1=min(y0+1,479)
//
// 坐标映射(定点): 设 v = 输出行列相对图像区左上角的偏移
//   src = v * K >> 16,  K = (den/num) 的 Q16 定点(1.0 = 65536)
//   → 整数部分为采样点, 小数部分为插值权重
//
// 行缓存: 3 块 640x32 简单双口 RAM, 按"源行号 % 3"轮转存放最近 3 行。
//   输出第 oy 行需要源行 sy0 与 sy1=sy0+1; 二者都有效时才能输出该行。
//   ⚠ 前提(必须遵守): **输出所需的源行不能落后输入前沿超过 2 行**。
//     本模块只有 3 行缓存, 若输出等到的源行已被新行覆盖 → 整帧写不完(死锁)。
//     实机余量(源 640x480, SPI 25MHz ≈ 96 拍/像素, 一行 61440 拍):
//       · 放大 300%(最大档): 每源像素产出 3 个输出像素 ≈ 3×11=33 拍 ≪ 96 拍
//       · 缩小 25%: 输出远慢于输入, 输出一直在等, 天然落后 ≤1 行
//     仿真喂数速率必须 ≥ 96 拍/像素, 否则放大档会出现假失败(bmp tb 用 97 拍)。
//   ⚠ 缩小档的图像**顶部对齐**(见上): 若顶部留黑边, 黑边要先于图像行输出,
//     耗时可达十几行源行时间, 输入前沿早已越过图像首行所需源行 → 死锁。
//
// 帧同步: 以写通路应答(sd_card_write_req_ack)上升沿为本帧起点 ——
//   与 frame_fifo_write 的帧边界一致(该应答期间 frame_fifo_write 清写 FIFO),
//   本模块在该沿之后才开始推数据, 首字不会被清掉; 每帧严格输出 307200 字。
//
// 输入节拍: in_en 在真实 SPI 节拍下是"多拍电平"(一像素期间保持高), 在快速
//   仿真下是"1 拍脉冲" → 统一用**上升沿**判定一个像素, 两种情况都正确。
//
// 档位 scale_sel: 0=25% 1=33% 2=50% 3=67% 4=100% 5=150% 6=200% 7=300%
//   (档位在每帧起点锁存; 改档后由上层发 reload_req 重读当前图, 立即生效)
//
// ★ 100% 档 = 真·1:1 旁路(2026-09-16 画质改造):
//   档 4(100%, 与源图同尺寸) 时**完全不进插值状态机**, 源像素一拍不差地
//   直通到写 FIFO(只加 1 拍寄存对齐)。理由:
//     · 画质: 默认档必须与"官方例程的原图"逐像素一致, 杜绝任何重采样
//       引入的软化/色边;
//     · 时序: 旁路无 3 行缓存等待, 输出与输入同速(96 拍/像素), 不占用
//       SDRAM 带宽峰值, 也不会因行缓存周转产生延迟;
//     · 面积: 旁路态下乘法器/行缓存的输出侧逻辑静态, 综合可按需裁剪。
//   其它档位仍走双线性插值(赛题扩展项要求"双线性插值优化质量")。
//====================================================================

`timescale 1ns/1ps

module bmp_scale #(
    parameter SRC_W  = 640,          // 源图宽(BMP 固定 640)
    parameter SRC_H  = 480,          // 源图高(BMP 固定 480)
    parameter CANV_W = 640,          // 输出画布宽(= SDRAM 帧宽)
    parameter CANV_H = 480           // 输出画布高(= SDRAM 帧高)
)(
    input               clk,               // sd_card_clk(100MHz)
    input               rst,               // 高电平有效复位
    input      [3:0]    scale_sel,         // 缩放档 0..7
    input               frame_start,       // 写通路应答(帧起点, sd_card_clk 域)
    input               in_en,             // 源像素写使能(bmp_data_wr_en)
    input      [31:0]   in_data,           // 源像素 {R,G,B,8'b0}
    output reg          out_en,            // 输出像素写使能(接 frame_read_write.write_en)
    output reg  [31:0]  out_data           // 输出像素(接 frame_read_write.write_data)
);

    //--------------------------------------------------------------
    // 8bit 饱和钳位(插值结果可能略越界)
    //--------------------------------------------------------------
    function [7:0] clamp8;
        input signed [10:0] v;
        begin
            if (v < 11'sd0)        clamp8 = 8'd0;
            else if (v > 11'sd255) clamp8 = 8'd255;
            else                   clamp8 = v[7:0];
        end
    endfunction

    //--------------------------------------------------------------
    // 缩放档配置(组合查表, 帧起点锁存)
    //   K = SRC/dst 的 Q16 定点(1.0 = 65536); 图像区 dstw x dsth 居中放置
    //   几何量全部由参数推导 → 缩放引擎尺寸可参数化(便于小尺寸快速仿真),
    //   默认参数(640x480 源/画布)下与实机配置完全一致。
    //--------------------------------------------------------------
    reg  [18:0]        cfg_k;
    reg  [11:0]        cfg_dstw;
    reg  [11:0]        cfg_dsth;
    reg  signed [12:0] cfg_x0;
    reg  signed [12:0] cfg_y0;

    always @(*) begin
        case (scale_sel)
            4'd0:    begin cfg_k=19'd262144; cfg_dstw=SRC_W/4;       cfg_dsth=SRC_H/4;       end // 25%
            4'd1:    begin cfg_k=19'd196608; cfg_dstw=SRC_W/3;       cfg_dsth=SRC_H/3;       end // 33%
            4'd2:    begin cfg_k=19'd131072; cfg_dstw=SRC_W/2;       cfg_dsth=SRC_H/2;       end // 50%
            4'd3:    begin cfg_k=19'd98304;  cfg_dstw=(SRC_W*2)/3;   cfg_dsth=(SRC_H*2)/3;   end // 67%
            4'd4:    begin cfg_k=19'd65536;  cfg_dstw=SRC_W;         cfg_dsth=SRC_H;         end // 100%
            4'd5:    begin cfg_k=19'd43691;  cfg_dstw=(SRC_W*3)/2;   cfg_dsth=(SRC_H*3)/2;   end // 150%
            4'd6:    begin cfg_k=19'd32768;  cfg_dstw=SRC_W*2;       cfg_dsth=SRC_H*2;       end // 200%
            default: begin cfg_k=19'd21845;  cfg_dstw=SRC_W*3;       cfg_dsth=SRC_H*3;       end // 300%
        endcase
        // 水平: 始终居中 → x0 = (CANV_W - dstw)/2 (负值 = 放大档左右中心裁剪)
        cfg_x0 = ($signed({1'b0, CANV_W[11:0]}) - $signed({1'b0, cfg_dstw})) >>> 1;
        // 垂直: 缩小档(dsth<=CANV_H)顶部对齐 y0=0; 放大档中心裁剪 y0<0。
        //   ※ 缩小档垂直居中会让"顶部黑边"先占用十几行源行时间, 期间输入前沿
        //     越过图像首行所需源行 → 3 行缓存被覆盖 → 死锁(详见文件头说明)。
        cfg_y0 = (cfg_dsth <= CANV_H[11:0]) ? 13'sd0
                : (($signed({1'b0, CANV_H[11:0]}) - $signed({1'b0, cfg_dsth})) >>> 1);
    end

    //--------------------------------------------------------------
    // 帧起点: 写通路应答两级同步 + 上升沿检测
    //--------------------------------------------------------------
    reg fs_s0, fs_s1, fs_s2;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            fs_s0 <= 1'b0; fs_s1 <= 1'b0; fs_s2 <= 1'b0;
        end
        else begin
            fs_s0 <= frame_start;
            fs_s1 <= fs_s0;
            fs_s2 <= fs_s1;
        end
    end
    wire fs_pulse = fs_s1 & ~fs_s2;      // 帧起点单周期脉冲

    //--------------------------------------------------------------
    // 输入侧: 源像素 → 行缓存(按行号%3 轮转)
    //--------------------------------------------------------------
    reg  [9:0]  wr_col;          // 源列计数 0..639
    reg  [9:0]  wr_row;          // 源行计数 0..479
    reg  [1:0]  wr_buf;          // 当前写入缓存号(0/1/2)
    reg         in_en_d;
    wire        in_pix  = in_en & ~in_en_d;                          // 像素有效(上升沿)
    wire        row_end = in_pix & (wr_col == SRC_W[9:0] - 10'd1);

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            wr_col <= 10'd0; wr_row <= 10'd0; wr_buf <= 2'd0; in_en_d <= 1'b0;
        end
        else begin
            in_en_d <= in_en;
            if (fs_pulse) begin
                wr_col <= 10'd0; wr_row <= 10'd0; wr_buf <= 2'd0;
            end
            else if (in_pix) begin
                if (row_end) begin
                    wr_col <= 10'd0;
                    wr_buf <= (wr_buf == 2'd2) ? 2'd0 : (wr_buf + 2'd1);
                    wr_row <= (wr_row == SRC_H[9:0] - 10'd1) ? 10'd0 : (wr_row + 10'd1);
                end
                else
                    wr_col <= wr_col + 10'd1;
            end
        end
    end

    // 三块行缓存(每块 1 写口 + 1 读口) + 同地址读数据
    reg  [31:0] lb0 [0:SRC_W-1];
    reg  [31:0] lb1 [0:SRC_W-1];
    reg  [31:0] lb2 [0:SRC_W-1];
    reg  [31:0] d0, d1, d2;
    reg  [9:0]  raddr;

    always @(posedge clk) begin
        if (in_pix && (wr_buf == 2'd0)) lb0[wr_col] <= in_data;
        d0 <= lb0[raddr];
    end
    always @(posedge clk) begin
        if (in_pix && (wr_buf == 2'd1)) lb1[wr_col] <= in_data;
        d1 <= lb1[raddr];
    end
    always @(posedge clk) begin
        if (in_pix && (wr_buf == 2'd2)) lb2[wr_col] <= in_data;
        d2 <= lb2[raddr];
    end

    // 行缓存登记表: 每块缓存当前存的是哪一行 / 是否有效
    //   · 一行的**首像素**到来时立刻把该块置无效(正在被覆盖, 读到的是半行数据)
    //   · 该行**末像素**时置有效并登记行号
    //   ※ 不能用"当前写块号"做组合 busy 判据: 输入停止(一帧读完)后写块号会
    //     冻结在 0, 使需要块 0 的输出行永久等待 → 整帧写不完(死锁)。
    //     用"块有效位"代替, 输入停后三块仍保持有效, 输出可正常读完最后几行。
    reg  [9:0]  buf_row [0:2];
    reg  [2:0]  buf_vld;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            buf_row[0] <= 10'd0; buf_row[1] <= 10'd0; buf_row[2] <= 10'd0;
            buf_vld    <= 3'b000;
        end
        else if (fs_pulse) begin
            buf_vld <= 3'b000;                    // 新帧: 行缓存全部作废
        end
        else begin
            if (in_pix && (wr_col == 10'd0)) begin
                // 本行首像素: 该块开始被覆盖 → 立即作废
                if (wr_buf == 2'd0)      buf_vld[0] <= 1'b0;
                else if (wr_buf == 2'd1) buf_vld[1] <= 1'b0;
                else                     buf_vld[2] <= 1'b0;
            end
            if (row_end) begin
                buf_row[wr_buf] <= wr_row;
                buf_vld[wr_buf] <= 1'b1;
            end
        end
    end

    //--------------------------------------------------------------
    // 输出节流: 每 8 拍最多输出 1 像素(瞬时速率 ≤ 12.5M 字/s)
    //   写通路 frame_read_write 的写 FIFO 只有 512 深, SDRAM 写突发
    //   (frame_fifo_write 128 字/突发)也要时间; 若图像区外的黑像素以
    //   1~2 拍/像素连续输出, 瞬时可达 50~100M 字/s → 写 FIFO 溢出丢像素,
    //   整帧行列错位(黑区尤其明显)。统一限速 8 拍/像素后:
    //   · 图像区本来就是 ≥8 拍/像素(两次行缓存读 + 4 级插值流水),
    //     不受影响;
    //   · 黑区自动降到 8 拍/像素; 全帧 480×640×8=2.46M 拍≈24.6ms,
    //     远小于输入一帧的时间(SPI 25MHz, 约 295ms), 不会成为瓶颈。
    //   ※ 图像区实际节拍 = 12 拍/像素(读 8 拍 + 插值流水 4 拍)≈37ms/帧,
    //     仍远小于 SPI 供数的一帧时间, 故限速器只在黑区起作用。
    //--------------------------------------------------------------
    reg  [2:0]  rate_cnt;
    always @(posedge clk or posedge rst) begin
        if (rst) rate_cnt <= 3'd0;
        else     rate_cnt <= rate_cnt + 3'd1;     // 自由运行
    end
    wire out_tick = (rate_cnt == 3'd0);           // 允许输出的那一拍

    //--------------------------------------------------------------
    // 输出侧状态定义
    //--------------------------------------------------------------
    localparam [4:0] O_IDLE = 5'd0,   // 等帧起点
                     O_BYP  = 5'd14,  // 100% 档: 源像素直通(1 拍寄存对齐)
                     O_ROW  = 5'd1,   // 行起点: 算 v = out_row - y0
                     O_MULY = 5'd2,   // 判图像行/黑行 + 垂直乘法
                     O_YMAP = 5'd3,   // 求 sy0/sy1/fy
                     O_WAIT = 5'd4,   // 等源行就绪
                     O_BLK  = 5'd5,   // 输出整行黑
                     O_CU   = 5'd6,   // 列起点: 算 u = out_col - x0
                     O_CCHK = 5'd7,   // 判图像列/黑列 + 列乘法
                     O_CX   = 5'd8,   // 求 fx/sx1, 发起 sx0 读
                     O_R1   = 5'd9,   // sx0 读延迟
                     O_R2   = 5'd10,  // 取 A[x0]/B[x0], 发起 sx1 读
                     O_R3   = 5'd11,  // sx1 读延迟
                     O_R4   = 5'd12,  // 取 A[x1]/B[x1]
                     O_H1   = 5'd15,  // 流水段1: 水平乘积
                     O_H2   = 5'd16,  // 流水段2: 水平插值+钳位
                     O_V1   = 5'd17,  // 流水段3: 垂直乘积
                     O_V2   = 5'd18,  // 流水段4: 垂直插值+钳位
                     O_OUT  = 5'd13;  // 输出该像素(数据取流水结果 rs_r)

    reg  [4:0]  state;
    reg  [9:0]  out_row, out_col;

    reg  [18:0] k_r;
    reg  [11:0] dstw_r, dsth_r;
    reg  signed [12:0] x0_r, y0_r;

    reg  signed [12:0] yy_r;             // v(输出行相对图像顶)
    reg  [31:0] sy_prod;                 // v * K
    reg  [11:0] sy0_r, sy1_r;
    reg  [7:0]  fy_r;

    reg  signed [12:0] xx_r;             // u(输出列相对图像左)
    reg  [31:0] sx_prod;                 // u * K
    reg  [11:0] sx0_r, sx1_r;
    reg  [7:0]  fx_r;
    reg  [1:0]  ia_r, ib_r;              // sy0/sy1 所在缓存号

    reg  [31:0] v00, v01, v10, v11;      // 四个采样点

    // 行缓存定位(组合): sy0_r/sy1_r 分别落在哪块缓存
    wire       m0 = buf_vld[0] && (buf_row[0] == sy0_r);
    wire       m1 = buf_vld[1] && (buf_row[1] == sy0_r);
    wire       m2 = buf_vld[2] && (buf_row[2] == sy0_r);
    wire       hitA = m0 | m1 | m2;
    wire [1:0] ia_w = m0 ? 2'd0 : (m1 ? 2'd1 : 2'd2);

    wire       n0 = buf_vld[0] && (buf_row[0] == sy1_r);
    wire       n1 = buf_vld[1] && (buf_row[1] == sy1_r);
    wire       n2 = buf_vld[2] && (buf_row[2] == sy1_r);
    wire       hitB = n0 | n1 | n2;
    wire [1:0] ib_w = n0 ? 2'd0 : (n1 ? 2'd1 : 2'd2);

    // 读数据按缓存号选择(三块并行读同一地址 → 每块各占一个读口)
    wire [31:0] mxA0 = (ia_r == 2'd0) ? d0 : (ia_r == 2'd1) ? d1 : d2;
    wire [31:0] mxB0 = (ib_r == 2'd0) ? d0 : (ib_r == 2'd1) ? d1 : d2;

    //--------------------------------------------------------------
    // 双线性插值 —— ★4 级流水(2026-09-16 时序修复)
    //   原实现把"水平插值 + 垂直插值"写在一个组合 always 里, 综合后从行
    //   缓存采样寄存器(v11_reg)到 out_data_reg 的组合路径 = 16 级逻辑 /
    //   22.3ns, 而本模块跑 sd_card_clk=100MHz(10ns) → 建立时间违规
    //   -12.444ns, out_data 全 24 位都是失败端点(SYN 报告 24 viol
    //   endpoints) → 实机插值像素采到未稳定的值 = 画面彩色噪点。
    //   现按"每像素多花 4 拍"拆成 4 级寄存器流水(SPI 供数约 96 拍/像素,
    //   余量充足), 每级只剩 1 次乘/加/钳位(≈3~5ns):
    //     段1 O_H1: 寄存 p00/p10 + 水平乘积 (p01-p00)*fx / (p11-p10)*fx
    //     段2 O_H2: 水平插值 p00+(乘积>>8) 并钳位 → hrA/hrB
    //     段3 O_V1: 垂直乘积 (hrB-hrA)*fy
    //     段4 O_V2: 垂直插值 hrA+(乘积>>8) 并钳位 → rs_r
    //     O_OUT   : rs_r 打包输出(与 hs/vs/de 同拍)
    //   数学与拆分前逐比特一致(只是把同一表达式切成 4 个时钟周期)。
    //--------------------------------------------------------------
    reg  [7:0]  q00 [0:2], q01 [0:2], q10 [0:2], q11 [0:2]; // 采样点通道拆包(组合)
    reg  [7:0]  pa00[0:2], pa10[0:2];     // 段1: p00/p10 寄存(段2 需要)
    reg signed [17:0] phA[0:2], phB[0:2]; // 段1: 水平乘积
    reg  [7:0]  hrA [0:2], hrB [0:2];     // 段2: 水平插值结果(已钳位)
    reg signed [17:0] pv [0:2];           // 段3: 垂直乘积
    reg  [7:0]  rs_r[0:2];                // 段4: 最终通道值(已钳位)
    reg signed [10:0] tA, tB, tV;
    integer           ci;

    always @(*) begin
        // 采样点拆分量: 字格式 {R,G,B,8'b0}
        q00[0]=v00[31:24]; q00[1]=v00[23:16]; q00[2]=v00[15:8];
        q01[0]=v01[31:24]; q01[1]=v01[23:16]; q01[2]=v01[15:8];
        q10[0]=v10[31:24]; q10[1]=v10[23:16]; q10[2]=v10[15:8];
        q11[0]=v11[31:24]; q11[1]=v11[23:16]; q11[2]=v11[15:8];
    end

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            for (ci = 0; ci < 3; ci = ci + 1) begin
                pa00[ci] <= 8'd0;    pa10[ci] <= 8'd0;
                phA[ci]  <= 18'sd0;  phB[ci]  <= 18'sd0;
                hrA[ci]  <= 8'd0;    hrB[ci]  <= 8'd0;
                pv[ci]   <= 18'sd0;  rs_r[ci] <= 8'd0;
            end
        end
        else case (state)
            // 段1: 寄存 p00/p10 并算水平乘积(1 减 + 1 乘)
            O_H1: for (ci = 0; ci < 3; ci = ci + 1) begin
                pa00[ci] <= q00[ci];
                pa10[ci] <= q10[ci];
                phA[ci]  <= ($signed({1'b0, q01[ci]}) - $signed({1'b0, q00[ci]}))
                            * $signed({1'b0, fx_r});
                phB[ci]  <= ($signed({1'b0, q11[ci]}) - $signed({1'b0, q10[ci]}))
                            * $signed({1'b0, fx_r});
            end
            // 段2: 上行/下行水平插值并钳位
            O_H2: for (ci = 0; ci < 3; ci = ci + 1) begin
                tA = $signed({1'b0, pa00[ci]}) + (phA[ci] >>> 8);
                tB = $signed({1'b0, pa10[ci]}) + (phB[ci] >>> 8);
                hrA[ci] <= clamp8(tA);
                hrB[ci] <= clamp8(tB);
            end
            // 段3: 垂直乘积
            O_V1: for (ci = 0; ci < 3; ci = ci + 1)
                pv[ci] <= ($signed({1'b0, hrB[ci]}) - $signed({1'b0, hrA[ci]}))
                          * $signed({1'b0, fy_r});
            // 段4: 垂直插值并钳位 → 最终通道值
            O_V2: for (ci = 0; ci < 3; ci = ci + 1) begin
                tV = $signed({1'b0, hrA[ci]}) + (pv[ci] >>> 8);
                rs_r[ci] <= clamp8(tV);
            end
            default: ;
        endcase
    end

    //--------------------------------------------------------------
    // 输出状态机
    //--------------------------------------------------------------
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state    <= O_IDLE;
            out_en   <= 1'b0;
            out_data <= 32'd0;
            out_row  <= 10'd0;
            out_col  <= 10'd0;
            k_r <= 19'd65536; dstw_r <= 12'd640; dsth_r <= 12'd480;
            x0_r <= 13'sd0;   y0_r <= 13'sd0;
            yy_r <= 13'sd0;   sy_prod <= 32'd0;
            sy0_r <= 12'd0;   sy1_r <= 12'd0;  fy_r <= 8'd0;
            xx_r <= 13'sd0;   sx_prod <= 32'd0;
            sx0_r <= 12'd0;   sx1_r <= 12'd0;  fx_r <= 8'd0;
            ia_r <= 2'd0;     ib_r <= 2'd0;
            raddr <= 10'd0;
            v00 <= 32'd0; v01 <= 32'd0; v10 <= 32'd0; v11 <= 32'd0;
        end
        else begin
            out_en <= 1'b0;                       // 默认: 每字 1 拍脉冲

            case (state)
            //---------------------------------------------
            // 等帧起点: 锁存本帧档位配置, 清计数
            //   · 100% 档(与源图同尺寸) → 旁路直通, 不做任何重采样
            //   · 其它档 → 进双线性插值状态机
            //---------------------------------------------
            O_IDLE: begin
                if (fs_pulse) begin
                    k_r     <= cfg_k;
                    dstw_r  <= cfg_dstw;
                    dsth_r  <= cfg_dsth;
                    x0_r    <= cfg_x0;
                    y0_r    <= cfg_y0;
                    out_row <= 10'd0;
                    out_col <= 10'd0;
                    // 100% 档判据: 定点映射恰好 1:1 且图像区=画布(无裁边/留黑)
                    if ((cfg_k == 19'd65536) &&
                        (cfg_dstw == SRC_W[11:0]) && (cfg_dsth == SRC_H[11:0]) &&
                        (SRC_W == CANV_W) && (SRC_H == CANV_H))
                        state <= O_BYP;
                    else
                        state <= O_ROW;
                end
            end
            //---------------------------------------------
            // 100% 档旁路: 源像素直通(输出与输入同速, 仅 1 拍寄存对齐)
            //   in_pix 是组合判出的"源像素有效" → 同拍锁存 out_en/out_data,
            //   二者相位天然一致; 每帧输出的字数 = 源像素数 = 640×480
            //   ★帧边界必须重新锁存档位并重新判定: 否则一旦进过旁路,
            //     之后把档位从 100% 调到其它档仍会错误地继续直通(不缩放)。
            //     fs_pulse(=写请求 ack, 与写 FIFO 清零同拍)时源像素尚未开始,
            //     因此本拍不丢像素。
            //---------------------------------------------
            O_BYP: begin
                if (fs_pulse) begin
                    k_r     <= cfg_k;
                    dstw_r  <= cfg_dstw;
                    dsth_r  <= cfg_dsth;
                    x0_r    <= cfg_x0;
                    y0_r    <= cfg_y0;
                    out_row <= 10'd0;
                    out_col <= 10'd0;
                    if ((cfg_k == 19'd65536) &&
                        (cfg_dstw == SRC_W[11:0]) && (cfg_dsth == SRC_H[11:0]) &&
                        (SRC_W == CANV_W) && (SRC_H == CANV_H))
                        state <= O_BYP;                    // 仍是 100% → 继续旁路
                    else
                        state <= O_ROW;                    // 已换档 → 转双线性插值
                end
                else if (in_pix) begin
                    out_en   <= 1'b1;
                    out_data <= in_data;
                end
            end
            //---------------------------------------------
            // 行起点: v = out_row - y0
            //---------------------------------------------
            O_ROW: begin
                yy_r  <= $signed({3'b000, out_row}) - y0_r;
                state <= O_MULY;
            end
            //---------------------------------------------
            // 判图像行 / 黑行; 图像行发起垂直乘法
            //---------------------------------------------
            O_MULY: begin
                if ((yy_r < 13'sd0) || (yy_r >= $signed({1'b0, dsth_r}))) begin
                    state <= O_BLK;                        // 图像区外 → 整行黑
                end
                else begin
                    sy_prod <= yy_r[12:0] * k_r;           // v>=0: 无符号乘正确
                    state   <= O_YMAP;
                end
            end
            //---------------------------------------------
            // 求 sy0/sy1/fy
            //---------------------------------------------
            O_YMAP: begin
                // 整数部分统一取 [31:16](Q16 定点); 越界钳到末行, 避免读到缓存外
                sy0_r <= (sy_prod[31:16] >= SRC_H[11:0] - 12'd1) ? (SRC_H[11:0] - 12'd1)
                                                                : sy_prod[31:16];
                sy1_r <= (sy_prod[31:16] >= SRC_H[11:0] - 12'd1) ? (SRC_H[11:0] - 12'd1)
                                                                : (sy_prod[31:16] + 12'd1);
                fy_r  <= sy_prod[15:8];                        // Q8 小数权重
                state <= O_WAIT;
            end
            //---------------------------------------------
            // 等两行源数据就绪(块有效位由输入侧行首/行末维护)
            //---------------------------------------------
            O_WAIT: begin
                if (hitA && hitB) begin
                    ia_r    <= ia_w;
                    ib_r    <= ib_w;
                    out_col <= 10'd0;
                    state   <= O_CU;
                end
            end
            //---------------------------------------------
            // 整行黑(图像区外)
            //---------------------------------------------
            O_BLK: begin
                if (out_tick) begin
                    out_en   <= 1'b1;
                    out_data <= 32'd0;
                    if (out_col == CANV_W[9:0] - 10'd1) begin
                        out_col <= 10'd0;
                        if (out_row == CANV_H[9:0] - 10'd1)
                            state <= O_IDLE;                  // 本帧输出完毕
                        else begin
                            out_row <= out_row + 10'd1;
                            state   <= O_ROW;
                        end
                    end
                    else
                        out_col <= out_col + 10'd1;
                end
            end
            //---------------------------------------------
            // 列起点: u = out_col - x0
            //---------------------------------------------
            O_CU: begin
                xx_r  <= $signed({3'b000, out_col}) - x0_r;
                state <= O_CCHK;
            end
            //---------------------------------------------
            // 判图像列 / 黑列; 图像列发起列乘法
            //---------------------------------------------
            O_CCHK: begin
                if ((xx_r < 13'sd0) || (xx_r >= $signed({1'b0, dstw_r}))) begin
                    if (out_tick) begin
                        out_en   <= 1'b1;                         // 黑像素
                        out_data <= 32'd0;
                        if (out_col == CANV_W[9:0] - 10'd1) begin
                            out_col <= 10'd0;
                            if (out_row == CANV_H[9:0] - 10'd1)
                                state <= O_IDLE;
                            else begin
                                out_row <= out_row + 10'd1;
                                state   <= O_ROW;
                            end
                        end
                        else begin
                            out_col <= out_col + 10'd1;
                            state   <= O_CU;
                        end
                    end
                end
                else begin
                    sx_prod <= xx_r[12:0] * k_r;              // u>=0: 无符号乘正确
                    state   <= O_CX;
                end
            end
            //---------------------------------------------
            // 求 fx/sx1, 发起 sx0 读(地址 = 整数部分)
            //---------------------------------------------
            O_CX: begin
                // 整数部分统一取 [31:16](与行方向一致, 避免位宽不统一埋雷)
                sx0_r <= (sx_prod[31:16] >= SRC_W[11:0] - 12'd1) ? (SRC_W[11:0] - 12'd1)
                                                                 : sx_prod[31:16];
                sx1_r <= (sx_prod[31:16] >= SRC_W[11:0] - 12'd1) ? (SRC_W[11:0] - 12'd1)
                                                                 : (sx_prod[31:16] + 12'd1);
                fx_r  <= sx_prod[15:8];                        // Q8 小数权重
                raddr <= sx_prod[31:16];                       // 读 A[x0]/B[x0]
                state <= O_R1;
            end
            //---------------------------------------------
            // sx0 读延迟
            //---------------------------------------------
            O_R1: state <= O_R2;
            //---------------------------------------------
            // 取 A[x0]/B[x0], 发起 sx1 读
            //---------------------------------------------
            O_R2: begin
                v00   <= mxA0;
                v10   <= mxB0;
                raddr <= sx1_r;
                state <= O_R3;
            end
            //---------------------------------------------
            // sx1 读延迟
            //---------------------------------------------
            O_R3: state <= O_R4;
            //---------------------------------------------
            // 取 A[x1]/B[x1] → 转入 4 级插值流水
            //---------------------------------------------
            O_R4: begin
                v01   <= mxA0;
                v11   <= mxB0;
                state <= O_H1;
            end
            //---------------------------------------------
            // 插值流水段1~4(纯粹为把长组合路径切成 4 拍; 运算在
            // 上面的流水 always 里按 state 逐级完成)
            //---------------------------------------------
            O_H1: state <= O_H2;
            O_H2: state <= O_V1;
            O_V1: state <= O_V2;
            O_V2: state <= O_OUT;
            //---------------------------------------------
            // 输出该像素(数据 = 流水段4 的结果 rs_r)
            //---------------------------------------------
            O_OUT: begin
                if (out_tick) begin
                    out_en   <= 1'b1;
                    out_data <= {rs_r[0], rs_r[1], rs_r[2], 8'b0};
                    if (out_col == CANV_W[9:0] - 10'd1) begin
                        out_col <= 10'd0;
                        if (out_row == CANV_H[9:0] - 10'd1)
                            state <= O_IDLE;
                        else begin
                            out_row <= out_row + 10'd1;
                            state   <= O_ROW;
                        end
                    end
                    else begin
                        out_col <= out_col + 10'd1;
                        state   <= O_CU;
                    end
                end
            end
            default: state <= O_IDLE;
            endcase
        end
    end

endmodule
