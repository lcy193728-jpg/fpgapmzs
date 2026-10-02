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
	// ---- 场景分区重载(透传 bmp_read_auto, sd_card_clk 同域) ----
	input [31:0]                zone_start,         //新分区扫描起点扇区
	input [31:0]                zone_wrap,          //新分区扫描上限扇区
	input [31:0]                zone_max_img,       //新分区图片张数
	input                       zone_load,          //分区重载请求(单周期脉冲)
	input                       reload_req,         //原地重读当前图请求(缩放档变化, 单周期脉冲)
	// ---- 会议议程配置(TF 卡固定扇区, MTG1 字节流) ----
	input [31:0]                mtg_start_sector,   //配置起始扇区(顶层给常量)
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
	// ---- WAV 背景音乐(TF 卡裸 PCM 流) ----
	input                       audio_clk,          //读侧时钟(= video_clk 25MHz, 48kHz 节拍域)
	input                       audio_rst_n,        //读侧复位(低有效)
	input                       wav_play_en,        //迎新场景选中 WAV(电平, audio_clk 域)
	input [31:0]                wav_start_lba,      //音频数据首扇区(卡上固定 LBA)
	input [31:0]                wav_sectors,        //音频数据总扇区数
	input                       wav_sample_tick,    //48kHz 取样节拍(audio_clk 域)
	input                       wav_sample_ready,   //下游已消费一拍(audio_clk 域)
	output signed [15:0]        wav_sample,         //(audio_clk 域)
	output                      wav_sample_valid,   //选中期间恒 1(下溢输出静音)
	output                      wav_primed,         //已攒够起播水位
	output                      SD_nCS,             //SD card chip select (SPI mode)
	output                      SD_DCLK,            //SD card clock
	output                      SD_MOSI,            //SD card controller data output
	input                       SD_MISO             //SD card controller data input
);
wire             bmp_sec_read;      //BMP 通路扇区读请求(电平)
wire[31:0]       bmp_sec_read_addr; //BMP 通路扇区地址
wire             mtg_sec_read;      //会议配置通路扇区读请求(电平)
wire[31:0]       mtg_sec_read_addr; //会议配置通路扇区地址
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

// ---- 仲裁器 A 侧: 图片轮播 + 会议配置的合并请求 ----
//   会议读取期间 bmp_read_auto 被 bmp_go 钉在安全窗口, 恒不发请求,
//   故此处"会议优先取地址"与改造前一致, 不存在两者同时有效的情形。
wire             a_sec_req  = bmp_sec_read | mtg_sec_read;
wire[31:0]       a_sec_addr = mtg_sec_read ? mtg_sec_read_addr : bmp_sec_read_addr;
wire             a_sec_data_valid;
wire             a_sec_end;
// ---- 仲裁器 B 侧: WAV 音频流 ----
wire             wav_sec_req_raw;
wire [31:0]      wav_sec_req_addr;
wire             wav_sec_data_valid;
wire             wav_sec_end;
// 开机放行门控: 会议配置(mtg_done_w)读完前不让音频参与仲裁 —— 与改造前的
//   启动时序一致(见文件头说明)。两个门控信号都是 sd 域 0→1 单次单调变化。
wire             wav_bus_ready = sd_init_done & mtg_done_w;
wire             wav_sec_req   = wav_sec_req_raw & wav_bus_ready;

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
	.b_addr                    (wav_sec_req_addr       ),
	.b_data_valid              (wav_sec_data_valid     ),
	.b_end                     (wav_sec_end            )
);

assign write_en = bmp_data_wr_en;
assign write_data = {bmp_data[23:16],bmp_data[15:8],bmp_data[7:0],8'b0};

// 会议配置读取收尾前, 把 BMP 挂在"未初始化"的安全窗口里
assign bmp_go    = sd_init_done & mtg_done_w;
assign mtg_done  = mtg_done_w;
assign mtg_ram_we   = mtg_ram_we_w;
assign mtg_ram_addr = mtg_ram_addr_w;
assign mtg_ram_data = mtg_ram_data_w;
assign mtg_ready    = mtg_ready_w;
assign mtg_error    = mtg_error_w;
assign mtg_total    = mtg_total_w;

//按键脉冲/图序号由上层 ui_key_ctrl 统一消抖后给出, 本模块不再做本地消抖
//   数据字节仍是控制器广播(仲裁器只门控 valid/end), 双方各自的 valid/end
//   由 audio_sd_arbiter 路由。
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
	.zone_start                (zone_start             ),
	.zone_wrap                 (zone_wrap              ),
	.zone_max_img              (zone_max_img           ),
	.zone_load                 (zone_load              ),
	.reload_req                (reload_req             ),
	.write_req                 (write_req              ),
	.write_req_ack             (write_req_ack          ),
	.sd_sec_read               (bmp_sec_read           ),
	.sd_sec_read_addr          (bmp_sec_read_addr      ),
	.sd_sec_read_data          (sd_sec_read_data       ),
	.sd_sec_read_data_valid    (a_sec_data_valid       ),	//仲裁器只回授权方
	.sd_sec_read_end           (a_sec_end              ),
	.bmp_data_wr_en            (bmp_data_wr_en         ),
	.bmp_data                  (bmp_data               ),
	.img_no                    (img_no                 ),
	.img_busy                  (img_busy               ),
	.bmp_error                 (bmp_error              ),
	.img_res                   (img_res                ),
	.img_v2x                   (img_v2x                )
);

// ---- 会议议程配置读取(开机独占一次; 自带超时兜底) ----
meeting_sd_rd meeting_sd_rd_m0(
	.clk                       (clk                    ),
	.rst                       (rst                    ),
	.start_sector              (mtg_start_sector       ),
	.sd_init_done              (sd_init_done           ),	//原始信号(不门控)
	.sd_sec_read               (mtg_sec_read           ),
	.sd_sec_read_addr          (mtg_sec_read_addr      ),
	.sd_sec_read_data          (sd_sec_read_data       ),
	.sd_sec_read_data_valid    (a_sec_data_valid       ),	//仲裁器只回授权方
	.sd_sec_read_end           (a_sec_end              ),
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
//   sd_byte 用控制器广播字节; 其 valid/end 已由仲裁器按授权方门控。
wav_stream_player #(
	.ADDR_WIDTH         (11                    ),
	.SAMPLES_PER_SECTOR (256                   ),
	.PREFILL            (1024                  )
) u_wav_player(
	.wr_clk                    (clk                    ),
	.wr_rst_n                  (~rst                   ),
	.play_enable               (wav_play_en            ),
	.loop_en                   (1'b1                   ),
	.start_lba                 (wav_start_lba          ),
	.total_sectors             (wav_sectors            ),
	.sd_req                    (wav_sec_req_raw        ),
	.sd_lba                    (wav_sec_req_addr       ),
	.sd_valid                  (wav_sec_data_valid     ),
	.sd_byte                   (sd_sec_read_data       ),
	.sd_done                   (wav_sec_end            ),
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
