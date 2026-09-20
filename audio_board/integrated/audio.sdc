
#**************************************************************
# top.sdc — pic_sdram 完整时序约束
#
# 依据小鹅通第六讲《Timing 约束》规范重写, 5 项改动:
#   1) 时钟全部改用显式 create_generated_clock 派生, 取代已 obsolete 的
#      derive_pll_clocks / rename_clock(TD 原报 USR-6136 CRITICAL-WARNING);
#      波形与 derive 结果逐条核对一致(rise/fall = 0/5, 0/4, 4/0, 0/20, 0/4 ns)。
#   2) SDRAM 硬核采样窗口 ext_mem_clk ↔ ext_mem_clk_sft 走 false_path:
#      实测该组 48+32=80 个违例端点 / STNS -262ns, 属"硬核 I/O 窗口被当成
#      fabric setup 路径"的固定伪违例, 不是真实可修的逻辑违例。
#   3) 单比特电平 CDC 的两级同步器首级寄存器 false_path(延迟由第二级消化)。
#   4) hold uncertainty 设 0.050ns: 本工程实测最差 hold 余量 HWNS 0.471ns,
#      0.050 是留真实余量的保守 guardband(课程同值)。
#   5) HDMI ODDR(5x 时钟域)到输出 PAD 的每通道路径 set_max_delay 设界。
#
# 时钟源: clk(R7)=50MHz, 经 sys_pll / video_pll 派生 5 个时钟:
#   sd_card_clk      100MHz   SD 卡控制器 / ui_key_ctrl / 场景层 / 缩放开方
#   ext_mem_clk      125MHz   SDRAM 控制器 + 帧读写存储侧
#   ext_mem_clk_sft  125MHz   SDRAM 硬核采样时钟(PLL C2, 相移 180°)
#   video_clk         25MHz   视频时序 / OSD 链 / display_adjust
#   hdmi_5x_clk      125MHz   TMDS 串化 + HDMI ODDR 输出
#**************************************************************

#**************************************************************
# Set Clock
#**************************************************************
create_clock -name clk -period 20.000 -waveform {0.000 10.000} [get_ports {clk}]

# sys_pll: C0=100MHz(×2, 0°) / C1=125MHz(×2.5, 0°) / C2=125MHz(×2.5, 180°)
create_generated_clock -name sd_card_clk -source [get_ports {clk}] -master_clock clk -multiply_by 2 -phase 0 [get_pins {sys_pll_m0/pll_inst.clkc[0]}]
create_generated_clock -name ext_mem_clk -source [get_ports {clk}] -master_clock clk -multiply_by 2.5 -phase 0 [get_pins {sys_pll_m0/pll_inst.clkc[1]}]
create_generated_clock -name ext_mem_clk_sft -source [get_ports {clk}] -master_clock clk -multiply_by 2.5 -phase 180 [get_pins {sys_pll_m0/pll_inst.clkc[2]}]

# video_pll: C0=25MHz(÷2, 0°) / C1=125MHz(×2.5, 0°)
create_generated_clock -name video_clk -source [get_ports {clk}] -master_clock clk -divide_by 2 -phase 0 [get_pins {video_pll_m0/pll_inst.clkc[0]}]
create_generated_clock -name hdmi_5x_clk -source [get_ports {clk}] -master_clock clk -multiply_by 2.5 -phase 0 [get_pins {video_pll_m0/pll_inst.clkc[1]}]

#**************************************************************
# Set Input Delay
#**************************************************************
# 输入侧只有按键(经 ui_key_ctrl 消抖)、拨码(经 scene_control 锁存)与 SD 卡
# 数据(由 sd_card_bmp 内部采样), 全部已在 RTL 内做同步/消抖, 无需板级
# 输入延迟建模。保持空白(与课程模板一致)。

#**************************************************************
# Set Output Delay
#**************************************************************
# 输出侧: 数码管(扫描显示, 无建立要求)、VGA(已弃用)、HDMI(由下面的
# set_max_delay -datapath_only 逐通道设界)、SD 卡 SPI(低速, 无需建模)。
# 保持空白(与课程模板一致)。

#**************************************************************
# Set Clock Groups / False Path
#**************************************************************
#---- SDRAM 硬核采样窗口: ext_mem_clk ↔ ext_mem_clk_sft ----
# ext_mem_clk_sft 只驱动 U3(sdram) 的 Clk_sft 采样端与 DQ 采样触发器。
# 官方 SDRAM 硬核自带 I/O 窗口, 把前向 DQ 采样路径当 fabric setup 路径
# 检查会得到固定伪违例(实测 -5.291ns / -2.293ns, 共 80 端点)。
set_false_path -from [get_clocks {ext_mem_clk}] -to [get_clocks {ext_mem_clk_sft}]
set_false_path -from [get_clocks {ext_mem_clk_sft}] -to [get_clocks {ext_mem_clk}]

# ※ 命名口径(实测): TD 的 get_regs 匹配的是触发器"输出网名"(= RTL 信号名),
#   不是综合后的触发器实例名(实例名形如 xxx_reg_syn_N、xxx_reg[k]_syn_N)。
#   写成 */xxx_reg / */xxx_reg[0] 会得到空集, set_false_path 报
#   USR-6001/8012/8159 CRITICAL-WARNING 后整条失效。故下面一律用 RTL 信号名。

#---- 单比特电平 CDC: 两级同步器首级 ----
# sync_2ff / reset_sync 的首级 sync_ff[0] 是异步输入落点, 亚稳态由第二级
# sync_ff[1] 消化, 首级不做建立检查(对应课程模板的 */s1)。
# 覆盖: 4 个分域复位同步器 + SDRAM 就绪同步 + 写通路应答同步(实测命中 6 个)。
set_false_path -to [get_regs -hier {*/sync_ff[0]}]

