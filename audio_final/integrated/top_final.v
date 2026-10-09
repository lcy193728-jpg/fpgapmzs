// Generated from main 6586b66447375c1c4dfc9568b17a79df889cfbae; audio output addition only.
//====================================================================
// 重要: 阶段2b 三个新模块以 `include 直接并入本文件(与 top.v 同目录,
//   同 color_bar.v 包含 video_define.v 的既有用法)。原因: 工程文件
//   pic_sdram.al 在 TD 打开/关闭过程中会回写覆盖外部手工登记的源码条目,
//   曾两度把 osd_welcome/display_adjust/bri_key_ctrl 从综合列表删除,
//   导致 HDL-8007 black box。改用 include 后模块定义跟随 top.v 必然
//   参与综合, 不再依赖 .al 维护。※ 请勿再通过 GUI "Add to Project"
//   重复添加这些 .v(会造成模块重复定义); 若工程树中已存在请移除。
//   (osd_scene/quiz_ctrl 为阶段2d 新增的场景层, 同法并入)
//   (bmp_scale 为双线性插值缩放引擎, 串在 sd_card_bmp→frame_read_write 写通路)
//====================================================================
`include "../../src/osd_welcome.v"
`include "../../src/display_adjust.v"
`include "../../src/ui_key_ctrl.v"
`include "../../src/osd_scene.v"
`include "../../src/quiz_ctrl.v"
`include "../../src/quiz_scene_ctrl.v"
`include "../../src/bmp_scale.v"
`include "../../src/reset_sync.v"
`include "../../src/sync_2ff.v"
`include "../../src/emergency_alarm_ctrl.v"
`include "../../src/emergency_font_rom.v"
`include "../../src/emergency_multi_overlay.v"
// 会议场景已于 2026-10-07 整体移除(用户决策: 丢会议主攻抢答场景):
//   删除 meeting_cfg/ctrl/fmt/osd/glyph_rom/sd_rd 六个文件与 meeting_text.vh,
//   释放 ≈1764 LUT / ≈863 REG / 4 块 BRAM9K / 2 块 BRAM32K。
//   拨码位置 2(SW2, 原会议)保留不重编号 → 走菜单画面(见下方 case)。
`include "../rtl/audio_feature_events.v"
`include "../rtl/scene_audio_final.v"
`include "../rtl/audio_viz_overlay.v"
// 按场景在"片内 DDS 合成音"与"TF 卡 WAV 背景音乐"之间切源(2026-09-26 新增):
//   本体只做组合多路选择, 例化在下方音频链里(scene_audio_final → 本模块 → audio_src_mux)。
`include "../rtl/audio_src_sel.v"

module top(
	input                       clk,
	input                       key1,       //KEY1(A2)：场景内功能模式循环 0图片/切图→1亮度→2分辨率
	input                       key2,       //KEY2(B2)：当前模式参数 减
	input                       key3,       //KEY3(B1)：当前模式参数 加
	input                       key4,       //KEY4(C1)：★迎新模式0 = 自动轮播↔手动单张 切换
	input [3:0]                 sw,         //板载拨码直接选场景: sw[0]=SW1场景0迎新
                                            //  sw[1]=SW2场景1预留(原会议, v11 起走菜单画面)
                                            //  sw[2]=SW3场景2抢答
                                            //  sw[3]=SW4场景3应急(应急最高 + 无应急时先触发先锁定)
                                            //  (引脚/极性见 top.adc; 四个全关=首页菜单态)
	// ---- 抢答台(2×40Pin 外扩口, 上拉/按下低; 引脚见 top.adc) ----
	input [3:0]                 quiz_btn,   //4 路选手抢答键(屏显 1~4 号)
	input                       quiz_start, //★【白色按钮】开始抢答(仅"待开始"态有效)
	input                       quiz_reset, //★【黑色按钮】播报下一题(仅"已锁定/超时"态有效)
	output [7:0]                seg_sel,    //8 位数码管位选
	output [7:0]                seg_data,	
    
    output			vga_out_hs,
    output			vga_out_vs,
//    output			vga_out_de,
    output	[11:0]	vga_data,
    //hdmi接口                         
	//HDMI
	output			HDMI_CLK_P,
	output			HDMI_D2_P,
	output			HDMI_D1_P,
	output			HDMI_D0_P,
	output                      sd_ncs,            //SD card chip select (SPI mode)
	output                      sd_dclk,           //SD card clock
	output                      sd_mosi,           //SD card controller data output
	input                       sd_miso           //SD card controller data input
);

//============================================================
// 上电自动复位(POR): 取消物理复位引脚(rst_n), 配置完成后由计数器产生
//   约 10ms 低电平复位, 保证 PLL/SDRAM/HDMI 上电稳定后再放行。
//   EG4 触发器上电由 GSR 清零 → por_cnt 从 0 起计, MSB 置 1 前保持复位。
//============================================================
reg  [19:0] por_cnt;
always @(posedge clk) begin
    if (!por_cnt[19])
        por_cnt <= por_cnt + 20'd1;   // 计满即停(524288 拍 ≈ 10.5ms@50MHz)
end
wire rst_n = por_cnt[19];              // POR 完成(仅表示上电已过 ≈10.5ms)

//------------------------------------------------------------
// 复位源汇总(小鹅通第六讲规范): POR 完成 & 全部 PLL 已锁定
//   原设计只用 por_cnt[19] 放行, 与 PLL 是否锁定无关 —— 若 PLL 因器件/
//   温度差异锁定较慢, 系统会在时钟未稳时就开始跑, 属"上电偶发异常"的
//   来源之一。现改为两条件相与(低有效):
//     ext_rst_n=0 → 全系统保持复位;
//     ext_rst_n=1 → 各时钟域由 reset_sync 同步释放(见 PLL 之后的例化)。
//------------------------------------------------------------
wire sys_pll_locked;
wire video_pll_locked;
wire ext_rst_n = rst_n & sys_pll_locked & video_pll_locked;

// 分域同步释放复位(低有效), 由 PLL 之后的 reset_sync 例化产生:
wire rst_n_clk;   // clk(50MHz 输入域)      : seg_scan
wire rst_n_sd;    // sd_card_clk(100MHz) 域 : ui_key_ctrl/scene_control/quiz_ctrl/
                  //                          sd_card_bmp/bmp_scale/frame_read_write 写侧
wire rst_n_mem;   // ext_mem_clk(125MHz) 域 : frame_read_write 存储侧 / sdram
wire rst_n_vid;   // video_clk(25MHz) 域    : 视频时序 / OSD 链 / hdmi_tx

parameter MEM_DATA_BITS         = 32  ;            //external memory user interface data width
parameter ADDR_BITS             = 21  ;            //external memory user interface address width
parameter BUSRT_BITS            = 10  ;            //external memory user interface burst width

//--------------------------------------------------------------
// 场景素材定位: 【FAT32 文件名寻址】(2026-10-07 v11 改造)
//
//   改造前 = 卡内扇区区间硬编码(四组 Z_* 常量)。缺点: 换卡/重排素材/
//     重新格式化都必须重跑 tools/find_bmp.py 重算扇区并重建位流;
//     --base 口径错一次(本卡隐藏扇区 64 而非 2048)就整体花屏。
//
//   改造后 = 开机由 fat32_lookup 读卡上的 MBR → BPB → 根目录, 按【文件名
//     前缀】把场景素材的物理位置查出来, 缓存成段表; 场景切换只是换一张
//     段表, 不再有任何扇区常量。换素材只需往卡根目录拷文件:
//       迎新区  WEL1.BMP … WEL8.BMP   (张数动态, 扫到几张算几张)
//       抢答区  QUIZ1.BMP … QUIZ8.BMP
//       应急区  ALM1.BMP  … ALM8.BMP
//     菜单(拨码全关)与预留位(拨码 SW2)复用迎新区素材作底图。
//
//   ⚠ 约束(8.3 短名, FAT32 长名不支持): 文件名必须【大写 8.3 短名】,
//     即 Windows 拷贝时不能生成 WEL1~1.BMP 这类自动编号名。
//   ⚠ BMP 规格不变: 640×480(或 320×240 / 1024×768)×24bit、非压缩、
//     正高度、放根目录。多分辨率轮播能力原样保留。
//   ※ bmp_read_auto 一行未改: 它仍只认 zone_start/zone_wrap/zone_max_img
//     三个数, 只是这三个数从"RTL 常量"改成了"FAT32 查表结果"。
//--------------------------------------------------------------
// 场景选择码(交给 sd_card_bmp 内的 FAT32 寻址层):
//   0=菜单 / 1=迎新 / 2=预留(原会议, 走菜单画面) / 3=抢答 / 4=应急
//   —— 就是 latch_sw, 下面直接透传, 不再有任何扇区常量。

//--------------------------------------------------------------
// TF 卡背景音乐素材区(裸 PCM: 48 kHz/16 bit 有符号/小端/单声道, 无文件头):
//   由 PC 端工具生成并整段写到卡的固定扇区上(不放进文件系统, 扇区天然连续):
//     python audio_final/tools/make_audio_corpus.py 你的歌.wav --name wel_music
//   工具会打印下面两行 localparam 与写卡命令, 直接把输出盖到此处即可。
//   素材区必须避开文件系统数据区(FAT32 会把音乐区当作未分配簇, 拷大文件
//     时可能被分配到那里而覆盖音乐; 2026-10-07 起图片走 FAT32 文件名寻址,
//     图片本身也在数据区内, 故音乐区要留得足够靠后)。
//
//   WAV_SECTORS = 0 表示"尚未准备音乐": 此时迎新技术场景**自动退回片内
//     DDS 合成音**(与改造前完全一致, 不会静音); 填上真实扇区数后, 迎新
//     场景即刻改播 TF 卡上的歌(见下方 sel_wav)。其余场景(抢答/应急)
//     一律保持片内合成音不变。
//--------------------------------------------------------------
localparam [31:0] WAV_START_LBA = 32'd300000;   // 音乐区起始扇区
//   素材: "Carefree" Kevin MacLeod (incompetech.com), CC BY 4.0, 3:25, 205.14 s
//    由 tools/make_audio_corpus.py 生成, 裸 PCM 18.78 MB = 38464 扇区
//    sha256 = 0d463ec052a46c5d16e125d348aa64301ec9c394b8b5810b75ef02712d1d5222
localparam [31:0] WAV_SECTORS   = 32'd38464;    // 音乐区总扇区数(0=未准备, 走 DDS)

    wire			vga_out_de;

wire Sdr_init_done;
wire Sdr_init_ref_vld;
wire Sdr_busy;


