//====================================================================
// 模块名 : reset_sync.v
// 功能   : 异步复位、同步释放(reset synchronizer) —— 小鹅通第六讲规范
//
// 为什么需要(未做会出现什么)：
//   1) 复位的"释放沿"若正好落在某触发器的建立/保持窗口内, 该触发器可能
//      进入亚稳态, 各触发器退出复位的时间不一致 → 状态机跑飞、上电偶发
//      异常(重上电又好了, 极难复现);
//   2) 多个时钟域共用同一个复位信号时, 释放沿在不同域被采到的时间不同,
//      会撕裂跨域握手(例如 toggle 同步链会误产生一个脉冲)。
//   规范做法: **每个时钟域各放一个本模块**, 复位"异步压下"(立刻生效,
//   不依赖时钟)、"同步释放"(两级触发器对齐到本域时钟沿)。
//
// 用法(顶层):
//   wire ext_rst_n = por_done & pll_all_locked;      // 低有效总复位
//   reset_sync u_rst_sd (.clk(sd_card_clk), .rst_n_async(ext_rst_n),
//                        .rst_n_sync(rst_n_sd));
//   各模块 .rst(~rst_n_sd)                            // 本域同步复位
//
// 代价: 复位释放比输入晚 2 个本域时钟周期(可忽略)。
// 注意: 相移时钟(如 SDRAM 采样用的 ext_mem_clk_sft)只做数据采样,
//       不承载逻辑, 不要给它挂同步器(第六讲明确)。
//====================================================================
`timescale 1ns/1ps

module reset_sync (
    input  wire clk,            // 本时钟域时钟
    input  wire rst_n_async,    // 异步复位输入(低有效)
    output wire rst_n_sync      // 本域同步释放后的复位(低有效)
);

    // 两级同步链:
    //   · rst_n_async=0 时被异步清零 → 复位立刻生效(与 clk 无关);
    //   · rst_n_async=1 时按本域时钟逐拍移入 1 → 释放沿对齐到 clk,
    //     两个触发器最多只有一个可能处于亚稳态, 第二级输出已稳定。
    reg [1:0] sync_ff;

    always @(posedge clk or negedge rst_n_async) begin
        if (!rst_n_async)
            sync_ff <= 2'b00;
        else
            sync_ff <= {sync_ff[0], 1'b1};
    end

    assign rst_n_sync = sync_ff[1];

endmodule
