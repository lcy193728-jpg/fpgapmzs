//====================================================================
// 模块名 : sd_card_bmp.v —— SD 卡 BMP 读取 + FAT32 文件名寻址
//                             + WAV 音频流(TF 卡裸 PCM)读取
//
// TF 卡上放三类数据, 全部复用同一片 SD 控制器 —— 板上 SPI 引脚
//   (sd_ncs/sd_dclk/sd_mosi/sd_miso)由 sd_card_top 独占,
//   **绝不能**再例化第二个 SPI master。
//
//   · BMP 图片     : 由 FAT32 寻址层按【文件名】动态定位(见 fat32_lookup.v)
//   · WAV 背景音乐 : 扇区 300000 起(裸 PCM 48kHz/16bit/mono, 见 wav_stream_player.v)
//
// ── v11 改造(2026-10-07): 硬编码分区表 → FAT32 文件名寻址 ──
//   改造前: 顶层用 case(latch_sw) 查 Z_* 常量, 换卡/重排素材/重新格式化都必须
//           重跑 find_bmp.py 重算扇区并【重新综合生成位流】。
//   改造后: 上电与场景切换时读一次卡根目录, 按前缀(WEL/QUIZ/ALM)匹配 8.3
//           短名, 直接算出 bmp_read_auto 要的 zone_start/zone_wrap/zone_max_img。
//           加/删/换图片只需改文件名 —— 不重编译、不重建位流。
//   ★ bmp_read_auto 一行未改: 它仍只认那三个数, 只是这三个数从"RTL 常量"
//     变成了"查表结果"(全案最重要的风险控制点)。
//   ★ 查表失败(卡没改名/非 FAT32)自动回退 10-4 兜底常量并置 zone_err ——
//     行为绝不比改造前差(见 fat32_lookup.v 头部)。
//
// 仲裁(2026-09-26 加背景音乐时改造, v11 沿用):
//   "迎新场景照片轮播 + 背景音乐"必须**并发**占用同一条 SPI 总线, 故引入
//   audio_sd_arbiter: 逐扇区授权, 总线数据/结束**只回给授权方**。
//     A 侧 = 图片轮播(bmp_read_auto) 与 FAT32 寻址层(fat32_lookup)的合并请求
//            (两者时间上互不重叠: 查表期间 bmp_go 钉 0, bmp 停在安全窗口)
//     B 侧 = WAV 音频流(wav_stream_player 写侧状态机), **优先**
//   音频只在循环缓冲低于水位时发请求(HIGH_WATER), 占空比约 5%,
//   图片拿到剩余带宽(见 audio_sd_arbiter 头注释的数值论证)。
//
//   开机顺序: 第一遍 FAT32 查表读完前音频不参与仲裁(与改造前的
//   "会议配置先读完"完全同一套串行化时序, 只是主体换成了查表)。
//
//   ※ fat32_lookup.v / audio_sd_arbiter.v / zone_launch.v /
//     wav_stream_player.v 未登记在 pic_sdram_audio_final.al 的综合列表里
//     (与 osd_scene/ui_key_ctrl 等同属"靠 include 并入"的一类), 而它们都在
//     本文件内例化, 故在本文件顶部 include, 保证"定义与例化在同一编译单元",
//     不依赖顶层 include 顺序。
//   ★2026-10-09: quiz_scene_ctrl 的 include 已从本文件**移除**——本文件并未
//     例化该模块(它只在 top_final.v 内例化, 由 top_final.v 自己 include)。
//     留着会导致"同一模块被两个编译单元各定义一次" → TD 报
//     HDL-7201 CRITICAL-WARNING: overwrite current module 'quiz_scene_ctrl'。
//====================================================================
`include "fat32_lookup.v"
`include "audio_sd_arbiter.v"
`include "zone_launch.v"
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
	// ---- 抢答场景「绝对跳图」(2026-10-08) ----
	//   锁定后按 winner 直接定位到 QUIZ 分区第 (winner+2) 张队伍图, 零额外查表。
	input                       key_jump,           //绝对跳图请求(单周期脉冲)
	input [3:0]                 jump_idx,           //目标图序号(0 基; 0=内容图, 1..4=队伍图)
	input                       slide_en,           //自动轮播使能(手动/应急=0 冻结当前画面)
	input [31:0]                slide_interval,     //批次4 轮播间隔(时钟周期, 周期档 2/3/5/10/30s)
	// ---- 场景素材定位(v11: FAT32 文件名寻址) ----
	input [2:0]                 zone_sel,           //场景码: 0菜单 1迎新 2预留 3抢答 4应急
	input                       zone_load_req,      //场景切换请求(单周期脉冲; 查表就绪后才真正下发)
	output                      zone_tbl_ready,     //段表已就绪(调试/上板观测)
	output                      zone_err,           //1=未匹配到文件(已回退 10-4 兜底常量)
	input                       reload_req,         //原地重读当前图请求(缩放档变化, 单周期脉冲)
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
//     wire[31:0] sd_sec_read_addr = <A侧地址> ? <A侧> : bmp_sec_read_addr;
//   后来改"仲裁器"时删掉了那条赋值式声明, 宽度信息随之丢失(逻辑没变,
//   只是漏了声明)。故此处必须保留显式位宽(见下面的 wire[31:0] 两行)。
wire             sd_sec_read;       //仲裁器 → SD 控制器: 扇区读请求(电平)
wire[31:0]       sd_sec_read_addr;  //仲裁器 → SD 控制器: 32 位扇区地址(物理扇区)
wire             bmp_data_wr_en;
wire[23:0]       bmp_data;
wire             sd_init_done;
wire             bmp_go;            //放行 BMP: FAT32 查表读完(或卡未就绪)

// ---- FAT32 寻址层(v11) ----
wire [31:0]      lu_start_w;        //本场景扫描起点(zone_start)
wire [31:0]      lu_wrap_w;         //本场景扫描上限(zone_wrap)
wire [31:0]      lu_max_w;          //本场景图片张数(zone_max_img)
wire             lu_ready;          //段表已就绪
wire             lu_err;            //未匹配到文件
wire             lu_busy;           //查表中(此时 bmp_go 钉 0)
wire             lu_sec_read;
wire [31:0]      lu_sec_read_addr;
wire             bmp_zone_load;     //下发给 bmp_read_auto 的分区重载脉冲

// ---- FAT32 查表停车/交棒(v11) ----
//   ★ 这些信号必须【声明在 wav_bus_ready 之前】, 否则 Verilog 会先生成
//     1 位隐式网络, 与本文件头警示的是同一类坑。
wire             first_tbl_done;    //第一次查表已收尾(zone_launch 输出)
wire             lu_start;          //下发一次查表(zone_launch 输出)
wire             lu_req;            //查表原始请求(上电首查 | 场景切换)
wire             bus_free;          //仲裁器侧总线空闲
reg              init_done_d;       //上电首查用的打拍寄存器
wire             first_start;       //上电首查(单拍脉冲)

// ---- 仲裁器 A 侧: 图片轮播 + FAT32 查表的合并请求 ----
//   查表期间 bmp_read_auto 被 bmp_go 钉在安全窗口, 恒不发请求,
//   故"查表优先取地址"不存在两者同时有效的情形(与改造前同一套路)。
wire             a_sec_req  = bmp_sec_read | lu_sec_read;
wire[31:0]       a_sec_addr = lu_sec_read ? lu_sec_read_addr : bmp_sec_read_addr;
wire             a_sec_data_valid;
wire             a_sec_end;
// ---- 仲裁器 B 侧: WAV 音频流 ----
wire             wav_sec_req_raw;
wire [31:0]      wav_sec_req_addr;
wire             wav_sec_data_valid;
wire             wav_sec_end;
// 开机放行门控: 第一遍 FAT32 查表读完前不让音频参与仲裁 —— 与改造前的
//   启动时序一致(见文件头说明)。两个门控信号都是 sd 域 0→1 单次单调变化。
wire             wav_bus_ready = sd_init_done & first_tbl_done;
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

// ---- FAT32 查表启动/收尾(v11: 全部交给 zone_launch, 见 src/zone_launch.v) ----
//   本文件原来在这里手写 init_done_d/tbl_ready_d/first_tbl_done 三个寄存器 +
//   四条组合赋值。v11 专项仿真(tb_zone_launch)证明那套朴素写法有两个缺口:
//     ① bmp_go 晚一拍钉 0 → 请求当拍 bmp_read_auto 已抢发一个扇区;
//     ② 查表不等总线空闲就发请求 → 与 BMP 争用 A 侧同一套数据广播口。
//   zone_launch 把"停车/交棒/分区下发"的时序收进一个模块并配了专项仿真,
//   故此处只做"上电首查脉冲"这一件小事, 其余全部下沉。
assign first_start = sd_init_done & ~init_done_d;            // 上电首查(单拍)
assign lu_req      = first_start | zone_load_req;            // 查表原始请求
assign bus_free    = ~sd_sec_read;                           // 仲裁器侧总线空闲

always @(posedge clk or posedge rst) begin
	if (rst) init_done_d <= 1'b0;
	else     init_done_d <= sd_init_done;
end

zone_launch u_zone_launch(
	.clk            (clk            ),
	.rst            (rst            ),
	.sd_init_done   (sd_init_done   ),
	.lu_req         (lu_req         ),
	.lu_busy        (lu_busy        ),
	.lu_ready       (lu_ready       ),
	.bus_free       (bus_free       ),
	.lu_start       (lu_start       ),
	.bmp_go         (bmp_go         ),
	.bmp_zone_load  (bmp_zone_load  ),
	.first_tbl_done (first_tbl_done )
);

assign zone_tbl_ready = lu_ready;
assign zone_err       = lu_err;

fat32_lookup u_fat32_lookup(
	.clk                       (clk                    ),
	.rst                       (rst                    ),
	.sd_init_done              (sd_init_done           ),	//原始信号(不门控)
	.zone_sel                  (zone_sel               ),
	.start_req                 (lu_start               ),
	.sd_sec_read               (lu_sec_read            ),
	.sd_sec_read_addr          (lu_sec_read_addr       ),
	.sd_sec_read_data          (sd_sec_read_data       ),
	.sd_sec_read_data_valid    (a_sec_data_valid       ),	//仲裁器只回授权方
	.sd_sec_read_end           (a_sec_end              ),
	.zone_start                (lu_start_w             ),
	.zone_wrap                 (lu_wrap_w              ),
	.zone_max_img              (lu_max_w               ),
	.tbl_ready                 (lu_ready               ),
	.zone_err                 (lu_err                 ),
	.busy                      (lu_busy                )
);

//按键脉冲/图序号由上层 ui_key_ctrl 统一消抖后给出, 本模块不再做本地消抖
//   数据字节仍是控制器广播(仲裁器只门控 valid/end), 双方各自的 valid/end
//   由 audio_sd_arbiter 路由。
bmp_read_auto bmp_read_auto_m0(
	.clk                       (clk                    ),
	.rst                       (rst                    ),
	.ready                     (                       ),
	.sd_init_done              (bmp_go                 ),	//查表期间钉 0 → 安全挂载窗口
	.state_code                (state_code             ),
	.bmp_width                 (bmp_width              ),
	.key_trigger               (key_next               ),
	.key_prev                  (key_prev               ),
	.key_jump                  (key_jump               ),	//抢答锁定绝对跳图
	.jump_idx                  (jump_idx               ),
	.slide_en                  (slide_en               ),
	.slide_interval            (slide_interval         ),
	.zone_start                (lu_start_w             ),	//v11: FAT32 查表结果
	.zone_wrap                 (lu_wrap_w              ),
	.zone_max_img              (lu_max_w               ),
	.zone_load                 (bmp_zone_load          ),	//段表就绪才脉冲
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
