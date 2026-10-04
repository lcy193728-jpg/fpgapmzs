//====================================================================
// 模块名 : sd_card_bmp.v —— SD 卡 BMP 读取 + 会议议程配置(固定扇区)读取
//                             + WAV 音频流(TF 卡裸 PCM)读取
//
// TF 卡上放三类数据, 全部复用同一片 SD 控制器 —— 板上 SPI 引脚
//   (sd_ncs/sd_dclk/sd_mosi/sd_miso)由 sd_card_top 独占,
//   **绝不能**再例化第二个 SPI master。
//
//   · BMP 图片          : 扇区 126656~135703(四场景分区, 见顶层 Z_* 表)
//   · 会议议程配置 MTG1 : 扇区 200000 起 3 个扇区(原始字节流, 见 meeting_sd_rd.v)
//   · WAV 背景音乐      : 扇区 300000 起(裸 PCM 48kHz/16bit/mono, 见 wav_stream_player.v)
//
// 仲裁(2026-09-26 加背景音乐时改造):
//   改造前是"开机会议配置串行读完 → 彻底放行 BMP"的静态方案(bmp_go 门控),
//   两个使用者**从不同时发请求**, 因此 sd_sec_read_data_valid / end 可以无脑
//   广播给双方(各自状态机自己过滤)。
//
//   加 WAV 流之后, "迎新场景照片轮播 + 背景音乐"必须**并发**占用同一条 SPI
//   总线, 广播不再安全(两个主设备会同时吞掉同一个扇区的 512 字节)。故引入
//   audio_sd_arbiter: 逐扇区授权, 总线数据/结束**只回给授权方**。
//     A 侧 = 图片轮播(bmp_read_auto) 与 会议配置(meeting_sd_rd) 的合并请求
//            (两者在时间上互不重叠: meeting 开机先独占, bmp_go 门控)
//     B 侧 = WAV 音频流(wav_stream_player 写侧状态机), **优先**
//   音频只在循环缓冲低于水位时发请求(HIGH_WATER), 故不会长期霸占总线;
//   图片拿到剩余带宽(音频占空比约 5%, 见 audio_sd_arbiter 头注释的数值论证)。
//
//   开机顺序仍是"会议配置先读完": 音频的扇区请求被
//   (sd_init_done & mtg_done_w) 掩掉, 配置读完前不参与仲裁 —— 与改造前
//   的启动时序完全一致, 只是之后总线由"单使用者"变成了"逐扇区轮转"。
//
//   ※ meeting_sd_rd.v / audio_sd_arbiter.v / wav_stream_player.v 未登记在
//     pic_sdram_audio_final.al 的综合列表里(与 osd_scene/ui_key_ctrl 等同属
//     "靠 include 并入"的一类), 而它们都在本文件内例化, 故在本文件顶部
//     include, 保证"定义与例化在同一编译单元", 不依赖顶层 include 顺序。
//====================================================================
`include "meeting_sd_rd.v"
`include "audio_sd_arbiter.v"
`include "../audio_final/rtl/wav_stream_player.v"
`include "fat32/fat32_volume_scanner.v"
`include "fat32/fat32_file_streamer.v"
`include "fat32/sd_sector_adapter.v"

