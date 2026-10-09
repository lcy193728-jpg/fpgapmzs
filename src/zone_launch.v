`timescale 1ns/1ps
//====================================================================
// 模块名 : zone_launch.v —— FAT32 查表「停车 / 交棒 / 分区下发」时序(v11)
//
// 背景(为什么需要这个模块):
//   v11 把"硬编码扇区常量"换成了"上电与场景切换时读一次卡根目录"。而
//   查表(fat32_lookup)与 BMP 轮播(bmp_read_auto)共用 audio_sd_arbiter
//   的 **A 侧**, 而 A 侧只有一套数据/结束广播口(见 arbiter 头注释)——
//   两者**绝不能同时发请求**, 否则同一个扇区的 512 字节会被两个状态机
//   同时吞掉。改造前不存在这个问题: 顶层把常量 zone_load 脉冲直接给
//   bmp_read_auto, 切场景**全程不读卡**; 会议配置读卡只发生在开机、
//   且 bmp_go 全程钉 0。所以这套握手是 v11 必须新增的东西。
//
// 四步握手(缺一不可, 每步都有踩过的坑):
//   ① **请求当拍就把 bmp_go 钉 0**, 不能"下一拍再钉"。
//      bmp_read_auto 一旦看到 sd_init_done=1 就会去扫图, 并会持着
//      sd_sec_read 一整段; 晚一拍钉 0 就等于放它先抢走一个扇区。
//   ② **不能只看 bmp_read_auto 的 sd_sec_read 是否撤掉**。
//      它在 sd_init_done 掉下来后【一拍】就把请求撤了, 但 SD 控制器
//      (sd_card_sec_read_write) 可能还在读那一个扇区, 仲裁器 owner 仍是 A。
//      此时若查表请求已到, 仲裁器把地址切成查表地址(控制器已锁 sec_addr,
//      扇区本身读得对), 但 a_data_valid/a_end 是【广播】给双方 →
//      那半个扇区的字节会喂给 fat32_lookup, 破坏 MBR/BPB/目录解析。
//      ⇒ 必须等【仲裁器侧 sd_sec_read 归 0】(= 无任何主设备在用总线)。
//   ③ **启动脉冲必须有防重入**: 请求到达时若总线正忙, 先记住(pend),
//      等总线空了再发; 且查表进行中不再发(靠 ~lu_busy)。
//   ④ **放行必须与分区下发同拍**(见下面 zone_wait 那段注释):
//      bmp_zone_load 是寄存输出, 落在 lu_ready 上升沿的【下一拍】; 而
//      lu_busy 在 lu_ready 当拍就掉了。若 bmp_go 只看 ~lu_busy, 它会早一拍
//      放行, 引擎就拿【旧分区】从 S_IDLE 进 S_FIND 扫图(应用点在下一个
//      S_IDLE), 白扫一段卡、上电时先扫编译期默认地址 ⇒ 可能先出错图。
//      故 zone_wait 把 bmp_go 多钉一拍, 与 bmp_zone_load 同拍拉高。
//
// 与 bmp_read_auto 的契约(都已被其源码证实, 故 bmp_read_auto 一行未改):
//   · sd_init_done=0 → 强制 state<=S_IDLE 且 sd_sec_read<=0(见其主状态机),
//     所以"钉 0"是它原生支持的停车方式;
//   · zone_load 单拍脉冲 → 锁存 zone_start/wrap/max_img 到 req_*, 置
//     zone_pend; 新分区只在 sd_init_done=1 且 state==S_IDLE 时应用
//     ("应用点"是它自己的安全边界, 会等当前扇区读完)。
//   本模块把 zone_load 定在 tbl_ready 上升沿的下一拍(寄存器打拍),
//   与"查表结果已稳定"严格对齐; 早一拍会锁到旧值。
//
// 语言: 纯 Verilog-2001。
//====================================================================

module zone_launch(
    input  wire clk,
    input  wire rst,
    input  wire sd_init_done,     // SD 控制器原始初始化完成(sd_card_top)
    input  wire lu_req,           // 查表原始请求(上电首查 / 场景切换; 脉冲或电平)
    input  wire lu_busy,          // 查表中(fat32_lookup.busy)
    input  wire lu_ready,         // 段表已就绪(fat32_lookup.tbl_ready)
    input  wire bus_free,         // 仲裁器侧总线空闲(= audio_sd_arbiter.sd_sec_read 取反)
    output wire lu_start,         // 下发一次查表(单拍脉冲) → fat32_lookup.start_req
    output wire bmp_go,           // 0=把 BMP 通路停在 S_IDLE → bmp_read_auto.sd_init_done
    output reg  bmp_zone_load,    // 段表就绪 → 分区重载脉冲 → bmp_read_auto.zone_load
    output reg  first_tbl_done    // 第一次查表已收尾(供 WAV 放行, 保持改造前启动时序)
);

    reg pend;        // 有请求待下发(等总线空闲)
    reg ready_d;     // lu_ready 打拍(用于上升沿检测)

    //--------------------------------------------------------------
    // ③ 启动脉冲: 有请求 & 总线空闲 & 不在查表中
    //--------------------------------------------------------------
    assign lu_start = (lu_req | pend) & bus_free & ~lu_busy;

    //--------------------------------------------------------------
    // ★ 分区下发与放行必须【同拍】—— 这一个是本模块存在的第二个理由:
    //   bmp_zone_load 是【寄存输出】(lu_ready 上升沿的下一拍), 而 lu_busy
    //   在 lu_ready 当拍就已经掉了。若 bmp_go 只看 ~lu_busy, 它会在
    //   zone_load 之前【早一拍】拉高 —— 后果是引擎拿旧分区跑起来:
    //   见 bmp_read_auto.v S_IDLE 的注释:
    //     "同一拍 zone_load + S_IDLE 应用: 置位优先, 而应用读的是 req_* 旧值
    //      → 旧请求仍被应用, 新请求留待下次应用"
    //   早一拍 ⇒ 引擎用【旧 req_*】从 S_IDLE 进 S_FIND 开始扫图, 新分区要等
    //   它累一圈回到 S_IDLE 才生效 ⇒ 白扫一大段卡、上电时甚至先扫一遍编译期
    //   默认地址(可能先载入一张错图 → 可视花屏)。
    //   故用 zone_wait(= "zone_load 将在下一拍下发") 把 bmp_go 多钉一拍,
    //   让【bmp_go 与 bmp_zone_load 同拍拉高】—— 与改造前顶层直接给脉冲时
    //   的相对时序完全一致。
    //--------------------------------------------------------------
    wire zone_wait = lu_ready & ~ready_d;   // 本拍不允许放行(下一拍才发 zone_load)

    //--------------------------------------------------------------
    // ① BMP 通路放行门控
    //   · lu_req 当拍就钉 0(组合项, 不等打拍)
    //   · 待下发/查表中一律钉 0
    //   · zone_wait 当拍钉 0(见上: 保证与 zone_load 同拍)
    //   · sd_init_done=0 时也是 0(与改造前一致)
    //--------------------------------------------------------------
    assign bmp_go = sd_init_done & ~(lu_req | pend | lu_busy | zone_wait);

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            pend          <= 1'b0;
            ready_d       <= 1'b0;
            bmp_zone_load <= 1'b0;
            first_tbl_done<= 1'b0;
        end
        else begin
            if (lu_start)          pend    <= 1'b0;   // 已下发
            else if (lu_req)       pend    <= 1'b1;   // 待下发(② 总线忙时在此等待)

            ready_d       <= lu_ready;
            // 段表就绪上升沿的下一拍 → 单拍分区重载脉冲(此时查表结果已稳定)
            bmp_zone_load <= lu_ready & ~ready_d;
            if (lu_ready)          first_tbl_done <= 1'b1;
        end
    end

endmodule