wire                            read_req;
wire                            read_req_ack;
wire                            read_en;
wire                            write_en;
wire                            write_req;
wire                            write_req_ack;
wire                            sd_card_clk;       //SD card controller clock
wire                            ext_mem_clk;       //external memory clock
wire                            ext_mem_clk_sft;

wire                            video_clk;         //video pixel clock
wire							hdmi_5x_clk;
wire                            hs;
wire                            vs;
wire 							de;
wire[23:0]                      vout_data;
wire[3:0]                       state_code;

wire                            slideshow_en;  // 底层轮播使能(应急=0冻结画面)，scene_control→bmp_read_auto
wire                            emergency;     // 应急锁存标志(1=应急中，驱动 osd_menu 顶部红条)
wire [1:0]                      scene_id;      // 生效场景码(0迎新 1预留[原会议] 2抢答 3应急)，供后续功能层/OSD
wire                            menu_active;   // 菜单态标志(1=SW1..3 无锁且非应急 → 显示四场景 OSD 菜单)
wire [2:0]                      latch_sw;      // 内容源/素材分区号(0菜单 1迎新 2预留[原会议] 3抢答 4应急)
wire                            scene_change_pulse; // 菜单↔场景/场景间切换事件 → 触发 bmp 分区重载

//场景素材定位(2026-10-07 v11 改造):
//   顶层不再输出任何扇区常量, 只给"选哪个场景"(zone_sel_l)。
//   sd_card_bmp 内的 FAT32 寻址层把该场景的素材段表查出来, 组合成
//   zone_start/zone_wrap/zone_max_img 再喂 bmp_read_auto;
//   zone_load 脉冲由 sd_card_bmp 内部在"段表就绪"或"场景切换"时产生。
//   (段表未就绪时不能脉冲 —— bmp_read_auto 在 zone_load 当拍就锁存这三个数)
wire [2:0]                      zone_sel_l;    // 0菜单 1迎新 2预留 3抢答 4应急
wire                            zone_load_l;   // 场景切换请求(=scene_change_pulse)
wire                            zone_tbl_ready;// FAT32 段表已就绪(仅供观测/上板核对)
wire                            zone_err_l;    // FAT32 未匹配到素材(已回退 10-4 兜底常量)
                                               //  ※ 上板观测用: 1=卡上没找到 WEL/QUIZ/ALM
                                               //    前缀的 8.3 短名(例如没改名 / 生成了
                                               //    WEL1~1.BMP 长名残留) → 底层按 10-4
                                               //    的固定扇区扫描, 画面等同于改造前。

assign zone_sel_l  = latch_sw;
assign zone_load_l = scene_change_pulse;

//OSD 叠加底座(插入 video_delay → hdmi_tx 之间)相关信号
wire                            osd_hs;        // osd_engine 输出同步
wire                            osd_vs;
wire                            osd_de;
wire [23:0]                     osd_data;      // OSD 仲裁后的像素
wire [11:0]                     px_x;          // 与 osd_data 对齐的像素坐标
wire [11:0]                     px_y;

//osd_menu 文字叠加引擎相关信号(输出送 osd_welcome → display_adjust → hdmi_tx)
wire                            menu_hs;       // osd_menu 输出同步/数据/坐标
wire                            menu_vs;
wire                            menu_de;
wire [23:0]                     menu_data;
wire [11:0]                     menu_px_x;
wire [11:0]                     menu_px_y;

//迎新场景 OSD(信息叠加)相关信号(输出送 display_adjust)
wire                            wl_hs;
wire                            wl_vs;
wire                            wl_de;
wire [23:0]                     wl_data;
wire [11:0]                     wl_px_x;
wire [11:0]                     wl_px_y;

//抢答/应急 场景 OSD(osd_scene)相关信号(v11: 会议已删; 输出送 emergency_multi_overlay)
wire                            sc_hs;
wire                            sc_vs;
wire                            sc_de;
wire [23:0]                     sc_data;
wire [11:0]                     sc_px_x;
wire [11:0]                     sc_px_y;
wire viz_hs,viz_vs,viz_de;
wire [23:0] viz_data;
wire [11:0] viz_px_x,viz_px_y;
wire audio_pcm_valid,audio_pcm_ready;
wire signed [15:0] audio_left,audio_right;

//场景层使能与抢答状态
//   (原 meeting_en 随会议场景一并删除; 场景层只剩抢答/应急)
wire                            quiz_en;       // 1=抢答场景(latch=3 且非应急)
wire                            alarm_en;      // 1=应急(最高优先级)
wire [1:0]                      alarm_type;    // 应急告警类型: 0火灾/1地震/2恶劣天气/3疏散(ui_key_ctrl 模式0 切换)
wire [3:0]                      alarm_mt, alarm_mo, alarm_st, alarm_so;
wire [1:0]                      q_state;       // 抢答状态 0等待 1抢答中 2锁定 3超时
wire [1:0]                      q_winner;      // 胜者 0..3(屏显 +1)
wire [3:0]                      q_t_tens;      // 倒计时 BCD 十位
wire [3:0]                      q_t_ones;      // 倒计时 BCD 个位
// ---- 2026-10-09 新增: 题号/结束/计分 ----
wire [3:0]                      q_idx;         // 当前题号 0..2
wire                            q_end;         // 1=已到结束页(钳位)
wire signed [7:0]               q_sc0, q_sc1, q_sc2, q_sc3;  // 4 队累计分
wire                            q_score_tog;   // 判分电平翻转(toggle)
wire [1:0]                      q_score_team;  // 本次被判队伍
wire                            ui_score_up;   // KEY3(计分档) 判对**电平**(2026-10-09c 由脉冲改电平)
wire                            ui_score_dn;   // KEY2(计分档) 判错**电平**
wire [7:0]                      run_hh;        // 系统运行时长 BCD 时
wire [7:0]                      run_mm;        // 分
wire [7:0]                      run_ss;        // 秒

//显示末级调节(亮度/淡入淡出/亮度条)相关信号(送 hdmi_tx)
wire                            fin_hs;
wire                            fin_vs;
wire                            fin_de;
wire [23:0]                     fin_data;

//迎新场景 OSD 使能: SW1 锁定且非应急(菜单态 latch=0, 其余场景/应急不叠)
wire                            welcome_en;
wire [3:0]                      bri_level;     // 亮度档 0..15(ui_key_ctrl 模式1可调)
wire                            img_busy;      // 底层 BMP 加载忙(sd_card_bmp 导出)
wire [7:0]                      img_no;        // 当前图序号(sd_card_bmp 导出, ui_key_ctrl 用)
wire [3:0]                      bmp_error;     // BMP 加载错误码(批次3: 0无/1头校验/2超时/3截断)
wire [1:0]                      img_res;       // 当前显示图源分辨率码(0=320x240 1=640x480
                                               //  2=1024x768 3=1280x960; 2026-10-02 分辨率字幕)
wire                            img_v2x;       // 当前图源高=240(只出 240 行, 交 bmp_scale 纵向 2×)

//人机交互(ui_key_ctrl)输出
wire [2:0]  ui_mode;        // 功能模式 0图片/1亮度/2缩放/3周期|对比度/4计分|对比度/5音量
                            //   ★各档功能随场景变(抢答 3=对比度; 迎新 4=对比度;
                            //     应急 2=对比度/3=音量, 见 ui_key_ctrl 内部重映射)
wire [3:0]  ui_vol;         // 音量档 0..15(模式5可调, 默认8=×1.0)
wire [3:0]  ui_con;         // ★对比度档 0..15(对比度档可调, 默认8=×1.0; 2026-10-09c)
wire [3:0]  res_level;      // 分辨率档 0..7
wire [7:0]  pic_param;      // 图片参数(0=轮播 / N=手动第N张)
wire [7:0]  ui_period_sec;  // 批次4 轮播间隔档(秒: 2/3/5/10/30)
wire [31:0] ui_period_cyc;  // 批次4 轮播间隔(时钟周期) → sd_card_bmp
wire        ui_disp_hold;   // 批次4 参数强显保持中(2 秒)
wire [2:0]  ui_disp_sel;    // 批次4 保持期显示的模式(产生动作时的 ui_mode)
wire        pic_manual;     // 1=手动单张(冻结自动轮播)
wire        key_next_pl;    // 手动"下一张"脉冲 → bmp_read_auto.key_trigger
wire        key_prev_pl;    // 手动"上一张"脉冲 → bmp_read_auto.key_prev
// ---- 抢答场景「绝对跳图」+ 中心扩散转场(2026-10-08) ----
wire        quiz_jump_req;  // 抢答锁定/复位 → 绝对跳图脉冲(→ sd_card_bmp.key_jump)
wire [3:0]  quiz_jump_idx;  // 目标图序号(0 基; 0=内容图, 1..4=队伍图)
wire        quiz_iris_trig; // 与跳图同拍的 iris 转场脉冲(→ display_adjust.iris_trig)
wire        quiz_locked;    // 1=抢答已锁定(显示队伍图态; 供观测/扩展)
wire [3:0]  quiz_jump_idx_l; // 组合给 sd_card_bmp: 菜单/非抢答场景强制 0(回内容图)
wire        res_chg_pl;     // 缩放档变化脉冲(1拍) → bmp 缩放引擎重载当前图
// v11: 四键消抖脉冲在顶层已无使用者(原会议链删除); 端口保留便于日后扩展
wire        key1_pl;
wire        key2_pl;
wire        key3_pl;
wire        key4_pl;
wire        bmp_slide_en;   // bmp 轮播使能 = 场景轮播使能 且 非手动单张

wire									  read_clk;

wire                            video_read_req;
wire                            video_read_req_ack;
wire                            video_read_en;
wire[31:0]                      video_read_data;
wire                            sd_card_write_en;      // sd_card_bmp 源像素写使能(接缩放引擎输入)
wire[31:0]                      sd_card_write_data;    // sd_card_bmp 源像素 {R,G,B,8'b0}
wire                            sd_card_write_req;
wire                            sd_card_write_req_ack;
wire                            bmp_scale_wr_en;       // 缩放引擎输出写使能 → frame_read_write.write_en
wire[31:0]                      bmp_scale_wr_data;     // 缩放引擎输出像素 → frame_read_write.write_data

wire App_rd_en;
wire [ADDR_BITS-1:0] App_rd_addr;
wire Sdr_rd_en;
wire [MEM_DATA_BITS - 1 : 0]Sdr_rd_dout;

wire App_wr_en;
wire [ADDR_BITS-1:0] App_wr_addr;
wire [MEM_DATA_BITS - 1 : 0]App_wr_din;
wire [3:0] App_wr_dm;