module sd_card_bmp(
	input                       clk,               
	input                       rst,             
	output [3:0]                state_code,	        //state indication coding,
													// 0:SD card is initializing,
													// 1:find the BMP file
													// 2:looking for the bmp file
													// 3:reading
													// 4:reading pixel data
													// 5:hold (slideshow interval)
	input[15:0]                 bmp_width,	        //search the width of bmp
	input                       key_next,           //手动"下一张"单周期脉冲(上层消抖后给出)
	input                       key_prev,           //手动"上一张"单周期脉冲(上层消抖后给出)
	input                       slide_en,           //自动轮播使能(手动/应急=0 冻结当前画面)
	input [31:0]                slide_interval,     //批次4 轮播间隔(时钟周期, 周期档 2/3/5/10/30s)
	// ---- 场景分区重载(FAT32 化: 由 latch_sw 场景号查 scanner 簇号表) ----
	//   latch_sw: 0菜单 1迎新 2会议 3抢答 4应急。本模块内部按场景查 res_cluster[]
	//   生成 bmp_read_auto 的簇号表(zone_cluster0..5/zone_size0..5), zone_load 触发。
	input [2:0]                 latch_sw,           //当前场景号(sd_card_clk 域寄存)
	input                       zone_load,          //分区重载请求(单周期脉冲)
	input                       reload_req,         //原地重读当前图请求(缩放档变化, 单周期脉冲)
	// ---- 会议议程配置(FAT32 化: MTG1.CFG 文件, 簇号由 scanner 扫出) ----
	output                      mtg_ram_we,         //配置 RAM 写使能(→ meeting_cfg 写口)
	output [10:0]               mtg_ram_addr,       //配置 RAM 写地址(0..1271)
	output [7:0]                mtg_ram_data,       //配置 RAM 写数据
	output                      mtg_ready,          //配置有效(解析通过)
	output                      mtg_error,          //配置无效(坏/截断/超时)
	output [4:0]                mtg_total,          //议程项数 1..16
	output                      mtg_done,           //配置读取收尾(放行 BMP)
	output                      write_req,          //start writing request
	input                       write_req_ack,      //write request response
	output                      write_en,           //bmp image data write enable
	output[31:0]                write_data,         //bmp image data
	output[7:0]                 img_no,             //当前显示图序号(透传, 数码管/上层用)
	output                      img_busy,           //底层图加载忙(扫/读/挂起), 供切场淡入淡出
	output[3:0]                 bmp_error,          //加载错误码(批次3 透传: 0无/1头校验/2超时/3截断)
	output[1:0]                 img_res,            //当前显示图源分辨率码(0=320x240 1=640x480
	                                                // 2=1024x768 3=1280x960; 供右上角分辨率字幕)
	output                      img_v2x,            //当前图源高=240(只出 240 行, bmp_scale 补纵向 2×)
	// ---- WAV 背景音乐(FAT32 化: WEL.BIN 文件, 簇号由 scanner 扫出) ----
	input                       audio_clk,          //读侧时钟(= video_clk 25MHz, 48kHz 节拍域)
	input                       audio_rst_n,        //读侧复位(低有效)
	input                       wav_play_en,        //迎新场景选中 WAV(电平, audio_clk 域)
	input                       wav_sample_tick,    //48kHz 取样节拍(audio_clk 域)
	input                       wav_sample_ready,   //下游已消费一拍(audio_clk 域)
	output signed [15:0]        wav_sample,         //(audio_clk 域)
	output                      wav_sample_valid,   //选中期间恒 1(下溢输出静音)
	output                      wav_primed,         //已攒够起播水位
	output                      wav_file_ready,     //WEL.BIN 已扫到(音乐素材存在, 供顶层 sel_wav 判定)
	output                      SD_nCS,             //SD card chip select (SPI mode)
	output                      SD_DCLK,            //SD card clock
	output                      SD_MOSI,            //SD card controller data output
	input                       SD_MISO             //SD card controller data input
);

// ---- FAT32 卷扫描器(开机独占一次, 扫目录拿 12 文件簇号/大小) ----
reg              scan_start;        // 扫描启动脉冲
wire             scan_busy;
wire             scan_done;
wire [7:0]       scan_fs_error;
wire [7:0]       scan_spc;          // sectors_per_cluster
wire [2:0]       scan_spc_shift;    // log2(sectors_per_cluster), 供 streamer 移位
wire [31:0]      scan_fat_start;    // FAT 表起始 LBA
wire [31:0]      scan_data_start;   // 数据区起始 LBA
wire [31:0]      scan_max_cluster;
wire [11:0]      scan_res_valid;    // 12 文件有效标志
wire [31:0]      scan_r0c, scan_r1c, scan_r2c, scan_r3c, scan_r4c, scan_r5c;
wire [31:0]      scan_r6c, scan_r7c, scan_r8c, scan_r9c, scan_r10c, scan_r11c;
wire [31:0]      scan_r0s, scan_r1s, scan_r2s, scan_r3s, scan_r4s, scan_r5s;
wire [31:0]      scan_r6s, scan_r7s, scan_r8s, scan_r9s, scan_r10s, scan_r11s;
// scanner 经 sd_sector_adapter 后的扇区接口(接入仲裁器 A 侧)
wire             scan_sd_req;       // adapter 输出 → 仲裁器 a_req
wire [31:0]      scan_sd_lba;       // adapter 输出 → 仲裁器 a_addr
// scanner 的 sector_* 接口(接 adapter 的 sector 侧)
wire             scan_sector_req;
wire [31:0]      scan_sector_lba;
wire             scan_sector_busy;
wire             scan_sector_valid;
wire [7:0]       scan_sector_byte;
wire [8:0]       scan_sector_byte_index;
wire             scan_sector_done;
wire [7:0]       scan_sector_error;

// 扫描结果锁存(scanner 在 sd 域, 结果在 scan_done 时稳定)
reg  [7:0]       spc_l;
reg  [2:0]       spc_shift_l;
reg  [31:0]      fat_start_l, data_start_l, max_cluster_l;
reg              scan_ok;           // 扫描成功且关键资源齐全
wire[7:0]        sd_sec_read_data; //synthesis keep
wire             sd_sec_read_data_valid;
wire             sd_sec_read_end;
// ⚠⚠ 这两根线【必须显式声明宽度】—— 上板花屏 + 无声的根因就在这:
//   它们由 audio_sd_arbiter 驱动、再接到 sd_card_top, 若漏声明, TD 会当成
//   "隐式网络"并**按 1 bit 处理**(编译日志实测):
//     HDL-1007 : undeclared symbol 'sd_sec_read_addr', assumed default net type 'wire'
//     HDL-5007 WARNING: actual bit length 1 differs from formal bit length 32
//                  for port 'sd_sec_read_addr' in src/sd_card_bmp.v(133)/(250)
//   → 32 位扇区地址只剩 bit0, CMD17 恒读扇区 0/1:
//       · BMP 扫描扫不到 "BM" → SDRAM 里没图 → 花屏
//       · WAV 读到的是 MBR(前 446B 全 0) → 拼出样本几乎全 0 → 无声
//   上游 fpgapmzs 原版是用【赋值式声明】给出宽度的:
//     wire[31:0] sd_sec_read_addr = mtg_sec_read ? mtg_sec_read_addr : bmp_sec_read_addr;
//   本次改"仲裁器"时删掉了那条 assign, 宽度信息随之丢失(逻辑没变, 只是漏了声明)。
wire             sd_sec_read;       //仲裁器 → SD 控制器: 扇区读请求(电平)
wire[31:0]       sd_sec_read_addr;  //仲裁器 → SD 控制器: 32 位扇区地址(物理扇区)
wire             bmp_data_wr_en;
wire[23:0]       bmp_data;
wire             sd_init_done;
wire             mtg_done_w;
wire             bmp_go;            //放行 BMP: 配置读取收尾(或卡未就绪)
wire             mtg_ram_we_w;      //meeting_sd_rd → 顶层(meeting_cfg 写口)
wire [10:0]      mtg_ram_addr_w;
wire [7:0]       mtg_ram_data_w;
wire             mtg_ready_w;
wire             mtg_error_w;
wire [4:0]       mtg_total_w;

