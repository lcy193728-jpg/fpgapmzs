//====================================================================
// 模块名 : sd_card_bmp.v —— SD 卡 BMP 读取 + 会议议程配置(固定扇区)读取
//
// 本次改动(会议场景上板整合):
//   TF 卡上额外放一份"会议议程配置"(原始 MTG1 字节流, 见 meeting_sd_rd.v),
//   必须复用同一片 SD 控制器 —— 板上 SPI 引脚(sd_ncs/sd_dclk/sd_mosi/sd_miso)
//   由 sd_card_top 独占, **绝不能**再例化第二个 SPI master。
//
//   仲裁方案(方案 A · 开机串行化, 最稳):
//     · sd_init_done 有效后, meeting_sd_rd 先独占总线读配置扇区;
//     · 读配置期间把 bmp_read_auto 的 sd_init_done 输入**钉在 0**
//       (bmp_read_auto 在 sd_init_done==0 时被锁在 S_IDLE 且 sd_sec_read<=0,
//        见 bmp_read_auto.v 的该分支 —— 这就是安全的挂载窗口);
//     · 配置读完(或超时收尾) mtg_done=1 → 放行 bmp_read_auto, 之后两者
//       不再同时占线(会议读取已彻底结束)。
//   代价: 开机多花几十 ms 读 1~3 个扇区; 收益: 全程无"运行中抢总线"竞态。
//
//   总线合并: sd_sec_read = BMP 请求 | 会议请求(电平)
//             sd_sec_read_addr = 会议请求 ? 会议地址 : BMP 地址
//   (会议读取期间 BMP 恒不发请求, 故此多路选择无冲突)
//
//   已知边界(与改造前一致): 官方 sd_card_cmd 在 S_READ_WAIT 等 0xFE 数据令牌
//   时自身无超时; meeting_sd_rd 自带超时兜底, 保证不会永久占线拖死 BMP。
//
//   ※ meeting_sd_rd.v 未登记在 pic_sdram.al 的综合列表里(与 osd_scene/ui_key_ctrl
//     等同属"靠 include 并入"的一类), 而它就在本文件内例化, 故在本文件顶部
//     include, 保证"定义与例化在同一编译单元", 不依赖顶层 include 顺序。
//====================================================================
`include "meeting_sd_rd.v"

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

// ---- 总线上板仲裁: 会议读取优先(其期间 BMP 恒不发请求) ----
wire             sd_sec_read      = bmp_sec_read | mtg_sec_read;
wire[31:0]       sd_sec_read_addr = mtg_sec_read ? mtg_sec_read_addr : bmp_sec_read_addr;

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
	.sd_sec_read_data_valid    (sd_sec_read_data_valid ),
	.sd_sec_read_end           (sd_sec_read_end        ),
	.bmp_data_wr_en            (bmp_data_wr_en         ),
	.bmp_data                  (bmp_data               ),
	.img_no                    (img_no                 ),
	.img_busy                  (img_busy               ),
	.bmp_error                 (bmp_error              )
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
	.sd_sec_read_data_valid    (sd_sec_read_data_valid ),
	.sd_sec_read_end           (sd_sec_read_end        ),
	.ram_we                    (mtg_ram_we_w           ),
	.ram_addr                  (mtg_ram_addr_w         ),
	.ram_data                  (mtg_ram_data_w         ),
	.ready                     (mtg_ready_w            ),
	.error                     (mtg_error_w            ),
	.total                     (mtg_total_w            ),
	.done                      (mtg_done_w             )
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
