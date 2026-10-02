`timescale 1ns/1ps
//====================================================================
// tb_audio_sd_arbiter.v —— audio_sd_arbiter 单元测试
//
// 被测: 逐扇区授予 + 音频在每个授权边界优先 + 数据/结束只回授权方。
// 手法: 用一个"行为级 SD 控制器模型"代替 sd_card_sec_read_write; 它把扇区
//       内容定义为 扇区地址低 8 位 重复 512 遍 —— 于是某主设备收到的字节
//       只要不等于它自己请求地址的低 8 位, 就说明地址串扰(这正是"把
//       sd_sec_read_data_valid 广播给两个主设备"会犯的错)。
//
// 覆盖:
//   阶段1 A1~A3 只有图片通路请求: 图片拿到完整扇区, 音频侧一字节不得
//   阶段2 B1~B3 只有音频通路请求: 音频拿到完整扇区, 图片侧一字节不得
//   阶段3 C1~C4 音频持续请求(缓冲见底的最坏情形): 图片连一个字节都拿不到
//               ("优先"成立); 音频撤请求后图片立即补完("不饿死"成立)
//   阶段4 D1~D4 音频按水位节流(真实情形): 两者真正交错, 各自数据完整,
//               且音频单次等待被授权不超过 1 个整扇区
//   阶段5 E1~E2 扇区读期间地址全程不动(仲裁"不可抢占"的硬约束)
//====================================================================
module tb_audio_sd_arbiter;
	reg clk=0, rst=1;
	always #5 clk = ~clk;              // 100 MHz

	// ---- 被测端口 ----
	wire        sd_sec_read;
	wire [31:0] sd_sec_read_addr;
	wire        sd_sec_read_data_valid;
	wire        sd_sec_read_end;
	reg  [7:0]  sd_data;
	reg         a_req, b_req;
	wire [31:0] a_addr, b_addr;
	wire        a_data_valid, a_end, b_data_valid, b_end;

	integer checks=0, fails=0;

	task chk;
		input cond;
		input [255:0] msg;
		begin
			checks = checks + 1;
			if(!cond) begin
				fails = fails + 1;
				$display("[FAIL] %0s", msg);
			end
		end
	endtask

	audio_sd_arbiter dut(
		.clk(clk), .rst(rst),
		.sd_sec_read(sd_sec_read), .sd_sec_read_addr(sd_sec_read_addr),
		.sd_sec_read_data_valid(sd_sec_read_data_valid), .sd_sec_read_end(sd_sec_read_end),
		.a_req(a_req), .a_addr(a_addr),
		.a_data_valid(a_data_valid), .a_end(a_end),
		.b_req(b_req), .b_addr(b_addr),
		.b_data_valid(b_data_valid), .b_end(b_end)
	);

	//====================================================================
	// 行为级 SD 控制器模型
	//   ST_IDLE 采样 sd_sec_read 并锁地址 → ST_GAP 2 拍(代表命令开销)
	//   → ST_BYTE 逐拍吐 1 字节 ×512 → ST_END 单拍 sd_sec_read_end
	//   时序与 sd_card_sec_read_write 的
	//   S_WAIT_READ_WRITE→S_CMD17→S_READ→S_READ_END 等价。
	//   扇区内容 = 该扇区地址低 8 位(整扇区恒定), 故 sd_data 只在进入
	//   ST_BYTE 那一刻装载一次。
	//====================================================================
	localparam ST_IDLE=0, ST_GAP=1, ST_BYTE=2, ST_END=3;
	reg [1:0]  st;
	reg [31:0] cur_addr;
	reg [10:0] byte_cnt;
	reg [1:0]  gap;
	reg        addr_moved_err;

	assign sd_sec_read_data_valid = (st == ST_BYTE);
	assign sd_sec_read_end        = (st == ST_END);

	always @(posedge clk or posedge rst) begin
		if(rst) begin
			st<=ST_IDLE; cur_addr<=32'd0; byte_cnt<=0; gap<=2; sd_data<=8'd0;
			addr_moved_err<=1'b0;
		end else begin
			// 扇区读期间 sd_sec_read_addr 必须保持不变(owner 未释放)
			if(st == ST_BYTE && sd_sec_read_addr !== cur_addr)
				addr_moved_err<=1'b1;
			case(st)
			ST_IDLE: if(sd_sec_read) begin
				cur_addr <= sd_sec_read_addr;   // 锁存: 与控制器同一拍
				byte_cnt <= 11'd0;
				gap      <= 2'd2;
				st       <= ST_GAP;
			end
			ST_GAP: begin
				if(gap == 2'd0) begin
					sd_data <= cur_addr[7:0];   // 整扇区内容恒定, 只装一次
					st      <= ST_BYTE;
				end else gap <= gap - 1'b1;
			end
			ST_BYTE: begin
				byte_cnt <= byte_cnt + 1'b1;
				if(byte_cnt == 11'd511) st <= ST_END;
			end
			ST_END: st <= ST_IDLE;
			default: st <= ST_IDLE;
			endcase
		end
	end

	//====================================================================
	// 两个主设备的行为模型
	//====================================================================
	reg [31:0] a_cur, b_cur;
	reg        a_err, b_err;
	integer    a_got, b_got, a_secs, b_secs;
	integer    b_wait_max, b_wait_now;

	assign a_addr = a_cur;
	assign b_addr = b_cur;

	always @(posedge clk) begin
		if(!rst) begin
			// 逐字节校验: 收到的数据必须等于"自己请求地址"的低 8 位
			if(a_data_valid && sd_data !== a_cur[7:0]) a_err <= 1'b1;
			if(b_data_valid && sd_data !== b_cur[7:0]) b_err <= 1'b1;
			if(a_data_valid) a_got <= a_got + 1;
			if(b_data_valid) b_got <= b_got + 1;
			if(a_end) begin a_secs <= a_secs + 1; a_cur <= a_cur + 1'b1; end
			if(b_end) begin b_secs <= b_secs + 1; b_cur <= b_cur + 1'b1; end
			// 音频等待时长: 从发出请求到地址被放上总线
			if(b_req && sd_sec_read && (sd_sec_read_addr == b_cur)) begin
				if(b_wait_now > b_wait_max) b_wait_max <= b_wait_now;
				b_wait_now <= 0;
			end else if(b_req) b_wait_now <= b_wait_now + 1;
		end
	end

	integer i, t0;
	initial begin
		a_req=0; b_req=0; a_cur=32'h0000_1100; b_cur=32'h0000_2200;
		a_err=0; b_err=0; a_got=0; b_got=0; a_secs=0; b_secs=0;
		b_wait_max=0; b_wait_now=0;

		rst = 1;
		repeat(10) @(posedge clk);
		rst = 0;
		repeat(4)  @(posedge clk);

		//------------------------------------------------------------
		// 阶段 1: 只有图片通路请求 → 音频侧必须一字节都收不到
		//------------------------------------------------------------
		a_req = 1'b1;
		wait(a_secs == 4);
		a_req = 1'b0;                      // 先撤请求, 避免又启动第 5 个扇区
		chk(a_got == 4*512, "A1 只有图片请求: 图片拿到 4 个完整扇区(2048 字节)");
		chk(b_got == 0,     "A2 只有图片请求: 音频侧一字节未收到");
		chk(!a_err,         "A3 只有图片请求: 图片数据无串扰");
		repeat(20) @(posedge clk);

		//------------------------------------------------------------
		// 阶段 2: 只有音频通路请求 → 图片侧必须一字节都收不到
		//------------------------------------------------------------
		a_got=0; b_got=0; a_secs=0; b_secs=0; a_err=0; b_err=0;
		a_cur=32'h0000_3100; b_cur=32'h0000_4200;
		repeat(4) @(posedge clk);
		b_req = 1'b1;
		wait(b_secs == 4);
		b_req = 1'b0;
		chk(b_got == 4*512, "B1 只有音频请求: 音频拿到 4 个完整扇区(2048 字节)");
		chk(a_got == 0,     "B2 只有音频请求: 图片侧一字节未收到");
		chk(!b_err,         "B3 只有音频请求: 音频数据无串扰");
		repeat(20) @(posedge clk);

		//------------------------------------------------------------
		// 阶段 3: 音频持续请求 = 缓冲见底的最坏情形
		//   b_req 全程不撤 → 每个授权边界音频都赢, 图片一个字节都拿不到;
		//   音频跑完 4 个扇区后撤请求, 图片必须立刻补完(不是永久饿死)。
		//------------------------------------------------------------
		a_got=0; b_got=0; a_secs=0; b_secs=0; a_err=0; b_err=0;
		a_cur=32'h0000_5100; b_cur=32'h0000_6200;
		a_req = 1'b1; b_req = 1'b1;
		wait(b_secs == 4);
		chk(a_got == 0,     "C1 音频优先: 音频 4 扇区跑完时图片连 1 字节都没开始");
		chk(b_got == 4*512, "C2 音频数据完整(2048 字节)");
		b_req = 1'b0;                      // 音频缓冲补满, 让出总线
		wait(a_secs == 4);
		a_req = 1'b0;
		chk(a_got == 4*512, "C3 图片未被饿死: 音频让出后补完 4 个扇区");
		chk(!a_err && !b_err, "C4 并发期间两侧数据均无串扰");
		repeat(20) @(posedge clk);

		//------------------------------------------------------------
		// 阶段 4: 音频按水位节流(真实情形) → 两者真正交错
		//   音频每拿 1 个扇区就撤请求 40 拍(模拟"缓冲已高于水位"), 图片
		//   在这些空隙里推进; 两者都必须完成, 且音频等待 ≤ 1 个整扇区。
		//------------------------------------------------------------
		a_got=0; b_got=0; a_secs=0; b_secs=0; a_err=0; b_err=0;
		b_wait_max=0; b_wait_now=0;
		a_cur=32'h0000_7100; b_cur=32'h0000_8200;
		a_req = 1'b1;
		for(i=0;i<4;i=i+1) begin
			b_req = 1'b1;
			t0 = b_secs;
			wait(b_secs == t0 + 1);
			b_req = 1'b0;
			repeat(40) @(posedge clk);      // 模拟"缓冲高于水位 → 暂停请求"
		end
		wait(a_secs == 4);
		a_req = 1'b0;
		chk(a_got == 4*512,  "D1 交错情形: 图片 4 个扇区全部完成");
		chk(b_got == 4*512,  "D2 交错情形: 音频 4 个扇区全部完成");
		chk(b_wait_max < 600, "D3 音频单次等待被授权不超过 1 个整扇区(≤600 拍)");
		chk(!a_err && !b_err, "D4 交错情形: 两侧数据均无串扰");
		repeat(600) @(posedge clk);

		//------------------------------------------------------------
		// 阶段 5: 硬约束与总线释放
		//------------------------------------------------------------
		chk(!addr_moved_err, "E1 扇区读期间 sd_sec_read_addr 未发生任何变动");
		chk(sd_sec_read == 1'b0 && !a_data_valid && !b_data_valid,
		    "E2 两侧均无请求时总线已彻底释放(请求/数据全为 0)");

		$display("====================================================");
		$display("tb_audio_sd_arbiter: checks=%0d fails=%0d", checks, fails);
		if(fails == 0) $display("RESULT: PASS");
		else           $display("RESULT: FAIL");
		$display("====================================================");
		$finish;
	end

	// 看门狗: 若断言死锁, 10 ms 后强制结束, 避免仿真跑挂
	initial begin
		#10_000_000;
		$display("[WATCHDOG] 仿真超时: checks=%0d fails=%0d", checks, fails);
		$display("RESULT: FAIL");
		$finish;
	end
endmodule