// ---- 仲裁器 A 侧: 图片轮播(streamer) + 会议配置(streamer) + FAT32 扫描器 的合并请求 ----
//   扫描器开机独占期间, bmp/meeting 都被门控不发请求, 故三者时间上互不重叠;
//   此处"扫描器最高优先取地址"安全(扫描器只在扫描阶段有效)。
//   FAT32 化: bmp 走 bmp_str_sd_req; meeting 复用 bmp streamer(串行), 无独立请求。
//   ⚠ bmp_str_sd_req 由下方 u_bmp_str_adapter 驱动, 此处先声明
//     (必须在引用之前声明, 否则 iverilog 报 bind 失败)。
wire             bmp_str_sd_req;   // bmp streamer 的 sd_sec 请求(adapter 输出)
wire [31:0]      bmp_str_sd_lba;   // bmp streamer 的 sd_sec 地址(adapter 输出)
wire             a_sec_req  = bmp_str_sd_req | scan_sd_req;
wire[31:0]       a_sec_addr = scan_sd_req ? scan_sd_lba : bmp_str_sd_lba;
wire             a_sec_data_valid;
wire             a_sec_end;
// ---- 仲裁器 B 侧: WAV 音频流(streamer) ----
//   FAT32 化: wav 走 streamer(wav_str_sd_req), 水位流控由 wav 内部 allow_req
//   接到 adapter 的 allow_req 输入(adapter 假装忙 → streamer 停在 ST_DATA_REQ)。
//   ⚠ wav_str_sd_req/wav_str_sd_lba 由下方 u_wav_str_adapter 驱动, 先声明。
wire             wav_str_sd_req;   // wav streamer 的 sd_sec 请求(adapter 输出)
wire [31:0]      wav_str_sd_lba;   // wav streamer 的 sd_sec 地址(adapter 输出)
wire             wav_sec_data_valid;
wire             wav_sec_end;
// 开机放行门控: 扫描(scanner) + 会议配置(mtg_done_w)都完成前不让音频参与
//   仲裁 —— 与改造前的启动时序一致, 只是多了一道"扫描完成"前置。
wire             wav_bus_ready = scan_ok & mtg_done_w;
wire             wav_sec_req   = wav_str_sd_req & wav_bus_ready;

audio_sd_arbiter u_sd_arbiter(
	.clk                       (clk                    ),
	.rst                       (rst                    ),
	.sd_sec_read               (sd_sec_read            ),
	.sd_sec_read_addr          (sd_sec_read_addr       ),
	.sd_sec_read_data_valid    (sd_sec_read_data_valid ),
	.sd_sec_read_end           (sd_sec_read_end        ),
	.a_req                     (a_sec_req              ),
	.a_addr                    (a_sec_addr             ),
	.a_data_valid              (a_sec_data_valid       ),
	.a_end                     (a_sec_end              ),
	.b_req                     (wav_sec_req            ),
	.b_addr                    (wav_str_sd_lba         ),
	.b_data_valid              (wav_sec_data_valid     ),
	.b_end                     (wav_sec_end            )
);