wire video_rd_en;
wire sd_card_wr_en;


wire Rd_state_end;

assign vga_out_hs = hs;
assign vga_out_vs = vs;
assign vga_out_de = de;
assign vga_data = {vout_data[23:20],vout_data[15:12],vout_data[7:4]};
//assign vga_out_r  = vout_data[15:11];
//assign vga_out_g  = vout_data[10:5];
//assign vga_out_b  = vout_data[4:0];
assign sdram_clk = ext_mem_clk;
//generate SD card controller clock and  SDRAM controller clock
//※ 第六讲规范: PLL 的 reset 接 ~rst_n(POR 期间保持复位), 并引出 locked
//   参与复位门控(见 ext_rst_n), 保证时钟稳定后才释放系统复位。
sys_pll sys_pll_m0(
	.refclk                     (clk),
	.clk0_out                   (sd_card_clk),
	.clk1_out                   (ext_mem_clk),
    .clk2_out					(ext_mem_clk_sft),
    .reset						(~rst_n),
    .locked						(sys_pll_locked)
    );
//generate video pixel clock	
video_pll video_pll_m0(
	.refclk                     (clk),
	.clk0_out                   (video_clk),
    .clk1_out					(hdmi_5x_clk),
    .reset						(~rst_n),
    .locked						(video_pll_locked)
	);

//------------------------------------------------------------
// 分域复位同步(小鹅通第六讲规范: 异步复位、同步释放)
//   每个时钟域各一个同步器, 两级触发器(释放延迟 2 拍)消除复位撤销时的
//   亚稳态; 释放沿与本域时钟对齐 → 域内触发器同拍退出复位, 避免"部分
//   先跑、部分还没跑"的启动竞态。
//   ※ ext_mem_clk_sft(180° 相移时钟)仅用于采样, 不挂同步器(同课程规范);
//   ※ hdmi_5x_clk 仅驱动 hdmi_tx 内部串化器, 模块只有一个 RST_N(video 域),
//     故不单独设同步器。
//------------------------------------------------------------
reset_sync u_rst_sync_clk (.clk(clk        ), .rst_n_async(ext_rst_n), .rst_n_sync(rst_n_clk));
reset_sync u_rst_sync_sd  (.clk(sd_card_clk), .rst_n_async(ext_rst_n), .rst_n_sync(rst_n_sd ));
reset_sync u_rst_sync_mem (.clk(ext_mem_clk), .rst_n_async(ext_rst_n), .rst_n_sync(rst_n_mem));
reset_sync u_rst_sync_vid (.clk(video_clk  ), .rst_n_async(ext_rst_n), .rst_n_sync(rst_n_vid));

//------------------------------------------------------------
// SDRAM 就绪状态跨域同步(小鹅通第六讲规范: 单比特电平跨域)
//   Sdr_init_done 由 ext_mem_clk(125MHz) 域产生, 这里要送到 sd_card_clk
//   (100MHz) 域作门控 → 两级同步消亚稳态(晚 2 拍, 对 ms 级启动无影响)。
//   用途: 实现课程启动序列"复位释放 → SDRAM 初始化 → SD 扫描/加载":
//         SDRAM 未就绪前, 保持 sd_card_bmp/bmp_scale 复位, 避免 SD 数据
//         在 SDRAM 未初始化时灌入写 FIFO(JTAG 热重配时该窗口真实存在)。
//------------------------------------------------------------
wire Sdr_init_done_sd;
sync_2ff u_sync_sdr_init (
    .clk        (sd_card_clk    ),
    .async_in   (Sdr_init_done  ),
    .sync_out   (Sdr_init_done_sd)
);
wire rst_n_sd_rdy = rst_n_sd & Sdr_init_done_sd;   // sd 域"可开始读写 SD"复位

//------------------------------------------------------------
// 写通路应答 write_req_ack 跨域同步(小鹅通第六讲规范)
//   write_req_ack 由 frame_fifo_write 在 ext_mem_clk(125MHz) 域产生, 原先直接
//   被 sd_card_clk(100MHz) 域的 bmp_read_auto 状态机当电平用 → 未同步的跨域
//   单比特电平。实测该路径 SWNS -1.199ns / 3 端点, 是真实亚稳态来源(不是伪违例)。
//   规范做法: 在域边界加两级同步器, 同步后的电平再交给 sd 域使用
//   (晚 2 拍 = 20ns; 写握手本身是 µs 级节奏, 无影响)。
//   ※ bmp_scale.frame_start 仍取原始 ack: 该模块内部已有 3 级同步(fs_s0/s1/s2)
//     并做边沿检测, 不能再叠加延迟, 否则帧起点脉冲与"清写 FIFO"错位。
//------------------------------------------------------------
wire write_req_ack_sd;
sync_2ff u_sync_wr_ack (
    .clk        (sd_card_clk            ),
    .async_in   (sd_card_write_req_ack  ),
    .sync_out   (write_req_ack_sd       )
);

	
//============================================================
// 蓝桥风格人机交互控制器(ui_key_ctrl, sd_card_clk 控制域):
//   KEY1(A2)=功能模式循环; ★2026-10-09f 起各场景序列不同:
//              · 迎新: 0图片→1亮度→2缩放→3周期→4对比度→5音量→0
//              · 抢答: 0图片→1亮度→2缩放→3对比度→4计分→5音量→0
//              · 应急: 0图片→1亮度→2对比度→3音量→0 (**无缩放、无周期档**)
//   KEY2(B2)=当前模式参数 减   KEY3(B1)=当前模式参数 加
//   KEY4(C1)=★2026-10-09e: **迎新场景模式0 = 自动轮播 ↔ 手动单张 切换**;
//              其余场景/模式无动作(v11 会议已删, 原"当前项重新计时"不再存在)
//   模式0(图片/切图): 默认自动轮播; KEY3=下一张 / KEY2=上一张(**只切图,
//                     不改自动/手动**); 按 KEY4 切换自动↔手动; 离开模式0 自动回自动轮播
//   模式1(亮度): KEY3 + / KEY2 -(0..15)  → display_adjust.bri_level
//   模式2(缩放): KEY3 + / KEY2 -(0..7)   → bmp_scale 双线性缩放
//                (档位变化输出 res_chg_pl → 重载当前图, 效果立即可见)
//                ★应急场景无此档(2 档 = 对比度)
//   模式3: 迎新 = 周期(KEY2/3 在 2/3/5/10/30 s 档间环绕, → bmp_read_auto.slide_interval)
//          抢答 = **对比度**(KEY2/3 调档 0..15, 默认 8)
//          应急 = **音量**
//   ★2026-10-09c/09e/09f 用户要求: 3/4 档功能随场景重映射 ——
//                · 迎新: 3 = 周期, 4 = **对比度**(默认 8)
//                · 抢答: 3 = **对比度**, 4 = **抢答计分**(KEY3 判对 / KEY2 判错)
//                · 应急: 2 = **对比度**, 3 = **音量**(无缩放/周期 → 整体前移)
//                模式号(数码管第5位)显示的就是用户约定的档位号。
//   模式5(音量): KEY3 + / KEY2 -(0..15)  → 音量末级增益 (下见"音量末级")
//                ★仅迎新/抢答场景能走到本档; 应急场景音量在 3 档。
////   ※ 按键只调参数, 与场景切换无关(场景由拨码决定, 见 scene_control)
//   ※ 所有场景共用同一套按键语义(全局统一样式)
//============================================================
// NOTE(2026-09-21): ui_key1~3 MUST be declared BEFORE the ui_key_ctrl
//   instantiation below. Declared after it, TD treats them as implicit nets
//   and ties them to 0 (HDL-7225 + SYN-5013 Undriven net), which silently
//   disables the alarm key gating (keys look permanently pressed).
// 2026-10-07 v11: 会议场景删除后, 按键"归口冻结"机制一并取消 ——
//   原 meeting_key_owner(latch_sw==2)驱动 control_lock, 现在恒 0:
//   四键在所有场景下语义统一(模式循环/参数增减/切图),
//   不再有"某个场景按键被接管"的特例。
//   (ui_key_ctrl 的 control_lock 端口保留, 便于日后需要时再加归口。)
wire ui_key1 = key1;
wire ui_key2 = key2;
wire ui_key3 = key3;