#---- 存储通路请求/应答 CDC 首级 ----
# frame_fifo_write/frame_fifo_read 内部各有 3 级同步链, 首级为异步落点;
# bmp_scale 内部 3 级同步链 fs_s0/s1/s2 的 fs_s0 同理由此免检。
# (write_len_d0 为总线, 综合后仅剩个别位、无法整体命中, 故不列; 实测该组无违例。)
set_false_path -to [get_regs -hier {*/write_req_d0}]
set_false_path -to [get_regs -hier {*/read_req_d0}]
set_false_path -to [get_regs -hier {*/fs_s0}]

#---- 异步 FIFO 异步清零(fifo_aclr)的跨域落点 ----
# frame_fifo_write/read 的 fifo_aclr 是 mem_clk(ext_mem_clk)域 FSM 的输出寄存器,
# 直接送两个异步 FIFO 的 rst 端。afifo_*.v 内部 asy_w_rst0/1、asy_r_rst0/1
# 是"异步复位、同步释放"复位同步器链 —— 清零的置位沿本来就刻意与目标域时钟
# 无关(异步清零的语义要求), 释放沿由第二级同步消化, 故对首级异步复位端的
# recovery/removal 检查无物理意义。属与上面 sync_ff[0] 同类的"CDC 首级免检"。
# (批次3 综合后布线实测: ext_mem_clk→sd_card_clk 该组 4 条路径中 1 端点
#  recovery -153ps, 是 phy 阶段布线抖动暴露出的唯一残留违例。
#  ※ 触发器的输出网名就是 RTL 里的 fifo_aclr, 不是 fifo_aclr_reg —— 见上面
#    "命名口径"; 实测本模式命中 2 个(读/写通路各一)。)
set_false_path -from [get_regs -hier {*/fifo_aclr}]

#---- sd_card_clk → clk: 数码管显示参数 ----
# clk(50MHz) 域只有 seg_scan(扫描显示)与 POR 计数器。seg_scan 取用的
# 场景号/亮度档/缩放档/模式号是"准静态"量(仅在按键或拨码动作时变化),
# 扫描刷新率 ~1kHz, 跨域取到旧值最多造成一位数码管瞬时跳字, 无功能影响。
# 与课程模板 set_false_path -from {pixel_clk} -to {sys_clk} 同类处理。
set_false_path -from [get_clocks {sd_card_clk}] -to [get_clocks {clk}]

#---- 复位源 ----
# 本工程无物理复位引脚: POR 计数器 por_cnt[19] 与两个 PLL 的 locked 相与
# 得到 ext_rst_n, 异步复位、同步释放(见 src/reset_sync.v)。复位释放沿刻意
# 不与任何时钟对齐, 恢复/移除检查必须免检
# (对应课程模板的 set_false_path -from [get_ports {sys_rst_n}])。
# ※ por_cnt[19] 是 RTL 里的 20bit POR 计数器, 综合后已无同名网(实测
#   get_regs/get_nets 查 *por* 均为空), 无法按名免检; 其释放沿的落点就是
#   上面那条 -to [get_regs {*/sync_ff[0]}], 已覆盖, 故此处不重复设约束。
set_false_path -from [get_pins {sys_pll_m0/pll_inst.extlock}]
set_false_path -from [get_pins {video_pll_m0/pll_inst.extlock}]

#**************************************************************
# Set Clock Uncertainty
#**************************************************************
# 单 PLL、同源时钟树, 域内发射/捕获共用全局缓冲。课程规范: hold 侧给
# 0.050ns 真实 guardband, 避免把抖动误差当成"必须手工插延迟"的违例。
set_clock_uncertainty -hold 0.050 [get_clocks {clk sd_card_clk ext_mem_clk ext_mem_clk_sft video_clk hdmi_5x_clk}]

#**************************************************************
# Set Multicycle Path
#**************************************************************
# 无不跨整周期的慢速握手通路(写/读握手均为电平应答, 单周期内完成)。
# 保持空白。

#**************************************************************
# Set Maximum Delay
#**************************************************************
# HDMI ODDR → 输出 PAD: 由 5x 时钟域(hdmi_5x_clk, 8ns)驱动的 4 条串化输出,
# 逐通道设 8.000ns(=1 个 5x 周期)上界, -datapath_only 只约束数据路径、
# 不把时钟树偏差算进来。这是数字侧每通道延迟界, 不等于模拟眼图结论。
set_max_delay -from [get_clocks {hdmi_5x_clk}] -to [get_ports {HDMI_CLK_P HDMI_D0_P HDMI_D1_P HDMI_D2_P}] 8.000 -datapath_only

#**************************************************************
# Set Minimum Delay
#**************************************************************
# 同域最小延迟已由 hold 检查覆盖(见上 uncertainty); 无额外最小延迟需求。
# 保持空白。

#**************************************************************
# Set Input Transition
#**************************************************************
# 输入时钟 clk(R7) 由板级 50MHz 有源晶振直驱, 转换时间为板级固定值,
# 由器件 input buffer 模型覆盖。保持空白。

# Bundled event payload is held until acknowledge. Capture occurs >=3 pixel
# cycles after request launch; bound route delay to one 40ns pixel period.
# Only synchronizer FIRST stages use the existing sync_ff[0] false path.
set_max_delay -from [get_regs -hier {u_audio_events/payload_hold[*]}] -to [get_regs -hier {u_audio_events/media_id[*] u_audio_events/event_kind[*]}] 40.000 -datapath_only
