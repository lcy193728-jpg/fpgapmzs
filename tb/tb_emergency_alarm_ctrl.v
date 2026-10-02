`timescale 1ns/1ps
// 2026-10-01 改版: emergency_alarm_ctrl 已退化为纯计时器(告警类型选择移到
//   ui_key_ctrl 应急场景模式0), 本 TB 相应只验证计时行为:
//     1) 复位清零; 2) alarm_en=0 期间不计数;
//     3) 进场景后 1Hz BCD 秒计数(经过 00:59 不跳秒), 满 60s 正确进位到 01:00;
//     4) 离开场景清零, 再次进入从 00:00 起算(分钟被清)。
//   CLK_HZ=2 → 每 2 拍为 1 秒, 便于快速跑到 60s。
//   ※ 用"条件等待 + guard 上限"代替逐拍精确计数, 避免复位/使能沿的
//     仿真调度顺序带来 ±1 拍脆弱性。
module tb_emergency_alarm_ctrl;
  reg clk=0, rst=1, alarm_en=0;
  wire [3:0] mt,mo,st,so;
  integer guard;
  reg saw59;
  always #5 clk=~clk;

  emergency_alarm_ctrl #(.CLK_HZ(2)) dut(
    .clk(clk), .rst(rst), .alarm_en(alarm_en),
    .elapsed_m_tens(mt), .elapsed_m_ones(mo),
    .elapsed_s_tens(st), .elapsed_s_ones(so));

  initial begin
    repeat(3) @(posedge clk); rst=0;
    repeat(3) @(posedge clk);
    if(mt!==0||mo!==0||st!==0||so!==0) $fatal(1,"reset must clear timer");

    // alarm_en=0 期间应恒定 00:00
    repeat(30) @(posedge clk);
    if(st!==0||so!==0) $fatal(1,"timer must stay 00:00 while alarm_en=0");

    // 进场景: 逐拍观察 BCD 秒, 直到进位 01:00
    alarm_en=1;
    saw59=1'b0; guard=0;
    while(!(mo==4'd1 && st==4'd0 && so==4'd0) && guard<400) begin
      @(posedge clk);
      guard = guard + 1;
      if(st==4'd5 && so==4'd9) saw59=1'b1;   // 记录确实出现过 00:59(不跳秒)
    end
    if(!(mo==4'd1 && st==4'd0 && so==4'd0))
      $fatal(1,"never rolled to 01:00 (guard=%0d, now %0d%0d:%0d%0d)",guard,mt,mo,st,so);
    if(!saw59) $fatal(1,"BCD seconds never passed 00:59");

    // 离开场景 -> 停止计数并保留最后显示值(此处为刚进位的 01:00)
    alarm_en=0; repeat(12) @(posedge clk);
    if(mt!==0||mo!==1||st!==0||so!==0)
      $fatal(1,"timer must freeze at 01:00 while alarm_en=0 (got %0d%0d:%0d%0d)",mt,mo,st,so);

    // 再次进入 -> 从 00:0x 重新起算(分钟已清, 不会残留 01:xx)
    alarm_en=1; repeat(3) @(posedge clk);
    if(mo!==0||st!==0||so>4'd1)
      $fatal(1,"re-entry must restart from 00:00 (got %0d%0d:%0d%0d)",mt,mo,st,so);

    $display("PASS: emergency timer 1Hz BCD, rolls at 60s, clears on entry/exit");
    $finish;
  end
endmodule
