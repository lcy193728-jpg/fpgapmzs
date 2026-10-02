//====================================================================
// 模块名 : seg_scan.v
// 功能   : 8 位数码管动态扫描(位选低有效, 段选低有效, seg_data[7]=小数点)
//   位序约定: seg_sel[n]=0 选中第 (n+1) 位; 第 1 位=最左(最高位)。
//   本工程显示布局(用户规格):
//     第1位 = 场景号(0..3)           → seg_data_0
//     第2~4位 = 当前模式参数值       → seg_data_1/2/3
//     第5位 = 功能模式号(0/1/2)      → seg_data_4
//     第6、7位 = 固定横线 "-" 分隔符 → seg_data_5/6
//     第8位 = 熄灭(备用)             → seg_data_7
//====================================================================

module seg_scan(
	input           clk,
	input           rst_n,
	output reg[7:0] seg_sel,      //digital led chip select(第 n 位选通 = bit n 拉低)
	output reg[7:0] seg_data,     //eight segment digital tube output,MSB is the decimal point
	input[7:0]      seg_data_0,
	input[7:0]      seg_data_1,
	input[7:0]      seg_data_2,
	input[7:0]      seg_data_3,
	input[7:0]      seg_data_4,
	input[7:0]      seg_data_5,
	input[7:0]      seg_data_6,
	input[7:0]      seg_data_7
);
parameter SCAN_FREQ = 200;     //scan frequency
parameter CLK_FREQ = 50000000; //clock frequency

parameter SCAN_COUNT = CLK_FREQ /(SCAN_FREQ * 8) - 1;

reg[31:0] scan_timer;  //scan time counter
reg[3:0] scan_sel;     //Scan select counter
always@(posedge clk or negedge rst_n)
begin
	if(rst_n == 1'b0)
	begin
		scan_timer <= 32'd0;
		scan_sel <= 4'd0;
	end
	else if(scan_timer >= SCAN_COUNT)
	begin
		scan_timer <= 32'd0;
		if(scan_sel == 4'd7)
			scan_sel <= 4'd0;
		else
			scan_sel <= scan_sel + 4'd1;
	end
	else
		begin
			scan_timer <= scan_timer + 32'd1;
		end
end
always@(posedge clk or negedge rst_n)
begin
	if(rst_n == 1'b0)
	begin
		seg_sel <= 8'b11111111;
		seg_data <= 8'hff;
	end
	else
	begin
		case(scan_sel)
			//first digital led(第1位: 场景号)
			4'd0:
			begin
				seg_sel <= 8'b1111_1110;
				seg_data <= seg_data_0;
			end
			//second digital led(第2位)
			4'd1:
			begin
				seg_sel <= 8'b1111_1101;
				seg_data <= seg_data_1;
			end
			4'd2:
			begin
				seg_sel <= 8'b1111_1011;
				seg_data <= seg_data_2;
			end
			4'd3:
			begin
				seg_sel <= 8'b1111_0111;
				seg_data <= seg_data_3;
			end
			//第5位: 功能模式号
			4'd4:
			begin
				seg_sel <= 8'b1110_1111;
				seg_data <= seg_data_4;
			end
			//第6位: 固定横线
			4'd5:
			begin
				seg_sel <= 8'b1101_1111;
				seg_data <= seg_data_5;
			end
			//第7位: 固定横线
			4'd6:
			begin
				seg_sel <= 8'b1011_1111;
				seg_data <= seg_data_6;
			end
			//第8位: 备用(熄灭)
			4'd7:
			begin
				seg_sel <= 8'b0111_1111;
				seg_data <= seg_data_7;
			end
			default:
			begin
				seg_sel <= 8'b1111_1111;
				seg_data <= 8'hff;
			end
		endcase
	end
end

endmodule
