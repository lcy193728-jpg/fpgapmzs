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
	// ---- 场景分区重载(透传 bmp_read_auto, sd_card_clk 同域) ----
	input [31:0]                zone_start,         //新分区扫描起点扇区
	input [31:0]                zone_wrap,          //新分区扫描上限扇区
	input [31:0]                zone_max_img,       //新分区图片张数
	input                       zone_load,          //分区重载请求(单周期脉冲)
	input                       reload_req,         //原地重读当前图请求(缩放档变化, 单周期脉冲)
	output                      write_req,          //start writing request
	input                       write_req_ack,      //write request response
	output                      write_en,           //bmp image data write enable
	output[31:0]                write_data,         //bmp image data
	output[7:0]                 img_no,             //当前显示图序号(透传, 数码管/上层用)
	output                      img_busy,           //底层图加载忙(扫/读/挂起), 供切场淡入淡出
	output                      SD_nCS,             //SD card chip select (SPI mode)
	output                      SD_DCLK,            //SD card clock
	output                      SD_MOSI,            //SD card controller data output
	input                       SD_MISO             //SD card controller data input
);
wire             sd_sec_read;
wire[31:0]       sd_sec_read_addr;
wire[7:0]        sd_sec_read_data; //synthesis keep
wire             sd_sec_read_data_valid;
wire             sd_sec_read_end;
wire             bmp_data_wr_en;
wire[23:0]       bmp_data;
wire             sd_init_done;
assign write_en = bmp_data_wr_en;
assign write_data = {bmp_data[23:16],bmp_data[15:8],bmp_data[7:0],8'b0};
//按键脉冲/图序号由上层 ui_key_ctrl 统一消抖后给出, 本模块不再做本地消抖
bmp_read_auto bmp_read_auto_m0(
	.clk                       (clk                    ),
	.rst                       (rst                    ),
	.ready                     (                       ),
	.sd_init_done              (sd_init_done           ),	
	.state_code                (state_code             ),
	.bmp_width                 (bmp_width              ),
	.key_trigger               (key_next               ),
	.key_prev                  (key_prev               ),
	.slide_en                  (slide_en               ),
	.zone_start                (zone_start             ),
	.zone_wrap                 (zone_wrap              ),
	.zone_max_img              (zone_max_img           ),
	.zone_load                 (zone_load              ),
	.reload_req                (reload_req             ),
	.write_req                 (write_req              ),
	.write_req_ack             (write_req_ack          ),
	.sd_sec_read               (sd_sec_read            ),
	.sd_sec_read_addr          (sd_sec_read_addr       ),
	.sd_sec_read_data          (sd_sec_read_data       ),
	.sd_sec_read_data_valid    (sd_sec_read_data_valid ),
	.sd_sec_read_end           (sd_sec_read_end        ),
	.bmp_data_wr_en            (bmp_data_wr_en         ),
	.bmp_data                  (bmp_data               ),
	.img_no                    (img_no                 ),
	.img_busy                  (img_busy               )
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