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
	input                       key,                //按键1(原始电平，内部消抖)，按下拉低触发切图
	output                      write_req,          //start writing request
	input                       write_req_ack,      //write request response
	output                      write_en,           //bmp image data write enable
	output[31:0]                write_data,         //bmp image data
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
//按键1消抖(内联实现，避免独立 ax_debounce.v 被 TD GUI 工程列表丢失导致 black box)
//clk=100MHz，两级同步 + 20ms 计数器消抖，检测下降沿(按下触发)
reg [20:0] deb_cnt;        // 消抖计数器，20ms@100MHz=2000000 周期(需 21bit)
reg [1:0]  key_sync;       // 两级同步
reg        key_stable;     // 消抖后稳定电平
reg        key_stable_d;   // 延迟一拍(边沿检测)
wire       button_negedge; // 按下下降沿单周期脉冲

always @(posedge clk or posedge rst) begin
	if (rst) begin
		key_sync     <= 2'b11;
		deb_cnt      <= 21'd0;
		key_stable   <= 1'b1;
		key_stable_d <= 1'b1;
	end
	else begin
		key_sync <= {key_sync[0], key};        // 两级同步
		if (key_sync[1] != key_sync[0])
			deb_cnt <= 21'd0;                   // 输入变化，重新计数
		else if (deb_cnt == 21'd2000000)
			key_stable <= key_sync[1];          // 稳定 20ms 后更新
		else
			deb_cnt <= deb_cnt + 21'd1;
		key_stable_d <= key_stable;
	end
end
assign button_negedge = key_stable_d & ~key_stable;   // 下降沿(按下)
bmp_read_auto bmp_read_auto_m0(
	.clk                       (clk                    ),
	.rst                       (rst                    ),
	.ready                     (                       ),
	.sd_init_done              (sd_init_done           ),	
	.state_code                (state_code             ),
	.bmp_width                 (bmp_width              ),
	.key_trigger               (button_negedge         ),
	.write_req                 (write_req              ),
	.write_req_ack             (write_req_ack          ),
	.sd_sec_read               (sd_sec_read            ),
	.sd_sec_read_addr          (sd_sec_read_addr       ),
	.sd_sec_read_data          (sd_sec_read_data       ),
	.sd_sec_read_data_valid    (sd_sec_read_data_valid ),
	.sd_sec_read_end           (sd_sec_read_end        ),
	.bmp_data_wr_en            (bmp_data_wr_en         ),
	.bmp_data                  (bmp_data               )
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