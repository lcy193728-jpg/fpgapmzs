`timescale 1ns/1ps
// Same sector handshake as main sd_card_top; share that controller via host mux.
// Never instantiate a second SPI master on the same pins. No FAT support assumed.
module meeting_sd_reader #(parameter START_SECTOR=200000, SECTORS=2)(
 input clk,rst,start,sd_init_done,
 output reg sd_sec_read,output reg [31:0] sd_sec_read_addr,
 input [7:0] sd_sec_read_data,input sd_sec_read_data_valid,sd_sec_read_end,
 output cfg_start,output cfg_valid,output [7:0] cfg_data,output cfg_last,
 output reg busy,output reg done);
reg [15:0] sector,byte_count;
reg request;
assign cfg_start=start && !busy;
assign cfg_valid=busy && sd_sec_read_data_valid;
assign cfg_data=sd_sec_read_data;
assign cfg_last=cfg_valid && sector==SECTORS-1 && byte_count==511;
always @(posedge clk) begin
 if(rst) begin busy<=0;done<=0;sector<=0;byte_count<=0;request<=0;sd_sec_read<=0;sd_sec_read_addr<=START_SECTOR;end
 else begin
 done<=0;sd_sec_read<=0;
 if(start && !busy) begin busy<=1;sector<=0;byte_count<=0;request<=1;sd_sec_read_addr<=START_SECTOR;end
 if(busy) begin
 if(request && sd_init_done) begin sd_sec_read<=1;request<=0;end
 if(sd_sec_read_data_valid) byte_count<=byte_count+1;
 if(sd_sec_read_end) begin
 if(sector==SECTORS-1) begin busy<=0;done<=1;end
 else begin sector<=sector+1;sd_sec_read_addr<=sd_sec_read_addr+1;byte_count<=0;request<=1;end
 end end
 end end
endmodule
