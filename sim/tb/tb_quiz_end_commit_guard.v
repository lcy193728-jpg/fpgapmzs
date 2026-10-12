`timescale 1ns/1ps
module tb_quiz_end_commit_guard;
    reg mem_clk=0,sd_clk=0,rst_mem=1,rst_sd=1;
    reg write_finish=0,quiz_en=0,q_end=0,img_busy=0;
    wire ready;
    always #7 mem_clk=~mem_clk;
    always #5 sd_clk=~sd_clk;
    quiz_end_commit_guard dut(
        .mem_clk(mem_clk),.rst_mem(rst_mem),.write_finish(write_finish),
        .sd_clk(sd_clk),.rst_sd(rst_sd),.quiz_en(quiz_en),.q_end(q_end),
        .img_busy(img_busy),.ready(ready));
    initial begin
        repeat(4)@(posedge sd_clk);rst_mem=0;rst_sd=0;quiz_en=1;
        @(negedge sd_clk);q_end=1;
        @(negedge sd_clk);img_busy=1;
        // write_finish 同步结果在 busy 仍为高时到达，随后 busy 才下降。
        @(negedge mem_clk);write_finish=1;
        @(negedge mem_clk);write_finish=0;
        repeat(5)@(posedge sd_clk);
        if(ready!==0)begin
            $display("[FAIL] ready asserted before source busy ended");$finish;
        end
        @(negedge sd_clk);img_busy=0;
        repeat(3)@(posedge sd_clk);
        if(ready!==1)begin
            $display("[FAIL] commit was swallowed at busy falling edge");$finish;
        end
        @(negedge sd_clk);q_end=0;
        repeat(2)@(posedge sd_clk);
        if(ready!==0)begin
            $display("[FAIL] ready did not clear after leaving end page");$finish;
        end
        $display("[PASS] end-page commit survives busy/finish race");
        $finish;
    end
endmodule
