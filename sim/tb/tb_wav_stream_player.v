`timescale 1ns/1ps
//====================================================================
// tb_wav_stream_player.v —— wav_stream_player 单元测试
//
// 被测: TF 卡字节流 → 16bit 小端样本 → 4KB 环形缓冲 → 48kHz 消费节拍。
//
// 手法: 双时钟激励(wr_clk 100MHz = sd_card_clk, rd_clk 25MHz = video_clk),
//   · 写侧: 手写"扇区发生器", 每扇区 256 样本, 样本值 = (base<<8)|k
//           (base = 8'hA0+扇区号, k = 扇区内序号) —— 先发低字节再发高字节,
//           因此能否还原出该值本身就验证了**小端字节序**。
//   · 读侧: 手打 sample_tick 脉冲, 在 tick 拍读 sample_out, 与期望逐样本比对。
//
// 覆盖(b1~b9):
//   b1 复位/未选中静默: sd_req=0, sample_valid=0, primed=0
//   b2 total_sectors=0 不发请求(边界)
//   b3 起播: WS_RUN + sd_lba=start_lba; 单扇区写完指针/缓冲内容/小端正确
//   b4 水位流控: 不消费持续写 → 进 WS_PAUSE 撤请求(让出总线给图片)
//   b5 读侧预充 + 前 601 样本逐样本比对(counter/指针同步)
//   b6 水位回落 → 自动回 WS_RUN 重新请求(不死锁)
//   b7 抽干 → 下溢: 静音、指针冻结、sample_valid 仍 1(下游不打嗝)
//   b8 播完 total_sectors → WS_END 停止请求
//   b9 取消选中 → 指针/计数/primed 清零; 重新选中从头播
//   b10 loop_en=1 → 播完自动回绕到 start_lba 续播(迎新背景音乐无缝循环)
//   [关键回归] 水位必须用 ADDR_WIDTH 位**回绕算术**: 写指针绕圈(wr_ptr<rd_ptr)
//              后流控仍须能从"继续写"判定成立, 否则永久卡在 WS_PAUSE —— b8 覆盖。
//
// 注意: 读侧只要缓冲 >= PREFILL(1024) 就会自动预充并消费第 1 个样本,
//   因此"写满到 HIGH_WATER(1536)"的实际扇区数是 7(=1792 样本)而非 6 —— 本 TB
//   用探测式循环(写到 PAUSE 为止)取得 written, 后续所有期望值都由 written 推导,
//   不写死扇区数, 换 DEPTH 后只需保证 total_sectors(=12) <= DEPTH/256 即可。
//====================================================================
module tb_wav_stream_player;
	// ---- 双时钟: 写域 100MHz / 读域 25MHz ----
	reg wr_clk = 0, rd_clk = 0;
	always #5  wr_clk = ~wr_clk;
	always #20 rd_clk = ~rd_clk;

	// ---- 被测端口 ----
	reg         wr_rst_n, rd_rst_n;
	reg         play_enable;
	reg         loop_en;
	reg  [31:0] start_lba, total_sectors;
	wire        sd_req;
	wire [31:0] sd_lba;
	reg         sd_valid;
	reg  [7:0]  sd_byte;
	reg         sd_done;
	reg         sample_tick, sample_ready;
	wire signed [15:0] sample_out;
	wire        sample_valid, primed;
	wire [31:0] sample_counter;

	integer checks = 0, fails = 0;
	task chk;
		input cond;
		input [511:0] msg;
		begin
			checks = checks + 1;
			if(!cond) begin
				fails = fails + 1;
				$display("[FAIL #%0d] %0s", checks, msg);
			end
		end
	endtask

	wav_stream_player #(.ADDR_WIDTH(11), .SAMPLES_PER_SECTOR(256), .PREFILL(1024)) dut(
		.wr_clk(wr_clk), .wr_rst_n(wr_rst_n),
		.play_enable(play_enable), .loop_en(loop_en),
		.start_lba(start_lba), .total_sectors(total_sectors),
		.sd_req(sd_req), .sd_lba(sd_lba),
		.sd_valid(sd_valid), .sd_byte(sd_byte), .sd_done(sd_done),
		.rd_clk(rd_clk), .rd_rst_n(rd_rst_n),
		.sample_tick(sample_tick), .sample_ready(sample_ready),
		.sample_out(sample_out), .sample_valid(sample_valid),
		.primed(primed), .sample_counter(sample_counter)
	);

	//====================================================================
	// 写侧激励: 一个扇区 = 256 样本, 每样本 2 字节(低→高)
	//====================================================================
	task feed_sector;
		input [7:0] base;
		integer k;
		begin
			for(k = 0; k < 256; k = k + 1) begin
				@(negedge wr_clk); sd_valid = 1'b1; sd_byte = k[7:0];   // 低字节
				@(negedge wr_clk);                  sd_byte = base;      // 高字节
				@(negedge wr_clk); sd_valid = 1'b0;
			end
			@(negedge wr_clk); sd_done = 1'b1;
			@(negedge wr_clk); sd_done = 1'b0;
		end
	endtask

	// 期望样本值: 第 idx 个样本 = (base<<8) | (idx & 0xFF), base = A0 + 扇区号
	function [15:0] exp_of;
		input integer idx;
		begin exp_of = ({8'hA0 + idx[15:8]} << 8) | {8'h00, idx[7:0]}; end
	endfunction

	//====================================================================
	// 读侧激励
	//====================================================================
	integer exp_idx, mism_n, prim_err;
	integer uf_val_err, uf_ptr_err;
	reg [31:0] rd_ptr_before;
	reg [15:0] expect_val;

	// 消费 n 个样本并逐个与 exp_of 比对(在 tick 拍取 sample_out)
	task consume_checked;
		input integer n;
		integer j;
		begin
			for(j = 0; j < n; j = j + 1) begin
				@(negedge rd_clk);
				sample_tick = 1'b1; sample_ready = 1'b1;
				// 本拍呈现的 sample_out 即本 tick 被消费的样本(posedge 才装载下一个)
				expect_val = exp_of(exp_idx);
				if(primed !== 1'b1) prim_err = prim_err + 1;
				if(sample_out !== $signed(expect_val)) begin
					mism_n = mism_n + 1;
					if(mism_n <= 5)
						$display("[MISMATCH] idx=%0d got=%h exp=%h", exp_idx, sample_out, expect_val);
				end
				exp_idx = exp_idx + 1;
				@(negedge rd_clk); sample_tick = 1'b0;
			end
		end
	endtask

	// 下溢消费 n 个样本: 必须恒静音且读指针冻结
	task consume_underflow;
		input integer n;
		integer j;
		begin
			for(j = 0; j < n; j = j + 1) begin
				@(negedge rd_clk);
				sample_tick = 1'b1; sample_ready = 1'b1;
				rd_ptr_before = dut.rd_ptr;
				if(sample_out !== 16'sd0) uf_val_err = uf_val_err + 1;
				@(negedge rd_clk);
				sample_tick = 1'b0;
				if(dut.rd_ptr !== rd_ptr_before) uf_ptr_err = uf_ptr_err + 1;
			end
		end
	endtask

	//====================================================================
	// 主流程
	//====================================================================
	integer i, written, remaining, total_written;
	reg     wrap_seen;
	initial begin
		wr_rst_n = 0; rd_rst_n = 0;
		play_enable = 0; loop_en = 0; start_lba = 32'h0030_0000; total_sectors = 32'd0;
		sd_valid = 0; sd_byte = 8'd0; sd_done = 0;
		sample_tick = 0; sample_ready = 0;
		exp_idx = 0; mism_n = 0; prim_err = 0; uf_val_err = 0; uf_ptr_err = 0;
		written = 0; wrap_seen = 1'b0;

		repeat(10) @(posedge wr_clk);
		wr_rst_n = 1; rd_rst_n = 1;
		repeat(4)  @(posedge wr_clk);

		//------------------------------------------------------------
		// b1 复位后 / 未选中: 必须完全静默
		//------------------------------------------------------------
		chk(sd_req == 1'b0,      "b1.1 复位后 sd_req=0");
		chk(sample_valid == 1'b0,"b1.2 未选中时 sample_valid=0");
		chk(primed == 1'b0,      "b1.3 未选中时 primed=0");
		chk(dut.wstate == 2'd0,  "b1.4 复位后写状态机在 WS_IDLE");

		//------------------------------------------------------------
		// b2 total_sectors=0 时即使选中也不发请求(边界保护)
		//------------------------------------------------------------
		play_enable = 1'b1;                  // total_sectors 仍为 0
		repeat(20) @(posedge wr_clk);
		chk(sd_req == 1'b0,      "b2.1 total_sectors=0 时不发扇区请求");
		chk(dut.wstate == 2'd0,  "b2.2 total_sectors=0 时停在 WS_IDLE");
		chk(sample_valid == 1'b1,"b2.3 选中(WAV源)期间 sample_valid 恒为 1");

		//------------------------------------------------------------
		// b3 起播 + 单扇区写入正确性
		//------------------------------------------------------------
		// 共 12 个扇区(1536 样本 < DEPTH=2048)。取 12 而不是 20 是为了让
		//   b8 收尾阶段"读侧不消费"地再写 5 个扇区时缓冲不会真的灌满 ——
		//   灌满后进 WS_PAUSE 是流控的正常行为, 但会让 b8 的"绕圈后仍持续
		//   请求"断言失去意义(那是容量问题, 不是流控 bug)。
		total_sectors = 32'd12;
		repeat(8) @(posedge wr_clk);
		chk(sd_req == 1'b1,                  "b3.1 起播发出扇区请求");
		chk(dut.wstate == 2'd1,              "b3.2 写状态机进入 WS_RUN");
		chk(sd_lba == 32'h0030_0000,         "b3.3 sd_lba = start_lba");

		feed_sector(8'hA0);                  // 扇区 0
		repeat(8) @(posedge wr_clk);
		chk(dut.sectors_read == 32'd1,       "b3.4 已完成 1 个扇区");
		chk(dut.cur_lba == 32'h0030_0001,    "b3.5 下一扇区地址 = start_lba+1");
		chk(dut.wr_ptr == 12'd256,           "b3.6 写指针推进 256 个样本");
		chk(primed == 1'b0,                  "b3.7 未达 PREFILL 时不预充");
		chk(dut.rd_ptr == 12'd0,             "b3.8 未达 PREFILL 时读指针不动");
		chk(dut.buffer[0]   == 16'hA000,     "b3.9 buffer[0] 小端拼接正确");
		chk(dut.buffer[1]   == 16'hA001,     "b3.10 buffer[1] 小端拼接正确");
		chk(dut.buffer[255] == 16'hA0FF,     "b3.11 扇区末样本正确");

		//------------------------------------------------------------
		// b4 持续写(不消费)直到水位到顶 → WS_PAUSE 并撤请求
		//   探测式: 写一个扇区判一次, 兜底 40 个扇区
		//------------------------------------------------------------
		i = 1;
		while(dut.wstate != 2'd2 && i < 40) begin
			feed_sector(8'hA0 + i[7:0]);
			i = i + 1;
			repeat(4) @(posedge wr_clk);
		end
		written      = i;
		total_written = i * 256;
		chk(dut.wstate == 2'd2,              "b4.1 水位到顶后进入 WS_PAUSE");
		chk(sd_req == 1'b0,                  "b4.2 WS_PAUSE 期间撤销请求(让出总线)");
		chk(written >= 5 && written < 40,    "b4.3 在合理扇区数内触发暂停");
		chk(dut.wr_ptr == total_written[10:0],"b4.4 写指针 = 已写扇区数 x 256");
		chk(dut.level_wr >= 11'd1536,        "b4.5 水位 >= HIGH_WATER(1536)");
		chk(primed == 1'b1,                  "b4.6 水位过 PREFILL 后已预充");
		chk(dut.rd_ptr == 11'd1,             "b4.7 预充已消费第 1 个样本(读指针=1)");
		chk(dut.buffer[256]  == 16'hA100,    "b4.8 扇区1 首样本正确");
		// 容量无关写法: 用探测得到的 written 推导"次末扇区首样本 / 末扇区末样本",
		//   改 DEPTH 后不必再手改扇区号(原 2816/3071 在 DEPTH=2048 时已越界)。
		chk(dut.buffer[(written-2)*256] == exp_of((written-2)*256), "b4.9 次末扇区首样本正确");
		chk(dut.buffer[written*256-1]   == exp_of(written*256-1),   "b4.10 末扇区末样本正确");

		//------------------------------------------------------------
		// b5 预充态 + 前 601 个样本逐样本比对
		//------------------------------------------------------------
		wait(primed == 1'b1);
		@(negedge rd_clk);
		chk(sample_counter == 32'd1,         "b5.1 预充已预取第 1 个样本");
		chk(dut.rd_ptr == 12'd1,             "b5.2 预充后读指针 = 1");

		consume_checked(600);
		chk(mism_n == 0,                     "b5.3 前 601 样本无失真(小端/顺序)");
		chk(prim_err == 0,                   "b5.4 消费过程 primed 恒为 1");
		chk(dut.rd_ptr == 12'd601,           "b5.5 读指针推进到 601");
		chk(sample_counter == 32'd601,       "b5.6 sample_counter 与读指针一致");

		//------------------------------------------------------------
		// b6 水位回落 → 自动回 WS_RUN(未绕圈)
		//------------------------------------------------------------
		repeat(20) @(posedge wr_clk);
		chk(dut.level_wr < 11'd1536,         "b6.1 消费后水位低于 HIGH_WATER");
		chk(dut.wstate == 2'd1,              "b6.2 水位回落后回 WS_RUN");
		chk(sd_req == 1'b1,                  "b6.3 重新发出扇区请求(未死锁)");

		//------------------------------------------------------------
		// b7 抽干全部真实样本 → 下溢
		//   交付语义: 预充把 buffer[0] 载入 sample_out(不算 tick),
		//   之后每个 tick 交付"上一拍载入"的样本 → 交付 total_written 个
		//   样本恰好需要 total_written 个 tick。第 total_written 个 tick 时
		//   模块内部 level_rd 已为 0(不再装载), 但本拍呈现的仍是最后一个
		//   真实样本(必须交给下游), 所以抽干 tick 数 = total_written - 600。
		//------------------------------------------------------------
		remaining = total_written - 600;
		consume_checked(remaining);
		chk(mism_n == 0,                     "b7.1 全部真实样本无失真");
		chk(exp_idx == total_written,        "b7.2 共交付 total_written 个真实样本");
		chk(dut.rd_ptr == total_written[10:0],"b7.3 读指针停在已写样本数(未越界)");
		chk(sample_counter == total_written, "b7.4 sample_counter = 已写样本数");
		chk(dut.level_rd == 12'd0,           "b7.5 缓冲已空(level_rd=0)");

		consume_underflow(50);
		chk(uf_val_err == 0,                 "b7.6 下溢期间输出恒为静音");
		chk(uf_ptr_err == 0,                 "b7.7 下溢期间读指针冻结");
		chk(sample_valid == 1'b1,            "b7.8 下溢时 sample_valid 仍为 1");

		//------------------------------------------------------------
		// b8 指针绕圈后的流控(关键回归) + 播完进 WS_END
		//------------------------------------------------------------
		repeat(20) @(posedge wr_clk);
		chk(sd_req == 1'b1 && dut.wstate == 2'd1, "b8.1 抽干后恢复请求(WS_RUN)");

		// 收尾: 再写 12-written(=5) 个扇区即播完。前 4 个(7..10)必须保持
		//   WS_RUN —— 写指针在第 1 个扇区时就绕圈(wr_ptr 1792+256→0 < rd_ptr
		//   1792), 关键回归正是"绕圈后 level 回绕算术仍允许继续写", 不死锁。
		for(i = written; i < 11; i = i + 1) begin
			feed_sector(8'hA0 + i[7:0]);
			repeat(10) @(posedge wr_clk);
			if(dut.wr_ptr < dut.rd_ptr) wrap_seen = 1'b1;   // 写指针已绕圈
			chk(dut.wstate == 2'd1 && sd_req == 1'b1, "b8.2 绕圈后仍 WS_RUN/持续请求");
		end
		chk(wrap_seen == 1'b1,               "b8.3 用例确已覆盖写指针绕圈场景");

		feed_sector(8'hA0 + 8'd11);          // 第 12 个扇区 → 播完
		repeat(8) @(posedge wr_clk);
		chk(dut.sectors_read == 32'd12,      "b8.4 已读完全部 12 个扇区");
		chk(dut.wstate == 2'd3,              "b8.5 播完进入 WS_END");
		chk(sd_req == 1'b0,                  "b8.6 WS_END 停止扇区请求");
		chk(dut.cur_lba == 32'h0030_000C,    "b8.7 结束地址 = start_lba+12");

		//------------------------------------------------------------
		// b9 取消选中 → 全清零; 再选中从头播
		//------------------------------------------------------------
		play_enable = 1'b0;
		repeat(20) @(posedge wr_clk);
		repeat(10) @(posedge rd_clk);
		chk(dut.wstate == 2'd0,              "b9.1 取消选中后写状态机回 WS_IDLE");
		chk(sd_req == 1'b0,                  "b9.2 取消选中后无请求");
		chk(primed == 1'b0,                  "b9.3 取消选中后 primed 清零");
		chk(dut.rd_ptr == 12'd0,             "b9.4 取消选中后读指针清零");
		chk(sample_counter == 32'd0,         "b9.5 取消选中后 sample_counter 清零");
		chk(sample_out == 16'sd0,            "b9.6 取消选中后输出静音");
		chk(sample_valid == 1'b0,            "b9.7 取消选中后 sample_valid=0");

		play_enable = 1'b1;                  // 重新选中(换场景再进来)
		repeat(20) @(posedge wr_clk);
		chk(dut.wstate == 2'd1,              "b9.8 重新选中后从头起播(WS_RUN)");
		chk(sd_lba == 32'h0030_0000,         "b9.9 重新选中后地址回到 start_lba");
		chk(dut.sectors_read == 32'd0,       "b9.10 重新选中后扇区计数清零");
		chk(dut.wr_ptr == 12'd0,             "b9.11 重新选中后写指针清零");

		//------------------------------------------------------------
		// b10 loop_en=1: 播完自动回绕续播(迎新背景音乐无缝循环)
		//   总扇区数取 4(=1024 样本 < HIGH_WATER), 保证写侧不会进 PAUSE,
		//   回绕条件里"水位已降到 HIGH_WATER 以下"从一开始就成立 → 进
		//   WS_END 后下一拍即回绕, 无需读侧配合消费。
		//------------------------------------------------------------
		play_enable = 1'b0;
		repeat(20) @(posedge wr_clk);
		repeat(10) @(posedge rd_clk);
		loop_en       = 1'b1;
		total_sectors = 32'd4;
		play_enable   = 1'b1;
		repeat(8) @(posedge wr_clk);
		chk(dut.wstate == 2'd1 && sd_lba == 32'h0030_0000, "b10.1 loop: 重新选中从头起播");
		for(i = 0; i < 4; i = i + 1) begin
			feed_sector(8'hB0 + i[7:0]);
			repeat(4) @(posedge wr_clk);
		end
		// 注: 4 个扇区一读完就立刻回绕, sectors_read 已被清零 —— 不能在此处
		//     断 sectors_read==4, 改由 b10.3~b10.7(状态/地址/计数/写指针)证明。
		repeat(8) @(posedge wr_clk);          // WS_END 下一拍即回绕
		chk(dut.wstate == 2'd1,              "b10.2 loop: 自动回绕到 WS_RUN");
		chk(dut.cur_lba == 32'h0030_0000,    "b10.3 loop: 地址回到 start_lba");
		chk(dut.sectors_read == 32'd0,       "b10.4 loop: 扇区计数清零");
		chk(sd_req == 1'b1,                  "b10.5 loop: 重新发出首扇区请求");
		chk(dut.wr_ptr == 12'd1024,          "b10.6 loop: 写指针继续环形推进(不回卷)");

		$display("====================================================");
		$display("tb_wav_stream_player: checks=%0d fails=%0d (written=%0d)", checks, fails, written);
		if(fails == 0) $display("RESULT: PASS");
		else           $display("RESULT: FAIL");
		$display("====================================================");
		$finish;
	end

	// 看门狗: 断言死锁时 40 ms 强制结束
	initial begin
		#40_000_000;
		$display("[WATCHDOG] 仿真超时: checks=%0d fails=%0d", checks, fails);
		$display("RESULT: FAIL");
		$finish;
	end
endmodule
