`timescale 1ns/1ps
// Reuse unmodified main key_debounce. Short action on release; long keys fire once.
module meeting_keys #(parameter DEB_MAX=2000000,LONG_CYCLES=100000000)(
 input clk,rst,input [3:0] raw,output reg [3:0] press,output reg end_long,home_long);
wire [3:0] down;
reg [3:0] previous,fired;
reg [31:0] held[0:3];
genvar g;
generate for(g=0;g<4;g=g+1) begin:k
 key_debounce #(.DEB_MAX(DEB_MAX)) d(.clk(clk),.rst(rst),.key_raw(raw[g]),.key_low_stable(down[g]),.negedge_pulse());
end endgenerate
integer i;
always @(posedge clk) begin
 if(rst) begin previous<=0;fired<=0;press<=0;end_long<=0;home_long<=0;
 for(i=0;i<4;i=i+1) held[i]<=0;end
 else begin
 press<=0;end_long<=0;home_long<=0;previous<=down;
 for(i=0;i<4;i=i+1) begin
 if(down[i]) begin
 if(held[i]<LONG_CYCLES) held[i]<=held[i]+1;
 if(held[i]==LONG_CYCLES-1 && !fired[i] && (i==1 || i==3)) begin
 fired[i]<=1;if(i==1) end_long<=1;else home_long<=1;end
 end else begin
 if(previous[i] && !fired[i]) press[i]<=1;
 held[i]<=0;fired[i]<=0;
 end end
 end end
endmodule
