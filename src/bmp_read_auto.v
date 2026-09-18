//====================================================================
// 模块名 : bmp_read_auto.v
// 功能   : BMP 自动轮播状态机 —— 按"卡内扇区分区"播放素材
//
// 相对旧版(裸固定区自动轮播)的改动：
//   1. 分区参数(扫描起点/回卷上限/图片张数)由固定参数提升为**可运行时
//      重载端口 zone_start/zone_wrap/zone_max_img** + zone_load 触发。
//      各场景素材在卡内占用不同扇区区间，场景切换(拨码)时顶层查表给出
//      新分区并打一拍 zone_load → 本模块在安全边界重启扫描，实现一卡多区。
//   2. 分区应用时机刻意选在安全点，避免中途撤 SD 读请求造成扇区残流
//      污染头部解析、或帧写只写一半挂起 write 通路：
//        · S_IDLE(空闲/初始化完成) —— 上电或复位后默认进入；
//        · S_HOLD(显示保持) —— 正常轮播每张图之间的自然边界。
//      zone_load 若在读图/扫描中途到达，只置 pending 标志，等当前图片
//      完整读完进入 S_HOLD 后才切到新分区(读完整张再切, 帧写不中断)。
//   3. 冻结(slide_en=0, 应急抢占)与手动切图(key_trigger)语义保持不变。
//   4. 新增 key_prev(手动"上一张")：分区内按序号从起点重扫, 跳过前面
//      的图直到目标序号, 支持图片回看; 同时导出 img_no(当前图序号)。
//   5. 批次4(小鹅通第三讲 §3.2 period_cfg 接口)：轮播间隔由固定 parameter
//      提升为**运行时输入 slide_interval**(ui_key_ctrl 周期档 2/3/5/10/30 s),
//      带下限校验(非法值忽略, 保持上一次有效值); 复位默认 = SLIDE_INTERVAL
//      (3s), 故未接该端口时行为与批次3 及以前完全一致。
// 底层原理(与官方一致)：
//   不解析 FAT 文件系统，从分区起点每 8 扇区(4KB 簇)跳读检查文件头
//   "BM"+640×480×24bit 严格校验，命中即整张读入 SDRAM
//
// ── 2026-09-17 批次3「容错恢复」(小鹅通第五讲·第4课_系统稳定性增强) ──
//   按课程 5 项必做优化落地, 目标: 一张坏图 / 一次读卡停顿不再造成卡死或花屏
//   ① BMP 严格校验(§2.1): 由"6 项 + file_len 精确等于 921654"改为课程
//      9 项一致性校验(签名/DIB头≥40/宽/高/平面数=1/位深24/无压缩/
//      pixel_offset∈[54,file_len)/file_len≥pixel_offset+像素字节数)。
//      · 放宽精确匹配 → 允许带多余尾数据或非 54 偏移的合法 BMP;
//      · 新增平面数/压缩/DIB/偏移 4 项 → 随机数据几乎不可能被误判为 BMP;
//      · 像素起点同时由"固定跳 54 字节"改为按 pixel_offset 取(更严谨)。
//   ② 错误码上报(§2.2): bmp_error[3:0] 电平(0无/1头校验/2超时/3截断),
//      供数码管/OSD 观测(§2.10 调试技巧)。清零时机 = 一帧成功写完(进 S_HOLD)。
//   ③ 坏图快速跳过(§2.3): 扫描时扇区以 "BM" 开头但 9 项校验不过 → 判为
//      "坏 BMP 文件"(持久性错误, 重试必然复现) → 报 ERR_HEADER 并按 file_len
//      折算簇数直接跳过整个文件(原来只 +8 扇区, 大文件要扫几百次)。
//   ④ 加载超时(§2.4): SD_READ_TIMEOUT_MS(默认 500ms)内无任何扇区读完
//      (无进展) → 判读卡死锁, 报 ERR_TIMEOUT 并回 S_IDLE 重新起请求。
//      ※ 课程写法是"进入状态时清零"; 本工程一个分区慢扫可能 >500ms 会误判,
//        故改为"每次扇区读完(有进展)即清零" —— 语义 = 连续 500ms 无进展。
//      ※ 已知边界(如实记录): 官方 sd_card_cmd 在 S_READ_WAIT 等 0xFE 数据
//        令牌时自身无超时, 读中途拔卡后该控制器无法自行退出; 本超时保证的是
//        "显示通路不死 + 错误可观测 + 重新发起请求", 彻底恢复需复位 SD 控制器。
//   ⑤ 像素完整性校验(§2.5): 计数实际拼出的像素数, 整帧读完时若不足 640×480
//      → 报 ERR_TRUNCATED(截断文件会让 SDRAM 半新半旧 → 画面撕裂)。
//   ⑥ 恢复策略(§2.2 重试→跳过→保留上一帧): 读图途中出错先重试 1 次
//      (MAX_RETRIES, 复用 reload_pend 原地重读机制 → 图序号不变),
//      仍失败则跳过本张继续往后扫。头校验失败发生在发 write_req 之前,
//      SDRAM 未被触碰 → 自然保留上一帧, 不花屏。
//      ※ 课程把恢复逻辑放 sd_card_bmp(因官方 bmp_read 是纯执行器); 本模块
//        自身即加载状态机, 恢复逻辑放回状态机内部单点实现, 避免两个状态机
//        争抢 write_req / 扫描地址。对外行为与课程一致。
//====================================================================

