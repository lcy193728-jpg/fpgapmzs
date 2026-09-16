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
// 底层原理(与官方一致)：
//   不解析 FAT 文件系统，从分区起点每 8 扇区(4KB 簇)跳读检查文件头
//   "BM"+640×480×24bit+file_len=921654 严格校验，命中即整张读入 SDRAM
//====================================================================

`timescale 1ns/1ps

module bmp_read_auto #(
    parameter [31:0] SLIDE_INTERVAL   = 32'd300_000_000, // 轮播间隔(时钟周期) 100MHz=3s
    parameter [31:0] ZONE_START_SECTOR = 32'd126000,     // 复位默认分区起点(菜单分区)
    parameter [31:0] ZONE_WRAP_SECTOR  = 32'd400000,     // 复位默认分区上限(回卷)
    parameter [31:0] ZONE_MAX_IMAGES   = 32'd5,          // 复位默认分区图片张数
    parameter [31:0] BMP_FILE_LEN      = 32'd921654      // 期望 BMP 文件长度=54+640*480*3
)(
    input               clk,                       // SD 卡时钟(100MHz)
    input               rst,                       // 高电平有效复位
    output              ready,                     // 空闲标志(仅调试用)
    input               sd_init_done,              // SD 卡初始化完成标志
    input               key_trigger,               // 按键手动切图/下一张(单周期高脉冲, 与 clk 同步)
    input               key_prev,                  // 按键手动"上一张"(单周期高脉冲, 与 clk 同步)
    input               slide_en,                  // 轮播使能(应急=0 冻结当前画面, 保留不清屏)
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
    output              img_busy                   // 1=底层图加载忙(扫/读/挂起/未初始化)
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
    // 内部寄存器
    //--------------------------------------------------------------
    reg [3:0]   state;
    reg [9:0]   rd_cnt;          // 扇区内字节计数(找图阶段)
    reg [7:0]   header_0;        // 文件头第 0 字节(应为 'B')
    reg [7:0]   header_1;        // 文件头第 1 字节(应为 'M')
    reg [31:0]  file_len;        // BMP 文件总长度(从头信息读取)
    reg [31:0]  width;           // BMP 宽度(从头信息读取)
    reg [31:0]  height;          // BMP 高度(从头信息读取, 校验 480)
    reg [15:0]  bit_cnt;         // BMP 色深(从头信息读取, 校验 24bit)
    reg [31:0]  bmp_len_cnt;     // 读图阶段的字节计数器
    reg         found;           // 命中标志(找到 "BM" + 宽度匹配)
    reg [1:0]   bmp_len_cnt_tmp; // RGB 三字节计数(0/1/2)
    reg [31:0]  hold_cnt;        // 轮播间隔计数器
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

    // BMP 像素数据有效：跳过前 54 字节文件头，且不超过文件长度
    wire bmp_data_valid = (sd_sec_read_data_valid && bmp_len_cnt > 32'd53 && bmp_len_cnt < file_len);
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
    // 文件头解析(严格校验 "BM"+宽640+高480+24bit+file_len, 过滤假"BM")
    //--------------------------------------------------------------
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            header_0 <= 8'd0;
            header_1 <= 8'd0;
            file_len <= 32'd0;
            width    <= 32'd0;
            height   <= 32'd0;
            bit_cnt  <= 16'd0;
            found    <= 1'b0;
        end
        else if (state == S_FIND && sd_sec_read_data_valid) begin
            if (rd_cnt == 10'd0)  header_0        <= sd_sec_read_data;
            if (rd_cnt == 10'd1)  header_1        <= sd_sec_read_data;
            // 文件长度(小端, 第 2~5 字节)
            if (rd_cnt == 10'd2)  file_len[7:0]   <= sd_sec_read_data;
            if (rd_cnt == 10'd3)  file_len[15:8]  <= sd_sec_read_data;
            if (rd_cnt == 10'd4)  file_len[23:16] <= sd_sec_read_data;
            if (rd_cnt == 10'd5)  file_len[31:24] <= sd_sec_read_data;
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
            // 色深(小端, 第 28~29 字节)
            if (rd_cnt == 10'd28) bit_cnt[7:0]    <= sd_sec_read_data;
            if (rd_cnt == 10'd29) bit_cnt[15:8]   <= sd_sec_read_data;
            if (rd_cnt == HEADER_SIZE && header_0 == "B" && header_1 == "M"
                && width[15:0] == bmp_width    // 宽 640
                && height        == 32'd480    // 高 480
                && bit_cnt       == 16'd24     // 24bit 真彩色
                && file_len      == BMP_FILE_LEN)
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
            scan_tgt_en      <= 1'b0;
            scan_tgt         <= 32'd0;
            pass_cnt         <= 32'd0;
            found_clr        <= 1'b0;
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
                    if (zone_pend) begin
                        // 应用请求分区, 重置计数后从头扫描
                        // (zone_pend 清位由上方挂起逻辑当拍完成, 此处只读不写)
                        z_start          <= req_start;
                        z_wrap           <= req_wrap;
                        z_max            <= req_max;
                        sd_sec_read_addr <= {req_start[31:3], 3'd0};
                        img_cnt          <= 32'd0;
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
                    if (sd_sec_read_end) begin
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
                                state        <= S_READ_WAIT;
                                sd_sec_read  <= 1'b0;
                                write_req    <= 1'b1;   // 启动写帧
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
                    if (sd_sec_read_end) begin
                        sd_sec_read_addr <= sd_sec_read_addr + 32'd1;
                        sd_sec_read      <= 1'b0;
                        if (bmp_len_cnt >= file_len) begin
                            // 本张图读完, 进入显示保持
                            state <= S_HOLD;
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
                             (slide_en && (hold_cnt >= SLIDE_INTERVAL))) begin
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
