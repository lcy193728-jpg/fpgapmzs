`timescale 1ns/1ps
//====================================================================
// 模块名 : meeting_sd_rd.v —— 会议议程配置(TF 卡固定扇区)读取 + MTG1 解析
// 来源   : dev_sim(meeting_scene3_sim) 的 meeting_sd_reader.v + meeting_config.v
//
// 与仿真版的差别(上板必改):
//   ① 仿真版没有超时兜底 —— 官方 sd_card_cmd 在 S_READ_WAIT 等 0xFE 数据令牌时
//      **自身无超时**, 一旦卡不应答会永久卡死, 并连带拖死 bmp_read_auto。
//      本版加"连续无字节进展"超时(默认 100ms@100MHz): 超时即撤请求、置
//      error=1、done=1, 保证显示通路不被卡住。
//   ② 扇区请求 `sd_sec_read` 改为**电平保持**(与 bmp_read_auto 完全同法):
//      在 sd_sec_read_end 当拍改地址并继续拉高; 收尾时在 end 当拍撤低。
//   ③ 解析与存储合并到本模块: 边解析边写 meeting_cfg 的双口 BRAM 写口,
//      不再需要"324 路并行可变索引读"。
//
// 握手(与 sd_card_top 的扇区读口一致, 本模块与 SD 控制器共用同一条 SPI):
//   sd_sec_read(出,电平) / sd_sec_read_addr(出,32) / sd_sec_read_data(入,8)
//   / sd_sec_read_data_valid(入) / sd_sec_read_end(入)
//   ※ 绝不能再例化第二个 SPI master 抢同一组引脚(见 sd_card_bmp.v)
//
// 开机串行化(方案 A): 本模块只在 sd_init_done 有效后占用总线; 读完(或超时)
//   置 done=1, 由 sd_card_bmp 用 `sd_init_done & done` 门控 bmp_read_auto,
//   使 BMP 通路在本模块结束后才开始工作。
//
// MTG1 配置格式(与仿真版一致):
//   4 字节魔数 'M''T''G''1' + 1 字节议程项数(1..16)
//   + 280-5=... 实际上字节流自 pos=5 起逐字节存入配置 RAM 偏移 (pos-5):
//     [0..39] 会议名称  [40..79] 主办单位  [80..119] 报到地点
//     [120..279] 注意事项 4 页(每页 40B)
//     [280+i*62 .. 341+i*62] 第 i 项: +0/+1=时长秒(大端) +2..41=名称 +42..61=发言人
//   总长 expected = 285 + 项数*62 字节(16 项 = 1277 字节 → 3 扇区)
// 语言: 纯 Verilog-2001。
//====================================================================

module meeting_sd_rd #(
    parameter [31:0] MAX_SECTORS   = 32'd3,             // 最多读几个扇区(16 项 = 1277B 需 3 扇区)
    parameter [31:0] CLK_FREQ_HZ   = 32'd100_000_000,   // 本模块时钟 = sd_card_clk
    parameter [31:0] TIMEOUT_MS    = 32'd100            // 连续无字节进展超时(ms)
)(
    input               clk,                    // sd_card_clk(100MHz)
    input               rst,                    // 高有效复位
    input      [31:0]   start_sector,           // 配置起始扇区(顶层给, 见 m8 写卡说明)
    input               sd_init_done,           // sd_card_top 的原始初始化完成(未门控)
    // ---- SD 扇区读口(接 sd_card_bmp 内的总线仲裁) ----
    output reg          sd_sec_read,            // 读请求(电平)
    output reg  [31:0]  sd_sec_read_addr,       // 扇区地址
    input      [7:0]    sd_sec_read_data,       // 扇区数据(字节)
    input               sd_sec_read_data_valid, // 数据有效
    input               sd_sec_read_end,        // 本扇区读完
    // ---- 配置 RAM 写口(同域, 接 meeting_cfg) ----
    output reg          ram_we,
    output reg  [10:0]  ram_addr,
    output reg  [7:0]   ram_data,
    // ---- 状态 ----
    output reg          ready,                  // 配置有效(解析完整通过)
    output reg          error,                  // 配置无效(坏/截断/超时)
    output reg  [4:0]   total,                  // 议程项数 1..16
    output reg          done                    // 读取收尾(放行 BMP)
);

    localparam [31:0] TIMEOUT_CYCLES = TIMEOUT_MS * (CLK_FREQ_HZ / 32'd1000);

    localparam [0:0] S_WAIT = 1'b0, S_READ = 1'b1;

    reg        state;
    reg [31:0] sector;
    reg [31:0] to_cnt;
    reg [11:0] pos;         // 配置字节流位置(0 基, 未自增)
    reg [4:0]  ptotal;      // 解析中的项数
    reg [5:0]  dmod;        // 项内字节相位(用于"时长"合法性校验, 免去除法)
    reg [7:0]  last_data;   // 上一字节(用于拼时长的 16bit 值)
    reg        bad;
    reg        fin;         // 已收尾(防止回到 S_WAIT 后重复起读)

    // expected = 285 + ptotal*62  (×62 用移位加减, 避免综合出乘法器)
    wire [11:0] expected = 12'd285 + ({7'd0, ptotal} << 6) - ({7'd0, ptotal} << 1);

    // 本扇区结束时是否收尾: 解析已完成 / 已判坏 / 已达扇区上限
    wire parse_done  = (pos >= expected) && (ptotal != 5'd0);
    wire stop_at_end = parse_done | bad | ((sector + 32'd1) >= MAX_SECTORS);

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state            <= S_WAIT;
            sd_sec_read      <= 1'b0;
            sd_sec_read_addr <= start_sector;
            sector           <= 32'd0;
            to_cnt           <= 32'd0;
            pos              <= 12'd0;
            ptotal           <= 5'd0;
            dmod             <= 6'd0;
            last_data        <= 8'd0;
            bad              <= 1'b0;
            fin              <= 1'b0;
            ram_we           <= 1'b0;
            ram_addr         <= 11'd0;
            ram_data         <= 8'd0;
            ready            <= 1'b0;
            error            <= 1'b0;
            total            <= 5'd0;
            done             <= 1'b0;
        end
        else begin
            ram_we <= 1'b0;     // 默认单拍写脉冲

            case (state)
            //------------------------------------------------
            // 等 SD 控制器初始化完成(与 bmp_read_auto 的挂起点一致)
            //   卡未插/初始化失败 → 一直等, 与改造前行为相同(不额外阻塞)
            //------------------------------------------------
            S_WAIT: begin
                if (sd_init_done && !fin) begin
                    sd_sec_read      <= 1'b1;
                    sd_sec_read_addr <= start_sector;
                    sector           <= 32'd0;
                    to_cnt           <= 32'd0;
                    pos              <= 12'd0;
                    ptotal           <= 5'd0;
                    dmod             <= 6'd0;
                    bad              <= 1'b0;
                    state            <= S_READ;
                end
            end
            //------------------------------------------------
            // 逐字节解析 + 写配置 RAM; 扇区读完换地址继续
            //------------------------------------------------
            S_READ: begin
                // ---- 字节流解析(规则与仿真版 meeting_config 完全一致) ----
                if (sd_sec_read_data_valid) begin
                    last_data <= sd_sec_read_data;
                    if (pos < 12'd4) begin
                        case (pos)
                            12'd0: if (sd_sec_read_data != 8'h4d) bad <= 1'b1; // 'M'
                            12'd1: if (sd_sec_read_data != 8'h54) bad <= 1'b1; // 'T'
                            12'd2: if (sd_sec_read_data != 8'h47) bad <= 1'b1; // 'G'
                            default: if (sd_sec_read_data != 8'h31) bad <= 1'b1;// '1'
                        endcase
                    end
                    else if (pos == 12'd4) begin
                        ptotal <= sd_sec_read_data[4:0];
                        total  <= sd_sec_read_data[4:0];
                        if (sd_sec_read_data == 8'd0 || sd_sec_read_data > 8'd16)
                            bad <= 1'b1;
                    end
                    else if (pos < expected && pos < 12'd1277) begin
                        ram_we   <= 1'b1;
                        ram_addr <= pos[10:0] - 11'd5;
                        ram_data <= sd_sec_read_data;
                        // 时长(项内前 2 字节, 大端)合法性: 0 < 值 <= 5999
                        //   ※ 必须加 pos>=285 门控(上板实测致命 bug):
                        //     dmod 自 pos=0 起就每 62 拍回绕(只在 pos==285 被强
                        //     制归零), 若不限项区, 会在 pos=62/124/186/248 处也
                        //     命中 dmod==0, 把元数据区(会议名称/主办/地点/注意
                        //     事项, 补零填充)的字节对当成时长校验:
                        //       pos=62  00 00 = 0     → 非法
                        //       pos=124 00 00 = 0     → 非法
                        //       pos=186 00 00 = 0     → 非法
                        //       pos=248 3C 3D = 15421 → 非法
                        //     结果 bad=1 → error=1, ready 永远为 0, 会议层一个
                        //     像素都不画(画面退回 osd_scene 的旧"会议公告")。
                        if (dmod == 6'd0 && pos >= 12'd285) begin
                            if ({last_data, sd_sec_read_data} == 16'd0 ||
                                {last_data, sd_sec_read_data} > 16'd5999)
                                bad <= 1'b1;
                        end
                    end
                    pos <= pos + 12'd1;
                    // 项内相位: pos==285(时长高字节)后归零, 每 62 字节一轮
                    if (pos == 12'd285)      dmod <= 6'd0;
                    else if (dmod == 6'd61)  dmod <= 6'd0;
                    else                     dmod <= dmod + 6'd1;
                end

                // ---- 扇区边界 / 超时 ----
                if (to_cnt == TIMEOUT_CYCLES) begin
                    // 超时兜底: 撤请求并收尾(保证 BMP 通路不被拖死)
                    sd_sec_read <= 1'b0;
                    error       <= 1'b1;
                    done        <= 1'b1;
                    fin         <= 1'b1;
                    state       <= S_WAIT;      // 停在等待态(不再抢总线)
                end
                else if (sd_sec_read_end) begin
                    to_cnt <= 32'd0;
                    if (stop_at_end) begin
                        sd_sec_read <= 1'b0;
                        done        <= 1'b1;
                        fin         <= 1'b1;
                        if (parse_done && !bad) ready <= 1'b1;
                        else                    error <= 1'b1;
                        state       <= S_WAIT;  // 收尾后不再占用总线
                    end
                    else begin
                        sd_sec_read_addr <= sd_sec_read_addr + 32'd1;
                        sector           <= sector + 32'd1;
                        sd_sec_read      <= 1'b1;   // 电平保持, 继续读下一扇区
                    end
                end
                else begin
                    to_cnt      <= to_cnt + 32'd1;
                    sd_sec_read <= 1'b1;
                end
            end
            endcase
        end
    end

endmodule
