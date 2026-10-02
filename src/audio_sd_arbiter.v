`timescale 1ns/1ps
//====================================================================
// 模块名 : audio_sd_arbiter.v —— SD 扇区读总线仲裁(音频优先, 逐扇区轮转)
//
// 背景(2026-09-26 迎新场景背景音乐改造):
//   本工程 SD 控制器 sd_card_top 全片只例化一次(在 sd_card_bmp 内), 板上
//   SD_nCS/SD_DCLK/SD_MOSI/SD_MISO 由它独占, 绝不能再例化第二个 SPI master。
//   改造前是"开机会议配置串行读完 → 彻底放行 BMP"的静态方案(bmp_go 门控),
//   两个使用者**从不同时发请求**, 因此 sd_sec_read_data_valid / end 可以
//   无脑广播给双方(各自状态机自己过滤)。
//
//   新增 TF 卡 WAV 音乐流后, "迎新场景照片轮播 + 背景音乐"必须**并发**占用
//   同一条 SPI 总线, 广播不再安全 —— 两个主设备会同时吞掉同一个扇区的
//   512 字节。故引入本仲裁器: 逐扇区授权, 总线数据/结束只回给授权方。
//
// 仲裁策略: 音频(B)严格优先, 但以"一个扇区"为最小不可抢占单位。
//   · owner 从"首次授权"一直保持到 sd_sec_read_end(扇区读完)才清 NONE;
//     期间对方请求到达也不切换 → sd_sec_read_addr 在整个扇区读周期内稳定。
//     (sd_card_sec_read_write 在 S_WAIT_READ_WRITE 那一拍把地址锁进
//      sec_addr, 之后就与 sd_sec_read_addr 无关, 但保持稳定最稳。)
//   · 音频只在其循环缓冲低于水位时才发请求(见 wav_stream_player 的
//     HIGH_WATER), 因此音频不会长期霸占总线; 图片通路拿到剩余带宽。
//   · 数值可行性(48 kHz/16bit/mono = 96 KB/s):
//       音频 ≈ 188 扇区/s, 单扇区约 0.25 ms → 占空比约 5%;
//       图片单张 ≈ 1800 扇区 ≈ 0.45 s; 交错后图片读取只延长约 5%,
//       而 8 KB 缓冲(≈85 ms, 稳态水位 ≈64 ms)远大于单扇区等待
//       (≤0.25 ms + 一个仲裁边界), 不会下溢。
//   · 反向安全: 音频若一直发请求, 总线会持续给它(严格优先), 但缓冲一满
//     请求即撤 → 图片不会被饿死; 不存在"音频卡死拖死图片"的路径。
//
// 时序: 全部工作在 sd_card_clk(100 MHz) 域 —— 上一版唯一时序紧张域。
//   本模块新增逻辑只有 2 位 owner 比较器 + 地址多路选择, 全部是扇区级
//   状态(每 0.25 ms 才动一次), 没有长组合链。
//
// 端口约定:
//   主 A = 图片轮播(bmp_read_auto) 与 会议配置(meeting_sd_rd) 的合并请求;
//          两者在时间上互不重叠(meeting 开机先独占, bmp_go 门控), 故共用
//          a_data_valid / a_end 广播是安全的 —— 与改造前行为一致。
//   主 B = WAV 音频流(wav_stream_player 写侧状态机)。
//====================================================================
module audio_sd_arbiter(
	input  wire        clk,
	input  wire        rst,
	// ---- SD 控制器侧(唯一物理主设备) ----
	output wire        sd_sec_read,        // 扇区读请求(电平, 保持整个扇区)
	output wire [31:0] sd_sec_read_addr,   // 扇区地址(组合, 授权当拍必须稳定)
	input  wire        sd_sec_read_data_valid, // 字节有效(仅路由给授权方)
	input  wire        sd_sec_read_end,    // 扇区读完(单拍, 参见 S_READ_END)
	// ---- 主 A: 图片轮播 / 会议配置 ----
	input  wire        a_req,
	input  wire [31:0] a_addr,
	output wire        a_data_valid,
	output wire        a_end,
	// ---- 主 B: 音频流(最高优先级) ----
	input  wire        b_req,
	input  wire [31:0] b_addr,
	output wire        b_data_valid,
	output wire        b_end
);
	localparam [1:0] OWN_NONE = 2'd0;
	localparam [1:0] OWN_A    = 2'd1;   // 图片/会议
	localparam [1:0] OWN_B    = 2'd2;   // 音频(优先)

	reg  [1:0] owner;                               // 当前占用方
	// 音频优先: 音频无请求时才轮到图片
	wire [1:0] want = b_req ? OWN_B : (a_req ? OWN_A : OWN_NONE);
	// 已授权则保持不变(扇区不可抢占); 空闲则取当前仲裁结果
	wire [1:0] act  = (owner == OWN_NONE) ? want : owner;

	always @(posedge clk or posedge rst) begin
		if(rst) owner <= OWN_NONE;
		else if(sd_sec_read_end)              owner <= OWN_NONE; // 扇区读完才释放
		else if(owner == OWN_NONE && want != OWN_NONE) owner <= want;
	end

	// 请求与地址都用 act 组合驱动: 授权当拍 sd_sec_read 拉高, 控制器在同
	//   一拍时钟沿把 sd_sec_read_addr 锁进 sec_addr, 因此地址不能打拍。
	assign sd_sec_read = (act != OWN_NONE);
	assign sd_sec_read_addr = (act == OWN_B) ? b_addr :
	                          (act == OWN_A) ? a_addr : 32'd0;

	// 数据/结束只回授权方(改造前是广播)
	assign a_data_valid = (owner == OWN_A) & sd_sec_read_data_valid;
	assign a_end        = (owner == OWN_A) & sd_sec_read_end;
	assign b_data_valid = (owner == OWN_B) & sd_sec_read_data_valid;
	assign b_end        = (owner == OWN_B) & sd_sec_read_end;
endmodule
