`timescale 1ns/1ps

module tb_welcome_mosaic;
    reg clk=0,rst=1,en=0,hs=0,vs=0,de=0;
    reg [23:0] din=0;
    reg [11:0] x=0,y=0;
    wire ho,vo,deo; wire [23:0] dout; wire [11:0] xo,yo;
    integer checks=0,fails=0;
    integer i;
    always #5 clk=~clk;

    welcome_mosaic dut(.video_clk(clk),.rst(rst),.enable_req(en),
      .hs_i(hs),.vs_i(vs),.de_i(de),.data_i(din),.px_x(x),.px_y(y),
      .hs_o(ho),.vs_o(vo),.de_o(deo),.data_o(dout),.px_x_o(xo),.px_y_o(yo));

    task pixel;
      input [11:0] tx,ty; input [23:0] td,exp; input [255:0] msg;
      begin
        x=tx;y=ty;din=td;de=1;@(posedge clk);@(posedge clk);#1;
        checks=checks+1;
        if(dout===exp && xo===tx && yo===ty && deo===1'b1)
          $display("[PASS] %0s",msg);
        else begin fails=fails+1;
          $display("[FAIL] %0s out=%h/%h xy=%0d,%0d/%0d,%0d",msg,dout,exp,xo,yo,tx,ty);
        end
      end
    endtask

    initial begin
      repeat(3)@(posedge clk);rst=0;
      pixel(0,0,24'h010203,24'h010203,"关闭态首像素透传");
      pixel(1,0,24'h112233,24'h112233,"关闭态相邻像素透传");

      de=0;en=1;repeat(3)@(posedge clk);
      pixel(0,0,24'hA01020,24'hA51021,"开启帧块0采样并量化RGB565");
      pixel(1,0,24'h010101,24'hA51021,"块0同行保持");
      pixel(15,0,24'h0F0F0F,24'hA51021,"块0末像素保持");
      pixel(16,0,24'hB03040,24'hB53042,"块1采样并量化RGB565");
      pixel(17,0,24'h020202,24'hB53042,"块1同行保持");
      pixel(0,1,24'hFFFFFF,24'hA51021,"块0下一行复用缓存");
      pixel(16,1,24'hEEEEEE,24'hB53042,"块1下一行复用缓存");

      // 连续视频流边界回归：每拍换一个像素，不再像 pixel 任务那样
      // 把同一输入保持两拍。覆盖 BRAM 同步读延迟和 x=15/16 块边界。
      for(i=0;i<=32;i=i+1) begin
        @(negedge clk);
        x=i[11:0]; y=12'd2; din={8'h10+i[7:0],8'h40+i[7:0],8'h80+i[7:0]}; de=1'b1;
        @(posedge clk); #1;
        if(i>0) begin
          checks=checks+1;
          if((xo!==(i-1)) || (yo!==12'd2) || !deo ||
             (dout!==(((i-1)<16)?24'hA51021:24'hB53042))) begin
            fails=fails+1;
            $display("[FAIL] 连续流块边界 i=%0d out=%h xy=%0d,%0d",i,dout,xo,yo);
          end
        end
      end
      if(fails==0)$display("[PASS] 连续像素流在 16x16 块边界无错位");

      en=0;repeat(3)@(posedge clk);
      // 从块首像素进入块1，模拟真实扫描顺序并发起同步 BRAM 读。
      pixel(16,1,24'hCCCCCC,24'hB53042,"帧中关闭请求后块首仍保持本帧模式");
      pixel(17,1,24'hDADADA,24'hB53042,"帧中关闭仍保持本帧模式");
      pixel(0,0,24'h556677,24'h556677,"下一帧首像素原子关闭");
      pixel(1,0,24'h778899,24'h778899,"关闭后继续逐拍透传");

      $display("==== tb_welcome_mosaic checks=%0d fails=%0d ====",checks,fails);
      if(fails==0)$display("RESULT: PASS");else $display("RESULT: FAIL");
      $finish;
    end
endmodule
