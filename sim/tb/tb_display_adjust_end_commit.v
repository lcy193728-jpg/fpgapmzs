`timescale 1ns/1ps

// 抢答结束 OSD 不依赖结束图片，但必须在帧边界整页提交，并共用 iris。
module tb_display_adjust_end_commit;
    reg clk=0,rst=1,vs_i=0,quiz_on=0,q_end=0,q_end_ready=0,bmp_busy=0,iris_trig=0;
    always #5 clk=~clk;
    wire hs_o,vs_o,de_o; wire [23:0] data_o;

    display_adjust #(
        .H_ACT(640),.V_ACT(480),.BAR_HOLD_FRAMES(0),.RES_HOLD_FRAMES(0),
        .MAN_HOLD_FRAMES(0),.VOL_HOLD_FRAMES(0),.RESW_HOLD_FRAMES(0),
        .SCB_HOLD_FRAMES(0),.IRIS_FRAMES(8),.WIPE_FRAMES(0)
    ) dut(
        .video_clk(clk),.rst(rst),.hs_i(1'b0),.vs_i(vs_i),.de_i(1'b1),
        .data_i(24'h123456),.px_x(12'd226),.px_y(12'd252),
        .menu_active(1'b0),.emerg(1'b0),.bmp_busy(bmp_busy),
        .iris_trig(iris_trig),.wipe_trig(1'b0),.bri_level(4'd8),.vol_level(4'd8),
        .res_level(4'd4),.con_level(4'd8),.img_res(2'd1),.pic_manual(1'b0),.res_info_always(1'b0),
        .ui_mode(3'd0),.quiz_on(quiz_on),.meeting_on(1'b0),.q_state(2'd0),
        .q_end(q_end),.q_end_ready(q_end_ready),
        .sc0(8'sd2),.sc1(8'sd1),.sc2(8'sd0),.sc3(-8'sd1),
        .sc_evt(1'b0),.sc_team(2'd0),.hs_o(hs_o),.vs_o(vs_o),.de_o(de_o),.data_o(data_o));

    task frame_start;
      begin
        @(negedge clk);vs_i=1;
        @(negedge clk);vs_i=0;
        repeat(2)@(posedge clk);
      end
    endtask

    initial begin
        repeat(4)@(posedge clk);rst=0;quiz_on=1;
        repeat(5)@(posedge clk);
        q_end=1;bmp_busy=1;iris_trig=1;
        repeat(5)@(posedge clk);
        if(dut.qend_visible!==0)begin
            $display("[FAIL] end OSD appeared in the middle of a frame");$finish;
        end
        frame_start; // 启动结束页中心扩散，图片仍 busy/ready=0
        if(dut.qend_visible!==1)begin
            $display("[FAIL] end OSD still depends on end-image commit");$finish;
        end
        // 测试点 (226,252) 距屏幕中心约 95px；此时扩散半径仅 56px，
        // 分数槽必须仍被同一 iris 遮罩挡住，不能全亮抢在背景前面。
        if(dut.iris_run!==1 || dut.iris_inside!==0 || dut.end_osd!==0)begin
            $display("[FAIL] end OSD bypassed the iris mask");$finish;
        end
        repeat(8) frame_start; // 最迟在扩散完成后，整屏 OSD 必须可见
        if(dut.end_osd!==1)begin
            $display("[FAIL] end OSD did not follow the revealed pixel");$finish;
        end
        $display("[PASS] end OSD is frame-committed, image-independent and iris-gated");
        $finish;
    end
endmodule