//====================================================================
// FAT32 卷扫描器 + 扇区适配层(开机独占一次)
//   扫描器用 sector_* 接口, 经 sd_sector_adapter 转成 sd_sec_* 接口,
//   接入仲裁器 A 侧(scan_sd_req/scan_sd_lba)。扫描期间 bmp/meeting/wav
//   都被门控不发请求, 故扫描器独占安全。
//   扫描结果在 scan_done 时稳定, 由下方 always 锁存进 res_cluster[]/res_size[]。
//====================================================================
fat32_volume_scanner u_scanner(
	.clk(clk), .rst_n(~rst), .scan_start(scan_start),
	.scan_busy(scan_busy), .scan_done(scan_done), .fs_error(scan_fs_error),
	.partition_lba(), .sectors_per_cluster(scan_spc),
	.sectors_per_cluster_shift(scan_spc_shift),
	.fat_start_lba(scan_fat_start), .data_start_lba(scan_data_start),
	.max_cluster(scan_max_cluster), .resource_valid(scan_res_valid),
	.resource0_cluster(scan_r0c), .resource1_cluster(scan_r1c),
	.resource2_cluster(scan_r2c), .resource3_cluster(scan_r3c),
	.resource4_cluster(scan_r4c), .resource5_cluster(scan_r5c),
	.resource6_cluster(scan_r6c), .resource7_cluster(scan_r7c),
	.resource8_cluster(scan_r8c), .resource9_cluster(scan_r9c),
	.resource10_cluster(scan_r10c), .resource11_cluster(scan_r11c),
	.resource0_size(scan_r0s), .resource1_size(scan_r1s),
	.resource2_size(scan_r2s), .resource3_size(scan_r3s),
	.resource4_size(scan_r4s), .resource5_size(scan_r5s),
	.resource6_size(scan_r6s), .resource7_size(scan_r7s),
	.resource8_size(scan_r8s), .resource9_size(scan_r9s),
	.resource10_size(scan_r10s), .resource11_size(scan_r11s),
	.sector_req(scan_sector_req), .sector_lba(scan_sector_lba),
	.sector_busy(scan_sector_busy), .sector_valid(scan_sector_valid),
	.sector_byte(scan_sector_byte), .sector_byte_index(scan_sector_byte_index),
	.sector_done(scan_sector_done), .sector_error(scan_sector_error)
);

