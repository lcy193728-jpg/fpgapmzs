# Final audio integration build; no simulation/download.
set board_dir [file normalize [file join [file dirname [info script]] ..]]
set prj [file join $board_dir .. pic_sdram_audio_final.al]
set adc [file join $board_dir .. top.adc]
set sdc [file join $board_dir .. audio_board integrated audio.sdc]
set name pic_sdram_audio_final
set out [file join $board_dir build]
file mkdir $out
cd [file dirname $prj]
import_device eagle_s20.db -package EG4S20BG256
open_project $prj -single_run
load_run_param -run syn_1
cd $out
elaborate -top top
read_adc $adc
read_sdc $sdc
optimize_rtl
report_area -file ${name}_rtl.area
optimize_gate ${name}_gate.area
legalize_phy_inst
update_timing
report_timing_summary -file ${name}_gate.timing
export_db ${name}_gate.db
load_run_param -run phy_1
#---------------------------------------------------------------------
#   [2026-10-02 二次改动: 修 bmp_read_auto 复位默认分区] 改动 =
#     ZONE_START/WRAP/MAX 由老卡 126000/400000/5 改为新卡菜单区 15936/26888/4
#     (仅参数默认值变化 → netlist 变化)。seed=35 退化到 SWNS -0.216ns(被闸门拦下)。
#   复用本次综合的 gate.db(14:24) 重扫: 31 +0.284(0 违例, HWNS +0.020) 通过。
#   → 本次固定 seed=31。RTL/SDC 未改, 仅布局种子。
#
#   [2026-10-02 三次改动: 修 1280×960 偏色 + 拆 len_ok 长组合路径]
#     src/bmp_read_auto.v 两处 RTL 改动:
#     ① 2× 源水平均值位宽修复 —— 原 (a+b)>>1 按 8bit 运算丢进位, 凡同通道
#        和 ≥256 的像素对输出恒小 128(实测 200+200 得 72 而非 200、255+255
#        得 127 而非 255), 即上板"迎新 1280 图偏色/色差"真根因; 640 源走直通
#        不经此路故正常。改为先零扩展 9bit 求和再取 [8:1], 对齐小鹅通官方
#        bmp24_decoder.average_four 写法。
#     ② 长度校验 len_ok 由单拍改为 rd_cnt 26/27/28 三级打拍 —— 原一拍内含
#        "dim_2x mux(依赖 height) + 32bit 变长加 + 32bit 比较", post-route
#        实测 9.772ns / 9 级(ADDER=4), sd_card_clk SWNS=-0.052ns(1 违例),
#        违反 BOARD_CHECKLIST C9「100MHz 域单条组合 ≤8ns」。
#     两次改动均先过 ModelSim: 新增 tb/tb_bmp_2x_decim.v(1280 专项, 7/7 PASS,
#       并已在修复前版本上复现 FAIL 证明用例有效) + 既有 tb_bmp_read_auto.v
#       回归 27 PASS / 0 FAIL。
#     → netlist 变化后 seed=31 直接过闸门: SWNS +0.148ns / HWNS +0.020ns,
#       6764+4484 端点 0 违例, 无需重扫种子。资源 BRAM 63/64(98.44%)最紧。
#
#   [2026-10-02 四次改动: 多分辨率自适应缩放器(320/640/1024/1280 → 640)]
#     src/bmp_read_auto.v 通用"640 相位累加器 + 箱式平均"横向缩放 + 纵向隔行抽取,
#     纵向 2×(源高 240)交下游 bmp_scale(新增 src_v2x 端口, 0 新增 BRAM);
#     src/display_adjust.v 右上角分辨率字幕由 2 档扩为 4 档(320x240/640x480/
#       1024x768/1280x960); top_final.v / top.v / top_audio.v 三处顶层连线同步。
#     ⚠ 期间修掉一处 TD 报错: img_v2x 曾被两个 always 块同时驱动
#       (HDL-8007 net constantly driven from multiple places) → 头部解析块
#       单一驱动(复位 + rd_cnt==54 锁存), 主状态机复位块不再写它。
#     netlist 变化后 seed=31 布线拥塞失败(RUN-8102/PHY-8023, 单点冲突
#       (x22y20_local6), 非资源超限: LUT 88.14% / BRAM 63/64 与改动前同量级)。
#     复用本次 gate.db(17:10) 重扫: seed 35 直接通过 —— SWNS +0.133ns /
#       HWNS +0.020ns, 0 违例, 布线无冲突。
#   → 本次固定 seed=35。
#
#   [2026-10-02 五次改动: 320 档横向由"最近邻复制"升级为线性插值 + 两处时序重构]
#     src/bmp_read_auto.v:
#     ① 320→640 横向线性插值 —— 原"每源像素复制 2 次"产生 2 像素台阶、细笔画
#        粘连(小鹅通第十三讲 2.3 节: "全屏模式应用双线性")。改为
#        偶列 out[2k]=s[k]; 奇列 out[2k+1]=mid(s[k],s[k+1]), 末列边缘钳位 →
#        与 Python LANCZOS 参考的笔画轮廓一致(tb 逐像素比对 [s0,(s0+s1)/2,s1,…])。
#        需要"左邻像素", 故新增 prev_pix 寄存 + 9bit 零扩展求和(守 C11);
#        行首只送 1 列、行尾多补 1 列 → 每行仍恰 640 列。源像素间隔约束 4→6 拍。
#     ② 放大发射状态机去计数器 —— 原 up_left 每拍自减引入"减法→比较→次态"长链
#        (post-route 12.65ns/8 级, SWNS −2.93ns/86 违例端点)。改为
#        "up_st 状态本身即进度 + up_more 静态标志", 次态只依赖寄存器 → 单级 LUT。
#     ③ 纵向行选择提前一拍 —— 原 rsel_use = row_start ? f(vacc 组合) : row_sel
#        让 vacc → +480 → 比较 → mux → 箱累加/计数 → hacc/bmp_data 形成横跨
#        纵/横的长链(12.269ns/11 级, 布线占 7.34ns/62%)。改为本行末预算
#        rsel_pend, 行首只读寄存器; vacc 更新逻辑一字未改 → 行选择序列逐拍等价。
#        ★期间踩坑: 第一版同时把 vacc 也提前(错在 row_sel 必须用"本行起始相位"
#          判定)→ 1024×768 行选择整体错位, tb_bmp_multires 立刻 FAIL(这正是
#          该 TB 的价值)。改成"只提前行选择、vacc 原样"即恢复 ALL PASS。
#     ⚠ 副作用: 逻辑较基线 +~590 LUT(16967→17557, 89.58%)→ seed 35 对本次
#       netlist 布得极差(最差路径在 sd_card_cmd 里, 逻辑仅 6 级但布线占 82%,
#       纯布局问题)。复用本次 gate.db 并行扫 16 个种子:
#         17 +0.174 | 31 +0.206 (均 PASS) | 29 −0.071 | 37 −0.693
#       → 选 seed 31(SWNS 余量更大)。
#     仿真: 全量回归 16 套 0 FAIL/0 ERROR(tb_bmp_multires 15 PASS, 含 320 线性
#       插值逐像素比对; tb_bmp_2x_decim 8 PASS 守住 1280 不回退;
#       tb_bmp_read_auto 27 PASS), 并已用"禁用插值"对照版复现 FAIL 证明用例有效。
#   → 本次固定 seed=31。
#
# 布局种子固定为 31 —— 由 tools/sweep_place_seed.tcl 对"当前 netlist"扫出来的最优解。
#   [2026-10-02 换卡 G: 后重扫] 本次改动 = top_final.v 的 Z_* 分区常量整体
#     由老卡 F:(偏移 2048) 改为新卡 G:(偏移 64): 迎新=第5~8张(含 2×1280)、
#     会议=第1张、抢答=第2张、应急复用抢答区。仅常量变化 → netlist 变化,
#     原 seed=19 布局退化到 sd_card_clk SWNS -2.074ns(不达标)。
#   复用当次综合的 gate.db(12:19) 重扫种子 20..35(结果见 seed*.timing):
#     20 -0.909 | 21 +0.101 | 22 -0.141 | 23 +0.147
#     24 -0.939 | 25 +0.170 | 26 -0.180 | 27 +0.103
#     28 -1.911 | 29 -0.212 | 30 -0.078 | 31 +0.284
#     32 +0.091 | 33 +0.067 | 34 +0.190 | 35 +0.314(0 违例, HWNS +0.020ns)
#   → 固定 seed=35 过闸门。RTL/SDC 一字未改, 仅布局种子。
#
#   [历史] 2026-10-02 多分辨率改动后: seed 19 +0.271 最优。
#         2026-10-01 合入 dev_sim 会议改动后: seed 12 +0.169ns 最优。
#         加 WAV 播放器时扫过种子 1..8: 4 最优(+0.263)。
#---------------------------------------------------------------------
#   [2026-10-02 21:40 重扫] Z_* 场景分区常量改为「卷内+64」口径后 netlist 变化,
#     seed 31 退化到 SWNS -0.001ns(1 违例端点), 复用 21:00 的 gate.db 重扫:
#       37 -0.212 | 31 -0.001 | 17 +0.102(0 违例) | 29 -1.326
#     → 固定 seed=17。
set_param place seed 17
place
route
# 官方 DefaultFlow.tcl 的收尾步骤: route 之后跑一次 fix_hold 修保持时间,
# 否则短路径(尤其 hdmi IP 内部 1 级逻辑的 EMB 写数据)会留下 hns 负值。
fix_hold
update_timing -mode final
report_area -io_info -file ${name}_phy.area
report_timing_summary -file ${name}_pr.timing
report_timing_exception -file ${name}_exception.timing
bitgen -bit ${name}.bit
puts "FINAL_AUDIO_BUILD_COMPLETE: [file join $out ${name}.bit]"
# 必须显式 exit: td_commands_prompt.exe 在脚本自然结束后不退出进程,
#   上层 build.ps1 的 `& $taskExe` 会永久阻塞(官方脚本一律以 exit 收尾)。
exit