ui_key_ctrl #(
    .BRI_INIT            (4'd8)
) ui_key_ctrl_m0(
    .clk                 (sd_card_clk          ),
    .rst                 (~rst_n_sd            ),
    .key1                (ui_key1             ),
    .key2                (ui_key2             ),
    .key3                (ui_key3             ),
    .key4                (key4                ),
    .control_lock        (1'b0                ),  // v11: 不再有场景接管按键
    .alarm_scene         (alarm_en             ),  // 应急场景标志
    .alarm_type          (alarm_type           ),  // 应急模式0 输出的告警类型
    .img_no              (img_no               ),
    .scene_chg           (scene_change_pulse   ),
    .mode                (ui_mode              ),
    .bri_level           (bri_level            ),
    .vol_level           (ui_vol               ),
    .con_level           (ui_con               ),  // ★对比度档(2026-10-09c)
    .res_level           (res_level            ),
    .period_sec          (ui_period_sec        ),
    .period_cycles       (ui_period_cyc        ),
    .disp_hold           (ui_disp_hold         ),
    .disp_sel            (ui_disp_sel          ),
    .pic_manual          (pic_manual           ),
    .pic_param           (pic_param            ),
    .scene_id            (scene_id             ),  // ★场景号: 供 3/4 档功能重映射(2026-10-09c)
    .key_next_pl         (key_next_pl          ),
    .key_prev_pl         (key_prev_pl          ),
    .res_chg_pl          (res_chg_pl           ),
    .key1_pl             (key1_pl              ),
    .key2_pl             (key2_pl             ),  // 会议: 下一项
    .key3_pl             (key3_pl             ),  // 会议: 上一项
    .key4_pl             (key4_pl             ),  // 会议: 当前项重新计时
    .score_up_lv         (ui_score_up         ),  // 抢答计分档: 判对 +2(按住电平)
    .score_dn_lv         (ui_score_dn         )   // 抢答计分档: 判错 -1(按住电平)
);

//============================================================
// 场景选择/应急仲裁(sd_card_clk 控制域, 输入=板载拨码 sw):
//   SW1~SW4 直接选场景 0~3(多开时 SW4>SW3>SW2>SW1 优先, 应急最高);
//   场景号=3(应急) → emergency=1 最高优先级(内容源冻结不重载素材);
//   四个 SW 全关 => menu_active=1(上电默认菜单, 拨上任一 SW 即退出)
//   scene_change_pulse(内容源切换) → 顶层查表后 zone_load 重载 bmp 分区
//============================================================
scene_control scene_control_m0(
    .clk                 (sd_card_clk          ),
    .rst                 (~rst_n_sd            ),
    .sw_raw              (sw                   ),
    .menu_active         (menu_active          ),
    .latch_sw            (latch_sw             ),
    .emergency           (emergency            ),
    .scene_id            (scene_id             ),
    .slideshow_en        (slideshow_en         ),
    .scene_change_pulse  (scene_change_pulse   ),
    .emergency_pulse     (                     ),
    .alarm_clr_pulse     (                     ),
    .sec_tick            (                     ),
    .run_hh              (run_hh               ),
    .run_mm              (run_mm               ),
    .run_ss              (run_ss               )
);

//============================================================
// 场景层使能(抢答/应急):
//   抢答 = 内容源 latch=3 且非应急; 应急 = emergency(最高优先级)。
//   (会议场景已整体移除, 原 meeting_en 一并删除)
//   (latch_sw/menu_active/emergency 均已在 scene_control 内 sd 域寄存;
//    下游 osd_scene 内部两级同步, 无亚稳态风险)
//============================================================
assign quiz_en    = (latch_sw == 3'd3) & ~emergency;
assign alarm_en   = emergency;

// 应急持续时间计时器(2026-10-01: 四类告警选择已移到 ui_key_ctrl 模式0, 本模块只剩计时)。
//   进入应急清零, 1Hz BCD 秒/分累加, 输出送应急画面层「持续时间 MM:SS」。
emergency_alarm_ctrl #(.CLK_HZ(100_000_000)) u_alarm_type_ctrl(
    .clk(sd_card_clk), .rst(~rst_n_sd), .alarm_en(alarm_en),
    .elapsed_m_tens(alarm_mt), .elapsed_m_ones(alarm_mo),
    .elapsed_s_tens(alarm_st), .elapsed_s_ones(alarm_so)
);

//============================================================
// 抢答台控制(quiz_ctrl, sd_card_clk 域) —— 【2026-10-09 按用户新流程重写】
//   内部 5 态流程机: 待开始 → 抢答中 → 已锁定 → (下一题/结束页)
//                             └→ 超时 → (下一题/结束页)
//   · 4 路选手键 → 同步+20ms 消抖 → 并行仲裁(同拍多路按 1>2>3>4 优先,
//     锁存后忽略后续) → 锁存胜者;
//   · 【白色按钮 quiz_start】仅在"待开始"态有效 → 启动 10s BCD 倒计时;
//   · 【黑色按钮 quiz_reset】仅在"已锁定/超时"态有效 → 题号 +1;
//     最后一题之后再按 → 进结束页(q_end=1), 此后任何键都不再动作;
//   · 评委判定: 板载 KEY2/KEY3 在「抢答计分」模式档(= 数码管模式 4)
//     分别出 score_dn_pl(判错 -1) / score_up_pl(判对 +2), 仅"已锁定"态有效;
//     分数 4 队累计, 由 display_adjust 在屏幕右上角弹 1 秒分数板。
//   仅在抢答场景(quiz_en)生效, 离开场景自动回"待开始"+ 清分。
//   外扩引脚见 top.adc(quiz_btn[3:0]/quiz_start/quiz_reset)。
//============================================================
quiz_ctrl #(
    .TIME_SEC            (8'd10              ),
    .Q_TOTAL             (4'd3               )   // 卡上题目图张数(QUIZ1..3)
) quiz_ctrl_m0(
    .clk                 (sd_card_clk       ),
    .rst                 (~rst_n_sd         ),
    .en                  (quiz_en           ),
    .player_raw          (quiz_btn          ),
    .start_raw           (quiz_start        ),   // 白色外接按钮: 开始抢答
    .next_raw            (quiz_reset        ),   // 黑色外接按钮: 播报下一题
    .judge_up_lv         (ui_score_up       ),   // KEY3(计分档): 判对 +2(电平)
    .judge_dn_lv         (ui_score_dn       ),   // KEY2(计分档): 判错 -1(电平)
    .qstate              (q_state           ),
    .winner              (q_winner          ),
    .t_tens              (q_t_tens          ),
    .t_ones              (q_t_ones          ),
    .q_idx               (q_idx             ),
    .q_end               (q_end             ),
    .sc0                 (q_sc0             ),
    .sc1                 (q_sc1             ),
    .sc2                 (q_sc2             ),
    .sc3                 (q_sc3             ),
    .score_tog           (q_score_tog       ),
    .score_team          (q_score_team      )
);

//============================================================
// 抢答场景「锁定→队伍图」桥接(quiz_scene_ctrl, sd_card_clk 域):
//   监听 quiz_ctrl.qstate 边沿:
//     · 进入 Q_LOCK(锁定) → 跳到第 (winner+2) 张队伍图 + 中心扩散转场;
//     · 进入 Q_IDLE(含复位/离开场景) → 跳回内容图(QUIZ1) + 转场。
//   跳图经 bmp_read_auto.key_jump 的"按序号目标扫描"实现, 零额外查表。
//   转场脉冲 iris_trig 送 display_adjust(video_clk 域, 内部两级同步)。
//============================================================
quiz_scene_ctrl quiz_scene_ctrl_m0(
    .clk                 (sd_card_clk       ),
    .rst                 (~rst_n_sd         ),
    .en                  (quiz_en           ),
    .qstate              (q_state           ),
    .winner              (q_winner          ),
    .q_idx               (q_idx             ),
    .q_end               (q_end             ),
    .jump_req            (quiz_jump_req     ),
    .jump_idx            (quiz_jump_idx     ),
    .iris_trig           (quiz_iris_trig    ),
    .locked              (quiz_locked       )
);

//============================================================
// 抢答跳图场景门控: 仅 zone_sel==3(抢答) 时把跳图请求转发给 sd_card_bmp;
//   其他场景/菜单下屏蔽脉冲与索引, 避免被抢答模块残留信号干扰。
//============================================================
wire        quiz_zone     = (zone_sel_l == 3'd3);
wire        quiz_jump_fwd = quiz_jump_req & quiz_zone;
assign      quiz_jump_idx_l = quiz_zone ? quiz_jump_idx : 4'd0;

//============================================================
// 中心扩散(iris)转场触发(sd_card_clk 域, toggle 电平) —— 【2026-10-08 改】
//   ★改动: 由"两个来源合并"改为"只保留抢答一路"。
//     原先 ② 把"迎新等场景的自动轮播切图(img_no 变化)"也并进来触发中心
//     扩散 → 迎新轮播每换一张都会做一次 iris。用户明确要求: **迎新轮播
//     保留原来的「淡入淡出」(经全黑)即可**, 中心扩散只留在抢答场景。
//     ⇒ 去掉 ② 这一路后, 迎新轮播切图沿原路径走 display_adjust 的
//       menu_evt → FOUT/FBLCK/FIN 淡入淡出状态机(img_no 变化本身会带动
//       scene/osd 侧的菜单态边沿), 行为与"图片化之前"逐位一致。
//     现在唯一来源:
//       ① 抢答锁定 / 复位(quiz_scene_ctrl.iris_trig 本身即 toggle 电平)。
//   ★为何仍用 toggle 而非脉冲: 100MHz 单拍脉冲窄于 25MHz 采样周期, 过域会丢;
//     电平翻转会保持到下次事件, 下游 2FF 必能采到(小鹅通第十讲做法)。
//   ★quiz_scene_ctrl 每个事件恰好翻转一次 → 下游检测"任意变化"即一次转场。
//============================================================
wire iris_toggle = quiz_iris_trig;


// 底层轮播使能: 应急冻结 或 手动单张(pic_manual)或【抢答场景】时停自动计时
//   ★【2026-10-08 改】抢答场景(zone_sel==3)强制停自动轮播:
//     抢答区 QUIZ 分区共 8 张(QUIZ1..3 题目 + QUIZ4..7 四张队伍图 + QUIZ8 结束页),
//     它们语义上**不是一组轮播图集** —— 之前 slideshow_en=1 令 bmp_read_auto
//     在 S_HOLD 里按 period_cyc 秒级自动循环切换, 表现为"抢答场景在自动轮播",
//     与设计意图(先停在题图, 等按钮再走流程)相悖。
//     ⇒ 冻结当前图, 只有 quiz_scene_ctrl 的 key_jump(题图/队伍图/结束页切换)
//       才会切图, 切换本身由 iris 转场呈现。
assign bmp_slide_en = slideshow_en & ~pic_manual & (zone_sel_l != 3'd3);

//SD card BMP file read(按键消抖已由 ui_key_ctrl 完成, 此处只收脉冲;
//                     zone_load=场景切换 → 分区重载)
//====================================================================
// TF 卡背景音乐(WAV)通路信号 —— **声明必须早于 sd_card_bmp 例化**:
//   播放器在该模块内部, 其样本输出/握手端口在此接出; 若在此处先用后声明,
//   Verilog 会先生成 1 位隐式网络, 之后显式声明即报"重复声明"。
//   具体逻辑(sel_wav / 48 kHz 节拍 / DDS↔WAV 切源)见下方音频链。
//====================================================================
wire             wav_valid;
wire             wav_ready;
wire signed[15:0] wav_left;
wire signed[15:0] wav_right;
wire             sel_wav;
wire             audio_rate_tick;
wire             wav_primed;      //WAV 播放器已攒够起播水位(读侧信号)
assign wav_right = wav_left;      // 单声道素材 → 左右声道同源

sd_card_bmp  sd_card_bmp_m0(
	.clk                        (sd_card_clk              ),
	.rst                        (~rst_n_sd_rdy ),
	.state_code                 (state_code               ),
	.bmp_width                  (16'd640                 	),  //image width
	.key_next                   (key_next_pl              ),
	.key_prev                   (key_prev_pl              ),
	.key_jump                   (quiz_jump_fwd            ),	//抢答绝对跳图(仅抢答场景)
	.jump_idx                   (quiz_jump_idx_l          ),	//目标图序号(0 基)
	.slide_en                   (bmp_slide_en             ),
	.slide_interval             (ui_period_cyc            ),  //批次4 周期档(2/3/5/10/30s)
	// ---- 场景素材定位(v11: FAT32 文件名寻址; 内部产出 zone_start/wrap/max) ----
	.zone_sel                   (zone_sel_l               ),  // 0菜单 1迎新 2预留 3抢答 4应急
	.zone_load_req              (zone_load_l              ),  // 场景切换请求(段表就绪后才真正下发)
	.zone_tbl_ready             (zone_tbl_ready           ),  // 段表已就绪(调试/上板观测)
	.zone_err                   (zone_err_l               ),  // 1=未匹配到素材(已回退兜底)
	.reload_req                 (res_chg_pl               ),
	.write_req                  (sd_card_write_req        ),
	.write_req_ack              (write_req_ack_sd         ),  // ext_mem_clk→sd_card_clk 已两级同步(见 u_sync_wr_ack)
	.write_en                   (sd_card_write_en         ),
	.write_data                 (sd_card_write_data       ),
	.img_no                     (img_no                   ),
	.img_busy                   (img_busy                 ),
	.bmp_error                  (bmp_error                ),
	.img_res                    (img_res                  ),  //源分辨率码四档(2026-10-02)
	.img_v2x                    (img_v2x                  ),  //源高=240 → bmp_scale 纵向 2×
	// ---- WAV 背景音乐(裸 PCM; 读侧 video_clk 域, 播放器在本模块内) ----
	.audio_clk                  (video_clk                ),
	.audio_rst_n                (rst_n_vid                ),
	.wav_play_en                (sel_wav                  ),
	.wav_start_lba              (WAV_START_LBA            ),
	.wav_sectors                (WAV_SECTORS              ),
	.wav_sample_tick            (audio_rate_tick          ),
	.wav_sample_ready           (wav_ready                ),
	.wav_sample                 (wav_left                 ),
	.wav_sample_valid           (wav_valid                ),
	.wav_primed                 (wav_primed               ),
	.SD_nCS                     (sd_ncs                   ),
	.SD_DCLK                    (sd_dclk                  ),
	.SD_MOSI                    (sd_mosi                  ),
	.SD_MISO                    (sd_miso                  )
);

//============================================================
// 双线性插值缩放引擎(bmp_scale, sd_card_clk 写通路):
//   位置: sd_card_bmp(源像素 640×480) → bmp_scale → frame_read_write(写 FIFO)
//   为何放在写通路: 显示侧 frame_fifo_read 是整帧突发读、SDRAM 地址由硬件
//     顺序推进，无法逐像素改地址；写侧逐像素可控，故在这里做坐标映射。
//   输出画布固定 640×480(= SDRAM 帧尺寸) → write_len/write_addr/行序翻转
//     逻辑全部无需改动；缩放图居中，区外填黑；>100% 档按中心裁剪。
//   分两级可分离插值: 先水平(A/B 两行各自 x 方向), 再垂直(y 方向)。
//   档位 scale_sel = res_level(ui_key_ctrl 模式2 用 KEY2/KEY3 调, 0..7):
//     0=25% 1=33% 2=50% 3=67% 4=100%(默认) 5=150% 6=200% 7=300%
//   档位变化时 ui_key_ctrl 给 res_chg_pl → sd_card_bmp 原地重读当前图,
//     新档位立即生效(见 bmp_read_auto 的 reload_req)。
//   frame_start 取 write_req_ack(帧起点), 与 frame_fifo_write 清写 FIFO 同拍,
//     保证本模块首个输出像素不会被 FIFO 清零动作丢掉。
//============================================================
bmp_scale bmp_scale_m0(
	.clk                        (sd_card_clk              ),
	.rst                        (~rst_n_sd_rdy                   ),
	.scale_sel                  (res_level                ),
	.frame_start                (sd_card_write_req_ack    ),
	.src_v2x                    (img_v2x                  ),  //源高=240 → 纵向 2× 补满 640x480
	.in_en                      (sd_card_write_en         ),
	.in_data                    (sd_card_write_data       ),
	.out_en                     (bmp_scale_wr_en          ),
	.out_data                   (bmp_scale_wr_data        )
);

//============================================================
// 数码管显示(8 位, 用户规格布局):
//   第1位 = 场景号(0..3)                → seg_data_0
//   第2~4位 = 当前模式参数(3位十进制, 前导零熄灭)
//             模式0: 0=轮播 / N=手动第N张; 模式1: 亮度 0..15;
//             模式2: 档位 0..7;            模式3: 轮播间隔秒数 2/3/5/10/30
//             模式5: 音量 0..15
//             (批次4: 参数刚被改动 → 该值强制保持显示 2 秒后自动返回,
//              见 ui_key_ctrl 的 disp_hold/disp_sel; 默认观感与之前一致)
//   第5位 = 功能模式号(0图片/1亮度/2分辨率/3周期/4会议计时/5音量) → seg_data_4
//   第6、7位 = 固定横线 "-" 分隔符      → seg_data_5/6
//             (批次3: bmp_error≠0 时改为显示 "E" + 错误码 十六进制数字,
//              即加载出错时第6位=E、第7位=1~3, 正常无错恢复横线。)
//   第8位 = A=自动轮播 / H=手动单张      → seg_data_7
//============================================================
// 参数强显保持: 保持期内用"动作发生时的模式"取值, 否则用当前模式
//   (disp_sel 只会是 1/2/3/5 之一 —— 只有模式1/2/3/5 会产生参数动作)
//   ★宽度必须 3 位: ui_mode 上限已到 5(音量档), 截成 2 位会把模式4/5 折回 0/1。
wire [2:0] disp_mode = ui_disp_hold ? ui_disp_sel : ui_mode;

// 当前模式对应的参数值(0..255)
//   ★2026-10-09c: 数码管"参数值"必须与按键实际作用的对象一致 ——
//     3/4 档的功能随场景不同(抢答 3=对比度 / 迎新 4=对比度),
//     故参数值也按场景选择: 抢答场景的 3 档、迎新/应急的对比度档显示对比度档位。
//   ★2026-10-09f: 应急场景"没有缩放、没有轮播周期档", 整体前移, 故:
//     · 应急 2 档 = 对比度, 3 档 = **音量**(不是缩放/周期)
//     · 迎新 3 档 = 周期, 4 档 = 对比度
//     · 抢答 3 档 = 对比度, 4 档 = 计分(无参数显示 → 走 default 图片值)
wire scr_param = (scene_id == 2'd2);          // 抢答场景
wire scr_emg   = (scene_id == 2'd3);          // ★应急场景(2026-10-09f)
wire dis_con   = scr_param ? (disp_mode == 3'd3)    // 抢答: 3 档 = 对比度
                : scr_emg  ? (disp_mode == 3'd2)    // 应急: 2 档 = 对比度(去缩放后前移)
                :            (disp_mode == 3'd4);   // 迎新: 4 档 = 对比度
wire dis_per   = ~scr_param & ~scr_emg & (disp_mode == 3'd3);  // 真·周期档(仅迎新的 3 档)
wire dis_vol   = scr_emg ? (disp_mode == 3'd3)      // ★应急: 3 档 = 音量
                         : (disp_mode == 3'd5);     // 其余: 5 档 = 音量
reg [7:0] param_val;
always @(*) begin
    if (dis_con)
        param_val = {4'd0, ui_con};               // ★对比度档 0..15
    else if (dis_vol)
        param_val = {4'd0, ui_vol};               // ★音量档 0..15
    else if (dis_per)
        param_val = ui_period_sec;                // 轮播间隔秒 2/3/5/10/30(仅迎新)
    else case (disp_mode)
        3'd1:    param_val = {4'd0, bri_level};   // 亮度档 0..15
        3'd2:    param_val = {4'd0, res_level};   // 分辨率档 0..7
        default: param_val = pic_param;           // 0=轮播 / N=手动第N张
    endcase
end
// 十进制百/十/个位
reg [3:0] p_h, p_t, p_o;
always @(*) begin
    p_h = param_val / 8'd100;
    p_t = (param_val % 8'd100) / 8'd10;
    p_o = param_val % 8'd10;
end
// 前导零熄灭: 百位(值<100)/十位(值<10)熄灭
wire blank_h = (param_val < 8'd100);
wire blank_t = (param_val < 8'd10);

wire [6:0] dec_scene, dec_h, dec_t, dec_o, dec_mode;
seg_decoder u_dec_scene (.bin_data({2'b0, scene_id}), .seg_data(dec_scene));
seg_decoder u_dec_h     (.bin_data(p_h              ), .seg_data(dec_h    ));
seg_decoder u_dec_t     (.bin_data(p_t              ), .seg_data(dec_t    ));
seg_decoder u_dec_o     (.bin_data(p_o              ), .seg_data(dec_o    ));
seg_decoder u_dec_mode  (.bin_data({1'b0, ui_mode }), .seg_data(dec_mode ));

//============================================================
// 数码管 8 位布局(v11: 会议 MM.SS 段随会议场景删除)
//   第1位 = 场景号(0..3) / 第2~4位 = 当前模式参数 / 第5位 = 功能模式号
//   第6、7位 = "-"(或错误码 E+n) / 第8位 = A 自动 / H 手动
//   ※ 原"会议场景时整屏切到 MM.SS 倒计时"的分支已移除,
//     数码管不再有按场景整体切换的第二套映射。
//============================================================
localparam [7:0] SEG_BLANK = 8'hFF;   // 全灭(含小数点)
localparam [7:0] SEG_DASH  = 8'hBF;   // 仅 g 段亮 = "-"
localparam [7:0] SEG_CH_A  = 8'h88;   // 字母 "A" = 自动轮播
localparam [7:0] SEG_CH_H  = 8'h89;   // 字母 "H" = 手动单张

// 批次3 错误码观测: bmp_error≠0 时第6/7位显示 "E"+错误码(十六进制), 否则横线
wire        err_show = (bmp_error != 4'd0);
wire [6:0]  dec_err;
seg_decoder u_dec_err (.bin_data(bmp_error), .seg_data(dec_err));

seg_scan seg_scan_m0(
	.clk                        (clk                      ),
	.rst_n                      (rst_n_clk                ),
	.seg_sel                    (seg_sel                  ),
	.seg_data                   (seg_data                 ),
	.seg_data_0                 ({1'b1, dec_scene}),
	.seg_data_1                 (blank_h ? SEG_BLANK : {1'b1, dec_h}),
	.seg_data_2                 (blank_t ? SEG_BLANK : {1'b1, dec_t}),
	.seg_data_3                 ({1'b1, dec_o}),
	.seg_data_4                 ({1'b1, dec_mode}),
	.seg_data_5                 (err_show ? {1'b1, 7'b000_0110} : SEG_DASH), // "E"
	.seg_data_6                 (err_show ? {1'b1, dec_err}      : SEG_DASH),
	.seg_data_7                 (pic_manual ? SEG_CH_H : SEG_CH_A)
);
wire hs_0;
wire vs_0;
wire de_0;
video_timing_data video_timing_data_m0
(
	.video_clk                  (video_clk                ),
	.rst                        (~rst_n_vid    ),
	.read_req                   (video_read_req           ),
	.read_req_ack               (video_read_req_ack       ),
	//.read_en                    (video_read_en            ),
	//.read_data                  (video_read_data          ),
	.hs                         (hs_0                       ),
	.vs                         (vs_0                       ),
	.de                         (de_0                         )
	//.vout_data                  (vout_data                )
);
video_delay video_delay_m0
(
    .video_clk                  (video_clk                ),
	.rst                        (~rst_n_vid    ),
    .read_en					(video_read_en),
    .read_data					(video_read_data[31:8]),
    .hs                         (hs_0                       ),
	.vs                         (vs_0                       ),
	.de                         (de_0                         ),
	.hs_r                       (hs                       ),
	.vs_r                       (vs                       ),
	.de_r                       (de                       ),
	.vout_data					(vout_data)
);

//============================================================
// OSD 叠加底座(阶段2a 骨架, 已并入数据通路)
//   输入 = video_delay 输出(已对齐像素流, 整体滞后 ~20 拍)
//   输出 = 重建 0 基坐标 + 通用叠加仲裁后的像素流 → osd_menu
//   ovl_en/ovl_rgb 暂置无效(后续时钟 OSD 层驱动)
//   测试矩形 TEST_RECT_EN=0 关闭, 坐标重建对功能透明
//============================================================
osd_engine #(
    .DATA_WIDTH   (24),
    .H_ACTIVE     (16'd640),
    .V_ACTIVE     (16'd480),
    .TEST_RECT_EN (1'b0),             // 调试用测试矩形, 正常关闭
    .TEST_X0      (12'd160),
    .TEST_Y0      (12'd120),
    .TEST_X1      (12'd480),
    .TEST_Y1      (12'd360)
) osd_engine_m0(
    .video_clk    (video_clk),
    .rst          (~rst_n_vid),
    .hs_i         (hs),
    .vs_i         (vs),
    .de_i         (de),
    .data_i       (vout_data),
    .ovl_en       (1'b0),             // 待接入时钟等 OSD 层
    .ovl_rgb      (24'h000000),
    .hs_o         (osd_hs),
    .vs_o         (osd_vs),
    .de_o         (osd_de),
    .data_o       (osd_data),
    .px_x         (px_x),
    .px_y         (px_y)
);

//============================================================
// 共享 OSD 字形 ROM(全网仅此一片, 省 BRAM)
//   三路 OSD 模块(osd_menu / osd_welcome / osd_scene)的字形窗**互斥**:
//     menu_en(菜单态 或 拨码位2) / welcome_en / quiz_en 为 SW 单选,
//     且应急时 menu_en=0、welcome_en=0, 任一时刻至多一路发读请求。
//   故三路共用一片 ROM: rd_en = 三路读请求之"或", addr = 优先级多路选择。
//   三模块内部同构(A 级 px2 发地址, ROM 晚一拍回 q → 与 px3 对齐),
//   因此 rom_en 与 rom_addr 天然同拍, 多路选择不会引入错位。
//============================================================
wire        m_rom_en, w_rom_en, s_rom_en;
wire [12:0] m_rom_addr, w_rom_addr, s_rom_addr;
wire [31:0] rom_q;

wire        osd_rom_en   = m_rom_en | w_rom_en | s_rom_en;
wire [12:0] osd_rom_addr = m_rom_en  ? m_rom_addr :
                           (w_rom_en ? w_rom_addr : s_rom_addr);

osd_font_rom #(
    .ADDR_W (13),
    .DEPTH  (6992)      // 2026-09-21: 字库换成 fpgapmzs 最新版(新增 AG* 议程字模, 5856→6992)
) u_osd_font_rom (
    .clk    (video_clk),
    .rst    (~rst_n_vid),
    .rd_en  (osd_rom_en),
    .addr   (osd_rom_addr),
    .q      (rom_q)
);

//============================================================
// OSD 菜单文字叠加引擎(阶段2a, 四场景首页菜单)
//   输入 = osd_engine 输出(已对齐像素流 + 0 基坐标 px_x/px_y)
//   叠加 = 首页菜单(标题+四场景入口+底部提示, 汉字 16×16 点阵 ROM)
//         / 应急顶部红条(emergency, 最高优先级, 不遮底图全屏切换)
//   控制 = menu_active(菜单态)/emergency(应急) 跨时钟域电平(内部两级同步)
//   输出 = 像素流 + 同拍坐标送 osd_welcome (整体延 ~3 拍, 同步随动)
//============================================================
osd_menu #(
    .DATA_W       (24),
    .H_ACT        (640),
    .V_ACT        (480)
) osd_menu_m0(
    .video_clk    (video_clk),
    .rst          (~rst_n_vid),
    .hs_i         (osd_hs),
    .vs_i         (osd_vs),
    .de_i         (osd_de),
    .data_i       (osd_data),
    .px_x         (px_x),
    .px_y         (px_y),
    .menu_en      (menu_active | (latch_sw == 3'd2)),  // v11: 拨码位 2(原会议)改走菜单画面
    .emerg_en     (emergency),
    .rom_en_o     (m_rom_en),
    .rom_addr_o   (m_rom_addr),
    .rom_q        (rom_q),
    .hs_o         (menu_hs),
    .vs_o         (menu_vs),
    .de_o         (menu_de),
    .data_o       (menu_data),
    .px_x_o       (menu_px_x),
    .px_y_o       (menu_px_y)
);

//============================================================
// 迎新展示场景 OSD 信息叠加(osd_welcome, 阶段2b 扩展功能1)
//   输入 = osd_menu 输出(背景流 + 同拍坐标)
//   叠加 = 顶部欢迎语(金底50%) / 左下报到地点卡(75%衬底+蓝强调)
//        / 右下联系方式卡(同上+青强调) / 底部滚动报到流程(每帧左移1px)
//   非 OSD 区域原样透传背景(背景保持); welcome_en=0(菜单/会议/抢答/应急)
//   时本模块纯透传。输出像素流 + 坐标送 display_adjust。
//============================================================
osd_welcome #(
    .DATA_W       (24),
    .H_ACT        (640),
    .V_ACT        (480)
) osd_welcome_m0(
    .video_clk    (video_clk),
    .rst          (~rst_n_vid),
    .hs_i         (menu_hs),
    .vs_i         (menu_vs),
    .de_i         (menu_de),
    .data_i       (menu_data),
    .px_x         (menu_px_x),
    .px_y         (menu_px_y),
    .welcome_en   (welcome_en),
    .rom_en_o     (w_rom_en),
    .rom_addr_o   (w_rom_addr),
    .rom_q        (rom_q),
    .hs_o         (wl_hs),
    .vs_o         (wl_vs),
    .de_o         (wl_de),
    .data_o       (wl_data),
    .px_x_o       (wl_px_x),
    .px_y_o       (wl_px_y)
);

//============================================================
// 抢答/应急 场景 OSD 叠加(osd_scene, 阶段2d 扩展)
//   输入 = osd_welcome 输出(背景流 + 同拍坐标)
//   叠加 = 抢答(标题条/状态面板/2× 倒计时+秒/滚动须知)
//        / 应急(本层 alarm_en 恒 0, 四类应急画面由下级 emergency_multi_overlay 画)
//   两路使能互斥(SW 单选)共用一片字形 ROM; 全 0 时纯透传。
//   输出像素流 + 坐标送 emergency_multi_overlay。
//   ※ v11: 会议层已删除 —— meeting_en/run_hh/run_mm/run_ss 四个端口本身
//     已从 osd_scene 移除, 故此处不再接线(否则 HDL-8007 找不到端口)。
//============================================================
osd_scene #(
    .DATA_W       (24),
    .H_ACT        (640),
    .V_ACT        (480)
) osd_scene_m0(
    .video_clk    (video_clk),
    .rst          (~rst_n_vid),
    .hs_i         (wl_hs),
    .vs_i         (wl_vs),
    .de_i         (wl_de),
    .data_i       (wl_data),
    .px_x         (wl_px_x),
    .px_y         (wl_px_y),
    .quiz_en      (quiz_en),
    .alarm_en     (1'b0), // 四类应急画面由下级 emergency_multi_overlay 统一绘制
    .qstate       (q_state),
    .winner       (q_winner),
    .t_tens       (q_t_tens),
    .t_ones       (q_t_ones),
    .rom_en_o     (s_rom_en),
    .rom_addr_o   (s_rom_addr),
    .rom_q        (rom_q),
    .hs_o         (sc_hs),
    .vs_o         (sc_vs),
    .de_o         (sc_de),
    .data_o       (sc_data),
    .px_x_o       (sc_px_x),
    .px_y_o       (sc_px_y)
);

wire em_hs, em_vs, em_de;
wire [23:0] em_data;
wire [11:0] em_px_x, em_px_y;

//============================================================
// v11(2026-10-07): 会议议程控制链整体删除
//   原链路: TF 卡扇区 200000(MTG1) → meeting_sd_rd → meeting_cfg →
//           meeting_ctrl(七状态计时) → meeting_osd(会议画面)
//   连带删除: 四键"翻转电平跨域"同步器(meet_key_tog/meet_press)、
//             meeting_en/alarm 的 video 域同步器(下游已无使用者)、
//             数码管的 MM.SS 稳定快照(mtg_bcd_*)与 4 个 seg 译码器。
//   现在 osd_scene 的输出(sc_*)直接进应急叠层。
//============================================================

emergency_multi_overlay u_emergency_multi(
    .clk(video_clk),.rst(~rst_n_vid),.hs_i(sc_hs),.vs_i(sc_vs),.de_i(sc_de),
    .data_i(sc_data),.px_x(sc_px_x),.px_y(sc_px_y),.alarm_en(alarm_en),
    .alarm_type(alarm_type),.min_tens(alarm_mt),.min_ones(alarm_mo),
    .sec_tens(alarm_st),.sec_ones(alarm_so),.hs_o(em_hs),.vs_o(em_vs),
    .de_o(em_de),.data_o(em_data),.px_x_o(em_px_x),.px_y_o(em_px_y)
);

// Actual final-PCM visualization: welcome, quiz and alarm only.
audio_viz_overlay u_audio_viz(
    .clk(video_clk),.rst(~rst_n_vid),.hs_i(em_hs),.vs_i(em_vs),.de_i(em_de),
    .data_i(em_data),.px_x(em_px_x),.px_y(em_px_y),.menu_active(menu_active),
    .scene_id(scene_id),.pcm_take(audio_pcm_valid&&audio_pcm_ready),.pcm(audio_left),
    .hs_o(viz_hs),.vs_o(viz_vs),.de_o(viz_de),.data_o(viz_data),
    .px_x_o(viz_px_x),.px_y_o(viz_px_y));

//============================================================
// 显示末级调节引擎(display_adjust, 阶段2b 扩展功能2/3):
//   1) 16 档亮度增益(key2 增 / key3 减, 默认 8=×1.0)
//   2) 亮度档变化显示左上角 16 档图形条(BAR_HOLD 帧后自动隐藏)
//   3) 场景切换淡入淡出: menu_active 边沿(菜单↔场景)触发,
//      alpha 逐帧降黑 → 等底层 img_busy 释放(新分区图写毕) → 淡入;
//      应急(emergency)期间强制不淡出(最高优先级即刻响应)
//============================================================
// ---- 场景切换与轮播反馈(display_adjust HUD 提示) ----
	//   res_level/pic_manual/ui_mode 三个电平已在 sd 域寄存, display_adjust
	//   内部两级同步后:
	//     · 缩放档变化 / 切到分辨率模式 → 弹"缩放条"(8 档, 30 帧后消失)
	//     · 亮度档变化 / 切到亮度模式 → 弹"亮度条"(16 档)
	//     · KEY4 切轮播↔手动 / 切到图片模式 → 弹"轮播-手动状态卡"
	//     · 批次4 周期档(ui_mode=3) → 不弹额外提示(沿用上一条提示到期即隐)
	//============================================================
	display_adjust #(
	    .DATA_W       (24),
	    .H_ACT        (640),
	    .V_ACT        (480)
	) display_adjust_m0(
	    .video_clk    (video_clk),
	    .rst          (~rst_n_vid),
	    .hs_i         (viz_hs),
	    .vs_i         (viz_vs),
	    .de_i         (viz_de),
	    .data_i       (viz_data),
	    .px_x         (viz_px_x),
	    .px_y         (viz_px_y),
	    .menu_active  (menu_active),
	    .emerg        (emergency),
	    .bmp_busy     (img_busy),
	    .iris_trig    (iris_toggle),
	    .bri_level    (bri_level),
	    .vol_level    (ui_vol),
	    .con_level    (ui_con),       // ★对比度档(2026-10-09c)
	    .res_level    (res_level),
	    .img_res      (img_res),
	    .pic_manual   (pic_manual),
	    .ui_mode      (ui_mode),
	    // ---- 抢答分数板(2026-10-09) ----
	    .quiz_on      (quiz_en),
	    .q_state      (q_state),
	    .q_end        (q_end),        // ★2026-10-09b: 结束页 → 4 队总分常显
	    .sc0          (q_sc0),
	    .sc1          (q_sc1),
	    .sc2          (q_sc2),
	    .sc3          (q_sc3),
	    .sc_evt       (q_score_tog),
	    .sc_team      (q_score_team),
	    .hs_o         (fin_hs),
	    .vs_o         (fin_vs),
	    .de_o         (fin_de),
	    .data_o       (fin_data)
	);

//============================================================
// 迎新场景 OSD 使能: latch=1(迎新区) 且非应急。
//  (latch_sw/menu_active/emergency 均在 scene_control 内 sd 域寄存,
//   组合简单且下游 osd_welcome 内部两级同步, 无亚稳态风险)
//============================================================
assign welcome_en = (latch_sw == 3'd1) && ~emergency;

// Final audio feature layer. Original modules/files remain unchanged.
wire audio_rst_n_ser;
reset_sync u_audio_serial_reset(.clk(hdmi_5x_clk),.rst_n_async(ext_rst_n),.rst_n_sync(audio_rst_n_ser));
wire [31:0] audio_media_samples,audio_mux_pairs,audio_zero_samples;
wire audio_menu_sync,audio_emergency_sync;wire [1:0] audio_scene_sync;
wire feature_event_valid;wire [1:0] feature_event_kind,feature_event_media;
wire zero_valid,zero_ready,media_valid,media_ready;
wire signed [15:0] zero_left,zero_right,media_left,media_right;
wire [8:0] media_gain;wire media_overflow,zero_overflow;wire [2:0] media_state;
// ---- 片内 DDS 合成音(会议/抢答/应急, 以及"未准备音乐时的迎新") ----
wire dds_valid,dds_ready;wire signed [15:0] dds_left,dds_right;wire [8:0] dds_gain;
// ---- TF 卡 WAV 背景音乐(仅迎新场景; 播放器在 sd_card_bmp 内) ----
//   wav_valid / wav_ready / wav_left / wav_right 已在 sd_card_bmp 例化前声明。
// 迎新(SW1 场景 0)且非菜单/非应急, 并且音乐素材已准备好 → 走 WAV;
//   否则退回 DDS。三个输入都在 video_clk 域(sync_2ff 后), 纯组合选择。
assign sel_wav = (audio_scene_sync == 2'd0) & ~audio_menu_sync &
                 (WAV_SECTORS != 32'd0);
sync_2ff u_audio_menu_sync(.clk(video_clk),.async_in(menu_active),.sync_out(audio_menu_sync));
sync_2ff u_audio_emergency_sync(.clk(video_clk),.async_in(emergency),.sync_out(audio_emergency_sync));
sync_2ff u_audio_scene0_sync(.clk(video_clk),.async_in(scene_id[0]),.sync_out(audio_scene_sync[0]));
sync_2ff u_audio_scene1_sync(.clk(video_clk),.async_in(scene_id[1]),.sync_out(audio_scene_sync[1]));
audio_feature_events u_feature_events(
 .clk(video_clk),.rst_n(rst_n_vid),.menu_active(audio_menu_sync),.emergency(audio_emergency_sync),
 .scene_id(audio_scene_sync),.q_state(q_state),.q_t_tens(q_t_tens),.q_t_ones(q_t_ones),
 .meeting_warn_event(1'b0),.meeting_timeout_event(1'b0),  // v11: 会议场景已删, 恒无事件
 .event_valid(feature_event_valid),.event_kind(feature_event_kind),.event_media(feature_event_media));
// [修复 2026-09-27] 静音"测试源"必须恒有效。
//   原实现用 audio_pcm_tone(#(.PROFILE(0)), .enable(1'b0)) 产生 zero_valid,
//   但该模块 sample_valid = (count != 0), 在 48 kHz 节拍那一拍恰为 0(晚一拍
//   才置 1)。而 audio_src_mux 的 launch(→ media_ready → wav_ready) 要求
//   test_valid 与 media_valid **同拍**为真, 于是节拍上 wav_ready 恒 0 →
//   wav_stream_player 永不推进(rd_ptr 恒停在预读值) → 迎新完全无声。
//   端到端仿真实测: 原实现 tick&&wav_ready 计数 = 0; 换恒有效静音后 = 576,
//   audio_left 非零, RESULT: PASS。
//   这里直接给"恒有效、恒零"的静音样本(混音级随之退化为对 media 的透传:
//   media_gain=256 时 输出 = 0 + (media-0) = media), 同时省掉一个 256 点
//   正弦 ROM + 乘法器, 对时序只有好处。
assign zero_valid   = 1'b1;
assign zero_left    = 16'sd0;
assign zero_right   = 16'sd0;
assign zero_overflow = 1'b0;
assign audio_zero_samples = 32'd0;
scene_audio_final u_scene_audio(
 .clk(video_clk),.rst_n(rst_n_vid),.event_valid(feature_event_valid),.event_kind(feature_event_kind),
 .media_id(feature_event_media),.menu_active(audio_menu_sync),.emergency(audio_emergency_sync),
 .active_scene(audio_scene_sync),
 .sample_valid(dds_valid),.sample_ready(dds_ready),.sample_left(dds_left),.sample_right(dds_right),
 .sample_gain(dds_gain),.overflow(media_overflow),.state_debug(media_state),.sample_count(audio_media_samples));
// DDS/WAV 切源: ready 只回给被选中的源; 未选中的 DDS 仍按 48 kHz 节拍排空
//   (否则其内部 FIFO 会淤积上一个场景的旧样本, 切回来时先放出旧音)。
audio_src_sel u_audio_src_sel(
 .clk(video_clk),.rst_n(rst_n_vid),.sel_wav(sel_wav),
 .dds_valid(dds_valid),.dds_ready(dds_ready),.dds_left(dds_left),.dds_right(dds_right),
 .dds_gain(dds_gain),
 .wav_valid(wav_valid),.wav_ready(wav_ready),.wav_left(wav_left),.wav_right(wav_right),
 .drain_tick(audio_rate_tick),
 .media_valid(media_valid),.media_ready(media_ready),.media_left(media_left),
 .media_right(media_right),.media_gain(media_gain));
//============================================================
// 音量末级(ui_key_ctrl 模式5, 2026-09-28 新增):
//   out = (in * vol) >>> 3, 16bit 饱和(越界钳到 ±满幅)
//     vol 0..15, 默认 8 = ×1.0;  0 = 静音;  15 ≈ ×1.875
//   · 位置: audio_src_mux 之后、音量柱(audio_viz_overlay)与 HDMI 打包之前 ——
//     迎新 WAV / 会议 / 抢答 / 应急 DDS **所有场景音频**统一受控,
//     且包络音量柱跟着实际输出走(调小音量柱子同步变矮)。
//   · 默认档 8 时 (in*8)>>>3 与原值逐位相同 → 不改默认听感/不改变既有观感。
//   · 组合直通、不插流水: audio_src_mux 输出在两个 48 kHz 节拍之间保持
//     数百拍稳定, audio_hdmi_valid 恰在节拍沿取样, 加流水反而会错位;
//     25 MHz 视频域做一次 16bit×4bit 乘法 + 移位, 时序极宽裕。
//     (vol 上限 15 → |积| ≤ 32768*15 = 491520, 21bit 有符号足够)
//   · vol_level 在 sd_card_clk 域, 此处两级同步到 video_clk(默认档 8 复位)。
//============================================================
wire signed [15:0] mux_left, mux_right;
reg  [3:0] vol_s0, vol_s1;
always @(posedge video_clk or negedge rst_n_vid)
    if(!rst_n_vid) begin vol_s0 <= 4'd8; vol_s1 <= 4'd8; end
    else           begin vol_s0 <= ui_vol; vol_s1 <= vol_s0; end
audio_src_mux u_audio_mux(
 .clk(video_clk),.rst_n(rst_n_vid),.test_valid(zero_valid),.media_valid(media_valid),
 .test_ready(zero_ready),.media_ready(media_ready),.test_left(zero_left),.test_right(zero_right),
 .media_left(media_left),.media_right(media_right),.media_gain(media_gain),
 .sample_valid(audio_pcm_valid),.sample_ready(audio_pcm_ready),.sample_left(mux_left),.sample_right(mux_right),
 .accepted_pairs(audio_mux_pairs));
wire signed [20:0] volp_l = mux_left  * $signed({1'b0, vol_s1});
wire signed [20:0] volp_r = mux_right * $signed({1'b0, vol_s1});
wire signed [20:0] volq_l = volp_l >>> 3;
wire signed [20:0] volq_r = volp_r >>> 3;
assign audio_left  = (volq_l >  21'sd32767) ? 16'sd32767 :
                     (volq_l < -21'sd32768) ? 16'sh8000 : volq_l[15:0];
assign audio_right = (volq_r >  21'sd32767) ? 16'sd32767 :
                     (volq_r < -21'sd32768) ? 16'sh8000 : volq_r[15:0];
//============================================================
// HDMI 输出级: 官方 HDMI 1.4b 发送器 IP + 官方 10:1 LVDS PHY
//   接法与小鹅通《第二讲第1课》top_tf_hdmi_audio.v 完全一致。
//   数据岛的位置/前导/保护带/AVI+Audio InfoFrame 全部由 IP 内部
//   按 HDMI 1.4b 规范产生(原手写核心把数据岛放在了 HSYNC 脉冲
//   内部, 转换芯片解不出音频)。IP 参数与本工程视频时序一致:
//   800x525 @25MHz, HSA96/HFP16/HBP48, VSA2/VFP10/VBP33, RGB, 48K。
//   音频源仍是本工程 48 kHz DDS 场景音, 只把 16 bit 样本左对齐成
//   24 bit LPCM, 并按 48 kHz 给出一拍 I_audio_valid。
//============================================================
// 48 kHz 取样节拍: 25 MHz/48000 不是整数, 用相位累加器产生平均
//   恰好 48 kHz 的单拍脉冲(与 scene_audio_final 内部同一个算法)。
//   (audio_rate_tick 这条网络已在 sd_card_bmp 例化前声明并接到 WAV 播放器)
localparam integer AUDIO_CLK_HZ    = 25000000;
localparam integer AUDIO_SAMPLE_HZ = 48000;
reg [31:0] audio_rate_acc;
assign audio_rate_tick = (audio_rate_acc >= (AUDIO_CLK_HZ - AUDIO_SAMPLE_HZ));
always @(posedge video_clk or negedge rst_n_vid)
    if(!rst_n_vid) audio_rate_acc <= 32'd0;
    else if(audio_rate_tick) audio_rate_acc <= audio_rate_acc - (AUDIO_CLK_HZ - AUDIO_SAMPLE_HZ);
    else audio_rate_acc <= audio_rate_acc + AUDIO_SAMPLE_HZ;

// 每拍只取一对样本: audio_src_mux 的输出在 ready 之前保持稳定
assign audio_pcm_ready = audio_rate_tick;
wire audio_hdmi_valid = audio_rate_tick && audio_pcm_valid;
wire [23:0] audio_hdmi_left  = {audio_left , 8'h00};
wire [23:0] audio_hdmi_right = {audio_right, 8'h00};

// CTS 由 IP 侧实测的像素时钟数给出(每 48 个样本报一次), 因此
// 25 MHz/48 kHz 这种非整数分频也能得到精确的 N/CTS。
wire        audio_acr_valid;
wire [19:0] audio_acr_cts,audio_acr_n;
audio_arc_calculate #(
    .ACR_N (6144)
) u_audio_arc_calculate (
    .I_clk         (video_clk),
    .I_rst         (~rst_n_vid),
    .I_audio_valid (audio_hdmi_valid),
    .O_acr_valid   (audio_acr_valid),
    .O_acr_cts     (audio_acr_cts),
    .O_acr_n       (audio_acr_n)
);

// RGB/DE -> AXIS 视频流(IP 的视频输入口)
wire        axis_s_user,axis_s_valid,axis_s_last,axis_s_ready;
wire [23:0] axis_s_data;
video_rgb_to_axis_640x480 u_video_rgb_to_axis_640x480 (
    .I_clk         (video_clk),
    .I_rst         (~rst_n_vid),
    .I_vs          (fin_vs),
    .I_de          (fin_de),
    .I_rgb         (fin_data),
    .O_video_user  (axis_s_user),
    .O_video_valid (axis_s_valid),
    .O_video_last  (axis_s_last),
    .O_video_data  (axis_s_data)
);

wire [9:0] tmds_ch0_data,tmds_ch1_data,tmds_ch2_data,tmds_clk_data;
wire       hdmi_edid_valid_unused,hdmi_video_locked_unused,hdmi_ddc_scl_unused,hdmi_ddc_sda_unused;
wire [7:0] hdmi_edid_data_unused;

// 板上 DDC 引脚未确认, 本版不做 EDID 读取: 触发恒 0, DDC 输出悬空。
// 若发现 IP 因未读 EDID 不出图, 再接出 O_ddc_scl/IO_ddc_sda 并给一次触发。
hdmi_1_4b_transmitter_core_wrapper #(
    .DEVICE            ("EG"),
    .HTOTAL            (800),
    .HSA               (96),
    .HFP               (16),
    .HBP               (48),
    .HACTIVE           (640),
    .VTOTAL            (525),
    .VSA               (2),
    .VFP               (10),
    .VBP               (33),
    .VACTIVE           (480),
    .VIDEO_VIC         (1),
    .VIDEO_TPG         ("Disable"),
    .VIDEO_FORMAT      ("RGB"),
    .AUDIO_SAMPLE_RATE ("48K"),
    .IIC_SCL_DIV       (250)
) u_hdmi_1_4b_transmitter_core (
    .I_pixel_clk        (video_clk),
    .I_rst              (~rst_n_vid),
    .I_edid_read_trig   (1'b0),
    .O_edid_read_valid  (hdmi_edid_valid_unused),
    .O_edid_read_data   (hdmi_edid_data_unused),
    .I_axis_s_user      (axis_s_user),
    .I_axis_s_valid     (axis_s_valid),
    .I_axis_s_last      (axis_s_last),
    .I_axis_s_data      (axis_s_data),
    .O_axis_s_ready     (axis_s_ready),
    .I_audio_valid      (audio_hdmi_valid),
    .I_audio_left_data  (audio_hdmi_left),
    .I_audio_right_data (audio_hdmi_right),
    .I_acr_valid        (audio_acr_valid),
    .I_acr_cts          (audio_acr_cts),
    .I_acr_n            (audio_acr_n),
    .O_video_locked     (hdmi_video_locked_unused),
    .O_ddc_scl          (hdmi_ddc_scl_unused),
    .IO_ddc_sda         (hdmi_ddc_sda_unused),
    .O_ch0_tmds_data    (tmds_ch0_data),
    .O_ch1_tmds_data    (tmds_ch1_data),
    .O_ch2_tmds_data    (tmds_ch2_data),
    .O_clk_tmds_data    (tmds_clk_data)
);

hdmi_phy_wrapper #(
    .DEVICE ("EG")
) u_hdmi_phy_wrapper (
    .I_pixel_clk        (video_clk),
    .I_serial_clk       (hdmi_5x_clk),
    .I_rst              (~audio_rst_n_ser),
    .I_tmds_channel_0   (tmds_ch0_data),
    .I_tmds_channel_1   (tmds_ch1_data),
    .I_tmds_channel_2   (tmds_ch2_data),
    .I_tmds_channel_clk (tmds_clk_data),
    .O_tmds_ch0_p       (HDMI_D0_P),
    .O_tmds_ch1_p       (HDMI_D1_P),
    .O_tmds_ch2_p       (HDMI_D2_P),
    .O_tmds_clk_p       (HDMI_CLK_P)
);

//video frame data read-write control
frame_read_write frame_read_write_m0(
    .mem_clk					(ext_mem_clk),
    .rst						(~rst_n_mem),
    .Sdr_init_done				(Sdr_init_done),
    .Sdr_init_ref_vld			(Sdr_init_ref_vld),
    .Sdr_busy					(Sdr_busy),
    
    .App_rd_en					(App_rd_en),
    .App_rd_addr				(App_rd_addr),
    .Sdr_rd_en					(Sdr_rd_en),
    .Sdr_rd_dout				(Sdr_rd_dout),
    
    .read_clk                   (video_clk           ),
	.read_req                   (video_read_req           ),
	.read_req_ack               (video_read_req_ack       ),
	.read_finish                (                   ),
	.read_addr_0                (24'd0              ), //first frame base address is 0
	.read_addr_1                (24'd0              ),
	.read_addr_2                (24'd0              ),
	.read_addr_3                (24'd0              ),
	.read_addr_index            (2'd0               ), //use only read_addr_0
	.read_len                   (24'd307200         ), //frame size//24'd786432
	.read_en                    (video_read_en            ),
	.read_data                  (video_read_data          ),
    
    .App_wr_en					(App_wr_en),
    .App_wr_addr				(App_wr_addr),
    .App_wr_din					(App_wr_din),
    .App_wr_dm					(App_wr_dm),
    
    .write_clk                  (sd_card_clk        ),
	.write_req                  (sd_card_write_req        ),
	.write_req_ack              (sd_card_write_req_ack    ),
	.write_finish               (                 ),
	.write_addr_0               (24'd0            ),
	.write_addr_1               (24'd0            ),
	.write_addr_2               (24'd0            ),
	.write_addr_3               (24'd0            ),
	.write_addr_index           (2'd0             ), //use only write_addr_0
	.write_len                  (24'd307200       ), //frame size
	.write_en                   (bmp_scale_wr_en          ),
	.write_data                 (bmp_scale_wr_data        )
);

sdram U3
(
.Clk				(ext_mem_clk),
.Clk_sft			(ext_mem_clk_sft),
.Rst				(~rst_n_mem),
    
.Sdr_init_done		(Sdr_init_done),
.Sdr_init_ref_vld	(Sdr_init_ref_vld),
.Sdr_busy			(Sdr_busy),
    
.App_wr_en			(App_wr_en),
.App_wr_addr		(App_wr_addr),  	
.App_wr_dm			(App_wr_dm),
.App_wr_din			(App_wr_din),
    
.App_rd_en			(App_rd_en),//data_req
.App_rd_addr		(App_rd_addr),
.Sdr_rd_en			(Sdr_rd_en),//data_valid
.Sdr_rd_dout		(Sdr_rd_dout)
);
endmodule 
