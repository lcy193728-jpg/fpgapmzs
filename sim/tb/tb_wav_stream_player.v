`timescale 1ns/1ps
//====================================================================
// tb_wav_stream_player.v —— wav_stream_player 单元测试(FAT32 file 接口版)
//
// 被测: TF 文件字节流(file 接口) → 16bit 小端样本 → 4KB 环形缓冲 → 48kHz 消费节拍。
//
// 手法: 双时钟激励(wr_clk 100MHz = sd_card_clk, rd_clk 25MHz = video_clk),
//   · 写侧: 手写"文件流发生器", 检测到 file_start 后按 file_size 吐字节,
//           每样本 2 字节(低→高)。样本值 = (base<<8)|k (base = 8'hA0, k = 序号)
//           —— 先发低字节再发高字节, 能否还原出该值即验证**小端字节序**。
//   · 读侧: 手打 sample_tick 脉冲, 在 tick 拍读 sample_out, 与期望逐样本比对。
//
// FAT32 化后相对旧版(扇区接口)的关键差异:
//   1. 写状态机不再有 WS_PAUSE(2'd2)。水位流控改为 allow_req 电平输出:
//      allow_req = (level_wr < HIGH_WATER)。发生器在 allow_req=0 时**暂停吐字节**,
//      模拟真实链路里 adapter 收到 allow_req=0 → sector_busy 拉高 → streamer 停
//      在 ST_DATA_REQ 等待(字节流暂停, 不丢字节)。
//   2. 写侧不再自己发扇区请求, 而是发 file_start(单拍脉冲) 启动一次文件流读取,
//      file_done 表示整个文件读完(替代旧版的 sectors_read==total_sectors)。
//   3. 循环回绕(loop_en): file_done 后水位腾出空间则重新 file_start 续播。
//
// 覆盖(b1~b9):
//   b1 复位/未选中静默: file_start=0, sample_valid=0, primed=0
//   b2 file_size=0 不发 file_start(边界)
//   b3 起播: WS_RUN + file_cluster=start_cluster; 单扇区写完指针/缓冲/小端正确
//   b4 水位流控: 不消费持续写 → allow_req 拉低(字节流暂停, 让出总线给图片)
//   b5 读侧预充 + 前 601 样本逐样本比对(counter/指针同步)
//   b6 水位回落 → allow_req 恢复(字节流继续, 不死锁)
//   b7 抽干 → 下溢: 静音、指针冻结、sample_valid 仍 1(下游不打嗝)
//   b8 播完 file_size → WS_END 停止; 取消选中全清零; 重新选中从头播
//   b9 loop_en=1 → 播完自动回绕重新 file_start 续播(迎新背景音乐无缝循环)
//
// 注意: 读侧只要缓冲 >= PREFILL(1024) 就会自动预充并消费第 1 个样本。
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
	reg  [31:0] start_cluster, file_size;
	wire        file_start;
	wire [31:0] file_cluster;
	wire [31:0] file_len_out;
	reg         file_valid;
	reg  [7:0]  file_byte;
	reg         file_done;
	reg  [7:0]  file_error;
	wire        allow_req;
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
		.start_cluster(start_cluster), .file_size(file_size),
		.file_start(file_start), .file_cluster(file_cluster), .file_len_out(file_len_out),
		.file_valid(file_valid), .file_byte(file_byte),
		.file_done(file_done), .file_error(file_error),
		.allow_req(allow_req),
		.rd_clk(rd_clk), .rd_rst_n(rd_rst_n),
		.sample_tick(sample_tick), .sample_ready(sample_ready),
		.sample_out(sample_out), .sample_valid(sample_valid),
		.primed(primed), .sample_counter(sample_counter)
	);

	//====================================================================
	// 文件流发生器: 检测到 file_start 后, 按 file_size 吐字节(每样本 2 字节,
	//   低→高)。allow_req=0 时暂停(模拟 adapter 流控暂停 streamer)。
	//   字节数 = file_size。样本数 = file_size / 2。样本值 = (base<<8)|k。
	//   本发生器只在"未被 allow_req 暂停"时推进, 并在吐满 file_size 字节后
	//   发一个 file_done 单拍。
	//====================================================================
	reg [7:0]  fgen_base;      // 当前这趟文件流的样本高字节基址
	integer    fgen_cnt;       // 全局字节序号(跨 feed_bytes 调用连续, 0 起)

	// 文件流发生器(同步阻塞式): 吐 nbytes 个字节(每样本 2 字节, 低→高)。
	//   allow_req=0 时原地等待(模拟 adapter 流控暂停 streamer)。
	//   样本值 = (base<<8)|(样本序号&0xFF)。样本序号 = fgen_cnt>>1, 且 fgen_cnt
	//   是**全局**字节序号(跨多次 feed_bytes 调用连续), 保证分批吐时样本序号
	//   不回卷。时序: 每字节占一个完整周期 —— negedge 置 file_valid=1+字节,
	//   下一 negedge 置 file_valid=0, 保证 file_valid=1 恰好被一个 posedge 采样。
	task feed_bytes;
		input [7:0]  base;
		input [31:0] nbytes;
		integer k;
		begin
			fgen_base  = base;
			for(k = 0; k < nbytes; k = k + 1) begin
				wait(allow_req == 1'b1);   // 水位满则暂停(让出总线给图片)
				@(negedge wr_clk);
				if(fgen_cnt[0] == 0)
					file_byte = (fgen_cnt >> 1) & 8'hFF;   // 低字节 = 样本内序号
				else
					file_byte = fgen_base;                 // 高字节 = base
				file_valid = 1'b1;
				@(negedge wr_clk);
				file_valid = 1'b0;
				fgen_cnt = fgen_cnt + 1;
			end
		end
	endtask

	// 发 file_done 单拍(文件流读完)
	task send_file_done;
		begin
			@(negedge wr_clk);
			file_done = 1'b1;
			@(negedge wr_clk);
			file_done = 1'b0;
		end
	endtask

	// 期望样本值: 第 idx 个样本 = (base<<8) | (idx & 0xFF), base = A0
	function [15:0] exp_of;
		input integer idx;
		begin exp_of = ({8'hA0} << 8) | {8'h00, idx[7:0]}; end
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
	integer i, total_written;
	initial begin
		wr_rst_n = 0; rd_rst_n = 0;
		play_enable = 0; loop_en = 0;
		start_cluster = 32'd100; file_size = 32'd0;
		file_valid = 0; file_byte = 8'd0; file_done = 0; file_error = 0;
		sample_tick = 0; sample_ready = 0;
		exp_idx = 0; mism_n = 0; prim_err = 0; uf_val_err = 0; uf_ptr_err = 0;
		fgen_cnt = 0;

		repeat(10) @(posedge wr_clk);
		wr_rst_n = 1; rd_rst_n = 1;
		repeat(4)  @(posedge wr_clk);

		//------------------------------------------------------------
		// b1 复位后 / 未选中: 必须完全静默
		//------------------------------------------------------------
		chk(file_start == 1'b0,     "b1.1 复位后 file_start=0");
		chk(sample_valid == 1'b0,   "b1.2 未选中时 sample_valid=0");
		chk(primed == 1'b0,         "b1.3 未选中时 primed=0");
		chk(dut.wstate == 2'd0,     "b1.4 复位后写状态机在 WS_IDLE");

		//------------------------------------------------------------
		// b2 file_size=0 时即使选中也不发 file_start(边界保护)
		//------------------------------------------------------------
		play_enable = 1'b1;                  // file_size 仍为 0
		repeat(20) @(posedge wr_clk);
		chk(file_start == 1'b0,     "b2.1 file_size=0 时不发 file_start");
		chk(dut.wstate == 2'd0,     "b2.2 file_size=0 时停在 WS_IDLE");
		chk(sample_valid == 1'b1,   "b2.3 选中(WAV源)期间 sample_valid 恒为 1");

		//------------------------------------------------------------
		// b3 起播 + 单扇区写入正确性
		//   文件大小 = 3072 样本 = 6144 字节(> DEPTH 2048, 覆盖绕圈与流控)。
		//------------------------------------------------------------
		file_size = 32'd6144;                // 3072 样本
		// file_start 是单拍脉冲, 设置 file_size 后下一拍即发出 → 用 wait 捕获
		wait(file_start == 1'b1);
		chk(file_start == 1'b1,     "b3.1 起播发出 file_start");
		chk(dut.wstate == 2'd1,     "b3.2 写状态机进入 WS_RUN");
		chk(file_cluster == 32'd100,"b3.3 file_cluster = start_cluster");
		chk(file_len_out == 32'd6144,"b3.4 file_len_out = file_size");

		// 同步吐 512 字节(=256 样本), 主流程精确控制写节奏
		feed_bytes(8'hA0, 32'd512);
		repeat(4) @(posedge wr_clk);
		chk(dut.wr_ptr == 12'd256,  "b3.5 写指针推进 256 个样本");
		chk(primed == 1'b0,         "b3.6 未达 PREFILL 时不预充");
		chk(dut.rd_ptr == 12'd0,    "b3.7 未达 PREFILL 时读指针不动");
		chk(dut.buffer[0]   == 16'hA000, "b3.8 buffer[0] 小端拼接正确");
		chk(dut.buffer[1]   == 16'hA001, "b3.9 buffer[1] 小端拼接正确");
		chk(dut.buffer[255] == 16'hA0FF, "b3.10 扇区末样本正确");

		//------------------------------------------------------------
		// b4 水位流控: 不消费持续写 → allow_req 拉低(字节流暂停, 让出总线)
		//   探测式: 吐到 allow_req 拉低为止(读到水位 >= HIGH_WATER)
		//------------------------------------------------------------
		// 继续吐字节, 直到 allow_req 拉低(水位到 HIGH_WATER)
		while(allow_req == 1'b1 && dut.wr_ptr != 12'd1537)
			feed_bytes(8'hA0, 32'd2);   // 一次一个样本(2 字节)
		repeat(4) @(posedge wr_clk);
		chk(allow_req == 1'b0,      "b4.1 水位到顶后 allow_req 拉低(暂停字节流)");
		chk(dut.level_wr >= 11'd1536,"b4.2 水位 >= HIGH_WATER(1536)");
		chk(primed == 1'b1,         "b4.3 水位过 PREFILL 后已预充");
		chk(dut.rd_ptr == 11'd1,    "b4.4 预充已消费第 1 个样本(读指针=1)");
		chk(dut.buffer[256] == 16'hA000, "b4.5 样本 256 正确(256&0xFF=0 → A000)");

		//------------------------------------------------------------
		// b5 预充态 + 前 601 个样本逐样本比对
		//------------------------------------------------------------
		wait(primed == 1'b1);
		@(negedge rd_clk);
		chk(sample_counter == 32'd1, "b5.1 预充已预取第 1 个样本");
		chk(dut.rd_ptr == 12'd1,     "b5.2 预充后读指针 = 1");

		consume_checked(600);
		chk(mism_n == 0,             "b5.3 前 601 样本无失真(小端/顺序)");
		chk(prim_err == 0,           "b5.4 消费过程 primed 恒为 1");
		chk(dut.rd_ptr == 12'd601,   "b5.5 读指针推进到 601");
		chk(sample_counter == 32'd601, "b5.6 sample_counter 与读指针一致");

		//------------------------------------------------------------
		// b6 水位回落 → allow_req 恢复(字节流继续, 不死锁)
		//   (b5 已消费 600 样本, 水位应回落到 HIGH_WATER 以下)
		//------------------------------------------------------------
		repeat(20) @(posedge wr_clk);
		chk(dut.level_wr < 11'd1536, "b6.1 消费后水位低于 HIGH_WATER");
		chk(allow_req == 1'b1,       "b6.2 水位回落后 allow_req 恢复");
		chk(dut.wstate == 2'd1,      "b6.3 仍在 WS_RUN(未死锁)");

		//------------------------------------------------------------
		// b7 吐完剩余字节 → 抽干全部真实样本 → 下溢
		//   已吐 1537 样本(b3 的 256 + b4 探测补到 1537), 剩余 3072-1537=1535 样本。
		//   边吐边消费+检查: 每吐一个样本, 消费一个样本并逐样本比对。
		//------------------------------------------------------------
		for(i = 0; i < 1535; i = i + 1) begin
			feed_bytes(8'hA0, 32'd2);          // 吐一个样本(2 字节)
			// 消费一个样本并检查(与 consume_checked 同款逻辑)
			@(negedge rd_clk);
			sample_tick = 1'b1; sample_ready = 1'b1;
			expect_val = exp_of(exp_idx);
			if(sample_out !== $signed(expect_val)) begin
				mism_n = mism_n + 1;
				if(mism_n <= 5)
					$display("[MISMATCH] idx=%0d got=%h exp=%h", exp_idx, sample_out, expect_val);
			end
			exp_idx = exp_idx + 1;
			@(negedge rd_clk); sample_tick = 1'b0;
		end
		send_file_done();                       // 文件读完
		repeat(8) @(posedge wr_clk);
		chk(dut.wstate == 2'd3,     "b7.0 吐完 + file_done 后进 WS_END");

		// 抽干剩余全部真实样本(缓冲里可能还压着未消费的)
		//   exp_idx 已推进到 2136(601+1535), 继续消费到 3072 才全部交付。
		while(exp_idx < 3072) begin
			@(negedge rd_clk);
			sample_tick = 1'b1; sample_ready = 1'b1;
			expect_val = exp_of(exp_idx);
			if(sample_out !== $signed(expect_val)) begin
				mism_n = mism_n + 1;
				if(mism_n <= 5)
					$display("[MISMATCH] idx=%0d got=%h exp=%h", exp_idx, sample_out, expect_val);
			end
			exp_idx = exp_idx + 1;
			@(negedge rd_clk); sample_tick = 1'b0;
		end
		chk(mism_n == 0,             "b7.1 全部真实样本无失真");
		chk(exp_idx == 3072,         "b7.2 共交付 3072 个真实样本");
		chk(sample_counter == 3072,  "b7.4 sample_counter = 已写样本数");

		consume_underflow(50);
		chk(uf_val_err == 0,         "b7.5 下溢期间输出恒为静音");
		chk(uf_ptr_err == 0,         "b7.6 下溢期间读指针冻结");
		chk(sample_valid == 1'b1,    "b7.7 下溢时 sample_valid 仍为 1");

		//------------------------------------------------------------
		// b8 取消选中全清零; 重新选中从头播
		//------------------------------------------------------------
		play_enable = 1'b0;
		repeat(20) @(posedge wr_clk);
		repeat(10) @(posedge rd_clk);
		chk(dut.wstate == 2'd0,     "b8.2 取消选中后写状态机回 WS_IDLE");
		chk(primed == 1'b0,         "b8.3 取消选中后 primed 清零");
		chk(dut.rd_ptr == 12'd0,    "b8.4 取消选中后读指针清零");
		chk(sample_counter == 32'd0,"b8.5 取消选中后 sample_counter 清零");
		chk(sample_out == 16'sd0,   "b8.6 取消选中后输出静音");
		chk(sample_valid == 1'b0,   "b8.7 取消选中后 sample_valid=0");

		play_enable = 1'b1;          // 重新选中(换场景再进来)
		repeat(20) @(posedge wr_clk);
		chk(dut.wstate == 2'd1,     "b8.8 重新选中后从头起播(WS_RUN)");
		chk(file_cluster == 32'd100,"b8.9 重新选中后 file_cluster = start_cluster");
		chk(dut.wr_ptr == 12'd0,    "b8.10 重新选中后写指针清零");

		//------------------------------------------------------------
		// b9 loop_en=1: 播完自动回绕重新 file_start 续播(无缝循环)
		//   文件大小取 4 个扇区 = 1024 样本 = 2048 字节 < HIGH_WATER,
		//   保证写侧不会因水位暂停, 回绕条件一开始就成立。
		//------------------------------------------------------------
		play_enable = 1'b0;
		repeat(20) @(posedge wr_clk);
		repeat(10) @(posedge rd_clk);
		loop_en       = 1'b1;
		file_size     = 32'd2048;
		play_enable   = 1'b1;
		wait(file_start == 1'b1);     // 捕获重新起播的 file_start
		chk(dut.wstate == 2'd1 && file_cluster == 32'd100, "b9.1 loop: 重新选中从头起播");
		// 吐满 2048 字节并 file_done, 观察自动回绕(重置字节序号从头吐)
		fgen_cnt = 0;
		feed_bytes(8'hB0, 32'd2048);
		send_file_done();
		// file_done 后进 WS_END, 因 loop_en && level<HIGH_WATER 下一拍即回绕。
		//   WS_END 只停留一拍(wait 会错过), 故直接等回绕后的 file_start 脉冲。
		wait(file_start == 1'b1);
		repeat(4) @(posedge wr_clk);
		chk(dut.wstate == 2'd1,     "b9.2 loop: 自动回绕到 WS_RUN");
		chk(file_cluster == 32'd100,"b9.3 loop: file_cluster 回到 start_cluster");

		$display("====================================================");
		$display("tb_wav_stream_player: checks=%0d fails=%0d", checks, fails);
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