`timescale 1ns/1ps

module bmp_read_auto #(
    parameter [31:0] SLIDE_INTERVAL   = 32'd300_000_000, // 轮播间隔兜底值(周期) 100MHz=3s
                                                        // (仅当 slide_interval 输入非法时使用)
    // ---- 批次4 运行时可配轮播间隔(小鹅通第三讲 §3.2 period_cfg 接口) ----
    parameter [31:0] MIN_PERIOD_CYCLES = 32'd50_000_000, // 间隔下限 0.5s@100MHz(课程 §3.2)
    parameter [31:0] ZONE_START_SECTOR = 32'd126000,     // 复位默认分区起点(菜单分区)
    parameter [31:0] ZONE_WRAP_SECTOR  = 32'd400000,     // 复位默认分区上限(回卷)
    parameter [31:0] ZONE_MAX_IMAGES   = 32'd5,          // 复位默认分区图片张数
    // ---- 批次3 容错参数(小鹅通第五讲 §2.4/§2.6 参数集中化) ----
    parameter [31:0] BMP_PIXEL_BYTES   = 32'd921600,     // 期望像素字节数=640×480×3(仿真可用小子集覆盖)
    parameter [15:0] SD_READ_TIMEOUT_MS= 16'd500,        // SD 读超时(ms): 连续无扇区进展即判死锁
    parameter [31:0] CLK_FREQ_HZ       = 32'd100_000_000,// 本模块时钟频率=sd_card_clk(100MHz)
    parameter [3:0]  MAX_RETRIES       = 4'd1            // 单张图加载失败重试次数(课程默认 1)
)(
    input               clk,                       // SD 卡时钟(100MHz)
    input               rst,                       // 高电平有效复位
    output              ready,                     // 空闲标志(仅调试用)
    input               sd_init_done,              // SD 卡初始化完成标志
    input               key_trigger,               // 按键手动切图/下一张(单周期高脉冲, 与 clk 同步)
    input               key_prev,                  // 按键手动"上一张"(单周期高脉冲, 与 clk 同步)
    input               slide_en,                  // 轮播使能(应急=0 冻结当前画面, 保留不清屏)
    // ---- 批次4 运行时可配轮播间隔(sd_card_clk 同域, 单周期脉冲不需要) ----
    //   由 ui_key_ctrl 的"周期档"给出(2/3/5/10/30 s 对应周期数);
    //   小于 MIN_PERIOD_CYCLES(0.5s) 视为非法 → 保持上一次有效值,
    //   复位默认 = SLIDE_INTERVAL(3s), 与批次3 及之前的固定行为完全一致。
    //   更新时机: 下一拍起生效; 若本拍正处 S_HOLD 且新值更小, 则可能立即
    //   满足条件切下一张 —— 语义等同"改完间隔马上生效", 不额外引入挂起态。
    input       [31:0] slide_interval,             // 轮播间隔(时钟周期)
    // ---- 分区重载(场景切换用, sd_card_clk 同域) ----
    // zone_load=1 的当拍锁存以下三参数; 在安全边界(S_IDLE/S_HOLD)重启扫描
    input       [31:0] zone_start,                 // 新分区扫描起点扇区
    input       [31:0] zone_wrap,                  // 新分区扫描上限(超过回卷到起点)
    input       [31:0] zone_max_img,               // 新分区图片张数(轮播一圈张数)
    input               zone_load,                 // 分区重载请求(单周期脉冲)
    // ---- 原地重读请求(缩放档变化用, sd_card_clk 同域) ----
    // reload_req: 当前显示图的缩放大/小档变化后, 立即重读"同一张图",
    //   使新档位马上生效(不切图、不改变图序号)。任意时刻到达都置挂起标志,
    //   在安全边界 S_HOLD 应用, 避免中断正在进行的帧写。
    input               reload_req,                // 重读当前图请求(单周期脉冲)
    output reg  [3:0]   state_code,                // 状态码(数码管显示)
    input      [15:0]   bmp_width,                 // BMP 图像宽度(固定 640)
    output reg          write_req,                 // 写帧请求(启动写 SDRAM)
    input               write_req_ack,             // 写帧响应(写通路已就绪)
    output reg          sd_sec_read,               // SD 卡扇区读请求
    output reg  [31:0]  sd_sec_read_addr,          // SD 卡扇区读地址
    input      [7:0]    sd_sec_read_data,          // SD 卡扇区读数据(字节)
    input               sd_sec_read_data_valid,    // 扇区读数据有效
    input               sd_sec_read_end,           // 扇区读结束(512 字节读完)
    output reg          bmp_data_wr_en,            // BMP 像素数据写使能
    output reg  [23:0]  bmp_data,                  // BMP 像素数据(24bit RGB)
    output      [7:0]   img_no,                    // 当前显示图序号(1..N; 0=空闲/未就绪)
    output              img_busy,                  // 1=底层图加载忙(扫/读/挂起/未初始化)
    output reg  [3:0]   bmp_error                  // 加载错误码(0无/1头校验/2超时/3截断)
);

    //--------------------------------------------------------------
    // 状态定义
    //--------------------------------------------------------------
    localparam [3:0] S_IDLE      = 4'd0;  // SD 初始化 / 空闲(分区应用点)
    localparam [3:0] S_FIND      = 4'd1;  // 扫描查找 BMP 文件头
    localparam [3:0] S_READ_WAIT = 4'd2;  // 等待写通路(FIFO)就绪
    localparam [3:0] S_READ      = 4'd3;  // 读取图像像素数据
    localparam [3:0] S_HOLD      = 4'd4;  // 显示保持(轮播间隔 / 分区应用点)

    localparam [9:0] HEADER_SIZE = 10'd54; // BMP 文件头 54 字节

    //--------------------------------------------------------------
    // 错误码(小鹅通第五讲 §2.2) 与容错参数派生值(§2.4/§2.5)
    //--------------------------------------------------------------
    localparam [3:0]  ERR_NONE      = 4'd0; // 无错误
    localparam [3:0]  ERR_HEADER    = 4'd1; // BMP 头 9 项严格校验不通过(坏图)
    localparam [3:0]  ERR_TIMEOUT   = 4'd2; // SD 连续 500ms 无扇区进展(读死锁)
    localparam [3:0]  ERR_TRUNCATED = 4'd3; // 像素数据截断(不足 640×480)
    // 期望像素数 = 像素字节数/3 (默认 921600/3 = 307200 = 640×480)
    localparam [31:0] BMP_PIXEL_COUNT = BMP_PIXEL_BYTES / 32'd3;
    // 超时阈值(时钟周期): 500ms@100MHz = 50,000,000
    //   ※ 先除后乘: 直接乘会超出 32bit(500×1e8=5e10)导致静默溢出
    localparam [31:0] TIMEOUT_CYCLES  = SD_READ_TIMEOUT_MS * (CLK_FREQ_HZ / 32'd1000);

    //--------------------------------------------------------------
    // 内部寄存器
    //--------------------------------------------------------------
    reg [3:0]   state;
    reg [9:0]   rd_cnt;          // 扇区内字节计数(找图阶段)
    reg [7:0]   header_0;        // 文件头第 0 字节(应为 'B')
    reg [7:0]   header_1;        // 文件头第 1 字节(应为 'M')
    reg [31:0]  file_len;        // BMP 文件总长度(从头信息读取)
    reg [31:0]  pixel_offset;    // 像素数据起始偏移(第 10~13 字节, 应 54)
    reg [31:0]  dib_size;        // DIB 头大小(第 14~17 字节, 应 ≥40)
    reg [31:0]  width;           // BMP 宽度(从头信息读取)
    reg [31:0]  height;          // BMP 高度(从头信息读取, 校验 480)
    reg [15:0]  planes;          // 平面数(第 26~27 字节, 应为 1)
    reg [15:0]  bit_cnt;         // BMP 色深(从头信息读取, 校验 24bit)
    reg [31:0]  compression;     // 压缩方式(第 30~33 字节, 应为 0)
    reg [31:0]  pixel_cnt;       // 已输出像素数(读图阶段, 完整性校验 §2.5)
    reg         hdr_passed;      // 打拍: 已越过文件头(= bmp_len_cnt >= pixel_offset)
    reg         pixel_full;      // 打拍: 像素数已达标(= pixel_cnt >= BMP_PIXEL_COUNT)
    reg [31:0]  sd_timeout_cnt;  // SD 无进展计时(周期, §2.4)
    reg [3:0]   retry_cnt;       // 本张图已重试次数(§2.2)
    reg [31:0]  file_base_addr;  // 命中文件所在簇地址(出错重试/跳过用)
    reg [31:0]  skip_lat;        // 坏图快跳步长(打拍, §2.3)
    reg [31:0]  wrap_lim;        // 坏图快跳的回卷阈值 = z_wrap - skip_lat(打拍)
    reg [31:0]  bmp_len_cnt;     // 读图阶段的字节计数器
    reg         found;           // 命中标志(找到 "BM" + 宽度匹配)
    reg [1:0]   bmp_len_cnt_tmp; // RGB 三字节计数(0/1/2)
    reg [31:0]  hold_cnt;        // 轮播间隔计数器
    reg [31:0]  period_cyc;      // 生效的轮播间隔(寄存器版: 合法性过滤后的 slide_interval)
    reg [31:0]  img_cnt;         // 当前分区已找到的图片计数(达到 z_max 后回卷)

    // 手动"上一张"的按序号目标扫描(由于分区素材连续排布, 从分区起点重扫,
    // 依次命中各图并跳过, 直到第 scan_tgt 号图):
    reg         scan_tgt_en;     // 1=本次扫描以 scan_tgt 号图为目标
    reg [31:0]  scan_tgt;        // 目标图序号(0 基: 第 N 张 => scan_tgt=N-1)
    reg [31:0]  pass_cnt;        // 已跳过的命中图计数(抵达目标前计数)
    reg         found_clr;       // 本张"命中"已处理, 请求清 found 标志

    // 当前生效分区(复位=默认/菜单分区; 仅 S_IDLE 应用时更新)
    reg [31:0]  z_start;
    reg [31:0]  z_wrap;
    reg [31:0]  z_max;
    // 请求分区(zone_load 当拍捕获)
    reg [31:0]  req_start;
    reg [31:0]  req_wrap;
    reg [31:0]  req_max;
    reg         zone_pend;       // 1=有未应用的分区请求(等待安全边界)
    reg         reload_pend;     // 1=有未应用的"原地重读当前图"请求(缩放档变化)
    reg         skip_pend;       // 1=重试耗尽需跳过本图, 跳过地址延到 S_IDLE 计算(§时序)

    //--------------------------------------------------------------
    // BMP 头严格校验(小鹅通第五讲 §2.1, 9 项)
    //   与课程 bmp24_decoder.validate_header 逐项对应:
    //     签名 / DIB头≥40 / 宽 / 高 / 平面数 / 位深 / 无压缩 /
    //     pixel_offset 范围 / file_len 能否装下全部像素
    //   (课程第 9 项"上游文件系统错误"本工程无文件系统层, 不适用)
    //   时序: 依赖字段(偏移 2~33)全部在 rd_cnt 到达 54 前锁存完毕,
    //         故 rd_cnt==54 处判定成立。用一致性校验而非"精确等于某常量",
    //         允许合法 BMP 带尾随数据或非 54 的像素偏移。
    //--------------------------------------------------------------
    wire header_match = (header_0 == "B") && (header_1 == "M") &&
                        (dib_size    >= 32'd40) &&
                        (width[15:0] == bmp_width) &&
                        (height      == 32'd480) &&
                        (planes      == 16'd1) &&
                        (bit_cnt     == 16'd24) &&
                        (compression == 32'd0) &&
                        (pixel_offset >= 32'd54) &&
                        (pixel_offset <  file_len) &&
                        (file_len    >= (pixel_offset + BMP_PIXEL_BYTES));

    //--------------------------------------------------------------
    // 坏图快跳步长(§2.3): 把 file_len 折算成"能覆盖整个文件的最小 8 扇区(4KB 簇)倍数"
    //   等价式: ceil(file_len/512) 再上取整到 8 的倍数
    //         ≡ ceil(file_len/4096) × 8 = ((file_len + 4095) >> 12) << 3
    //   ※ 用等价式是为了"只做一次 32bit 加法": 原写法 (+511)>>9 再 +7 再掩码 是
    //     三级 32bit 运算, 综合实测把 file_len→sd_sec_read_addr 拉成 12.8ns 长链
    //     (48 个 FEPS 违例)。移位是纯连线, 不占逻辑级。
    //   ※ 下限 8 扇区: file_len 极小、或 +4095 溢出(>0xFFFFF000) 都会把步长算成 0,
    //     那时地址原地不动 → 每次超时后重扫同一地址(永久打转), 故 0 一律退回 8。
    //--------------------------------------------------------------
    wire [31:0] skip_step_raw = ((file_len + 32'd4095) >> 12) << 3;
    wire [31:0] skip_next     = (skip_step_raw == 32'd0) ? 32'd8 : skip_step_raw;

    //--------------------------------------------------------------
    // 步长/回卷阈值 打拍(§2.3 时序): 文件头读齐后(file_len 锁存完成)分两拍存好
    //   · 第 1 拍(rd_cnt==6): 算步长  skip_lat = ((file_len+4095)>>12)<<3
    //   · 第 2 拍(rd_cnt==7): 算阈值  wrap_lim = z_wrap - skip_lat
    //     (用 "addr >= z_wrap-skip" 等价判定 "addr+skip >= z_wrap", 让加法与比较
    //      并联而不是串联 —— 否则又是一条 加法→比较 的 10ns 链)
    //   为什么必须打拍: 若在扫描分支里现算, path = file_len→加法→比较→再加地址→
    //     再比较→地址 mux, 实测 12.8ns > 10ns 周期。打拍后扫描分支只剩
    //     "寄存器比较 ∥ 寄存器加法 → mux", 与原 "+8 扇区" 分支同级。
    //   安全性: 两个值都在"解析本扇区文件头"时刷新, 而使用点(坏图分支/S_READ 出错
    //     分支)最早也在本扇区读完(sd_sec_read_end)之后, 远晚于 rd_cnt==7;
    //     分区(z_wrap)只在 S_IDLE 应用, 应用后必先重扫到某个文件头才可能用到。
    //--------------------------------------------------------------
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            skip_lat <= 32'd8;
            wrap_lim <= 32'd0;
        end
        else if (state == S_FIND && sd_sec_read_data_valid) begin
            if (rd_cnt == 10'd6) skip_lat <= skip_next;
            if (rd_cnt == 10'd7)
                wrap_lim <= (z_wrap < skip_lat) ? 32'd0 : (z_wrap - skip_lat);
        end
    end

    // BMP 像素数据有效：已越过文件头(hdr_passed, 按 pixel_offset)、
    //   不超过文件长度(bmp_len_cnt<file_len)、且未读满期望像素数(!pixel_full)
    //   ※ hdr_passed / pixel_full 是打拍版(§时序), 见下方对应 always 块 ——
    //     原写法把 "bmp_len_cnt>=pixel_offset" 与 "pixel_cnt<BMP_PIXEL_COUNT"
    //     两条 32bit 变量比较直接组合进来, 会与 frame_read_done 的
    //     "bmp_len_cnt>=file_len" 一起汇入主状态机的整块使能锥, post-route
    //     实测 11.602ns > 11.517ns(Setup -85ps / 8 FEPS)。打拍后比较结果只
    //     驱动一个寄存器, 长链被截断; 逐字节行为与组合判定完全一致。
    wire bmp_data_valid = (sd_sec_read_data_valid &&
                           hdr_passed               &&
                           bmp_len_cnt < file_len   &&
                           ~pixel_full);
    // 与 bmp_data_wr_en 同条件的一个像素拼出事件(§2.5 完整性计数)
    wire bmp_pixel_out = (bmp_len_cnt_tmp == 2'd2) && bmp_data_valid;

    //--------------------------------------------------------------
    // 像素有效窗口的两个"打拍判定"(§2.1/§2.5, 纯时序优化, 语义不变)
    //   · hdr_passed : 当前字节已是像素数据(bmp_len_cnt >= pixel_offset)
    //   · pixel_full : 已凑满 BMP_PIXEL_COUNT 个像素
    //   bmp_len_cnt 在 S_READ 内每有效字节 +1(单调), pixel_cnt 每 3 字节 +1,
    //   故用"再加 1 是否达标"前瞻一拍置位 —— 落在寄存器上的值恰好在
    //   bmp_len_cnt 等于 pixel_offset 那一拍 / 第 BMP_PIXEL_COUNT 个像素
    //   产出那一拍之后生效, 与原来的逐字节组合判定等价。
    //--------------------------------------------------------------
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            hdr_passed <= 1'b0;
            pixel_full <= 1'b0;
        end
        else if (state != S_READ) begin
            // 离开读图态即复位两个标志(与 bmp_len_cnt/pixel_cnt 的清零时机一致)
            hdr_passed <= 1'b0;
            pixel_full <= 1'b0;
        end
        else begin
            if (sd_sec_read_data_valid)
                hdr_passed <= (bmp_len_cnt + 32'd1 >= pixel_offset);
            if (bmp_pixel_out)
                pixel_full <= (pixel_cnt + 32'd1 >= BMP_PIXEL_COUNT);
        end
    end

    assign ready = (state == S_IDLE);
    // 底层图加载忙: SD 未初始化 / 有分区请求未应用 / 扫找或读图中。
    //   S_HOLD(显示保持)且无挂起 = 当前帧已完整写入 SDRAM(稳定画面) → 0,
    //   供视频域 display_adjust 做"切场淡出→等图就绪→淡入"的锚点。
    assign img_busy = ~sd_init_done | zone_pend |
                      (state == S_FIND) | (state == S_READ_WAIT) | (state == S_READ);
    // 当前显示图序号(= img_cnt; 保持态为 1..z_max, 空闲/扫描期为上次值或 0)
    assign img_no = img_cnt[7:0];

    //--------------------------------------------------------------
    // zone_load 捕获(独立于主状态机, 只锁存目标分区参数):
    //   req_* 由本 always 唯一驱动; zone_pend 挂起标志改由主状态机
    //   always 唯一驱动(见下)——避免同一 reg 被两个 always 写(多重驱动)
    //--------------------------------------------------------------
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            req_start <= ZONE_START_SECTOR;
            req_wrap  <= ZONE_WRAP_SECTOR;
            req_max   <= ZONE_MAX_IMAGES;
        end
        else if (zone_load) begin
            req_start <= zone_start;
            req_wrap  <= zone_wrap;
            req_max   <= zone_max_img;
        end
    end

    //--------------------------------------------------------------
    // 找图阶段字节计数(rd_cnt)
    //--------------------------------------------------------------
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            rd_cnt <= 10'd0;
        end
        else if (state == S_FIND) begin
            if (sd_sec_read_data_valid)
                rd_cnt <= rd_cnt + 10'd1;
            else if (sd_sec_read_end)
                rd_cnt <= 10'd0;
        end
        else begin
            rd_cnt <= 10'd0;
        end
    end

    //--------------------------------------------------------------
    // 文件头解析(锁存偏移 0~33 的字段, 读齐 54 字节后做 9 项严格校验)
    //--------------------------------------------------------------
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            header_0     <= 8'd0;
            header_1     <= 8'd0;
            file_len     <= 32'd0;
            pixel_offset <= 32'd0;
            dib_size     <= 32'd0;
            width        <= 32'd0;
            height       <= 32'd0;
            planes       <= 16'd0;
            bit_cnt      <= 16'd0;
            compression  <= 32'd0;
            found        <= 1'b0;
        end
        else if (state == S_FIND && sd_sec_read_data_valid) begin
            if (rd_cnt == 10'd0)  header_0        <= sd_sec_read_data;
            if (rd_cnt == 10'd1)  header_1        <= sd_sec_read_data;
            // 文件长度(小端, 第 2~5 字节)
            if (rd_cnt == 10'd2)  file_len[7:0]   <= sd_sec_read_data;
            if (rd_cnt == 10'd3)  file_len[15:8]  <= sd_sec_read_data;
            if (rd_cnt == 10'd4)  file_len[23:16] <= sd_sec_read_data;
            if (rd_cnt == 10'd5)  file_len[31:24] <= sd_sec_read_data;
            // 像素数据起始偏移(小端, 第 10~13 字节; §2.1 新增校验用)
            if (rd_cnt == 10'd10) pixel_offset[7:0]   <= sd_sec_read_data;
            if (rd_cnt == 10'd11) pixel_offset[15:8]  <= sd_sec_read_data;
            if (rd_cnt == 10'd12) pixel_offset[23:16] <= sd_sec_read_data;
            if (rd_cnt == 10'd13) pixel_offset[31:24] <= sd_sec_read_data;
            // DIB 头大小(小端, 第 14~17 字节)
            if (rd_cnt == 10'd14) dib_size[7:0]   <= sd_sec_read_data;
            if (rd_cnt == 10'd15) dib_size[15:8]  <= sd_sec_read_data;
            if (rd_cnt == 10'd16) dib_size[23:16] <= sd_sec_read_data;
            if (rd_cnt == 10'd17) dib_size[31:24] <= sd_sec_read_data;
            // 图像宽度(小端, 第 18~21 字节)
            if (rd_cnt == 10'd18) width[7:0]      <= sd_sec_read_data;
            if (rd_cnt == 10'd19) width[15:8]     <= sd_sec_read_data;
            if (rd_cnt == 10'd20) width[23:16]    <= sd_sec_read_data;
            if (rd_cnt == 10'd21) width[31:24]    <= sd_sec_read_data;
            // 图像高度(小端, 第 22~25 字节)
            if (rd_cnt == 10'd22) height[7:0]     <= sd_sec_read_data;
            if (rd_cnt == 10'd23) height[15:8]    <= sd_sec_read_data;
            if (rd_cnt == 10'd24) height[23:16]   <= sd_sec_read_data;
            if (rd_cnt == 10'd25) height[31:24]   <= sd_sec_read_data;
            // 平面数(小端, 第 26~27 字节; §2.1 新增校验用)
            if (rd_cnt == 10'd26) planes[7:0]     <= sd_sec_read_data;
            if (rd_cnt == 10'd27) planes[15:8]    <= sd_sec_read_data;
            // 色深(小端, 第 28~29 字节)
            if (rd_cnt == 10'd28) bit_cnt[7:0]    <= sd_sec_read_data;
            if (rd_cnt == 10'd29) bit_cnt[15:8]   <= sd_sec_read_data;
            // 压缩方式(小端, 第 30~33 字节; §2.1 新增校验用)
            if (rd_cnt == 10'd30) compression[7:0]   <= sd_sec_read_data;
            if (rd_cnt == 10'd31) compression[15:8]  <= sd_sec_read_data;
            if (rd_cnt == 10'd32) compression[23:16] <= sd_sec_read_data;
            if (rd_cnt == 10'd33) compression[31:24] <= sd_sec_read_data;
            // 头读齐即做 9 项严格校验(§2.1)
            if (rd_cnt == HEADER_SIZE && header_match)
                found <= 1'b1;
        end
        else if ((state != S_FIND) || found_clr) begin
            found <= 1'b0;
        end
    end

    //--------------------------------------------------------------
    // 读图阶段字节计数器(bmp_len_cnt)
    //--------------------------------------------------------------
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            bmp_len_cnt <= 32'd0;
        end
        else if (state == S_READ) begin
            if (sd_sec_read_data_valid)
                bmp_len_cnt <= bmp_len_cnt + 32'd1;
        end
        else if (state == S_HOLD || state == S_IDLE) begin
            bmp_len_cnt <= 32'd0;   // 进入保持态/空闲时清零, 准备下一次读图
        end
    end

    //--------------------------------------------------------------
    // RGB 三字节计数(把字节流拼接成 24bit 像素)
    //--------------------------------------------------------------
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            bmp_len_cnt_tmp <= 2'd0;
        end
        else if (state == S_READ) begin
            if (bmp_data_valid)
                bmp_len_cnt_tmp <= (bmp_len_cnt_tmp == 2'd2) ? 2'd0 : bmp_len_cnt_tmp + 2'd1;
        end
        else if (state == S_HOLD || state == S_IDLE) begin
            bmp_len_cnt_tmp <= 2'd0;
        end
    end

    //--------------------------------------------------------------
    // BMP 像素数据拼接输出：每 3 字节(B,G,R)拼成一个 24bit 像素
    //--------------------------------------------------------------
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            bmp_data_wr_en <= 1'b0;
            bmp_data       <= 24'd0;
        end
        else if (state == S_READ) begin
            if (bmp_len_cnt_tmp == 2'd2 && bmp_data_valid) begin
                bmp_data_wr_en  <= 1'b1;
                bmp_data[23:16] <= sd_sec_read_data;   // R
            end
            else if (bmp_len_cnt_tmp == 2'd1 && bmp_data_valid) begin
                bmp_data_wr_en  <= 1'b0;
                bmp_data[15:8]  <= sd_sec_read_data;   // G
            end
            else if (bmp_len_cnt_tmp == 2'd0 && bmp_data_valid) begin
                bmp_data_wr_en  <= 1'b0;
                bmp_data[7:0]   <= sd_sec_read_data;   // B
            end
            else begin
                bmp_data_wr_en <= 1'b0;
            end
        end
        else begin
            bmp_data_wr_en <= 1'b0;
        end
    end

    //--------------------------------------------------------------
    // 像素完整性计数(小鹅通第五讲 §2.5)
    //   统计实际拼出的 24bit 像素个数; 整帧读完时若 < 期望值 → 判像素截断。
    //   S_HOLD / S_IDLE 清零, 与 bmp_len_cnt 同步(下一次读图从 0 起算)。
    //   ※ 边界说明(如实记录): 像素计数与 bmp_len_cnt 同源计数, 而 9 项校验
    //     已保证 file_len ≥ pixel_offset + 像素字节数, 故"读到 file_len 却像素
    //     不足"在理想通路下不会发生 —— 此项实为**守卫式防御**(防数据有效脉冲
    //     缺失/计数逻辑异常), 不是主要检测手段。真实的"卡内数据读不全"表现为
    //     读停住无进展 → 由超时(ERR_TIMEOUT)兜住; 而"文件被截断但头里 file_len
    //     仍写全"这种情况, 在没有文件系统/目录项做二次比对的前提下(见文件头),
    //     本层无法识别(会继续读到后继文件的数据), 需靠上层分区间距约定规避。
    //--------------------------------------------------------------
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            pixel_cnt <= 32'd0;
        end
        else if (state == S_HOLD || state == S_IDLE) begin
            pixel_cnt <= 32'd0;
        end
        else if (bmp_pixel_out) begin
            pixel_cnt <= pixel_cnt + 32'd1;
        end
    end

    //--------------------------------------------------------------
    // SD 读超时计时(小鹅通第五讲 §2.4): "连续无扇区进展"计时
    //   · 只在扫图(S_FIND)/读图(S_READ)阶段计时, 其它状态清零
    //     (等效于课程"进入 ST_SCAN/ST_LOAD_DATA 时清零");
    //   · 每次扇区读完(有进展)也清零 —— 语义 = 连续 500ms 无进展即判死锁。
    //     ※ 课程写法为"仅进入状态清零"; 本工程一次分区慢扫可能 >500ms,
    //       按课程原样会误判超时, 故按"有无进展"计时(见文件头说明)。
    //   · 超时阈值 TIMEOUT_CYCLES = 500ms @100MHz = 50,000,000 周期。
    //--------------------------------------------------------------
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            sd_timeout_cnt <= 32'd0;
        end
        else if ((state != S_FIND && state != S_READ) || sd_sec_read_end) begin
            sd_timeout_cnt <= 32'd0;
        end
        else begin
            sd_timeout_cnt <= sd_timeout_cnt + 32'd1;
        end
    end
    wire sd_timeout = (sd_timeout_cnt >= TIMEOUT_CYCLES);

    //--------------------------------------------------------------
    // 读图阶段"整帧读完"与"致命错误"判定(供 S_READ 单点判决)
    //   frame_read_done: 扇区边界且已读够 file_len 字节
    //   load_fatal     : 读超时, 或整帧读完但像素数不足(截断)
    //--------------------------------------------------------------
    wire frame_read_done = (state == S_READ) && sd_sec_read_end && (bmp_len_cnt >= file_len);
    wire load_fatal      = (state == S_READ) &&
                           (sd_timeout || (frame_read_done && ~pixel_full));

    //--------------------------------------------------------------
    // 轮播间隔寄存器(批次4, §3.2): 只在输入合法(≥下限 0.5s)时更新
    //   · 复位值 = SLIDE_INTERVAL(3s) —— 与批次3 前的固定 parameter 完全一致,
    //     ui_key_ctrl 未接/未驱动时行为不变(上电默认档也是 3s)。
    //   · 用"寄存器版"而不是组合 mux: 让 S_HOLD 分支的 32bit 比较器输入
    //     始终是寄存器, 与原来"寄存器 vs 常量"同级, 不新增组合级数(时序)。
    //   · 非法值(0 或 <0.5s)被忽略 → 天然实现课程 period_cfg_valid 的防护,
    //     不存在"间隔被写成 0 → 疯狂切图"的失效模式。
    //--------------------------------------------------------------
    always @(posedge clk or posedge rst) begin
        if (rst)
            period_cyc <= SLIDE_INTERVAL;
        else if (slide_interval >= MIN_PERIOD_CYCLES)
            period_cyc <= slide_interval;
    end

    //--------------------------------------------------------------
    // 轮播间隔计数器(S_HOLD 计时; slide_en=0 冻结清零, 杜绝解冻瞬间误切)
    //--------------------------------------------------------------
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            hold_cnt <= 32'd0;
        end
        else if (state == S_HOLD) begin
            if (slide_en)
                hold_cnt <= hold_cnt + 32'd1;
            else
                hold_cnt <= 32'd0;
        end
        else begin
            hold_cnt <= 32'd0;
        end
    end

    //--------------------------------------------------------------
    // 主状态机
    //--------------------------------------------------------------
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state            <= S_IDLE;
            sd_sec_read      <= 1'b0;
            sd_sec_read_addr <= {ZONE_START_SECTOR[31:3], 3'd0};
            write_req        <= 1'b0;
            state_code       <= 4'd0;
            img_cnt          <= 32'd0;
            z_start          <= ZONE_START_SECTOR;
            z_wrap           <= ZONE_WRAP_SECTOR;
            z_max            <= ZONE_MAX_IMAGES;
            zone_pend        <= 1'b0;
            reload_pend      <= 1'b0;
            skip_pend        <= 1'b0;
            scan_tgt_en      <= 1'b0;
            scan_tgt         <= 32'd0;
            pass_cnt         <= 32'd0;
            found_clr        <= 1'b0;
            bmp_error        <= ERR_NONE;
            retry_cnt        <= 4'd0;
            file_base_addr   <= 32'd0;
        end
        else begin
            // 命中标志清除请求默认拉低(本 always 唯一驱动点)
            found_clr <= 1'b0;

            // 分区请求挂起标志(与主状态机同 always 的单一驱动点):
            //   zone_load 任意时刻置位(含 SD 初始化等待期);
            //   当拍 S_IDLE 真正应用新分区时清位(需 sd_init_done, 与 case 应用对齐).
            //   · 同一拍 zone_load + S_IDLE 应用: 置位优先(新请求挂起), 而应用读的
            //     是 req_* 旧值 → 旧请求仍被应用, 新请求留待下次应用, 不丢不重.
            //   · 挂起请求经 S_FIND 扇区读间隙 / S_HOLD 边界回 S_IDLE 统一应用.
            if (zone_load)
                zone_pend <= 1'b1;
            else if (zone_pend && sd_init_done && (state == S_IDLE))
                zone_pend <= 1'b0;

            // 原地重读挂起标志(本 always 唯一驱动点):
            //   reload_req 任意时刻置位; 在 S_HOLD 边界真正应用时清位.
            //   (与 S_HOLD 分支同拍: 分支读旧值 1 → 本拍仍执行重读, 不丢)
            if (reload_req)
                reload_pend <= 1'b1;
            else if (reload_pend && (state == S_HOLD))
                reload_pend <= 1'b0;

            if (sd_init_done == 1'b0) begin
                // SD 卡尚未初始化完成, 回到空闲等待(分区应用点, 不扫不读)
                state       <= S_IDLE;
                sd_sec_read <= 1'b0;
                state_code  <= 4'd0;
            end
            else begin
                case (state)
                //------------------------------------------------
                // 空闲: 若请求了新分区则应用并从头扫描; 否则直接开始
                //------------------------------------------------
                S_IDLE: begin
                    state_code <= 4'd1;
                    // 任何进入空闲的路径都取消"按序号目标扫描"
                    scan_tgt_en <= 1'b0;
                    pass_cnt    <= 32'd0;
                    skip_pend   <= 1'b0;
                    if (zone_pend) begin
                        // 应用请求分区, 重置计数后从头扫描
                        // (zone_pend 清位由上方挂起逻辑当拍完成, 此处只读不写)
                        // 分区优先于"跳坏图": 换区即从新起点重扫, 跳过已无意义
                        z_start          <= req_start;
                        z_wrap           <= req_wrap;
                        z_max            <= req_max;
                        sd_sec_read_addr <= {req_start[31:3], 3'd0};
                        img_cnt          <= 32'd0;
                    end
                    else if (skip_pend) begin
                        // ---- 跳过本张坏图(§2.2 重试耗尽)的落点地址 ----
                        // 地址在这里算而不是在 S_READ 里算(§时序): S_READ 的
                        // load_fatal 由 bmp_len_cnt 32bit 比较组合产生, 若它去选
                        // sd_sec_read_addr 的地址 mux, 实测 10.412ns > 10ns 周期
                        // (11 个 FEPS 违例)。这里 file_base_addr/skip_lat/wrap_lim/
                        // z_start 全是寄存器 → 只有 加法∥比较 → mux 一级组合。
                        sd_sec_read_addr <= (file_base_addr >= wrap_lim) ?
                                            z_start : (file_base_addr + skip_lat);
                    end
                    else begin
                        // 扫描地址 8 对齐(4KB 簇边界)
                        sd_sec_read_addr <= {sd_sec_read_addr[31:3], 3'd0};
                    end
                    state <= S_FIND;
                end

                //------------------------------------------------
                // 扫描找图: 逐扇区(每 8 扇区跳)检查文件头
                // 分区切换只允许在扇区读间隙(读途中不撤请求, 不脏数据)
                //------------------------------------------------
                S_FIND: begin
                    state_code <= 4'd2;
                    if (sd_timeout) begin
                        // ---- 扫描期超时(§2.4): 连续 500ms 无扇区读完 ----
                        // 报 ERR_TIMEOUT 后回 S_IDLE 重新起请求(地址保持,
                        // S_IDLE 会 8 对齐后重扫)。显示通路不受影响。
                        bmp_error   <= ERR_TIMEOUT;
                        sd_sec_read <= 1'b0;
                        state       <= S_IDLE;
                    end
                    else if (sd_sec_read_end) begin
                        state_code <= 4'd3;
                        if (zone_pend) begin
                            // 扇区读间隙(本扇区已读完, SD 控制器已回 idle)
                            // 收到分区请求: 立即回 S_IDLE 应用, 防止分区内
                            // 无图/扫描漫长时切换请求被无限挂起
                            sd_sec_read <= 1'b0;
                            state       <= S_IDLE;
                        end
                        else if (found) begin
                            found_clr <= 1'b1;      // 本张命中已处理, 清命中标志
                            if (scan_tgt_en && (pass_cnt != scan_tgt)) begin
                                // ---- 按序号目标扫描: 当前命中不是目标图 ----
                                // 跳过本图, 从下一簇继续扫描(区素材连续排布)
                                pass_cnt <= pass_cnt + 32'd1;
                                if (sd_sec_read_addr >= z_wrap)
                                    sd_sec_read_addr <= z_start;
                                else
                                    sd_sec_read_addr <= sd_sec_read_addr + 32'd8;
                                state        <= S_FIND;
                                sd_sec_read  <= 1'b0;
                            end
                            else begin
                                // ---- 命中即读取(普通顺序下一张 / 目标图) ----
                                state          <= S_READ_WAIT;
                                sd_sec_read    <= 1'b0;
                                write_req      <= 1'b1;   // 启动写帧
                                file_base_addr <= sd_sec_read_addr; // 记录本图起始簇
                                if (scan_tgt_en) begin
                                    // 目标图: 图序号 = 目标序号 + 1
                                    img_cnt     <= scan_tgt + 32'd1;
                                    pass_cnt    <= 32'd0;
                                    scan_tgt_en <= 1'b0;
                                end
                                else
                                    img_cnt <= img_cnt + 32'd1;
                            end
                        end
                        else if (header_0 == "B" && header_1 == "M") begin
                            // ---- 坏图快跳(§2.3): 有 BMP 签名但 9 项校验不过 ----
                            // 判为"坏 BMP 文件"→ 报 ERR_HEADER(持久性错误, 重试
                            // 必然复现, 故不重试), 并按 file_len 折算簇数跳过整个
                            // 文件(原来只 +8 扇区, 900KB 的坏图要扫 225 次)。
                            // 阈值用打拍值 wrap_lim(=z_wrap-skip_lat)避免 加法→比较 串联
                            bmp_error <= ERR_HEADER;
                            if (sd_sec_read_addr >= wrap_lim)
                                sd_sec_read_addr <= z_start;
                            else
                                sd_sec_read_addr <= sd_sec_read_addr + skip_lat;
                        end
                        else begin
                            // 未命中: 地址 +8 继续扫描, 越界则回卷分区起点
                            if (sd_sec_read_addr >= z_wrap)
                                sd_sec_read_addr <= z_start;
                            else
                                sd_sec_read_addr <= sd_sec_read_addr + 32'd8;
                        end
                    end
                    else begin
                        sd_sec_read <= 1'b1;   // 持续发读请求
                    end
                end

                //------------------------------------------------
                // 读等待: 等写通路应答
                //------------------------------------------------
                S_READ_WAIT: begin
                    if (write_req_ack) begin
                        state     <= S_READ;
                        write_req <= 1'b0;
                    end
                end

                //------------------------------------------------
                // 读图数据: 持续读扇区直到文件读完
                // (帧写一旦开始不中断, 分区切换排队到 S_HOLD)
                //------------------------------------------------
                S_READ: begin
                    state_code <= 4'd4;
                    if (sd_sec_read_end)
                        sd_sec_read_addr <= sd_sec_read_addr + 32'd1;  // 顺序读下一扇区
                    // ---- 单点判决: 超时 或 整帧读完 ----
                    if (sd_timeout || frame_read_done) begin
                        sd_sec_read <= 1'b0;
                        if (load_fatal) begin
                            // ==== 出错(§2.2): 报错误码 → 重试 1 次 → 仍失败跳过 ====
                            //  超时: 读卡中途卡住(帧可能已写一半, 单缓冲无法回滚)
                            //  截断: 文件像素不足 640×480(继续显示会半新半旧撕裂)
                            bmp_error <= sd_timeout ? ERR_TIMEOUT : ERR_TRUNCATED;
                            if (retry_cnt < MAX_RETRIES) begin
                                // 重试: 复用"原地重读当前图"机制(reload_pend),
                                //   从分区起点重扫到本张 → 图序号不变,
                                //   且经 S_HOLD 清掉 bmp_len_cnt/pixel_cnt 计数。
                                retry_cnt   <= retry_cnt + 4'd1;
                                reload_pend <= 1'b1;
                                state       <= S_HOLD;
                            end
                            else begin
                                // 重试已用尽 → 跳过本张: 图序号回退 1(本张未显示,
                                //   保持用户看到的序号连续), 越过整个坏文件继续扫;
                                //   经 S_IDLE 清计数, 并让分区挂起请求优先应用。
                                //   ※ 跳过落点地址不在此处算(§时序): 该赋值的选择项
                                //     由 load_fatal 决定, 而 load_fatal 源自
                                //     bmp_len_cnt 32bit 比较 → 会把地址 mux 拉成
                                //     10.412ns 长链(11 FEPS)。改为置 skip_pend,
                                //     由 S_IDLE 用纯寄存器值算(见 S_IDLE 分支)。
                                retry_cnt <= 4'd0;
                                img_cnt   <= img_cnt - 32'd1;
                                skip_pend <= 1'b1;
                                state     <= S_IDLE;
                            end
                        end
                        else begin
                            // ==== 整帧完整读完: 清错误码/重试计数, 进入显示保持 ====
                            bmp_error <= ERR_NONE;
                            retry_cnt <= 4'd0;
                            state     <= S_HOLD;
                        end
                    end
                    else begin
                        sd_sec_read <= 1'b1;
                    end
                end

                //------------------------------------------------
                // 显示保持: 保持当前图; 分区请求/手动上一张/手动下一张/
                //            自动轮播计时到 都会切图
                //   · 分区请求(zone_pend): 回 S_IDLE 立即应用新分区
                //   · 手动上一张(key_prev): 按序号目标从分区起点重扫(支持回看)
                //   · 手动下一张(key_trigger)/自动计时到: 顺序下一张,
                //     本分区播满一圈(z_max)则回卷起点
                //   ※ key_trigger/key_prev 由上层(ui_key_ctrl)在手动模式下
                //     给出单周期脉冲; 手动模式 slide_en=0, 自动计时不会触发
                //------------------------------------------------
                S_HOLD: begin
                    state_code <= 4'd5;
                    if (zone_pend) begin
                        // 分区切换: 回 S_IDLE 统一应用(清帧写计数已由
                        // S_HOLD 清零逻辑完成), 避免在此复制应用逻辑
                        state       <= S_IDLE;
                        sd_sec_read <= 1'b0;
                    end
                    else if (reload_pend) begin
                        // ---- 原地重读当前这张图(缩放档变化, 图序号不变) ----
                        // 第 1 张: 直接回分区起点重读(scan_tgt_en=0 即"命中即读")
                        // 第 N 张: 复用"按序号目标扫描"跳到第 N-1 号(0 基)图
                        sd_sec_read_addr <= z_start;
                        img_cnt          <= 32'd0;
                        pass_cnt         <= 32'd0;
                        if (img_cnt <= 32'd1) begin
                            scan_tgt_en <= 1'b0;
                        end
                        else begin
                            scan_tgt_en <= 1'b1;
                            scan_tgt    <= img_cnt - 32'd1;
                        end
                        state <= S_FIND;
                    end
                    else if (key_prev) begin
                        // ---- 手动"上一张": 目标序号 = (当前序号-1) mod z_max ----
                        if (z_max <= 32'd1) begin
                            // 分区只有一张图: 直接回卷起点重读
                            sd_sec_read_addr <= z_start;
                            img_cnt          <= 32'd0;
                        end
                        else begin
                            scan_tgt_en      <= 1'b1;
                            scan_tgt         <= (img_cnt <= 32'd1) ?
                                                (z_max - 32'd1) : (img_cnt - 32'd2);
                            pass_cnt         <= 32'd0;
                            sd_sec_read_addr <= z_start;
                            img_cnt          <= 32'd0;
                        end
                        state <= S_FIND;
                    end
                    else if (key_trigger ||
                             (slide_en && (hold_cnt >= period_cyc))) begin
                        // ---- 顺序下一张(手动按键 / 自动计时到) ----
                        if (img_cnt >= z_max) begin
                            // 已播完一圈: 直接回卷分区起点
                            sd_sec_read_addr <= z_start;
                            img_cnt          <= 32'd0;
                        end
                        else begin
                            // 对齐到下一个 8 扇区边界找本分区下一张图
                            sd_sec_read_addr <= {sd_sec_read_addr[31:3] + 1'b1, 3'd0};
                        end
                        state <= S_FIND;
                    end
                end

                default: state <= S_IDLE;
            endcase
            end
        end
    end

endmodule
