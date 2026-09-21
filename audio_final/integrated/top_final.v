// Generated from main 6586b66447375c1c4dfc9568b17a79df889cfbae; audio output addition only.
//====================================================================
// 重要: 阶段2b 三个新模块以 `include 直接并入本文件(与 top.v 同目录,
//   同 color_bar.v 包含 video_define.v 的既有用法)。原因: 工程文件
//   pic_sdram.al 在 TD 打开/关闭过程中会回写覆盖外部手工登记的源码条目,
//   曾两度把 osd_welcome/display_adjust/bri_key_ctrl 从综合列表删除,
//   导致 HDL-8007 black box。改用 include 后模块定义跟随 top.v 必然
//   参与综合, 不再依赖 .al 维护。※ 请勿再通过 GUI "Add to Project"
//   重复添加这些 .v(会造成模块重复定义); 若工程树中已存在请移除。
//   (osd_scene/quiz_ctrl 为阶段2d 新增的会议/抢答/应急场景层, 同法并入)
//   (bmp_scale 为双线性插值缩放引擎, 串在 sd_card_bmp→frame_read_write 写通路)
//====================================================================
`include "../../src/osd_welcome.v"
`include "../../src/display_adjust.v"
`include "../../src/ui_key_ctrl.v"
`include "../../src/osd_scene.v"
`include "../../src/quiz_ctrl.v"
`include "../../src/bmp_scale.v"
`include "../../src/reset_sync.v"
`include "../../src/sync_2ff.v"
`include "../../src/emergency_alarm_ctrl.v"
`include "../../src/emergency_font_rom.v"
`include "../../src/emergency_multi_overlay.v"
// 会议议程控制与计时链(2026-09-21 从 fpgapmzs main ee717b2 移植):
//   meeting_osd 自带 meeting_fmt(串行 BCD 格式化)与 meeting_glyph_rom
//   (4096×16 会议专用字库)并以裸文件名 include; meeting_sd_rd 由
//   sd_card_bmp.v 内部 include 并入(定义与例化同一编译单元)。
`include "../../src/meeting_cfg.v"
`include "../../src/meeting_ctrl.v"
`include "../../src/meeting_osd.v"
`include "../rtl/audio_feature_events.v"
`include "../rtl/scene_audio_final.v"
`include "../rtl/audio_viz_overlay.v"

module top(
	input                       clk,
	input                       key1,       //KEY1(A2)：场景内功能模式循环 0图片/切图→1亮度→2分辨率
	input                       key2,       //KEY2(B2)：当前模式参数 减
	input                       key3,       //KEY3(B1)：当前模式参数 加
	input                       key4,       //KEY4(C1)：预留(已释放——原"自动/手动切换"并入模式0)
	input [3:0]                 sw,         //板载拨码直接选场景: sw[0]=SW1场景0迎新
                                            //  sw[1]=SW2场景1会议 sw[2]=SW3场景2抢答
                                            //  sw[3]=SW4场景3应急(应急最高 + 无应急时先触发先锁定)
                                            //  (引脚/极性见 top.adc; 四个全关=首页菜单态)
	// ---- 抢答台(2×40Pin 外扩口, 上拉/按下低; 引脚见 top.adc) ----
	input [3:0]                 quiz_btn,   //4 路选手抢答键(屏显 1~4 号)
	input                       quiz_start, //开始/下一轮(抢答中再按=重开本轮计时)
	input                       quiz_reset, //复位/清除(回到"等待开始")
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
// 场景素材分区表(卡内扇区区间): 四个场景 = 四个互不相同的独立分区,
// 拨码切场景时按此表查得分区 → zone_load 重载 bmp 扫描, 各播各自区域的图.
// 数据来源: tools/find_bmp.py --drive F --sizes 2,2,1,1 --names WEL,MEET,QUIZ,ALARM
//   卡上 6 张 640×480/24bit BMP 全部 8 扇区对齐且紧邻(间隔 1808 扇区),
//   经 tools/find_bmp.py 与首扇区 MD5 逐张比对, 实际文件顺序为:
//     第1张 126656 = 5.bmp | 第2张 128464 = 6.bmp | 第3张 130272 = 7.bmp
//     第4张 132080 = 1.bmp | 第5张 133888 = 2.bmp | 第6张 135696 = 3.bmp
//   即卡内物理顺序为 5,6,7,1,2,3(按拷贝先后分配, 与文件名无关)。
//   按 2/2/1/1 均分成四个场景区:
//     迎新区 = 5.bmp,6.bmp | 会议区 = 7.bmp,1.bmp
//     抢答区 = 2.bmp       | 应急区 = 3.bmp
//   ⚠ 换卡/重排素材后必须重跑该工具并同步本表(扇区值会变), 否则扫不到图.
//     想让每个场景都放 2~3 张: 重新拷 8~12 张到卡后跑
//     python tools/find_bmp.py --drive F --sizes 2,2,2,2 --names WEL,MEET,QUIZ,ALARM
//     再把输出的 START/WRAP/IMGS 覆盖下面的 Z_* 即可(逻辑不用动).
//--------------------------------------------------------------
localparam [31:0] Z_MENU_START  = 32'd126656;   // 菜单区(=迎新区; 菜单全屏 OSD 自绘, 底层仅预载一张)
localparam [31:0] Z_MENU_WRAP   = 32'd130272;   // 菜单区扫描上限(=下一区起点)
localparam [31:0] Z_MENU_IMGS   = 32'd2;        // 菜单区张数
localparam [31:0] Z_WEL_START   = 32'd126656;   // 迎新区起点(卡上第 1 张)
localparam [31:0] Z_WEL_WRAP    = 32'd130272;   // 迎新区扫描上限(=下一区起点)
localparam [31:0] Z_WEL_IMGS    = 32'd2;        // 迎新区张数(5.bmp,6.bmp)
localparam [31:0] Z_MEET_START  = 32'd130272;   // 会议区起点(卡上第 3 张)
localparam [31:0] Z_MEET_WRAP   = 32'd133888;   // 会议区扫描上限(=下一区起点)
localparam [31:0] Z_MEET_IMGS   = 32'd2;        // 会议区张数(7.bmp,1.bmp)
localparam [31:0] Z_QUIZ_START  = 32'd133888;   // 抢答区起点(卡上第 5 张)
localparam [31:0] Z_QUIZ_WRAP   = 32'd135696;   // 抢答区扫描上限(=下一区起点)
localparam [31:0] Z_QUIZ_IMGS   = 32'd1;        // 抢答区张数(2.bmp)
localparam [31:0] Z_ALARM_START = 32'd135696;   // 应急区起点(卡上第 6 张, 独立第 4 分区)
localparam [31:0] Z_ALARM_WRAP  = 32'd135704;   // 应急区扫描上限(=末张 135696 + 8 扇区)
localparam [31:0] Z_ALARM_IMGS  = 32'd1;        // 应急区张数(3.bmp)

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
wire [1:0]                      scene_id;      // 生效场景码(0迎新 1会议 2抢答 3应急)，供后续功能层/OSD
wire                            menu_active;   // 菜单态标志(1=SW1..3 无锁且非应急 → 显示四场景 OSD 菜单)
wire [2:0]                      latch_sw;      // 内容源/素材分区号(0菜单 1迎新 2会议 3抢答 4应急)
wire                            scene_change_pulse; // 菜单↔场景/场景间切换事件 → 触发 bmp 分区重载

//场景分区重载: scene_control 查表输出目标分区, zone_load 脉冲随切换事件给出
//(四场景 = 四个独立分区; 应急=独立第 4 分区, 与其它场景同等重载)
reg  [31:0]                     zone_start_l;   // 目标分区起点扇区
reg  [31:0]                     zone_wrap_l;    // 目标分区扫描上限
reg  [31:0]                     zone_max_l;     // 目标分区图片张数
wire                            zone_load_l;    // 分区重载请求(=scene_change_pulse)

always @(*) begin
    case (latch_sw)
        3'd0: begin // 菜单(全屏 OSD 自绘, 底层预载迎新区一张)
            zone_start_l = Z_MENU_START;
            zone_wrap_l  = Z_MENU_WRAP;
            zone_max_l   = Z_MENU_IMGS;
        end
        3'd1: begin // 迎新
            zone_start_l = Z_WEL_START;
            zone_wrap_l  = Z_WEL_WRAP;
            zone_max_l   = Z_WEL_IMGS;
        end
        3'd2: begin // 会议
            zone_start_l = Z_MEET_START;
            zone_wrap_l  = Z_MEET_WRAP;
            zone_max_l   = Z_MEET_IMGS;
        end
        3'd3: begin // 抢答
            zone_start_l = Z_QUIZ_START;
            zone_wrap_l  = Z_QUIZ_WRAP;
            zone_max_l   = Z_QUIZ_IMGS;
        end
        default: begin // 应急(第 4 分区)
            zone_start_l = Z_ALARM_START;
            zone_wrap_l  = Z_ALARM_WRAP;
            zone_max_l   = Z_ALARM_IMGS;
        end
    endcase
end
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

//会议/抢答/应急 场景 OSD(osd_scene)相关信号(输出送 display_adjust)
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
wire                            meeting_en;    // 1=会议场景(latch=2 且非应急)
wire                            quiz_en;       // 1=抢答场景(latch=3 且非应急)
wire                            alarm_en;      // 1=应急(最高优先级)
wire [1:0]                      alarm_type;    // KEY1选/KEY2减/KEY3加: 火灾/地震/恶劣天气/临时疏散
wire [3:0]                      alarm_mt, alarm_mo, alarm_st, alarm_so;
wire [1:0]                      q_state;       // 抢答状态 0等待 1抢答中 2锁定 3超时
wire [1:0]                      q_winner;      // 胜者 0..3(屏显 +1)
wire [3:0]                      q_t_tens;      // 倒计时 BCD 十位
wire [3:0]                      q_t_ones;      // 倒计时 BCD 个位
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

//人机交互(ui_key_ctrl)输出
wire [2:0]  ui_mode;        // 功能模式 0图片/1亮度/2分辨率/3轮播周期/4会议计时
wire [3:0]  res_level;      // 分辨率档 0..7
wire [7:0]  pic_param;      // 图片参数(0=轮播 / N=手动第N张)
wire [7:0]  ui_period_sec;  // 批次4 轮播间隔档(秒: 2/3/5/10/30)
wire [31:0] ui_period_cyc;  // 批次4 轮播间隔(时钟周期) → sd_card_bmp
wire        ui_disp_hold;   // 批次4 参数强显保持中(2 秒)
wire [2:0]  ui_disp_sel;    // 批次4 保持期显示的模式(产生动作时的 ui_mode)
wire        pic_manual;     // 1=手动单张(冻结自动轮播)
wire        key_next_pl;    // 手动"下一张"脉冲 → bmp_read_auto.key_trigger
wire        key_prev_pl;    // 手动"上一张"脉冲 → bmp_read_auto.key_prev
wire        res_chg_pl;     // 缩放档变化脉冲(1拍) → bmp 缩放引擎重载当前图
wire        key2_pl;        // KEY2 消抖"按下"脉冲(模式4=会议计时 开始/暂停/继续)
wire        key3_pl;        // KEY3 消抖"按下"脉冲(模式4=当前议程项 重新计时)
wire        bmp_slide_en;   // bmp 轮播使能 = 场景轮播使能 且 非手动单张

//------------------------------------------------------------
// 会议议程配置链(2026-09-21 从 fpgapmzs main 移植):
//   TF 卡固定扇区 →(sd_card_bmp 内 meeting_sd_rd, sd 域解析写 BRAM)
//   → meeting_cfg(双口 BRAM + video 域快照) → meeting_ctrl(七状态计时)
//   ⇄ meeting_osd(会议画面, 串在 osd_scene 与应急叠层之间)
//   会议逻辑全部在 video_clk(25MHz) 域, 与 OSD 同域, 仅使能/告警跨域同步。
//------------------------------------------------------------
wire        mtg_ram_we;         // 配置 RAM 写使能(→ meeting_cfg 写口)
wire [10:0] mtg_ram_addr;       // 配置 RAM 写地址(0..1271)
wire [7:0]  mtg_ram_data;       // 配置 RAM 写数据
wire        mtg_ready;          // 配置有效(MTG1 解析通过)
wire        mtg_error;          // 配置无效(坏/截断/超时)
wire [4:0]  mtg_total;          // 议程项数 1..16
wire        mtg_done;           // 配置读取收尾(此信号后 BMP 通路放行)

wire        mtg_cfg_ready_v;    // 以下均由 meeting_cfg 在 video 域输出
wire        mtg_cfg_error_v;
wire [4:0]  mtg_total_v;
wire [15:0] mtg_duration_v, mtg_next_duration_v;
wire [10:0] mo_cfg_addr;        // meeting_osd → 配置 BRAM 取字地址(2026-09-21 新增)
wire [7:0]  mo_cfg_byte;        // 配置 BRAM → meeting_osd 字形字节(晚地址一拍)

wire [2:0]  mtg_state;          // meeting_ctrl: 七状态
wire [3:0]  mtg_current;        // 当前议程项(0 起)
wire [15:0] mtg_remaining, mtg_overtime;
wire        mtg_alarm_paused;
wire [31:0] mtg_uptime;
wire [1:0]  mtg_notice_sel;     // meeting_osd 输出(注意事项页选择)
wire [3:0]  mtg_ov_index;       // meeting_osd 输出(议程总览行号)
wire        meeting_en_v;       // meeting_en 同步到 video 域
wire        alarm_v;            // emergency 同步到 video 域
// 会议 OSD 输出像素流(插在 osd_scene 与 emergency_multi_overlay 之间)
wire        mo_hs, mo_vs, mo_de;
wire [23:0] mo_data;
wire [11:0] mo_px_x, mo_px_y;


wire									  write_clk;
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
//   KEY1(A2)=功能模式循环 0图片/切图→1亮度→2缩放→3周期→0
//   KEY2(B2)=当前模式参数 减   KEY3(B1)=当前模式参数 加
//   KEY4(C1)=**已释放**(顶层保留引脚, 不接逻辑, 留作后续扩展)
//   模式0(图片/切图): 默认自动轮播; KEY3=下一张 / KEY2=上一张(第1张时按
//                     KEY2 = 回自动轮播); 按 KEY3 即自动转入手动单张;
//                     离开模式0(去亮度/缩放/周期)自动回自动轮播
//   模式1(亮度): KEY3 + / KEY2 -(0..15)  → display_adjust.bri_level
//   模式2(缩放): KEY3 + / KEY2 -(0..7)   → bmp_scale 双线性缩放
//                (档位变化输出 res_chg_pl → 重载当前图, 效果立即可见)
//   模式3(周期): KEY3 + / KEY2 - 在 2/3/5/10/30 s 档间**环绕** →
//                ui_period_cyc → bmp_read_auto.slide_interval(轮播间隔运行时可配)
//   ※ 按键只调参数, 与场景切换无关(场景由拨码决定, 见 scene_control)
//   ※ 所有场景共用同一套按键语义(全局统一样式)
//============================================================
// NOTE(2026-09-21): ui_key1~3 MUST be declared BEFORE the ui_key_ctrl
//   instantiation below. Declared after it, TD treats them as implicit nets
//   and ties them to 0 (HDL-7225 + SYN-5013 Undriven net), which silently
//   disables the alarm key gating (keys look permanently pressed).
// 2026-09-21 按键归口(用户要求, 场景四不再用 KEY4):
//   应急场景(alarm_en)期间 KEY1~KEY3 属于"四类告警选择":
//       KEY1 = 选择(顺序循环) / KEY2 = 减 / KEY3 = 加
//   此时把三键从 ui_key_ctrl 的输入上"截走"(恒接高=未按下), 避免同一次
//   按键既切告警类型、又去调亮度/缩放/周期。非应急时三键含义完全不变。
wire ui_key1 = alarm_en ? 1'b1 : key1;
wire ui_key2 = alarm_en ? 1'b1 : key2;
wire ui_key3 = alarm_en ? 1'b1 : key3;

ui_key_ctrl #(
    .BRI_INIT            (4'd8)
) ui_key_ctrl_m0(
    .clk                 (sd_card_clk          ),
    .rst                 (~rst_n_sd            ),
    .key1                (ui_key1             ),
    .key2                (ui_key2             ),
    .key3                (ui_key3             ),
    .img_no              (img_no               ),
    .scene_chg           (scene_change_pulse   ),
    .mode                (ui_mode              ),
    .bri_level           (bri_level            ),
    .res_level           (res_level            ),
    .period_sec          (ui_period_sec        ),
    .period_cycles       (ui_period_cyc        ),
    .disp_hold           (ui_disp_hold         ),
    .disp_sel            (ui_disp_sel          ),
    .pic_manual          (pic_manual           ),
    .pic_param           (pic_param            ),
    .key_next_pl         (key_next_pl          ),
    .key_prev_pl         (key_prev_pl          ),
    .res_chg_pl          (res_chg_pl           ),
    .key2_pl             (key2_pl             ),  // 模式4: 会议计时 开始/暂停/继续
    .key3_pl             (key3_pl             )   // 模式4: 当前议程项 重新计时
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
// 场景层使能(会议/抢答/应急):
//   会议 = 内容源 latch=2 且非应急; 抢答 = latch=3 且非应急;
//   应急 = emergency(最高优先级, 覆盖前两者)。
//   (latch_sw/menu_active/emergency 均已在 scene_control 内 sd 域寄存;
//    下游 osd_scene 内部两级同步, 无亚稳态风险)
//============================================================
assign meeting_en = (latch_sw == 3'd2) & ~emergency;
assign quiz_en    = (latch_sw == 3'd3) & ~emergency;
assign alarm_en   = emergency;

// 四类应急告警选择(KEY1 选 / KEY2 减 / KEY3 加), 进入应急默认火灾并清零计时。
emergency_alarm_ctrl #(.CLK_HZ(100_000_000)) u_alarm_type_ctrl(
    .clk(sd_card_clk), .rst(~rst_n_sd), .alarm_en(alarm_en),
    .key1_raw(ui_key1), .key2_raw(ui_key2), .key3_raw(ui_key3),
    .alarm_type(alarm_type), .elapsed_m_tens(alarm_mt), .elapsed_m_ones(alarm_mo),
    .elapsed_s_tens(alarm_st), .elapsed_s_ones(alarm_so)
);

//============================================================
// 抢答台控制(quiz_ctrl, sd_card_clk 域):
//   4 路选手键 → 同步+20ms 消抖 → 片内并行仲裁(同拍多路按 1>2>3>4
//   优先, 锁存后忽略后续) → 锁存胜者; 10s BCD 倒计时; 归零判超时。
//   仅在抢答场景(quiz_en)生效, 离开场景自动回"等待开始"。
//   外扩引脚见 top.adc(quiz_btn[3:0]/quiz_start/quiz_reset)。
//============================================================
quiz_ctrl #(
    .TIME_SEC            (8'd10              )
) quiz_ctrl_m0(
    .clk                 (sd_card_clk       ),
    .rst                 (~rst_n_sd         ),
    .en                  (quiz_en           ),
    .player_raw          (quiz_btn          ),
    .start_raw           (quiz_start        ),
    .clear_raw           (quiz_reset        ),
    .qstate              (q_state           ),
    .winner              (q_winner          ),
    .t_tens              (q_t_tens          ),
    .t_ones              (q_t_ones          )
);

// 底层轮播使能: 应急冻结 或 手动单张(pic_manual)时停自动计时
assign bmp_slide_en = slideshow_en & ~pic_manual;

//SD card BMP file read(按键消抖已由 ui_key_ctrl 完成, 此处只收脉冲;
//                     zone_load=场景切换 → 分区重载)
sd_card_bmp  sd_card_bmp_m0(
	.clk                        (sd_card_clk              ),
	.rst                        (~rst_n_sd_rdy ),
	.state_code                 (state_code               ),
	.bmp_width                  (16'd640                 	),  //image width
	.key_next                   (key_next_pl              ),
	.key_prev                   (key_prev_pl              ),
	.slide_en                   (bmp_slide_en             ),
	.slide_interval             (ui_period_cyc            ),  //批次4 周期档(2/3/5/10/30s)
	.zone_start                 (zone_start_l             ),
	.zone_wrap                  (zone_wrap_l              ),
	.zone_max_img               (zone_max_l               ),
	.zone_load                  (zone_load_l              ),
	.reload_req                 (res_chg_pl               ),
	// ---- 会议议程配置(TF 卡固定扇区 200000, MTG1 字节流; 开机独占读 3 扇区) ----
	.mtg_start_sector           (32'd200000                ),
	.mtg_ram_we                 (mtg_ram_we               ),
	.mtg_ram_addr               (mtg_ram_addr             ),
	.mtg_ram_data               (mtg_ram_data             ),
	.mtg_ready                  (mtg_ready                ),
	.mtg_error                  (mtg_error                ),
	.mtg_total                  (mtg_total                ),
	.mtg_done                   (mtg_done                 ),
	.write_req                  (sd_card_write_req        ),
	.write_req_ack              (write_req_ack_sd         ),  // ext_mem_clk→sd_card_clk 已两级同步(见 u_sync_wr_ack)
	.write_en                   (sd_card_write_en         ),
	.write_data                 (sd_card_write_data       ),
	.img_no                     (img_no                   ),
	.img_busy                   (img_busy                 ),
	.bmp_error                  (bmp_error                ),
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
//             (批次4: 参数刚被改动 → 该值强制保持显示 2 秒后自动返回,
//              见 ui_key_ctrl 的 disp_hold/disp_sel; 默认观感与之前一致)
//   第5位 = 功能模式号(0图片/1亮度/2分辨率/3周期) → seg_data_4
//   第6、7位 = 固定横线 "-" 分隔符      → seg_data_5/6
//             (批次3: bmp_error≠0 时改为显示 "E" + 错误码 十六进制数字,
//              即加载出错时第6位=E、第7位=1~3, 正常无错恢复横线。)
//   第8位 = A=自动轮播 / H=手动单张      → seg_data_7
//============================================================
// 参数强显保持: 保持期内用"动作发生时的模式"取值, 否则用当前模式
//   (disp_sel 只会是 1/2/3 之一 —— 只有模式1/2/3 会产生参数动作)
wire [1:0] disp_mode = ui_disp_hold ? ui_disp_sel : ui_mode;

// 当前模式对应的参数值(0..255)
reg [7:0] param_val;
always @(*) begin
    case (disp_mode)
        2'd1:    param_val = {4'd0, bri_level};   // 亮度档 0..15
        2'd2:    param_val = {4'd0, res_level};   // 分辨率档 0..7
        2'd3:    param_val = ui_period_sec;       // 轮播间隔秒 2/3/5/10/30
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
	.seg_data_0                 ({1'b1, dec_scene}        ),
	.seg_data_1                 (blank_h ? SEG_BLANK : {1'b1, dec_h}),
	.seg_data_2                 (blank_t ? SEG_BLANK : {1'b1, dec_t}),
	.seg_data_3                 ({1'b1, dec_o}            ),
	.seg_data_4                 ({1'b1, dec_mode}         ),
	.seg_data_5                 (err_show ? {1'b1, 7'b000_0110} : SEG_DASH), // 出错=字母E, 正常=横线
	.seg_data_6                 (err_show ? {1'b1, dec_err}      : SEG_DASH), // 出错=错误码, 正常=横线
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
//     menu_active / welcome_en / meeting_en|quiz_en|alarm_en 为 SW 单选,
//     且应急时 menu_active=0、welcome_en=0, 任一时刻至多一路发读请求。
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
    .menu_en      (menu_active),
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
// 会议/抢答/应急 场景 OSD 叠加(osd_scene, 阶段2d 扩展)
//   输入 = osd_welcome 输出(背景流 + 同拍坐标)
//   叠加 = 会议(标题条/运行时长面板/4 页公告翻页/滚动会务提示)
//        / 抢答(标题条/状态面板/2× 倒计时+秒/滚动须知)
//        / 应急(顶条 4Hz 闪烁+警示三角/深红标题/滚动疏散告警)
//   三场景互斥(SW 单选)共用一片字形 ROM; 三使能全 0 时纯透传。
//   输出像素流 + 坐标送 display_adjust。
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
    .meeting_en   (meeting_en),
    .quiz_en      (quiz_en),
    .alarm_en     (1'b0), // 四类应急画面由下级 emergency_multi_overlay 统一绘制
    .qstate       (q_state),
    .winner       (q_winner),
    .t_tens       (q_t_tens),
    .t_ones       (q_t_ones),
    .run_hh       (run_hh),
    .run_mm       (run_mm),
    .run_ss       (run_ss),
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
// 会议议程控制链(2026-09-21 从 fpgapmzs main ee717b2 移植上板)
//   数据流: TF 卡固定扇区 200000 →(sd_card_bmp 内 meeting_sd_rd, sd 域)
//           → meeting_cfg(BRAM + video 域快照) → meeting_ctrl(七状态计时)
//           ⇄ meeting_osd(会议画面, 串在 osd_scene 与应急叠层之间)
//   按键  : 只在"会议场景(latch=2) + 功能模式4"下, 把 KEY2/KEY3 的消抖脉冲
//           跨到 video 域接 meeting_ctrl 的 press[0](开始/暂停/继续)与
//           press[3](当前项重新计时); 其它场景/模式完全不采用 → 原有按键
//           功能(亮度/缩放/周期/切图)一字未改。
//   ※ 会议逻辑全部在 video_clk(25MHz) 域, 故 SEC_CYCLES=25_000_000。
//   ※ 与应急的关系: meeting_en 已含 ~emergency, 应急时 meeting_osd 使能=0
//     纯透传, 四类应急画面仍由下级 emergency_multi_overlay 全屏绘制。
//============================================================
// ---- 使能/告警 电平跨域(sd_card_clk → video_clk, 两级同步) ----
sync_2ff u_sync_meet_en (.clk(video_clk), .async_in(meeting_en), .sync_out(meeting_en_v));
sync_2ff u_sync_alarm   (.clk(video_clk), .async_in(emergency ), .sync_out(alarm_v     ));

// ---- 会议按键脉冲跨域: sd 域单拍(10ns) vs video 拍(40ns), 直接两级同步会漏采,
//      故先转"翻转电平", 同步后再做边沿检测还原单拍脉冲 ----
wire k2_meet = key2_pl & meeting_en & (ui_mode == 3'd4);
wire k3_meet = key3_pl & meeting_en & (ui_mode == 3'd4);

reg k2_tog, k3_tog;
always @(posedge sd_card_clk) begin
    if (!rst_n_sd) begin k2_tog <= 1'b0; k3_tog <= 1'b0; end
    else begin
        if (k2_meet) k2_tog <= ~k2_tog;
        if (k3_meet) k3_tog <= ~k3_tog;
    end
end

reg k2_s0, k2_s1, k2_s2, k3_s0, k3_s1, k3_s2;
always @(posedge video_clk) begin
    if (!rst_n_vid) begin
        k2_s0 <= 1'b0; k2_s1 <= 1'b0; k2_s2 <= 1'b0;
        k3_s0 <= 1'b0; k3_s1 <= 1'b0; k3_s2 <= 1'b0;
    end
    else begin
        k2_s0 <= k2_tog; k2_s1 <= k2_s0; k2_s2 <= k2_s1;
        k3_s0 <= k3_tog; k3_s1 <= k3_s0; k3_s2 <= k3_s1;
    end
end

wire meet_press_start  = k2_s1 ^ k2_s2;   // 1 拍: 开始/暂停/继续
wire meet_press_retime = k3_s1 ^ k3_s2;   // 1 拍: 当前议程项重新计时

// ---- 配置存储 + 视频域快照(写口在 sd 域, 读口在 video 域) ----
meeting_cfg meeting_cfg_m0(
    .wr_clk         (sd_card_clk        ),
    .wr_en          (mtg_ram_we         ),
    .wr_addr        (mtg_ram_addr       ),
    .wr_data        (mtg_ram_data       ),
    .cfg_ready      (mtg_ready          ),
    .cfg_error      (mtg_error          ),
    .cfg_total      (mtg_total          ),
    .cfg_current    (mtg_current        ),
    .clk            (video_clk          ),
    .rst            (~rst_n_vid         ),
    .rd_addr        (mo_cfg_addr        ),  // meeting_osd 取字地址
    .rd_data        (mo_cfg_byte        ),  // 配置 BRAM 取字数据(晚地址一拍)
    .ready          (mtg_cfg_ready_v    ),
    .error          (mtg_cfg_error_v    ),
    .total          (mtg_total_v        ),
    .duration       (mtg_duration_v     ),
    .next_duration  (mtg_next_duration_v)
);

// ---- 七状态议程计时(会议场景内使能; 配置有效才走计时) ----
meeting_ctrl #(
    .SEC_CYCLES     (25_000_000         )   // video_clk = 25.000MHz
) meeting_ctrl_m0(
    .clk            (video_clk          ),
    .rst            (~rst_n_vid         ),
    .en             (meeting_en_v       ),
    .config_ready   (mtg_cfg_ready_v    ),
    .alarm          (alarm_v            ),
    .press          ({meet_press_retime, 1'b0, 1'b0, meet_press_start}),
    .end_long       (1'b0               ),  // 本板只用 KEY2/KEY3 两个功能, 不设长按
    .home_long      (1'b0               ),
    .total          (mtg_total_v        ),
    .duration       (mtg_duration_v     ),
    .state          (mtg_state          ),
    .current        (mtg_current        ),
    .remaining      (mtg_remaining      ),
    .overtime       (mtg_overtime       ),
    .alarm_paused   (mtg_alarm_paused   ),
    .warn_event     (                   ),
    .timeout_event  (                   ),
    .uptime         (mtg_uptime         )
);

// ---- 会议场景画面(插在 osd_scene 与应急叠层之间) ----
//   使能 = 会议场景 且 配置已就绪: 配置缺失(TF 卡没写 MTG1 扇区)时本层不画,
//   自动退回 osd_scene 原有的"会议公告"画面(优雅降级; osd_scene 一字未改)。
meeting_osd meeting_osd_m0(
    .clk            (video_clk          ),
    .rst            (~rst_n_vid         ),
    .en             (meeting_en_v & mtg_cfg_ready_v),
    .alarm          (alarm_v            ),
    .hs_i           (sc_hs              ),
    .vs_i           (sc_vs              ),
    .de_i           (sc_de              ),
    .data_i         (sc_data            ),
    .px_x           (sc_px_x            ),
    .px_y           (sc_px_y            ),
    .state          (mtg_state          ),
    .current        (mtg_current        ),
    .total          (mtg_total_v        ),
    .remaining      (mtg_remaining      ),
    .overtime       (mtg_overtime       ),
    .next_duration  (mtg_next_duration_v),
    .uptime         (mtg_uptime         ),
    .alarm_paused   (mtg_alarm_paused   ),
    .cfg_addr       (mo_cfg_addr        ),  // 取字地址 → 配置 BRAM
    .cfg_byte       (mo_cfg_byte        ),  // 取字数据(晚地址一拍)
    .hs_o           (mo_hs              ),
    .vs_o           (mo_vs              ),
    .de_o           (mo_de              ),
    .data_o         (mo_data            ),
    .px_x_o         (mo_px_x            ),
    .px_y_o         (mo_px_y            ),
    .notice_sel     (mtg_notice_sel     ),
    .overview_index (mtg_ov_index       )
);

emergency_multi_overlay u_emergency_multi(
    .clk(video_clk),.rst(~rst_n_vid),.hs_i(mo_hs),.vs_i(mo_vs),.de_i(mo_de),
    .data_i(mo_data),.px_x(mo_px_x),.px_y(mo_px_y),.alarm_en(alarm_en),
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
	    .bri_level    (bri_level),
	    .res_level    (res_level),
	    .pic_manual   (pic_manual),
	    .ui_mode      (ui_mode),
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
sync_2ff u_audio_menu_sync(.clk(video_clk),.async_in(menu_active),.sync_out(audio_menu_sync));
sync_2ff u_audio_emergency_sync(.clk(video_clk),.async_in(emergency),.sync_out(audio_emergency_sync));
sync_2ff u_audio_scene0_sync(.clk(video_clk),.async_in(scene_id[0]),.sync_out(audio_scene_sync[0]));
sync_2ff u_audio_scene1_sync(.clk(video_clk),.async_in(scene_id[1]),.sync_out(audio_scene_sync[1]));
audio_feature_events u_feature_events(
 .clk(video_clk),.rst_n(rst_n_vid),.menu_active(audio_menu_sync),.emergency(audio_emergency_sync),
 .scene_id(audio_scene_sync),.q_state(q_state),.q_t_tens(q_t_tens),.q_t_ones(q_t_ones),
 .event_valid(feature_event_valid),.event_kind(feature_event_kind),.event_media(feature_event_media));
audio_pcm_tone #(.PROFILE(0)) u_zero_source(
 .clk(video_clk),.rst_n(rst_n_vid),.enable(1'b0),.sample_valid(zero_valid),.sample_ready(zero_ready),
 .sample_left(zero_left),.sample_right(zero_right),.overflow(zero_overflow),.sample_count(audio_zero_samples));
scene_audio_final u_scene_audio(
 .clk(video_clk),.rst_n(rst_n_vid),.event_valid(feature_event_valid),.event_kind(feature_event_kind),
 .media_id(feature_event_media),.menu_active(audio_menu_sync),.emergency(audio_emergency_sync),
 .active_scene(audio_scene_sync),
 .sample_valid(media_valid),.sample_ready(media_ready),.sample_left(media_left),.sample_right(media_right),
 .sample_gain(media_gain),.overflow(media_overflow),.state_debug(media_state),.sample_count(audio_media_samples));
audio_src_mux u_audio_mux(
 .clk(video_clk),.rst_n(rst_n_vid),.test_valid(zero_valid),.media_valid(media_valid),
 .test_ready(zero_ready),.media_ready(media_ready),.test_left(zero_left),.test_right(zero_right),
 .media_left(media_left),.media_right(media_right),.media_gain(media_gain),
 .sample_valid(audio_pcm_valid),.sample_ready(audio_pcm_ready),.sample_left(audio_left),.sample_right(audio_right),
 .accepted_pairs(audio_mux_pairs));
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
// 恰好 48 kHz 的单拍脉冲(与 scene_audio_final 内部同一个算法)。
localparam integer AUDIO_CLK_HZ    = 25000000;
localparam integer AUDIO_SAMPLE_HZ = 48000;
reg [31:0] audio_rate_acc;
wire audio_rate_tick = (audio_rate_acc >= (AUDIO_CLK_HZ - AUDIO_SAMPLE_HZ));
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
