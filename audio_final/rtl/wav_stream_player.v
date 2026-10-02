`timescale 1ns/1ps
//====================================================================
// 模块名 : wav_stream_player.v —— TF 卡 WAV(裸 PCM)流式播放器
//
// 来源: 小鹅通《第十一讲：WAV音频播放》的 wav_stream_player.v, 按本工程
//   实际接口裁剪/加固后移植。原始版本假定自己**独占** SD 卡且**不需要
//   水位流控**(其注释写"水位检查隐含在消费速率里"), 本工程两条都不成立:
//     · 迎新技术 SD 总线要与图片轮播共用 → 由 audio_sd_arbiter 逐扇区仲裁;
//     · 仲裁下写入端可能被图片扇区挡最多一个扇区时间, 必须显式水位流控,
//       否则写入端会以 ~1.2 MB/s 突发写满并**追尾覆盖**未读数据(听感上是
//       严重失真), 这是移植版必须补的关键点。
//
// 架构(与小鹅通一致):
//   TF 扇区字节流(wr_clk = sd_card_clk 100 MHz, 逐拍 1 字节)
//     → 两字节拼一个 16 bit 样本 → 写入 BRAM 循环缓冲(2048×16 = 4 KB)
//   48 kHz 取样节拍(rd_clk = video_clk 25 MHz, 由 48 kHz 相位累加器给出)
//     → 从 BRAM 读出 → 交给 audio_src_sel/audio_src_mux
//
// 数据格式: 裸 16 bit 有符号 小端序 PCM, 48 kHz 单声道; TF 字节先低后高。
//   PC 端工具 tools/make_audio_corpus.py 负责把任意 WAV 转成该格式。
//
// 跨时钟域: 读写指针各自格雷码 + 2 级触发器同步, 是 FPGA 的标准做法。
//
// 流控(本工程新增):
//   · 写侧每读完一个扇区判断一次: level_wr < HIGH_WATER(75% = 1536) 才继续
//     请求下一个扇区, 否则进 WS_PAUSE 等消费端把水位拉下来。
//   · 读侧先攒够 PREFILL(1024 样本 ≈ 21 ms) 才置 primed, 避免上电抖动;
//     下溢时输出静音但 sample_valid 仍保持有效, 下游 HDMI 链不会卡死
//     (这一点与小鹅通一致, 也是本工程音频通路"valid 恒有效"的既有约定)。
//
// 循环(本工程新增 loop_en):
//   迎新场景的背景音乐要一直响, 故播完最后一扇区后可选**无缝回绕**重播:
//   WS_END 里若 loop_en=1 且水位已降到 HIGH_WATER 以下, 就把 cur_lba 拉回
//   start_lba、扇区计数清零、直接回 WS_RUN。此时环形缓冲里还压着 ~37 ms 的
//   曲尾数据, 新写入的曲首正好接在它后面被消费 → 听感上无断点。
//   (回绕不消耗额外 BRAM: 读写指针都是环形自增, 不需要任何地址回卷逻辑)
//
// 位宽/容量: ADDR_WIDTH=11 → 2048 样本 = 4 KB(32 Kbit), 恰好落进硬 BRAM。
//   [2026-09-27 由 12 降到 11] ADDR_WIDTH=12 时 4096x16 = 64 Kbit, 综合把
//   循环缓冲映射成 7 块 BRAM9K —— 而本工程基线已用 60/64, 综合报
//   "emb number = 67, exceeds the limit 64"(BRAM9K 只剩 4 块)。降到 11 后
//   2048x16 = 32 Kbit 只需 2~4 块 BRAM9K(或 1 块 bram32k, 尚余 14 块), 面积达标。
//   稳态水位在 HIGH_WATER(1536) 上下波动 ±256 样本 ≈ 27..37 ms, 仍远大于
//   单扇区等待(BMP 让路 ≤0.5 ms), 故仲裁引入的抖动不会造成下溢。
//====================================================================
module wav_stream_player #(
	parameter integer ADDR_WIDTH = 11,          // 2048 x 16 bit = 4 KB
	parameter integer SAMPLES_PER_SECTOR = 256, // 512 字节 / 2
	parameter integer PREFILL = 1024            // 起播水位(样本)
) (
	// ---- 写侧: sd_card_clk 域 ----
	input  wire        wr_clk,
	input  wire        wr_rst_n,
	input  wire        play_enable,        // 电平: 选中 WAV 期间为 1
	input  wire        loop_en,            // 电平: 1=播完自动回绕续播(背景音乐)
	input  wire [31:0] start_lba,          // 音频数据首扇区(卡上裸 PCM 起点)
	input  wire [31:0] total_sectors,      // 音频数据总扇区数
	output wire        sd_req,             // 扇区读请求(→ audio_sd_arbiter 的 b_req)
	output wire [31:0] sd_lba,             // 扇区地址(→ 仲裁器 b_addr)
	input  wire        sd_valid,           // 字节有效(仲裁器只回授权方)
	input  wire [7:0]  sd_byte,
	input  wire        sd_done,            // 扇区读完(单拍)
	// ---- 读侧: video_clk 域 ----
	input  wire        rd_clk,
	input  wire        rd_rst_n,
	input  wire        sample_tick,        // 48 kHz 取样节拍(与音频链同源)
	input  wire        sample_ready,       // 下游可接收(consumed 单拍)
	output wire signed [15:0] sample_out,
	output wire        sample_valid,       // 选中期间恒为 1(下溢时输出静音)
	output wire        primed,             // 已攒够 PREFILL, 可放真实样本
	output reg  [31:0] sample_counter      // 已消费样本数(可上 OSD/数码管)
);
	localparam integer DEPTH      = (1 << ADDR_WIDTH);
	localparam integer HIGH_WATER = DEPTH - DEPTH/4;   // 75% = 1536

	// ---------------- 循环缓冲(推断为双时钟 BRAM) ----------------
	// 必须带 TD 强制注释: 否则 2048x16 会被综合成分布式 RAM(≈2048 个 LUT),
	//   整设计 mslice 6749 > 4900 直接 place 失败(tested 2026-09-27)。
	//   同款写法见 src/meeting_cfg.v(写 sd_card_clk / 读 video_clk 真双口)与
	//   src/osd_font_rom.v —— 它们都靠这句落进硬 BRAM。
	// 读口 rd_clk 侧是"地址是寄存器、输出到寄存器"的标准同步读(见下), 与 BRAM
	//   的 1 拍读延迟语义一致, 故映射后时序与仿真完全一致, 无需改状态机。
	reg [15:0] buffer [0:DEPTH-1]; /* fehdl force_ram=1, ram_style="bram" */
	reg [ADDR_WIDTH-1:0] wr_ptr;       // 写指针(wr_clk 域)
	reg [ADDR_WIDTH-1:0] rd_ptr;       // 读指针(rd_clk 域)

	// ---- 格雷码同步: wr_ptr → rd_clk 域 ----
	reg [ADDR_WIDTH-1:0] wr_gray;
	reg [ADDR_WIDTH-1:0] wr_gray_sync1, wr_gray_sync2;
	// ---- 格雷码同步: rd_ptr → wr_clk 域 ----
	reg [ADDR_WIDTH-1:0] rd_gray;
	reg [ADDR_WIDTH-1:0] rd_gray_sync1, rd_gray_sync2;

	function [ADDR_WIDTH-1:0] to_gray;
		input [ADDR_WIDTH-1:0] b;
		begin to_gray = b ^ (b >> 1); end
	endfunction

	function [ADDR_WIDTH-1:0] from_gray;
		input  [ADDR_WIDTH-1:0] g;
		reg    [ADDR_WIDTH-1:0] b;
		integer i;
		begin
			b[ADDR_WIDTH-1] = g[ADDR_WIDTH-1];
			for(i = ADDR_WIDTH-2; i >= 0; i = i - 1)
				b[i] = b[i+1] ^ g[i];
			from_gray = b;
		end
	endfunction

	wire [ADDR_WIDTH-1:0] wr_ptr_in_rd = from_gray(wr_gray_sync2);
	wire [ADDR_WIDTH-1:0] rd_ptr_in_wr = from_gray(rd_gray_sync2);
	// 水位 = 环形缓冲占用样本数, 必须用 ADDR_WIDTH 位**回绕算术**:
	//   level = (ptr_w - ptr_r) mod 2^ADDR_WIDTH, 只要占用 < 2^ADDR_WIDTH 即为真值。
	//   [修复] 若改用 ADDR_WIDTH+1 位减法, 当写指针绕回后(wr_ptr < rd_ptr)会
	//   得到 真值+2048, 恒 >= HIGH_WATER → 写侧会永久卡在 WS_PAUSE(死锁)。
	//   本模块占用上限 = HIGH_WATER + 1 个扇区 = 1536+256 = 1792 < 2048, 因此
	//   ADDR_WIDTH 位回绕算术始终有效(流控在扇区边界检查, 单扇区最多多写 256)。
	//   · level_wr 在写域算(格雷同步的 rd_ptr 偏旧 → 水位偏大, 流控安全方向)
	//   · level_rd 在读域算(格雷同步的 wr_ptr 偏旧 → 水位偏小, 不会读到未写数据)
	wire [ADDR_WIDTH-1:0] level_wr = wr_ptr - rd_ptr_in_wr;
	wire [ADDR_WIDTH-1:0] level_rd = wr_ptr_in_rd - rd_ptr;

	// ---------------- 写侧状态机 ----------------
	localparam [1:0] WS_IDLE  = 2'd0;
	localparam [1:0] WS_RUN   = 2'd1;   // 持有请求, 收字节
	localparam [1:0] WS_PAUSE = 2'd2;   // 缓冲已够, 让出总线
	localparam [1:0] WS_END   = 2'd3;   // 全部扇区读完
	reg [1:0]  wstate;
	reg [31:0] cur_lba;
	reg [31:0] sectors_read;
	reg [7:0]  lo_byte;
	reg        lo_pending;

	assign sd_req = (wstate == WS_RUN);
	assign sd_lba = cur_lba;

	// play_enable 由 video_clk 域的场景选择给出(sel_wav), 写侧在 sd_card_clk
	//   域 → 两级同步后再用于写状态机。它是准静态电平(切场景才变), 加同步
	//   只是保证跨域采样不出现亚稳态, 不影响任何时序路径。
	reg play_en_s1, play_en_sync;
	always @(posedge wr_clk or negedge wr_rst_n) begin
		if(!wr_rst_n) begin
			play_en_s1  <= 1'b0;
			play_en_sync<= 1'b0;
		end else begin
			play_en_s1  <= play_enable;
			play_en_sync<= play_en_s1;
		end
	end

	always @(posedge wr_clk or negedge wr_rst_n) begin
		if(!wr_rst_n) begin
			wstate       <= WS_IDLE;
			cur_lba      <= 32'd0;
			sectors_read <= 32'd0;
			wr_ptr       <= {ADDR_WIDTH{1'b0}};
			lo_pending   <= 1'b0;
			lo_byte      <= 8'd0;
			rd_gray      <= {ADDR_WIDTH{1'b0}};
			rd_gray_sync1<= {ADDR_WIDTH{1'b0}};
			rd_gray_sync2<= {ADDR_WIDTH{1'b0}};
		end else begin
			// rd_ptr 同步进写域(算水位用)
			rd_gray       <= to_gray(rd_ptr);
			rd_gray_sync1 <= rd_gray;
			rd_gray_sync2 <= rd_gray_sync1;

			case(wstate)
			WS_IDLE: begin
				wr_ptr     <= {ADDR_WIDTH{1'b0}};
				lo_pending <= 1'b0;
				if(play_en_sync && total_sectors != 32'd0) begin
					cur_lba      <= start_lba;
					sectors_read <= 32'd0;
					wstate       <= WS_RUN;
				end
			end
			WS_RUN: begin
				// 字节拼样本: TF 先低字节后高字节 → 小端序
				if(sd_valid) begin
					if(!lo_pending) begin
						lo_byte    <= sd_byte;
						lo_pending <= 1'b1;
					end else begin
						buffer[wr_ptr] <= {sd_byte, lo_byte};
						wr_ptr         <= wr_ptr + 1'b1;
						lo_pending     <= 1'b0;
					end
				end
				if(sd_done) begin
					// 扇区边界对齐(512 字节为偶数, 正常 lo_pending 已是 0)
					lo_pending   <= 1'b0;
					sectors_read <= sectors_read + 1'b1;
					cur_lba      <= cur_lba + 1'b1;
					if(sectors_read + 1'b1 >= total_sectors)
						wstate <= WS_END;
					else if(level_wr < HIGH_WATER)
						wstate <= WS_RUN;      // 背靠背请求下一个扇区
					else
						wstate <= WS_PAUSE;    // 水位够高, 让出总线给图片
				end
			end
			WS_PAUSE: begin
				if(!play_en_sync)            wstate <= WS_IDLE;
				else if(level_wr < HIGH_WATER) wstate <= WS_RUN;
			end
			WS_END: begin
				// 播完最后一扇区。loop_en=0 → 停在 WS_END 等取消选中(sd_req=0);
				//   loop_en=1 → 水位腾出空间后立即回绕到 start_lba 无缝续播。
				//   水位门限与 WS_PAUSE 同一条(见上方回绕算术说明), 保证缓冲
				//   占用不会超过 HIGH_WATER + 1 个扇区。
				if(!play_en_sync)            wstate <= WS_IDLE;
				else if(loop_en && (level_wr < HIGH_WATER)) begin
					cur_lba      <= start_lba;
					sectors_read <= 32'd0;
					wstate       <= WS_RUN;
				end
			end
			default: wstate <= WS_IDLE;
			endcase
		end
	end

	// ---------------- 读侧(48 kHz 消费) ----------------
	reg primed_r;
	assign primed       = primed_r;
	// 选中 WAV 期间 sample_valid 恒为 1: 预充/下溢阶段输出静音但有效,
	//   保证下游 audio_src_mux 的 "test_valid && media_valid" 永不打嗝
	//   (否则每次预充都会丢一个 48 kHz 样本, 听感是密集的小爆音)。
	assign sample_valid = play_enable;

	// ---- BRAM 同步读口 ----
	// 硬性要求: 存储读必须是"地址是寄存器、输出是寄存器"的**独立无条件**赋值。
	//   若把它和指针自增写在同一个过程块里, TD 会识别出 RAM 却推断 BRAM 失败
	//   (SYN-5042), 掉进分布式 RAM → mslice 6749 > 4900, place 直接报错。
	// 关键点: rd_addr 只在"装载事件"(预充 / 48kHz 消费节拍)那一拍更新,
	//   两次装载之间它与 rd_q 都保持不变 —— 正好复刻旧版 sample_out 的
	//   "保持到下次装载"语义, 而不是让输出自己跟着 rd_ptr 往前跑。
	// 时序: 装载事件发生在第 E 拍 → rd_q 于第 E+1 拍给出 buffer[rd_ptr(E)],
	//   与旧版 sample_out(E+1) <= buffer[rd_ptr(E)] 逐拍完全一致。
	// 消音: 旧版在"未选中 / 预充未完成 / 下溢"时把 sample_out 赋 0, 用一个
	//   影子标志 out_zero 承载这三种情形(转移条件与旧版一字不差)。
	reg [ADDR_WIDTH-1:0] rd_addr;      // 当前呈现样本的地址(仅装载事件更新)
	reg signed [15:0]    rd_q;         // BRAM 同步读输出(晚 rd_addr 一拍)
	reg                  out_zero;     // 1 = 本拍输出静音
	always @(posedge rd_clk) rd_q <= buffer[rd_addr];

	assign sample_out = out_zero ? 16'sd0 : rd_q;

	always @(posedge rd_clk or negedge rd_rst_n) begin
		if(!rd_rst_n) begin
			rd_ptr         <= {ADDR_WIDTH{1'b0}};
			rd_addr        <= {ADDR_WIDTH{1'b0}};
			out_zero       <= 1'b1;
			sample_counter <= 32'd0;
			primed_r       <= 1'b0;
			wr_gray        <= {ADDR_WIDTH{1'b0}};
			wr_gray_sync1  <= {ADDR_WIDTH{1'b0}};
			wr_gray_sync2  <= {ADDR_WIDTH{1'b0}};
		end else begin
			// wr_ptr 同步进读域
			wr_gray       <= to_gray(wr_ptr);
			wr_gray_sync1 <= wr_gray;
			wr_gray_sync2 <= wr_gray_sync1;

			if(!play_enable) begin
				// 退出 WAV 源: 指针与起播标志全部复位, 下次从头播
				rd_ptr         <= {ADDR_WIDTH{1'b0}};
				rd_addr        <= {ADDR_WIDTH{1'b0}};
				primed_r       <= 1'b0;
				sample_counter <= 32'd0;
				out_zero       <= 1'b1;
			end else begin
				// 攒够 PREFILL 才起播; 本拍把 buffer[rd_ptr] 送给 BRAM,
				//   下一拍 rd_q 即第 1 个真实样本(与旧版预充语义一致)
				if(!primed_r && (level_rd >= PREFILL)) begin
					primed_r       <= 1'b1;
					rd_addr        <= rd_ptr;
					rd_ptr         <= rd_ptr + 1'b1;
					sample_counter <= sample_counter + 1'b1;
					out_zero       <= 1'b0;
				end
				// 每个 48 kHz 消费节拍装载并推进一个样本
				if(sample_tick && sample_ready && primed_r) begin
					if(level_rd != 0) begin
						rd_addr        <= rd_ptr;
						rd_ptr         <= rd_ptr + 1'b1;
						sample_counter <= sample_counter + 1'b1;
						out_zero       <= 1'b0;
					end else begin
						out_zero       <= 1'b1;   // 下溢: 静音, 不推进指针
					end
				end
			end
		end
	end
endmodule
