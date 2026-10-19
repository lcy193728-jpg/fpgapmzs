`timescale 1ns/1ps
module tb_welcome_uart;
  localparam CPB=8;
  reg clk=0,vclk=0,rst_n=0,vrst_n=0,rx=1,frame_start=0;
  wire tx,update,pause_sys,pause_vid;
  wire [191:0] ids_sys,ids_vid;
  wire [5:0] len_sys,speed_sys,len_vid,speed_vid;
  wire [223:0] em_ids_sys,em_ids_vid;
  wire [5:0] em_len_sys,em_speed_sys,em_len_vid,em_speed_vid;
  wire em_update,em_pause_sys,em_override_sys,em_pause_vid,em_override_vid;
  integer errors=0,reply_count=0;
  reg [7:0] reply_bytes[0:31];
  wire [7:0] reply_data; wire reply_valid,reply_err;
  always #10 clk=~clk;
  always #19 vclk=~vclk;

  welcome_uart_controller #(.CLKS_PER_BIT(CPB)) dut(
    .clk(clk),.rst_n(rst_n),.uart_rx(rx),.uart_tx(tx),.cfg_update(update),
    .cfg_ids(ids_sys),.cfg_length(len_sys),.cfg_speed(speed_sys),.cfg_pause(pause_sys),
    .emergency_update(em_update),.emergency_ids(em_ids_sys),
    .emergency_length(em_len_sys),.emergency_speed(em_speed_sys),
    .emergency_pause(em_pause_sys),.emergency_override(em_override_sys));
  uart_rx_byte #(.CLKS_PER_BIT(CPB)) reply_rx(
    .clk(clk),.rst_n(rst_n),.rx(tx),.data(reply_data),.valid(reply_valid),.framing_error(reply_err));
  welcome_cfg_frame_commit cdc(
    .src_clk(clk),.src_rst_n(rst_n),.src_commit(update),.src_ids(ids_sys),
    .src_length(len_sys),.src_speed(speed_sys),.src_pause(pause_sys),
    .dst_clk(vclk),.dst_rst_n(vrst_n),.frame_start(frame_start),
    .dst_ids(ids_vid),.dst_length(len_vid),.dst_speed(speed_vid),.dst_pause(pause_vid));
  emergency_cfg_frame_commit em_cdc(
    .src_clk(clk),.src_rst_n(rst_n),.src_commit(em_update),.src_ids(em_ids_sys),
    .src_length(em_len_sys),.src_speed(em_speed_sys),.src_pause(em_pause_sys),
    .src_override(em_override_sys),.dst_clk(vclk),.dst_rst_n(vrst_n),
    .frame_start(frame_start),.dst_ids(em_ids_vid),.dst_length(em_len_vid),
    .dst_speed(em_speed_vid),.dst_pause(em_pause_vid),.dst_override(em_override_vid));

  always @(posedge clk) if(reply_valid) begin reply_bytes[reply_count]=reply_data;reply_count=reply_count+1;end

  task send_byte(input [7:0] b); integer n; begin
    rx=0;repeat(CPB)@(posedge clk);
    for(n=0;n<8;n=n+1) begin rx=b[n];repeat(CPB)@(posedge clk);end
    rx=1;repeat(CPB)@(posedge clk);
  end endtask
  task send_text2; begin
    send_byte(8'hA5);send_byte(8'h5A);send_byte(8'h01);send_byte(8'h02);
    send_byte(8'd17);send_byte(8'd16);send_byte(8'h01^8'h02^8'd16^8'd17);
  end endtask
  task send_one(input [7:0] cmd,input [7:0] val); begin
    send_byte(8'hA5);send_byte(8'h5A);send_byte(cmd);send_byte(8'h01);
    send_byte(val);send_byte(cmd^8'h01^val);
  end endtask
  task send_em_text2; begin
    send_byte(8'hA5);send_byte(8'h5A);send_byte(8'h11);send_byte(8'h02);
    send_byte(8'd17);send_byte(8'd16);send_byte(8'h11^8'h02^8'd16^8'd17);
  end endtask
  task pulse_frame; begin @(posedge vclk);frame_start=1;@(posedge vclk);frame_start=0;end endtask
  task check(input cond,input [255:0] msg); begin
    if(!cond)begin errors=errors+1;$display("[FAIL] %0s",msg);end else $display("[PASS] %0s",msg);
  end endtask

  initial begin
    repeat(5)@(posedge clk);rst_n=1;repeat(3)@(posedge vclk);vrst_n=1;
    check(len_sys==20 && speed_sys==1 && !pause_sys,"system defaults");
    check(len_vid==20 && speed_vid==1 && !pause_vid,"video defaults");
    check(!em_override_sys && !em_override_vid,"emergency type defaults");
    send_text2();repeat(8)@(posedge clk);
    check(len_sys==2 && ids_sys[5:0]==16 && ids_sys[11:6]==17,"text command decoded");
    check(len_vid==20,"CDC holds until frame boundary");
    repeat(5)@(posedge vclk);pulse_frame();repeat(2)@(posedge vclk);
    check(len_vid==2 && ids_vid[5:0]==16 && ids_vid[11:6]==17,"text committed at frame boundary");
    send_one(8'h02,8'd7);repeat(8)@(posedge clk);pulse_frame();repeat(2)@(posedge vclk);
    check(speed_sys==7 && speed_vid==7,"speed command");
    send_one(8'h03,8'd1);repeat(8)@(posedge clk);pulse_frame();repeat(2)@(posedge vclk);
    check(pause_sys && pause_vid,"pause command");
    send_byte(8'hA5);send_byte(8'h5A);send_byte(8'h04);send_byte(8'h00);send_byte(8'h04);
    repeat(8)@(posedge clk);pulse_frame();repeat(2)@(posedge vclk);
    check(len_vid==20 && speed_vid==1 && !pause_vid,"restore default command");
    send_em_text2();repeat(8)@(posedge clk);
    check(em_len_sys==2 && em_ids_sys[6:0]==16 && em_ids_sys[13:7]==17 && em_override_sys,
          "emergency text command decoded");
    check(!em_override_vid,"emergency CDC holds until frame boundary");
    repeat(5)@(posedge vclk);pulse_frame();repeat(2)@(posedge vclk);
    check(em_len_vid==2 && em_ids_vid[6:0]==16 && em_ids_vid[13:7]==17 && em_override_vid,
          "emergency text committed at frame boundary");
    send_one(8'h12,8'd9);repeat(8)@(posedge clk);pulse_frame();repeat(2)@(posedge vclk);
    check(em_speed_sys==9 && em_speed_vid==9,"emergency speed command");
    send_one(8'h13,8'd1);repeat(8)@(posedge clk);pulse_frame();repeat(2)@(posedge vclk);
    check(em_pause_sys && em_pause_vid,"emergency pause command");
    send_byte(8'hA5);send_byte(8'h5A);send_byte(8'h14);send_byte(8'h00);send_byte(8'h14);
    repeat(8)@(posedge clk);pulse_frame();repeat(2)@(posedge vclk);
    check(!em_override_vid && em_speed_vid==1 && !em_pause_vid,"restore emergency defaults");
    repeat(600)@(posedge clk);
    check(reply_count>=48,"eight complete ACK frames transmitted");
    check(!reply_err,"reply UART framing");
    if(errors==0)$display("=== welcome UART/CDC regression PASS ===");
    else $display("=== welcome UART/CDC regression FAIL errors=%0d ===",errors);
    $finish;
  end
endmodule
