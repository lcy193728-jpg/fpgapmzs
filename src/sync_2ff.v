//====================================================================
// 模块名 : sync_2ff.v
// 功能   : 单比特电平跨时钟域两级同步器 —— 小鹅通第五/六讲规范
//
// 用途: 把一个"慢变化的电平/标志"从源时钟域搬到目标时钟域。
//   典型场景: Sdr_init_done(SDRAM 初始化完成, ext_mem_clk 域) → 送
//   sd_card_clk 域作为"可以开始读写"的门控; scene_control 的应急标志
//   等。位宽 >1 的**连续数据**不要用它(应走异步 FIFO), 快速变化的
//   **脉冲**也不要直接用它(应改成"电平翻转 + 目标域边沿检测", 见
//   frame_read_write 的 write_finish_toggle)。
//
// 代价: 目标域看到该电平比源域晚 2 拍(2 个目标域时钟周期)。
// 注意: 同步器不加复位 —— 复位本身是异步信号, 复位期间源域可能无时钟,
//       让同步链自由跟随输入反而更安全(标准做法)。
//====================================================================
`timescale 1ns/1ps

module sync_2ff (
    input  wire clk,            // 目标时钟域时钟
    input  wire async_in,       // 源域电平(异步输入)
    output wire sync_out        // 目标域同步后的电平
);

    reg [1:0] sync_ff;

    always @(posedge clk) begin
        sync_ff <= {sync_ff[0], async_in};
    end

    assign sync_out = sync_ff[1];

endmodule
