`timescale 1ns/1ps
//====================================================================
// tb_audio_chain_e2e.v —— 迎新 WAV 音频链路**端到端**集成测试
//
// 目的: 板上"迎新无声"的定位。卡内容已被证明正确(物理 LBA 300000 与源
//   文件 SHA 一致), 各模块单元测试也通过, 因此必须把顶层实际的那条链
//   原样拼起来复现, 看信号在哪一级断掉:
//
//   48kHz 节拍(audio_rate_tick, 顶层同款相位累加器)
//        │
//   恒有效静音源(zero_valid≡1, 修复后) ──────┐
//        │                                    ├→ audio_src_mux → audio_left
//   wav_stream_player → audio_src_sel ────────┘
//        ▲
//   fat32_file_streamer ← sd_sector_adapter ← 本 TB 的"扇区服务器"
//
// 与顶层一致的关键点(逐条对齐 top_final.v):
//   · video_clk 25MHz / sd_card_clk 100MHz
//   · audio_pcm_ready = audio_rate_tick(单拍)
//   · sel_wav 常量电平(= 迎新场景)
//   · wav_sample_ready = wav_ready(= audio_src_sel 回给 WAV 的 media_ready)
//   · 文件数据前 288 个样本为 0(源曲 576 字节静音前奏), 之后非零
//
// FAT32 化差异(相对旧扇区接口版):
//   · wav_stream_player 现在是 file 接口(start_cluster/file_size/file_*),
//     由 fat32_file_streamer 读文件字节流, 经 sd_sector_adapter 桥接到
//     扇区服务器(模拟 sd_card_sec_read_write)。
//   · 本 TB 的"扇区服务器"额外模拟一张 FAT 表 + 数据簇, 使 streamer 能
//     正常遍历簇链读到完整文件(单簇链: 每簇 FAT 项=下一簇号, 末簇=EOC)。
//
// 判读: 打印 primed / wav_left 首次非零 / audio_left 首次非零 的时刻,
//   哪一级一直是 0 就是断点。
//====================================================================
module tb_audio_chain_e2e;

	// ---- 双时钟 ----
	reg video_clk = 0, sd_clk = 0;
	always #20 video_clk = ~video_clk;   // 25 MHz (40ns)
	always #5  sd_clk    = ~sd_clk;      // 100 MHz (10ns)

	reg rst_n_vid = 0;   // video 域复位(低有效)
	reg rst_sd    = 1;   // sd 域复位(高有效)

	// ---- 48kHz 节拍(与 top_final 完全同款) ----
	localparam integer AUDIO_CLK_HZ    = 25000000;
	localparam integer AUDIO_SAMPLE_HZ = 48000;
	reg [31:0] audio_rate_acc;
	wire audio_rate_tick = (audio_rate_acc >= (AUDIO_CLK_HZ - AUDIO_SAMPLE_HZ));
	always @(posedge video_clk or negedge rst_n_vid)
		if(!rst_n_vid)              audio_rate_acc <= 32'd0;
		else if(audio_rate_tick)    audio_rate_acc <= audio_rate_acc - (AUDIO_CLK_HZ - AUDIO_SAMPLE_HZ);
		else                        audio_rate_acc <= audio_rate_acc + AUDIO_SAMPLE_HZ;

	// ---- 场景选择: 迎新 = 选中 WAV ----
	reg sel_wav = 0;

	// ---- WAV 侧 ----
	wire             wav_valid, wav_ready, wav_primed;
	wire signed[15:0] wav_left, wav_right;

	// ---- DDS 侧(本用例不选, 恒 0) ----
	wire             dds_valid = 1'b0;
	wire             dds_ready;
	wire signed[15:0] dds_left  = 16'sd0, dds_right = 16'sd0;
	wire [8:0]        dds_gain  = 9'd256;

	// ---- 媒体口 ----
	wire             media_valid, media_ready;
	wire signed[15:0] media_left, media_right;
	wire [8:0]        media_gain;

	// ---- 静音 test 源(与 top_final.v 修复后一致: 恒有效、恒零) ----
	wire             zero_ready;
	wire             zero_valid   = 1'b1;
	wire signed[15:0] zero_left   = 16'sd0;
	wire signed[15:0] zero_right  = 16'sd0;

	// ---- 末端 PCM ----
	wire              audio_pcm_valid;
	wire              audio_pcm_ready = audio_rate_tick;
	wire signed[15:0] audio_left, audio_right;
	wire [31:0]       mux_pairs;

	audio_src_sel u_audio_src_sel(
		.clk(video_clk), .rst_n(rst_n_vid), .sel_wav(sel_wav),
		.dds_valid(dds_valid), .dds_ready(dds_ready),
		.dds_left(dds_left), .dds_right(dds_right), .dds_gain(dds_gain),
		.wav_valid(wav_valid), .wav_ready(wav_ready),
		.wav_left(wav_left), .wav_right(wav_right),
		.drain_tick(audio_rate_tick),
		.media_valid(media_valid), .media_ready(media_ready),
		.media_left(media_left), .media_right(media_right), .media_gain(media_gain));

	audio_src_mux u_audio_mux(
		.clk(video_clk), .rst_n(rst_n_vid),
		.test_valid(zero_valid), .media_valid(media_valid),
		.test_ready(zero_ready), .media_ready(media_ready),
		.test_left(zero_left), .test_right(zero_right),
		.media_left(media_left), .media_right(media_right), .media_gain(media_gain),
		.sample_valid(audio_pcm_valid), .sample_ready(audio_pcm_ready),
		.sample_left(audio_left), .sample_right(audio_right),
		.accepted_pairs(mux_pairs));

	//====================================================================
	// FAT32 文件流: streamer + adapter + 扇区服务器
	//   链: wav(file_*) → fat32_file_streamer(sector_*) → sd_sector_adapter
	//       → 扇区服务器(sd_sec_*, 模拟 sd_card_sec_read_write)
	//====================================================================
	// WAV 文件参数(scanner 目录项给出; 本 TB 直接硬编码)
	localparam [31:0] WAV_CLUSTER   = 32'd100;    // 起始簇号(任意合法值)
	//   单簇文件(首簇即 EOC): file_size 取 4096 字节 = 2048 样本, 一簇刚好装下,
	//   简化 FAT 链模型(streamer 只读 1 个数据簇即 file_done)。
	//   ⚠ 前 288 样本(576 字节)为静音前奏, 之后非零 → 非零样本约 1472 个。
	localparam [31:0] WAV_FILE_SIZE = 32'd4096;

	// streamer FAT 参数
	localparam [7:0]  SPC        = 8'd8;         // 每簇 8 扇区
	localparam [31:0] FAT_START  = 32'd32;       // FAT 表起始扇区(模拟)
	localparam [31:0] DATA_START = 32'd64;       // 数据区起始扇区(模拟)
	localparam [31:0] MAX_CLU    = 32'd1000;

	// ---- WAV → streamer 的 file 接口 ----
	wire        wav_file_start;
	wire [31:0] wav_file_cluster;
	wire [31:0] wav_file_len;
	wire        wav_allow_req;
	wire        wav_file_valid;
	wire [7:0]  wav_file_byte;
	wire        wav_file_done;
	wire [7:0]  wav_file_error;

	wav_stream_player #(.ADDR_WIDTH(11), .SAMPLES_PER_SECTOR(256), .PREFILL(1024)) u_wav_player(
		.wr_clk(sd_clk), .wr_rst_n(~rst_sd),
		.play_enable(sel_wav), .loop_en(1'b1),
		.start_cluster(WAV_CLUSTER), .file_size(WAV_FILE_SIZE),
		.file_start(wav_file_start), .file_cluster(wav_file_cluster),
		.file_len_out(wav_file_len),
		.file_valid(wav_file_valid), .file_byte(wav_file_byte),
		.file_done(wav_file_done), .file_error(wav_file_error),
		.allow_req(wav_allow_req),
		.rd_clk(video_clk), .rd_rst_n(rst_n_vid),
		.sample_tick(audio_rate_tick), .sample_ready(wav_ready),
		.sample_out(wav_left), .sample_valid(wav_valid),
		.primed(wav_primed), .sample_counter());

	assign wav_right = wav_left;

	// ---- streamer 的 sector 接口 → adapter ----
	wire        str_sector_req;
	wire [31:0] str_sector_lba;
	wire        str_sector_busy;
	wire        str_sector_valid;
	wire [7:0]  str_sector_byte;
	wire [8:0]  str_sector_byte_index;
	wire        str_sector_done;
	wire [7:0]  str_sector_error;

	fat32_file_streamer #(.MAX_VISITED_CLUSTERS(8192)) u_streamer(
		.clk(sd_clk), .rst_n(~rst_sd),
		.file_start(wav_file_start), .first_cluster(wav_file_cluster),
		.file_size(wav_file_len),
		.sectors_per_cluster(SPC),
		.sectors_per_cluster_shift(3'd3),   // SPC=8 → log2(8)=3
		.fat_start_lba(FAT_START), .data_start_lba(DATA_START),
		.max_cluster(MAX_CLU),
		.file_busy(), .file_done(wav_file_done),
		.file_valid(wav_file_valid), .file_byte(wav_file_byte),
		.file_byte_offset(), .fs_error(wav_file_error),
		.sector_req(str_sector_req), .sector_lba(str_sector_lba),
		.sector_busy(str_sector_busy),
		.sector_valid(str_sector_valid), .sector_byte(str_sector_byte),
		.sector_byte_index(str_sector_byte_index),
		.sector_done(str_sector_done), .sector_error(str_sector_error));

	// ---- adapter 的 sd_sec 侧 → 扇区服务器 ----
	wire        sd_sec_read;
	wire [31:0] sd_sec_read_addr;
	wire        sd_sec_read_data_valid, sd_sec_read_end;
	wire [7:0]  sd_sec_read_data;

	sd_sector_adapter u_adapter(
		.clk(sd_clk), .rst_n(~rst_sd),
		.allow_req(wav_allow_req),
		.sector_req(str_sector_req), .sector_lba(str_sector_lba),
		.sector_busy(str_sector_busy),
		.sector_valid(str_sector_valid), .sector_byte(str_sector_byte),
		.sector_byte_index(str_sector_byte_index),
		.sector_done(str_sector_done), .sector_error(str_sector_error),
		.sd_sec_read(sd_sec_read), .sd_sec_read_addr(sd_sec_read_addr),
		.sd_sec_read_data_valid(sd_sec_read_data_valid),
		.sd_sec_read_data(sd_sec_read_data),
		.sd_sec_read_end(sd_sec_read_end));

	//====================================================================
	// 扇区服务器: 模拟 sd_card_sec_read_write 的对外时序 + FAT/数据区内容
	//   IDLE → (sd_sec_read 有效) 锁存地址 → CMD 延迟 → 逐拍吐 512 字节
	//        → 单拍 sd_sec_read_end → 回 IDLE
	//   内容: FAT 表扇区给出簇链(FAT 项 = 下一簇号 / 末簇 EOC);
	//         数据区扇区给出 WAV 样本字节。
	//====================================================================
	localparam integer CMD_LAT = 32;   // 模拟 CMD17 开销(拍, sd_clk)
	localparam [1:0] SRV_IDLE = 2'd0, SRV_CMD = 2'd1, SRV_DATA = 2'd2, SRV_END = 2'd3;

	reg        srv_valid;
	reg [7:0]  srv_data;
	reg        srv_end;
	reg [1:0]  srv_state;
	reg [31:0] srv_addr;
	reg [9:0]  srv_cnt;
	integer    srv_lat;

	assign sd_sec_read_data_valid = srv_valid;
	assign sd_sec_read_end        = srv_end;
	assign sd_sec_read_data       = srv_data;

	// ---- 文件内样本: 前 288 个样本(576 字节)为 0(静音前奏), 之后非零 ----
	//   file_off = 文件内字节偏移(0 起, 跨扇区连续)
	function [7:0] file_byte_at;
		input [31:0] file_off;
		integer idx;
		reg [15:0] sval;
		begin
			idx = file_off >> 1;   // 样本号
			if(idx < 288) sval = 16'd0;
			else          sval = 16'sd2000 + (idx & 16'h3FFF);
			file_byte_at = file_off[0] ? sval[15:8] : sval[7:0];
		end
	endfunction

	// 扇区字节: 区分 FAT 扇区与数据扇区
	function [7:0] sec_byte_at;
		input [31:0] lba;     // 绝对扇区号
		input integer off;    // 0..511 扇区内字节偏移
		integer fat_idx;      // FAT 表项序号 = 簇号
		integer clu;          // 数据区对应的簇号
		reg [31:0] fatval;
		begin
			// ---- FAT 表扇区: 每个 FAT 项 4 字节(FAT32), 值 = 下一簇号或 EOC ----
			//   fat_idx = (扇区内字节偏移 / 4)。簇 100 起单链: 100→101→...→EOC。
			if(lba >= FAT_START && lba < DATA_START) begin
				fat_idx = (lba - FAT_START) * 128 + (off >> 2);   // 每扇区 128 个 FAT 项
				if(fat_idx == WAV_CLUSTER)
					fatval = 32'h0FFFFFFF;   // 单簇文件: 首簇即末簇(EOC)
				else
					fatval = 32'd0;          // 空闲簇
				// 小端输出 4 字节 FAT 项
				case(off[1:0])
					2'd0: sec_byte_at = fatval[7:0];
					2'd1: sec_byte_at = fatval[15:8];
					2'd2: sec_byte_at = fatval[23:16];
					default: sec_byte_at = fatval[31:24];
				endcase
			end
			// ---- 数据区扇区: 文件字节 ----
			else begin
				// 数据区扇区 LBA = DATA_START + (clu-2)*SPC + 扇区内偏移
				//   → 反解簇号: clu = (lba - DATA_START)/SPC + 2
				clu = (lba - DATA_START) / SPC + 32'd2;
				// 只有簇 100(文件首簇)有数据, 其余填 0。
				// 文件内字节偏移 = (lba - 数据区起始扇区)*512 + off。
				if(clu == WAV_CLUSTER)
					sec_byte_at = file_byte_at((lba - (DATA_START + (WAV_CLUSTER - 2) * SPC)) * 512 + off);
				else
					sec_byte_at = 8'd0;
			end
		end
	endfunction

	initial begin
		srv_valid = 0; srv_data = 8'd0; srv_end = 0;
		srv_state = SRV_IDLE; srv_addr = 32'd0; srv_cnt = 10'd0; srv_lat = 0;
	end

	always @(posedge sd_clk or posedge rst_sd) begin
		if(rst_sd) begin
			srv_state <= SRV_IDLE; srv_valid <= 1'b0; srv_end <= 1'b0;
			srv_data <= 8'd0; srv_cnt <= 10'd0; srv_lat <= 0;
		end else begin
			srv_valid <= 1'b0;
			srv_end   <= 1'b0;
			case(srv_state)
			SRV_IDLE: if(sd_sec_read) begin
				$display("[srv-req] t=%0t latch lba=%0d", $time, sd_sec_read_addr);
				srv_addr <= sd_sec_read_addr;
				srv_lat  <= CMD_LAT;
				srv_state<= SRV_CMD;
			end
			SRV_CMD: begin
				if(srv_lat == 0) begin
					srv_cnt   <= 10'd0;
					srv_state <= SRV_DATA;
				end else srv_lat <= srv_lat - 1;
			end
			SRV_DATA: begin
				srv_valid <= 1'b1;
				srv_data  <= sec_byte_at(srv_addr, srv_cnt);
				if(srv_cnt == 10'd511) srv_state <= SRV_END;
				else                   srv_cnt   <= srv_cnt + 1'b1;
			end
			SRV_END: begin
				srv_end   <= 1'b1;
				srv_state <= SRV_IDLE;
			end
			default: srv_state <= SRV_IDLE;
			endcase
		end
	end

	//====================================================================
	// 观测
	//====================================================================
	integer t_primed = -1, t_wavnz = -1, t_pcmnz = -1;
	integer n_wavnz = 0, n_pcmnz = 0, n_launch = 0, n_wready = 0;
	integer n_ticks = 0, n_pcmvalid = 0;
	integer n_tick_and_ready = 0, n_adv_cond = 0;
	reg     d_primed = 0, d_out_nz = 0, d_pcm_nz = 0, d_send = 0, d_bytes = 0;

	always @(posedge video_clk) begin
		if(rst_n_vid) begin
			if(wav_primed && t_primed < 0) t_primed = $time;
			if(wav_left != 16'sd0) begin n_wavnz = n_wavnz + 1; if(t_wavnz < 0) t_wavnz = $time; end
			if(audio_left != 16'sd0) begin n_pcmnz = n_pcmnz + 1; if(t_pcmnz < 0) t_pcmnz = $time; end
			if(media_ready) n_launch = n_launch + 1;
			if(wav_ready)   n_wready = n_wready + 1;
			if(audio_rate_tick) n_ticks = n_ticks + 1;
			if(audio_pcm_valid) n_pcmvalid = n_pcmvalid + 1;
			if(audio_rate_tick && wav_ready) n_tick_and_ready = n_tick_and_ready + 1;
			// 播放器内部实际推进条件
			if(audio_rate_tick && wav_ready && u_wav_player.primed_r) n_adv_cond = n_adv_cond + 1;
			if(wav_primed) d_primed = 1'b1;
			if(wav_left != 16'sd0) d_out_nz = 1'b1;
			if(audio_left != 16'sd0) d_pcm_nz = 1'b1;
		end
	end

	// 诊断: 记录播放器把样本写到 buffer 的哪几个关键下标
	always @(posedge sd_clk) begin
		if(!rst_sd && wav_file_valid && u_wav_player.lo_pending &&
		   (u_wav_player.wr_ptr==11'd0 || u_wav_player.wr_ptr==11'd1 ||
		    u_wav_player.wr_ptr==11'd256 || u_wav_player.wr_ptr==11'd288 ||
		    u_wav_player.wr_ptr==11'd512))
			$display("[wr] t=%0t wr_ptr=%0d sample=%0d",
				$time, u_wav_player.wr_ptr, {wav_file_byte, u_wav_player.lo_byte});
	end

	// 诊断: 状态变化追踪(sd_sec_read / streamer state / 写状态机 / 服务器)
	reg        tr_sdread;
	reg [3:0]  tr_strst, tr_wstate;
	reg [1:0]  tr_srv;
	integer    tr_n = 0;
	initial begin tr_sdread = 0; tr_strst = 4'd0; tr_wstate = 2'd0; tr_srv = 2'd0; end
	always @(posedge sd_clk) begin
		if(!rst_sd && tr_n < 120 &&
		   (sd_sec_read !== tr_sdread || u_streamer.state !== tr_strst ||
		    u_wav_player.wstate !== tr_wstate ||
		    srv_state !== tr_srv)) begin
			$display("[tr] t=%0t sd_read=%b strst=%0d wstate=%0d srvst=%0d srv_cnt=%0d wr_ptr=%0d",
				$time, sd_sec_read, u_streamer.state, u_wav_player.wstate,
				srv_state, srv_cnt, u_wav_player.wr_ptr);
			tr_sdread <= sd_sec_read; tr_strst <= u_streamer.state;
			tr_wstate <= u_wav_player.wstate;
			tr_srv    <= srv_state;
			tr_n      <= tr_n + 1;
		end
	end

	// 诊断: 消费到第 290 个样本时, 直接看 buffer 内容与交付值
	reg chk288 = 0;
	integer kk, first_nz;
	always @(posedge video_clk) begin
		if(rst_n_vid && !chk288 && (u_wav_player.sample_counter == 32'd290)) begin
			chk288 <= 1'b1;
			$display("[chk] t=%0t cnt=%0d rd_ptr=%0d rd_addr=%0d rd_q=%0d wav_left=%0d wr_ptr=%0d",
				$time, u_wav_player.sample_counter, u_wav_player.rd_ptr,
				u_wav_player.rd_addr, u_wav_player.rd_q, wav_left, u_wav_player.wr_ptr);
			first_nz = -1;
			for(kk = 0; kk < 1200; kk = kk + 1)
				if(first_nz < 0 && u_wav_player.buffer[kk] !== 16'd0) first_nz = kk;
			$display("[chk] buffer 首个非零下标 = %0d (期望 288)", first_nz);
			$display("[chk] buffer[286..291] = %0d %0d %0d %0d %0d %0d",
				u_wav_player.buffer[286], u_wav_player.buffer[287], u_wav_player.buffer[288],
				u_wav_player.buffer[289], u_wav_player.buffer[290], u_wav_player.buffer[291]);
		end
	end

	// 诊断: primed 之后, 对齐到一个 48kHz tick 抓 15 拍
	integer dcnt;
	initial begin
		wait(rst_n_vid);
		wait(wav_primed);
		wait(audio_rate_tick);          // 当前正处于 tick=1 的时刻
		$display("---- [diag] 对齐 tick 抓 15 拍 ----");
		for(dcnt = 0; dcnt < 15; dcnt = dcnt + 1) begin
			$display("[diag] t=%0t tick=%b wav_ready=%b mux_busy=%b mux_sv=%b mux_bit=%0d launch=%b zero_valid=%b media_valid=%b rd_ptr=%0d",
				$time, audio_rate_tick, wav_ready, u_audio_mux.busy, u_audio_mux.sample_valid,
				u_audio_mux.bit_index, u_audio_mux.launch, zero_valid, media_valid, u_wav_player.rd_ptr);
			@(posedge video_clk);
		end
		$display("---- [diag] end ----");
	end


	always @(posedge sd_clk) begin
		if(!rst_sd) begin
			if(sd_sec_read_end)  d_send = 1'b1;      // 粘滞: 曾收到扇区结束
			if(wav_file_valid)   d_bytes = 1'b1;     // 粘滞: 曾收到数据字节
		end
	end

	//====================================================================
	// 主流程
	//====================================================================
	initial begin
		$display("=== tb_audio_chain_e2e start ===");
		sel_wav = 1'b0;
		rst_n_vid = 1'b0; rst_sd = 1'b1;
		repeat(10) @(posedge sd_clk);
		repeat(10) @(posedge video_clk);
		rst_sd    = 1'b0;
		rst_n_vid = 1'b1;
		repeat(10) @(posedge video_clk);

		// 进入迎新场景: 选中 WAV
		sel_wav = 1'b1;

		// 跑 12 ms: 起播 + 288 个静音样本 ≈ 6 ms, 之后出现非零
		#12_000_000;

		$display("----------------------------------------------------");
		$display("primed 首次=1         : t=%0d ns  (wav_primed=%b)", t_primed, wav_primed);
		$display("wav_left 首次非零     : t=%0d ns  (nonzero cycles=%0d)", t_wavnz, n_wavnz);
		$display("audio_left 首次非零   : t=%0d ns  (nonzero cycles=%0d)", t_pcmnz, n_pcmnz);
		$display("media_ready 脉冲数    : %0d", n_launch);
		$display("wav_ready 脉冲数      : %0d", n_wready);
		$display("48kHz tick 数         : %0d", n_ticks);
		$display("tick && wav_ready 同拍: %0d  <== 必须 >0 播放器才会推进", n_tick_and_ready);
		$display("播放器推进条件命中    : %0d", n_adv_cond);
		$display("audio_pcm_valid 拍数  : %0d", n_pcmvalid);
		$display("mux accepted_pairs    : %0d", mux_pairs);
		$display("player sample_counter : %0d", u_wav_player.sample_counter);
		$display("player wr_ptr/rd_ptr  : %0d / %0d", u_wav_player.wr_ptr, u_wav_player.rd_ptr);
		$display("player wstate         : %0d", u_wav_player.wstate);
		$display("level_rd / level_wr   : %0d / %0d", u_wav_player.level_rd, u_wav_player.level_wr);
		$display("streamer state        : %0d", u_streamer.state);
		$display("----------------------------------------------------");
		$display("调试字节 D[7:0]={primed1,pcm_nz,out_nz,send,bytes,req,sel_wav,primed}");
		$display("  = {%b,%b,%b,%b,%b,%b,%b,%b}",
			d_primed, d_pcm_nz, d_out_nz, d_send, d_bytes,
			wav_file_start, sel_wav, wav_primed);
		$display("----------------------------------------------------");
		if(t_pcmnz >= 0) $display("RESULT: PASS  (末端 PCM 出现非零 → 音频链在仿真中打通)");
		else             $display("RESULT: FAIL  (末端 PCM 恒 0 → 复现了板上故障, 断点在上述各级)");
		$display("=== tb_audio_chain_e2e end ===");
		$finish;
	end

	// 心跳(便于观察仿真进度/是否卡死)
	integer hb;
	initial begin
		for(hb = 0; hb < 40; hb = hb + 1) begin
			#1_000_000;
			$display("[hb t=%0t ns] primed=%b wav_left=%0d audio_left=%0d rd_ptr=%0d lvl_rd=%0d srv=%0d req=%b",
				$time, wav_primed, wav_left, audio_left,
				u_wav_player.rd_ptr, u_wav_player.level_rd, srv_state, sd_sec_read);
			$fflush;
		end
	end

	// 看门狗
	initial begin
		#60_000_000;
		$display("[WATCHDOG] 超时");
		$display("RESULT: FAIL");
		$finish;
	end
endmodule
