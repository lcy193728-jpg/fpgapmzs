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
bmp_read_auto bmp_read_auto_m0(
	.clk                       (clk                    ),
	.rst                       (rst                    ),
	.ready                     (                       ),
	.sd_init_done              (sd_init_done           ),	
	.state_code                (state_code             ),
	.bmp_width                 (bmp_width              ),
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