// 扫描器的 sector 接口经 sd_sector_adapter 桥接到仲裁器 A 侧(sd_sec 接口)
sd_sector_adapter u_scan_adapter(
	.clk(clk), .rst_n(~rst), .allow_req(1'b1),
	.sector_req(scan_sector_req), .sector_lba(scan_sector_lba),
	.sector_busy(scan_sector_busy), .sector_valid(scan_sector_valid),
	.sector_byte(scan_sector_byte), .sector_byte_index(scan_sector_byte_index),
	.sector_done(scan_sector_done), .sector_error(scan_sector_error),
	.sd_sec_read(scan_sd_req), .sd_sec_read_addr(scan_sd_lba),
	.sd_sec_read_data_valid(a_sec_data_valid),
	.sd_sec_read_data(sd_sec_read_data),
	.sd_sec_read_end(a_sec_end)
);

// 扫描结果锁存 + 启动控制(scanner 开机独占一次)
//   时序: sd_init_done 后立即 scan_start; scan_done 时锁存 12 簇号/大小/文件系统参数。
//   关键资源齐全(至少 0~9 十张 BMP + 10 MTG1.CFG + 11 WEL.BIN)才置 scan_ok。
integer si;
always @(posedge clk or posedge rst) begin
	if (rst) begin
		scan_start      <= 1'b0;
		scan_ok         <= 1'b0;
		spc_l           <= 8'd0;
		spc_shift_l     <= 3'd0;
		fat_start_l     <= 32'd0;
		data_start_l    <= 32'd0;
		max_cluster_l   <= 32'd0;
	end else begin
		scan_start <= 1'b0;   // 单拍脉冲
		if (sd_init_done && !scan_busy && !scan_done && !scan_ok) begin
			// SD 就绪且尚未扫描成功 → 发起扫描
			scan_start <= 1'b1;
		end
		if (scan_done) begin
			// 锁存文件系统参数(资源簇号/大小直接引用 scanner 输出, 不再锁一份)
			spc_l         <= scan_spc;
			spc_shift_l   <= scan_spc_shift;
			fat_start_l   <= scan_fat_start;
			data_start_l  <= scan_data_start;
			max_cluster_l <= scan_max_cluster;
			// 关键资源齐全判定(0~9 十张 BMP + 10 MTG1.CFG + 11 WEL.BIN 全命中)
			scan_ok <= (scan_fs_error == 8'h00) && (scan_res_valid == 12'hfff);
		end
	end
end

assign write_en = bmp_data_wr_en;
assign write_data = {bmp_data[23:16],bmp_data[15:8],bmp_data[7:0],8'b0};

//====================================================================
// 场景 → 资源号 → 簇号映射(FAT32 化, 替换顶层 Z_* 扇区表)
//   scanner 扫出的 12 资源(见 fat32_volume_scanner 头注释):
//     0=1_MEET.BMP 1=2_QUIZ.BMP 2=3_EXTRA 3=4_EXTRA
//     4=W1_320A 5=W2_640A 6=W3_1024A 7=W4_320B 8=W5_640B 9=W6_1024B
//     10=MTG1.CFG 11=WEL.BIN
//   场景(latch_sw) → 图片资源号:
//     0 菜单 / 1 迎新 : 4,5,6,7,8,9 (6 张)
//     2 会议          : 0        (1 张)
//     3 抢答 / 4 应急 : 1        (1 张)
//   输出 bmp 用簇号表 zone_clu[0..5]/zone_siz[0..5] + zone_max, 随 zone_load
//   锁存给 bmp_read_auto。
//====================================================================
reg  [31:0] zone_clu [0:5];
reg  [31:0] zone_siz [0:5];
reg  [31:0] zone_max;
integer zi;
// 资源号 → 簇号/大小的组合 mux(直接引用 scanner 输出, 省掉 res_cluster/res_size
//   的 24×32bit 锁存 —— scanner 的 resource 寄存器在 scan_done 后保持稳定,
//   无需再锁一份, 省 ~768 FF ≈ 384 mslice)。
function [31:0] res_cluster_sel;
    input [3:0] idx;
    begin
        case (idx)
            4'd0:  res_cluster_sel = scan_r0c;
            4'd1:  res_cluster_sel = scan_r1c;
            4'd2:  res_cluster_sel = scan_r2c;
            4'd3:  res_cluster_sel = scan_r3c;
            4'd4:  res_cluster_sel = scan_r4c;
            4'd5:  res_cluster_sel = scan_r5c;
            4'd6:  res_cluster_sel = scan_r6c;
            4'd7:  res_cluster_sel = scan_r7c;
            4'd8:  res_cluster_sel = scan_r8c;
            4'd9:  res_cluster_sel = scan_r9c;
            4'd10: res_cluster_sel = scan_r10c;
            4'd11: res_cluster_sel = scan_r11c;
            default: res_cluster_sel = 32'd0;
        endcase
    end
endfunction
function [31:0] res_size_sel;
    input [3:0] idx;
    begin
        case (idx)
            4'd0:  res_size_sel = scan_r0s;
            4'd1:  res_size_sel = scan_r1s;
            4'd2:  res_size_sel = scan_r2s;
            4'd3:  res_size_sel = scan_r3s;
            4'd4:  res_size_sel = scan_r4s;
            4'd5:  res_size_sel = scan_r5s;
            4'd6:  res_size_sel = scan_r6s;
            4'd7:  res_size_sel = scan_r7s;
            4'd8:  res_size_sel = scan_r8s;
            4'd9:  res_size_sel = scan_r9s;
            4'd10: res_size_sel = scan_r10s;
            4'd11: res_size_sel = scan_r11s;
            default: res_size_sel = 32'd0;
        endcase
    end
endfunction
// 每场景的资源号(组合): 第 zi 张图对应的 scanner 资源索引
function [3:0] scene_res_idx;
    input [2:0] scene;
    input [31:0] zi;
    begin
        case (scene)
            3'd0, 3'd1: // 菜单/迎新: 资源 4..9
                scene_res_idx = 4'd4 + zi[3:0];
            3'd2:        // 会议: 资源 0
                scene_res_idx = 4'd0;
            3'd3, 3'd4:  // 抢答/应急: 资源 1
                scene_res_idx = 4'd1;
            default:
                scene_res_idx = 4'd4 + zi[3:0];
        endcase
    end
endfunction

// zone_load 当拍按当前 latch_sw 查表生成簇号表(6 槽; 未用槽填 0)
//   ※ scene_res_idx 对会议/抢答/应急场景所有 zi 都返回固定资源号(0 或 1),
//     多余的槽(zi≥实际张数)填相同簇号无副作用 —— bmp_read_auto 用 zone_max
//     只轮播前 N 张, 不会读到多余槽。
//   ※ 触发条件除 zone_load 外还加 scan_ok 上升沿: 上电菜单态没有
//     scene_change_pulse, 若不主动触发, 簇号表会停在复位全 0 → bmp 放行后
//     按簇号 0 空读(花屏)。scan_ok 生效当拍 res_cluster[] 也已锁存就绪
//     (两者同在 scan_done 当拍非阻塞赋值、下一拍生效), 故用 scan_ok 上升沿触发。
reg scan_ok_d1;   // scan_ok 打一拍, 供上升沿检测
always @(posedge clk or posedge rst) begin
    if (rst) scan_ok_d1 <= 1'b0;
    else     scan_ok_d1 <= scan_ok;
end
wire scan_ok_rise = scan_ok & ~scan_ok_d1;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        zone_max <= 32'd6;
        for (zi = 0; zi < 6; zi = zi + 1) begin
            zone_clu[zi] <= 32'd0;
            zone_siz[zi] <= 32'd0;
        end
    end
    else if (zone_load || scan_ok_rise) begin
        case (latch_sw)
            3'd2: zone_max <= 32'd1;            // 会议 1 张
            3'd3, 3'd4: zone_max <= 32'd1;      // 抢答/应急 1 张
            default: zone_max <= 32'd6;         // 菜单/迎新 6 张
        endcase
        for (zi = 0; zi < 6; zi = zi + 1) begin
            zone_clu[zi] <= res_cluster_sel(scene_res_idx(latch_sw, zi));
            zone_siz[zi] <= res_size_sel(scene_res_idx(latch_sw, zi));
        end
    end
end

// zone_load 打一拍再给 bmp_read_auto: 簇号表(zone_clu[]/zone_max)在 zone_load
//   当拍非阻塞更新、下一拍才稳定, 若同一拍就给 bmp_read_auto 捕获, 读到的是
//   旧簇号表 → 切场景读到上一场景的图。故把 zone_load 延一拍, 保证 bmp_read_auto
//   捕获时 zone_clu[] 已是新值。scan_ok_rise 同理(scan 完成自动触发那次)。
reg zone_load_d1;
always @(posedge clk or posedge rst) begin
    if (rst) zone_load_d1 <= 1'b0;
    else     zone_load_d1 <= zone_load || scan_ok_rise;
end
wire bmp_zone_load = zone_load_d1;

//====================================================================
// BMP 文件流读取(fat32_file_streamer): bmp_read_auto 给出 file_start+簇号,
//   经 streamer 遍历 FAT 链读整文件, 字节流回给 bmp_read_auto。
//   ★资源优化(2026-10-03): mtg(会议配置)与 bmp(图片)严格串行(mtg_done_w 门控
//     bmp_go), 且 scanner→mtg→bmp 顺序执行互不重叠。故 mtg 复用本 streamer,
//     省掉一个独立 streamer + adapter(~214 seq ≈ 107 mslice)。mtg_done_w 选择
//     输入簇号/大小, 输出字节按 mtg_done_w demux 分回 mtg 与 bmp。
//====================================================================
wire            bmp_file_start;
wire [31:0]     bmp_file_cluster;
wire [31:0]     bmp_file_size;
wire            bmp_file_valid;
wire [7:0]      bmp_file_byte;
wire            bmp_file_done;
wire [7:0]      bmp_file_error;
// streamer 的 sector 接口经 adapter 转 sd_sec 接口, 接入仲裁器 A 侧
//   (bmp_str_sd_req/bmp_str_sd_lba 已在仲裁器合并逻辑前声明, 此处不再重复)
wire            bmp_str_req;
wire [31:0]     bmp_str_lba;
wire            bmp_str_busy, bmp_str_valid, bmp_str_done;
wire [7:0]      bmp_str_byte, bmp_str_error;
wire [8:0]      bmp_str_byte_idx;

// ---- mtg/bmp 共享 streamer 的输入 mux / 输出 demux ----
//   mtg 阶段(mtg_done_w=0): 读 MTG1.CFG; bmp 阶段(mtg_done_w=1): 读图。
//   两者 file_start 互斥(mtg_done_w=0 时 bmp_go 门控 bmp 不发 start;
//   mtg 读完即 idle 不再发 start), 故可直接复用。
wire            mtg_file_start;    // meeting_sd_rd 输出(下方例化)
wire [31:0]     mtg_file_cluster;
wire [31:0]     mtg_file_size;
wire        shared_file_start   = mtg_file_start | bmp_file_start;
wire [31:0] shared_file_cluster = mtg_done_w ? bmp_file_cluster : mtg_file_cluster;
wire [31:0] shared_file_size    = mtg_done_w ? bmp_file_size    : mtg_file_size;

fat32_file_streamer u_bmp_streamer(
    .clk(clk), .rst_n(~rst),
    .file_start(shared_file_start),
    .first_cluster(shared_file_cluster),
    .file_size(shared_file_size),
    .sectors_per_cluster(spc_l),
    .sectors_per_cluster_shift(spc_shift_l),
    .fat_start_lba(fat_start_l),
    .data_start_lba(data_start_l),
    .max_cluster(max_cluster_l),
    .file_busy(),
    .file_done(bmp_file_done),
    .file_valid(bmp_file_valid),
    .file_byte(bmp_file_byte),
    .file_byte_offset(),
    .fs_error(bmp_file_error),
    .sector_req(bmp_str_req), .sector_lba(bmp_str_lba),
    .sector_busy(bmp_str_busy), .sector_valid(bmp_str_valid),
    .sector_byte(bmp_str_byte), .sector_byte_index(bmp_str_byte_idx),
    .sector_done(bmp_str_done), .sector_error(bmp_str_error)
);

sd_sector_adapter u_bmp_str_adapter(
    .clk(clk), .rst_n(~rst), .allow_req(1'b1),
    .sector_req(bmp_str_req), .sector_lba(bmp_str_lba),
    .sector_busy(bmp_str_busy), .sector_valid(bmp_str_valid),
    .sector_byte(bmp_str_byte), .sector_byte_index(bmp_str_byte_idx),
    .sector_done(bmp_str_done), .sector_error(bmp_str_error),
    .sd_sec_read(bmp_str_sd_req), .sd_sec_read_addr(bmp_str_sd_lba),
    .sd_sec_read_data_valid(a_sec_data_valid),
    .sd_sec_read_data(sd_sec_read_data),
    .sd_sec_read_end(a_sec_end)
);

//====================================================================
// 会议配置文件流读取(fat32_file_streamer): MTG1.CFG(资源 10)经 streamer
//   读整文件, 字节流回给 meeting_sd_rd 解析。
//   ★已并入 bmp streamer(见上方 shared_file_*), 此处仅 demux 分回 meeting_sd_rd。
//====================================================================
// mtg 侧消费共享 streamer 的输出(仅 mtg_done_w=0 阶段有效; bmp 阶段 mtg 已 idle 不消费)
wire            mtg_file_valid = bmp_file_valid & ~mtg_done_w;
wire [7:0]      mtg_file_byte  = bmp_file_byte;
wire            mtg_file_done  = bmp_file_done & ~mtg_done_w;
wire [7:0]      mtg_file_error = bmp_file_error;

//====================================================================
// WAV 背景音乐文件流读取(fat32_file_streamer): WEL.BIN(资源 11)经 streamer
//   读整文件, 字节流回给 wav_stream_player。水位流控由 wav 的 allow_req
//   接到 adapter 的 allow_req 输入(adapter 假装忙 → streamer 停在 ST_DATA_REQ)。
//====================================================================
wire            wav_file_start;
wire [31:0]     wav_file_cluster;
wire [31:0]     wav_file_size;
wire            wav_file_valid;
wire [7:0]      wav_file_byte;
wire            wav_file_done;
wire [7:0]      wav_file_error;
wire            wav_allow_req;
wire            wav_str_req;
wire [31:0]     wav_str_lba;
wire            wav_str_busy, wav_str_valid, wav_str_done;
wire [7:0]      wav_str_byte, wav_str_error;
wire [8:0]      wav_str_byte_idx;

fat32_file_streamer u_wav_streamer(
    .clk(clk), .rst_n(~rst),
    .file_start(wav_file_start),
    .first_cluster(wav_file_cluster),
    .file_size(wav_file_size),
    .sectors_per_cluster(spc_l),
    .sectors_per_cluster_shift(spc_shift_l),
    .fat_start_lba(fat_start_l),
    .data_start_lba(data_start_l),
    .max_cluster(max_cluster_l),
    .file_busy(),
    .file_done(wav_file_done),
    .file_valid(wav_file_valid),
    .file_byte(wav_file_byte),
    .file_byte_offset(),
    .fs_error(wav_file_error),
    .sector_req(wav_str_req), .sector_lba(wav_str_lba),
    .sector_busy(wav_str_busy), .sector_valid(wav_str_valid),
    .sector_byte(wav_str_byte), .sector_byte_index(wav_str_byte_idx),
    .sector_done(wav_str_done), .sector_error(wav_str_error)
);

sd_sector_adapter u_wav_str_adapter(
    .clk(clk), .rst_n(~rst), .allow_req(wav_allow_req),
    .sector_req(wav_str_req), .sector_lba(wav_str_lba),
    .sector_busy(wav_str_busy), .sector_valid(wav_str_valid),
    .sector_byte(wav_str_byte), .sector_byte_index(wav_str_byte_idx),
    .sector_done(wav_str_done), .sector_error(wav_str_error),
    .sd_sec_read(wav_str_sd_req), .sd_sec_read_addr(wav_str_sd_lba),
    .sd_sec_read_data_valid(wav_sec_data_valid),
    .sd_sec_read_data(sd_sec_read_data),
    .sd_sec_read_end(wav_sec_end)
);

// 会议配置读取收尾 + 扫描完成后, 才把 BMP 挂在"就绪"窗口里。
//   启动顺序(2026-10-03 FAT32 化): sd_init_done → scanner 扫目录(scan_ok)
//   → meeting 读配置(mtg_done_w) → bmp 放行。scanner 先于 meeting 是因为
//   meeting 的 MTG1.CFG 也依赖 scanner 扫出的簇号。
assign bmp_go    = scan_ok & mtg_done_w;
assign mtg_done  = mtg_done_w;
assign mtg_ram_we   = mtg_ram_we_w;
assign mtg_ram_addr = mtg_ram_addr_w;
assign mtg_ram_data = mtg_ram_data_w;
assign mtg_ready    = mtg_ready_w;
assign mtg_error    = mtg_error_w;
assign mtg_total    = mtg_total_w;
// WEL.BIN(资源 11)是否扫到 → 供顶层 sel_wav 判定音乐素材是否就绪。
assign wav_file_ready = (res_cluster_sel(4'd11) != 32'd0) && scan_ok;

//按键脉冲/图序号由上层 ui_key_ctrl 统一消抖后给出, 本模块不再做本地消抖
//   FAT32 化: bmp_read_auto 通过 file_* 接口对接 bmp streamer(字节流),
//   簇号表 zone_clu[]/zone_siz[] 由场景映射逻辑在 zone_load 当拍锁存后传入。
bmp_read_auto bmp_read_auto_m0(
	.clk                       (clk                    ),
	.rst                       (rst                    ),
	.ready                     (                       ),
	.sd_init_done              (bmp_go                 ),	//收尾前钉 0 → 安全挂载窗口
	.state_code                (state_code             ),
	.bmp_width                 (bmp_width              ),
	.key_trigger               (key_next               ),
	.key_prev                  (key_prev               ),
	.slide_en                  (slide_en               ),
	.slide_interval            (slide_interval         ),
	.zone_start                (32'd0                  ),
	.zone_wrap                 (32'd0                  ),
	.zone_max_img              (zone_max               ),
	.zone_load                 (bmp_zone_load          ),
	.zone_cluster0             (zone_clu[0]            ),
	.zone_cluster1             (zone_clu[1]            ),
	.zone_cluster2             (zone_clu[2]            ),
	.zone_cluster3             (zone_clu[3]            ),
	.zone_cluster4             (zone_clu[4]            ),
	.zone_cluster5             (zone_clu[5]            ),
	.zone_size0                (zone_siz[0]            ),
	.zone_size1                (zone_siz[1]            ),
	.zone_size2                (zone_siz[2]            ),
	.zone_size3                (zone_siz[3]            ),
	.zone_size4                (zone_siz[4]            ),
	.zone_size5                (zone_siz[5]            ),
	.reload_req                (reload_req             ),
	.write_req                 (write_req              ),
	.write_req_ack             (write_req_ack          ),
	.file_start                (bmp_file_start         ),
	.file_cluster              (bmp_file_cluster       ),
	.file_len_out              (bmp_file_size          ),
	.file_valid                (bmp_file_valid         ),
	.file_byte                 (bmp_file_byte          ),
	.file_done                 (bmp_file_done          ),
	.file_error                (bmp_file_error         ),
	.bmp_data_wr_en            (bmp_data_wr_en         ),
	.bmp_data                  (bmp_data               ),
	.img_no                    (img_no                 ),
	.img_busy                  (img_busy               ),
	.bmp_error                 (bmp_error              ),
	.img_res                   (img_res                ),
	.img_v2x                   (img_v2x                )
);

// ---- 会议议程配置读取(开机独占一次; 自带超时兜底) ----
//   FAT32 化: 走 file 接口对接 mtg streamer, 读 MTG1.CFG(资源 10)的簇号+大小。
meeting_sd_rd meeting_sd_rd_m0(
	.clk                       (clk                    ),
	.rst                       (rst                    ),
	.start_cluster             (res_cluster_sel(4'd10)  ),
	.file_size                 (res_size_sel(4'd10)     ),
	.sd_init_done              (scan_ok                ),	//扫描完成后才读配置(MTG1.CFG 簇号已就绪)
	.file_start                (mtg_file_start         ),
	.file_cluster              (mtg_file_cluster       ),
	.file_len_out              (mtg_file_size          ),
	.file_byte                 (mtg_file_byte          ),
	.file_valid                (mtg_file_valid         ),
	.file_done                 (mtg_file_done          ),
	.file_error                (mtg_file_error         ),
	.ram_we                    (mtg_ram_we_w           ),
	.ram_addr                  (mtg_ram_addr_w         ),
	.ram_data                  (mtg_ram_data_w         ),
	.ready                     (mtg_ready_w            ),
	.error                     (mtg_error_w            ),
	.total                     (mtg_total_w            ),
	.done                      (mtg_done_w             )
);

// ---- WAV 背景音乐流(裸 PCM; 写侧 sd 域, 读侧 audio_clk 域) ----
//   loop_en=1: 迎新场景要一直有音乐, 播完自动回绕续播(无缝, 见模块头注释)。
//   FAT32 化: file_* 接口对接 wav streamer, 读 WEL.BIN(资源 11)的簇号+大小。
//   水位流控 allow_req 接到 wav adapter(见下方 u_wav_str_adapter)。
wav_stream_player #(
	.ADDR_WIDTH         (11                    ),
	.SAMPLES_PER_SECTOR (256                   ),
	.PREFILL            (1024                  )
) u_wav_player(
	.wr_clk                    (clk                    ),
	.wr_rst_n                  (~rst                   ),
	.play_enable               (wav_play_en            ),
	.loop_en                   (1'b1                   ),
	.start_cluster             (res_cluster_sel(4'd11)  ),
	.file_size                 (res_size_sel(4'd11)     ),
	.file_start                (wav_file_start         ),
	.file_cluster              (wav_file_cluster       ),
	.file_len_out              (wav_file_size          ),
	.file_valid                (wav_file_valid         ),
	.file_byte                 (wav_file_byte          ),
	.file_done                 (wav_file_done          ),
	.file_error                (wav_file_error         ),
	.allow_req                 (wav_allow_req          ),
	.rd_clk                    (audio_clk              ),
	.rd_rst_n                  (audio_rst_n            ),
	.sample_tick               (wav_sample_tick        ),
	.sample_ready              (wav_sample_ready       ),
	.sample_out                (wav_sample             ),
	.sample_valid              (wav_sample_valid       ),
	.primed                    (wav_primed             ),
	.sample_counter            (                       )
);

sd_card_top  sd_card_top_m0(
	.clk                       (clk                    ),
	.rst                       (rst                    ),
	.SD_nCS                    (SD_nCS                 ),
	.SD_DCLK                   (SD_DCLK                ),
	.SD_MOSI                   (SD_MOSI                ),
	.SD_MISO                   (SD_MISO                ),
	.sd_init_done              (sd_init_done           ),
	.sd_sec_read               (sd_sec_read            ),
	.sd_sec_read_addr          (sd_sec_read_addr       ),
	.sd_sec_read_data          (sd_sec_read_data       ),
	.sd_sec_read_data_valid    (sd_sec_read_data_valid ),
	.sd_sec_read_end           (sd_sec_read_end        ),
	.sd_sec_write              (1'b0                   ),
	.sd_sec_write_addr         (32'd0                  ),
	.sd_sec_write_data         (                       ),
	.sd_sec_write_data_req     (                       ),
	.sd_sec_write_end          (                       )
);
endmodule 
