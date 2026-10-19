`timescale 1ns/1ps

// 证明 6 位寿命计数器与“最近 50 根柱是否含非零值”的规格严格一致。
module tb_audio_viz_live_age;
    reg [5:0] age=0;
    reg [49:0] ref_window=0;
    integer i,checks=0,fails=0;

    task push;
      input nz;
      begin
        ref_window={ref_window[48:0],nz};
        if(nz) age=6'd50;
        else if(age!=0) age=age-1'b1;
        checks=checks+1;
        if((age!=0)!=(ref_window!=0))begin
          fails=fails+1;
          $display("[FAIL] step=%0d nz=%b age=%0d ref=%h",i,nz,age,ref_window);
        end
      end
    endtask

    initial begin
      // 边界：一根有声柱恰好保持 50 次写入窗口。
      i=0; push(1'b1);
      for(i=1;i<=55;i=i+1) push(1'b0);
      // 混合模式：在寿命未结束前反复装载，覆盖连续声音与间歇声音。
      for(i=56;i<500;i=i+1) push(((i%7)==0)||((i%31)==3));
      $display("==== tb_audio_viz_live_age checks=%0d fails=%0d ====",checks,fails);
      if(fails==0)$display("RESULT: PASS");else $display("RESULT: FAIL");
      $finish;
    end
endmodule
