`timescale 1ns/1ps

// 会议 OSD 项目特化算术等价回归：
//   1) 0..20s 倒计时译码与原 /10,%10 完全一致；
//   2) 200*sec/20 进度长度与 10*sec 一致；
//   3) 状态文字 0..167 局部坐标的 /24,%24 等价；
//   4) 非会议时内部坐标隔离，但输出坐标/像素仍透传。
module tb_meeting_osd_logic_equiv;
    reg clk=0,rst=1,en=0;
    reg [1:0] state=0;
    reg [5:0] sec=0;
    reg [11:0] x=0,y=0;
    reg [23:0] din=24'h123456;
    wire ho,vo,deo;
    wire [23:0] dout;
    wire [11:0] xo,yo;
    integer i,checks=0,fails=0;
    always #5 clk=~clk;

    meeting_osd dut(
      .video_clk(clk),.rst(rst),.hs_i(1'b0),.vs_i(1'b0),.de_i(1'b1),
      .data_i(din),.px_x(x),.px_y(y),.meet_en(en),.m_state(state),.m_sec(sec),
      .hs_o(ho),.vs_o(vo),.de_o(deo),.data_o(dout),.px_x_o(xo),.px_y_o(yo));

    initial begin
      repeat(3)@(posedge clk); rst=0;

      // 非会议场景内部操作数锁零，对外仍延迟一拍透传。
      x=12'd517;y=12'd233;din=24'hA1B2C3;repeat(3)@(posedge clk);#1;
      checks=checks+1;
      if(dut.geo_x!==0 || dut.geo_y!==0 || xo!==12'd517 || yo!==12'd233 || dout!==24'hA1B2C3)begin
        fails=fails+1;$display("[FAIL] inactive operand isolation/pass-through");
      end

      en=1;repeat(4)@(posedge clk);
      for(i=0;i<=20;i=i+1)begin
        sec=i[5:0];repeat(3)@(posedge clk);#1;
        checks=checks+1;
        if(dut.s_ten!==(i/10) || dut.s_one!==(i%10) || dut.pb_fill!==((200*i)/20))begin
          fails=fails+1;
          $display("[FAIL] sec=%0d ten=%0d/%0d one=%0d/%0d fill=%0d/%0d",
                   i,dut.s_ten,i/10,dut.s_one,i%10,dut.pb_fill,(200*i)/20);
        end
      end

      for(i=0;i<168;i=i+1)begin
        x=12'd24+i;y=12'd12;#1;
        checks=checks+1;
        if(dut.status_ci!==(i/24) || dut.status_cx!==(i%24))begin
          fails=fails+1;
          $display("[FAIL] lx=%0d ci=%0d/%0d cx=%0d/%0d",
                   i,dut.status_ci,i/24,dut.status_cx,i%24);
        end
      end

      $display("==== tb_meeting_osd_logic_equiv checks=%0d fails=%0d ====",checks,fails);
      if(fails==0)$display("RESULT: PASS");else $display("RESULT: FAIL");
      $finish;
    end
endmodule
