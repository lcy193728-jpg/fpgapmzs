# 上板前检查清单（持续追加版）

> 目的：每次“要求上板的代码”动手综合/烧录前，先按本清单核对；每次踩到**新的不同问题**，把 现象→根因→修复→预防 追加到对应分类，防止复发。
> 配合 `c:\Users\Lenovo\.trae-cn\memory\projects\...\project_memory.md` 的项目记忆使用。

---

## A. 工程文件 pic_sdram.al 与综合列表（黑盒类高发区）

- [ ] A1 凡是 top.v 新例化的**自研模块**，其 `.v` 源文件必须出现在综合列表（.al `<Verilog>` 组内，`UsedInSyn=true`，CompileOrder 递增）。
  - 缺登记的报错：`ERROR: xxx(...) is a black box in top.v(NNN)` + `CRITICAL-WARNING: instantiate unknown module`（HDL-8007 / HDL-7144）。
  - 判定：查 `pic_sdram.al` 是否含 `<File Path="src/xxx.v">` 且 `UsedInSyn Val="true"`。
- [ ] A2 **禁止在 TD 打开工程期间外部手工改 .al**——TD 关闭/保存时会用内存文件列表回写磁盘，把外部写入的登记条目删掉（曾两次删除 osd_welcome/display_adjust/bri_key_ctrl 登记）。
  - 新增源码首选：TD 内 GUI `右键 Design Sources → Add to Project`（软件自己维护，不丢）。
- [ ] A3 黑盒兜底加固：把强依赖模块用 **同目录 `include** 并入 top.v（先例：color_bar.v `include "video_define.v"`）。
  - 当前已 `include`：`ui_key_ctrl.v`、`osd_welcome.v`、`display_adjust.v`、`osd_scene.v`、`quiz_ctrl.v`（阶段 2d 新增）、`bmp_scale.v`（阶段 2e 新增）。
  - ⚠ include 后**不要再 GUI Add 同一文件**，否则模块重复定义。
  - ⚠ TD 的 include 解析支持“含入文件同目录”的相对名（src 内已证）。
- [ ] A4 综合前重新生成过比特流？确认这次综合的 top.v 确实包含目标功能（防止烧了旧比特流误判代码无效）。

## B. 综合/实现/下载流程

- [ ] B1 综合报错分诊顺序：
  1. `syntax error` → 看具体文件行（含 include 展开行要回原文件看）；
  2. `black box / unknown module` → 走 A1~A3；
  3. P&R/时序 → 看具体路径约束；
  4. 下载报错 → 与代码无关，走 B2。
- [ ] B2 下载/烧录报错排查（不是代码问题）：
  - 驱动/下载线/USB 连接；板子已上电；
  - 下载界面 Device = **EG4S20BG256**；
  - 临时跑 → JTAG 下载到 SRAM；赛题固化（上电即运行）→ **下载到配置 Flash/SPI**，两种模式别搞混。
- [ ] B3 改过 .al / 工程文件后：先**完全退出 TD**（含托盘），重开工程再综合，确保加载的是最新文件列表。
- [ ] B4 **素材与分区表一致性**（上板前，涉及 TF 卡时必查）：
  - 跑 `python tools/find_bmp.py --drive <盘符>`（**管理员权限**）核对：合格图张数、8 扇区对齐、各段 START/WRAP/IMGS；
  - `Z_*_IMGS` 必须 = 该段实际张数（多设会扫过头/串段，少设会少播）；
  - `Z_*_WRAP` 必须 ≥ 该段末张起点且不越过下一段首张起点；
  - BMP 必须 640×480/24bit/非压缩/**正高度**/**正好 921654 字节**，卡须完整格式化 + 簇 ≥ 4KB；
  - 换卡或重排素材后**必须重跑并同步 `Z_*`**（FAT 分配顺序不可预测）。
  - 补充（2026-09-16 实测有效）：文件系统只给扇区号，**不给文件名**。想知道「哪个扇区=哪张图」，用物理盘比对首扇区前 512B 的 MD5：
    `python -c "import hashlib;offs=[...];f=open(r'\\.\F:','rb',buffering=0);print([(o,hashlib.md5((f.seek(o*512),f.read(512))[1]).hexdigest()[:10]) for o in offs])"`，
    再与 `hashlib.md5(open('F:/N.bmp','rb').read(512))` 逐个配对（物理盘读取仍需管理员）。
- [ ] B5 **命令行全流程编译（不开 GUI，可用于自动化）**：TD 的每个 Run 目录（`pic_sdram_Runs/syn_1`、`phy_1`）里都有 `settings.cfg`（含 `start_step/end_step/parent/prj_name`）+ `run.bat`，其内容就是
  `cd <Run目录> && td_commands_prompt.exe E:/FPGA/TD/doc/scripts/DefaultFlow.tcl`
  - 该 exe 把**第一个参数当 Tcl 脚本 source**（所以必须用**正斜杠**路径，反斜杠会被 PowerShell 吃掉变成 `E:FPGATD...` → `couldn't read file`）。
  - 顺序：先跑 `syn_1`（read_design→opt_rtl→opt_gate，产出 `pic_sdram_gate.db`）→ 再跑 `phy_1`（opt_place→opt_route→bitgen，产出 `pic_sdram.bit`）。
  - `phy_1/settings.cfg` 里 `parent=../syn_1`，故**两次的 cwd 必须是各自 Run 目录**。
  - 判据：退出码 0 + 输出末尾出现 `bitgen ... Generate bits file pic_sdram.bit`。
- [ ] B6 **时序 WNS 负值属该工程正常现象，不要误判**：官方 lab_ex_6 例程最终 `Setup WNS -6565ps / NUM_FEPS 66`，本工程 `-6565ps / 70`（基本一致），根因是官方 `top.sdc` 用 `derive_pll_clocks`（TD 报 `USR-6136 obsolete`）导致部分 CDC/跨域路径被当同步路径约束。官方比特流在真机可正常工作，故**以 NUM_FEPS 与官方同量级为验收依据**，不追求 WNS ≥ 0。
  - 2026-09-16 更新：`bmp_scale` 流水化后 syn_1 复测 `Setup WNS -5291ps / TNS -272939ps / NUM_FEPS 95`、`Hold WNS 471ps / NUM_FEPS 0`（比官方例程的 -6565ps **更优**）；残余负值集中在 `clk5`(125MHz，仅 1 个端点/1 扇出) 与 `clk4`(50MHz) 的少量跨域路径，与官方同源，属正常。**判据不变：看 `NUM_FEPS` 与官方同量级，且自研模块不出现在违规路径里。**

- [ ] B7 **命令行烧录（不开 GUI，可脚本化）**：烧录后端是 `E:\FPGA\TD\bin\bw_commands_prompt.exe`，用法与 B5 同理（**第一个参数当 Tcl 脚本 source，路径用正斜杠**）。脚本里写 `download` 命令即可，实测两条：
  - 临时验证（JTAG→SRAM，约 7s，掉电即失）：
    `download -bit <绝对路径>/pic_sdram.bit -mode jtag -spd 7 -sec 64 -cable 0`
  - 赛题固化（写入板载配置 SPI Flash，约 77s，上电即运行）：
    `download -bit <绝对路径>/pic_sdram.bit -mode program_spi -v -spd 7 -cable 0 -flashsize 128`
  - 命令名来自 `E:\FPGA\TD\doc\config\config.json` 的 `Mode_Macro`（`PROGRAM_SRAM`→`jtag`、`PROGRAM_FLASH`→`program_spi -v`）；`-spd 7`=16MHz、`-cable 0`=第 1 根下载线、`-flashsize 128`=128Mbit。
  - **成功判据**：`PRG-2014 : Chip validation success: EG4S20BG256` → `PRG-1001 : SPI Flash ID is: ef` → `program_spi` 完成 → `verify_spi` 无报错 → 末尾 `program -cable 0 -spd 7`（把 Flash 内容重新配置进 FPGA），退出码 0。
  - 先 SRAM 再 Flash：SRAM 快且非破坏，适合快速验证画面；确认无误再固化。

## C. RTL 易错点（回归暴露过的真 Bug）

- [ ] C1 多比特变量必须按宽度声明。反例：display_adjust.v `reg lvl_past`（1bit）赋 `4'd8` 被截成 0 → `lvl_s!=lvl_past` 恒真 → 亮度条每拍重武装**永不隐藏**。修复 `reg [3:0] lvl_past`。
- [ ] C2 TB 期望要与 RTL 真实步进对齐，别想当然：
  - 淡入 alpha 每帧 +64 → 实际序列 …0, **64,128,192**,255（不是 63/127/191）；
  - 亮度档在帧边界武装 `bar_cnt=BAR_HOLD` 后，**本帧 vs 边沿即扣 1** → BAR_HOLD=3 实际只连显 2 帧；
  - 暗带 = `bg>>2`（25%），不是 `bg>>1`（50%）。
- [ ] C3 例化端口名/位宽与模块定义逐一核对（top.v ↔ 各 src/*.v 头部）。
- [ ] C4 **模块内用到的新信号必须同时补进端口列表**。反例：bmp_read_auto.v 的 `S_HOLD` 里用了 `key_prev`，但端口列表漏声明 → vlog 报 `Undefined variable: 'key_prev'`，且模块按旧端口数编译 → tb 报 `Port 'key_prev' not found` + `Too many port connections`。
  - 预防：改完源文件先跑一次**纯编译体检**（见 D3），比只跑 tb 更早暴露；报错若指向“端口数不符/未定义变量”，优先查端口声明是否与 RTL 用法一致。
- [ ] C5 仿真里的消抖/分频等长计数参数要用 **defparam 缩短**，别让 TB 等真实 20ms（2,000,000 拍）：如 `defparam dut.u_k1.DEB_MAX = 21'd100;`（ui_key_ctrl 内含 **4 个** `ui_key_dbnc`：u_k1/u_k2/u_k3/u_k4，**逐一 defparam**；阶段 2e 起 KEY4 已启用，也要消抖）。按键激励需“按住 ≥DEB 拍 + 释放 ≥DEB 拍”，否则第二次按下无新下降沿。
- [ ] C6 **例化模块内 ROM 地址寄存器位宽必须 = ROM 的 `ADDR_W`**（当前 `osd_font_rom.ADDR_W=13`）。反例：`osd_menu.v`/`osd_welcome.v` 的 `rom_addr` 原为 `reg [10:0]`（11 位）接 13 位地址端口，ModelSim **不做零扩展而补 X** → `mem[X]` → 整屏输出 X（TB 报大片 `未知色 xxXXXx` 或 86028 处失败）。修复：改 `reg [12:0] rom_addr;` + `rom_addr = 13'd0;`。
- [ ] C7 2× 放大带的**墨点计数要 ×4**（RTL 行列复制，ROM 仍存 1× 原模）；且**同一 x 区间可能对应多行**，动态数字/文字着色命中必须同时限定**行窗（`rid3`）+ x 窗**，否则别行文字会被误着色（TB 期望与实际计数不符）。
- [ ] C8 **流式缩放/行缓存类模块：必须核算「输出所需源行 vs 输入前沿」的领先/落后关系**。反例：`bmp_scale.v` 缩小档（25%/50%）原本把图像**垂直居中**（顶部先输出十几行黑边），黑边输出期间输入前沿已推进过图像首行所需源行 → 3 块行缓存被新行覆盖 → 输出永远等不到有效源行 → **整帧写不完（out_cnt 卡在 1152 而非 3072）**。
  - 修复：缩小档（`dsth ≤ CANV_H`）取 `y0=0` **顶部对齐**（下方留黑），放大档才中心裁剪（`y0<0`）。
  - 通用判据：只有 3 行缓存时，**输出所需源行不能落后输入前沿超过 2 行**；「输出节流」只能减慢输出，不能加快输入。
  - 同时核对**仿真喂数速率必须 ≈ 实机**（本工程 SPI≈**96 拍/像素**）：喂太快（如 32 拍/像素）会让放大档输出/输入带宽不匹配，出现与设计无关的**假死锁**。TB 内应带 `[STALL]` 诊断打印（打印 out_cnt/state/行号/缓存有效位）便于定位。
- [ ] C9 **长组合路径必须流水化——按「逻辑级数」而不是「功能正确」判断**（本项是「插值画面彩色噪点」的真根因）：
  - 现象：真机挂 640×480 图有**彩色噪点/发糊**，仿真却完全正确（因为仿真无延迟）。
  - 定位方法：综合后读 `pic_sdram_Runs/syn_1/pic_sdram_gate.timing` 的 **Max Paths** 段，找 `Begin:/End:` 两端点与 `Data Path Delay`、`Logic Level`；再看 `Clock Summary` 里对应时钟的 `SWNS`。
  - 实证：`bmp_scale.v` 原把「水平插值 3 通道 + 垂直插值 3 通道 + 钳位」写在一个组合 `always` → 从行缓存采样寄存器到 `out_data_reg` 为 **22.328ns / 16 级逻辑（ADDER=12 MULT18=2 LUT5=1 LUT3=1）**，而本模块在 `sd_card_clk=100MHz(10ns)` → **Setup WNS -12.444ns，`out_data` 全 24 位都是失败端点** → 实机采到未稳定值 = 彩色噪点。
  - 修复范式：把长链按「一次乘/加/钳位 = 1 拍」切成寄存器流水（本次切成 `O_H1→O_H2→O_V1→O_V2` 4 级，状态位宽 `4→5`），**数学逐比特等价**，帧率余量充足（50MHz 域 SPI 供数 ≈96 拍/像素 ≫ 12 拍/像素）。修后 `clk0 SWNS -12.444 → -2.153ns`，且 `bmp_scale_m0` 完全退出违规路径列表，总 `Setup WNS -12444ps → -5291ps`。
  - 通用判据：任一自研模块跑在 100/125MHz 域时，**单条组合路径 ≤ 8ns（约 ≤8 级 LUT/1 级乘法器）**；出现「1 个乘法器 + 多次同链加法」就要切流水。
- [ ] C10 **按键消抖必须「以消抖后电平为唯一基准」**（本项是「KEY 偶发失灵」的真根因）：
  - 反例：旧写法用「原始电平边沿」触发、同时用计数器滤抖 → 长按/连按时首个抖动沿被吞、或释放期抖动产生假触发，表现为**偶发失灵/连跳**。
  - 正确算法：采样同步 → 计数器只在**当前电平 ≠ 消抖后电平**时累加，达到 `DEB_MAX`（10ms@100MHz = 1_000_000）才把消抖后电平翻新；**触发脉冲一律由「消抖后电平」的上升/下降沿产生**。`ui_key_ctrl.ui_key_dbnc` 与 `scene_control.key_debounce` 两处必须同算法，不许各写一套。
  - 回归要求：TB 必须含**抖动沿 + 毛刺 + 连按 + 长按**四类激励（见 `tb_ui_key_ctrl.v`），只测「理想单次按下」抓不到这类缺陷。

## D. 版本验证纪律

- [ ] D1 每版上板前跑全套 ModelSim 回归，**10 套**全 PASS（错误 0）再走 TD：
  `run_sim.do` / `run_sim_scene.do` / `run_sim_ui.do` / `run_sim_osd.do` / `run_sim_menu.do` / `run_sim_welcome.do` / `run_sim_osd_scene.do` / `run_sim_quiz.do` / `run_sim_bmp_scale.do` / `run_sim_display.do`。
- [ ] D2 大改后对照 README「当前视频链路」与 top.v 实际接线是否一致（防文档/代码漂移）。
- [ ] D3 源文件改完先做**纯编译体检**（不开仿真），快速抓语法/端口错：
  `vlog +incdir+../src ../src/top.v ../src/scene_control.v ../src/sd_card_bmp.v ...`（top.v 会经 `include` 带入 ui_key_ctrl/osd_welcome/display_adjust/osd_scene/quiz_ctrl/**bmp_scale**，勿再单独编译这六个，否则重复定义）。

---
### 追加记录格式（每遇新问题续在文末）
```
- [date] 现象：… / 根因：… / 修复：… / 归入分类：…
```

### 追加记录

- [2026-09-11] 现象：bmp 回归 `vlog` 报 `Undefined variable: 'key_prev'`，且 `vsim` 报 `Port 'key_prev' not found` + `Too many port connections (Expected 22, found 23)`；同时 work 库里留着旧版模块按 22 端口加载。 / 根因：新增 `key_prev` 手动“上一张”逻辑时只在 S_HOLD 里用了该信号，**端口列表漏声明** `input key_prev`（`img_no` 已声明但旧编译产物未更新，故也报缺）。 / 修复：bmp_read_auto.v 端口列表补 `input key_prev`；tb 补 `.img_busy()` 消除未连接告警；重新编译。 / 归入分类：C4、D3。
- [2026-09-11] 现象：修改文件后仅跑 tb 才发现端口错，排查绕路。 / 根因：缺少“先纯编译体检”这一步。 / 修复：确立 D3 流程（vlog 全源编译，注意 top.v 的 include 不要重复编译）。 / 归入分类：D3。
- [2026-09-11] 现象：需求理解偏差——“KEY1 切场景”与用户本意不符。 / 根因：用户规格中 KEY1 是**场景内的功能模式切换键**，场景只由拨码决定；早期实现把 KEY1 做成了场景循环（还会触发应急）。 / 修复：KEY1=功能模式循环（0图片/1亮度/2分辨率），KEY2=参数减、KEY3=参数加、KEY4 预留；`scene_control` 去掉 key_scene/key1_press 输入与 k1_takeover，`menu_active=~sw_any`（全关即菜单，拨上任一即退出）；tb/doc 同步。 / 归入分类：需求确认（设计评审）。
- [2026-09-11] 现象：`run_sim_osd_scene.do` 首跑 `vlog` 报 `osd_scene.v(725): Undefined variable: 'qsec_hit'`。 / 根因：给倒计时「秒」字新增金色命中变量时只写了使用、漏了声明。 / 修复：在 `mt_colon_hit` 后补 `wire qsec_hit = (rid3==ID_QZ_CNT) && (px3>=336) && (px3<368);`。 / 归入分类：C4。
- [2026-09-11] 现象：`run_sim_welcome.do` 回归 15 处失败（`W_TITLE ON` 处 X 化、计数出现负值/乱值），`run_sim_menu.do` 更出现 86028 处失败（大片 `未知色 xxXXXx`）。 / 根因：`osd_menu.v`/`osd_welcome.v` 的 `rom_addr` 声明为 11 位（`reg [10:0]`），而 `osd_font_rom.ADDR_W=13`；ModelSim 对窄位宽接宽端口**补 X 而非零扩展** → `mem[X]` 读出全 X（用 `_diag_menu.do` 断点确认 `addr=1167 q=xxxx`）。 / 修复：两模块 `rom_addr` 改 `reg [12:0]` + 初值 `13'd0`；临时诊断脚本 `_diag_*.do` 用完删除。 / 归入分类：C6。
- [2026-09-11] 现象：`run_sim_osd_scene.do` 抢答段 GOLD/WHITE/PANEL 计数与期望不符（GOLD got=2412 exp=1951、WHITE got=1016 exp=1372）。 / 根因：① TB 期望漏乘——倒计时数字与胜者号是 2× 放大（墨点应 ×4），TB 只按 ×1 计；② RTL 误着色——动态数字格 `qcg_hit/qwg_hit` 只按 x 区间判定，抢答状态文字落在同 x 区间时被当金色数字。 / 修复：TB 计数 `q_dig_run`/`ex_qz_dig` 改 ×4；RTL 命中加行窗条件 `(rid3==ID_QZ_CNT)`/`(rid3==ID_QZ_STAT)`；`M_RUN ON` 采样点由无墨的 (398,77) 改到真实墨点 (414,77)。 / 归入分类：C7、C2。
- [2026-09-11] 阶段 2d 收尾：新增 `osd_scene.v`（会议/抢答/应急三场景 OSD，真汉字）+ `quiz_ctrl.v`（4 路并行仲裁/倒计时）+ 外扩 6 脚约束（GPIOA0~A5=H13/N16/N14/G14/H15/F14，**以板卡丝印为准**）；两个新模块按 A3 用 `include`；回归扩为 **9 套全 PASS**。 / 归入分类：A3、D1、外扩口。
- [2026-09-11] 素材排布：确立「一卡多区」硬约束并把 `tools/find_bmp.py` 改造为排布助手。 / 依据：`bmp_read_auto.v` 每 8 扇区(4096B)步进扫 "BM" 头，且读完整张后地址**向上取整到 8 扇区边界**（S_HOLD 分支）→ 每张合格图起点必须落在 8 扇区格点、同段图片必须连续；一张 921654B ≈ 1801 扇区非 8 的倍数，靠 FAT 簇 ≥4KB（占 1808 扇区）才天然对齐。 / 产物：`find_bmp.py` 支持 `--drive/--start/--end/--sizes/--names`，输出 ① 合格图清单（含 8 扇区对齐检查）② 分段 `{START,WRAP,IMGS}` 与可直接粘贴进 top.v 的 localparam（WRAP 取下一段首张，末段=末张+8）③ 「命中 BM 但不合格」清单（排查残留/花屏）；并提示物理盘读取需管理员权限。 / 归入分类：B4。
- [2026-09-16] 现象：想不开 GUI 完成「综合→布局布线→比特流」，不知道 TD 的命令行入口。 / 根因：TD 未提供单一 `-run` 开关；批处理入口藏在每个 Run 目录的 `run.bat` 里。 / 修复：确立 B5 流程（`td_commands_prompt.exe <DefaultFlow.tcl>`，cwd 必须在对应 Run 目录；脚本路径用正斜杠）。实测 syn_1 约 50s、phy_1 约 2m20s，退出码 0 并生成 `pic_sdram.bit`（682004 B）。 / 归入分类：B5。
- [2026-09-16] 现象：phy_1 最终时序 `Setup WNS -6565ps / TNS -293868ps / NUM_FEPS 70`，一度怀疑设计不可用。 / 根因：与官方 lab_ex_6 参考例程**完全同值**（-6565ps / 66 条），源自官方 `top.sdc` 的 `derive_pll_clocks` 已废弃（TD 报 `USR-6136 obsolete`），CDC 路径被误当同步路径。 / 修复：不改代码，按 B6 建立判据（NUM_FEPS 与官方同量级即通过）。**不要为刷时序去动官方 SDC**。 / 归入分类：B6、B1。
- [2026-09-16] 现象：用户往卡里重装素材后需要确认分区；旧表虽数值正确但没人知道「第 N 张」是哪个文件。 / 根因：文件系统不暴露「文件→物理扇区」映射，`find_bmp.py` 只报扇区号。 / 修复：用首扇区前 512B MD5 与各文件头 512B 配对（见 B4 补充），实测卡内物理顺序 = **5,6,7,1,2,3**（与文件名无关，按拷贝先后分配），按 2/2/2 分为 迎新区=5,6 / 会议区=7,1 / 抢答区=2,3，与既有 `Z_*` 表一致，仅补注释与 README 说明。 / 归入分类：B4。
- [2026-09-16] 现象：要求烧录板卡时，本机 USB 只识别到读卡器/键鼠/摄像头，**无任何 Anlogic 下载器设备**（AL-LINK / USB-JTAG）。 / 根因：板卡未接 USB 下载线或未上电。 / 处置：下载属硬件侧动作，**必须先确认设备管理器出现下载器**（驱动来自 TD 安装目录的 `anlocyusb.inf`）；下载界 Device 选 `EG4S20BG256`，临时验证选 JTAG→SRAM，赛题固化选 `PROGRAM_FLASH`。可用 `Get-PnpDevice` 过滤 `USB*` 快速自查。 / 归入分类：B2。
- [2026-09-16] 现象：想不开 GUI 完成烧录。 / 根因：不知 `download` 命令语法。 / 修复：从历史日志 `E:\FPGA\TD\bin\log\bw_*.log`（历次成功烧录的原始命令行）+ `doc\config\config.json` 的 `Mode_Macro` 反推出 B7；实测本版 `pic_sdram.bit` 先 SRAM（7.3s）后 SPI Flash 固化（76.8s，含 verify）**全部成功**，设备识别为 `Anlogic usb cable v0.1`(VID_0547&PID_1002)、Flash ID `ef`。 / 归入分类：B7、B2。
- [2026-09-16] 阶段 2e 需求落地（四项）：①**一卡四区**——`top.v` 分区表新增 `Z_ALARM` 第 4 区（应急改播告警素材，不再「冻结上一场景画面」），`scene_control.latch_sw` 增加码值 4=应急供查表；②**KEY4 显式切「自动轮播↔手动单张」**（`ui_key_ctrl` 内 `k4_p` 翻转 `pic_manual`，数码管第 8 位 `A`/`H`）；③**分辨率真做**——新增 `bmp_scale.v` 双线性插值引擎串入写通路（`sd_card_bmp → bmp_scale → frame_read_write`，8 档 25%~300%）；④`bmp_read_auto`/`sd_card_bmp` 新增 `reload_req`（改档**原地重读当前图**、图序号不变）。回归扩为 **10 套全 PASS**；TD syn_1 已确认 `bmp_scale_m0` 真正进入综合（`Inferred FSM for state_reg` + 3 块 `Logic BRAM 1024x32`）。 / 归入分类：A3、D1、C8。
- [2026-09-16] 现象：`run_sim_bmp_scale.do` 首跑 2 处 FAIL——25% 档 `out_cnt=1152`（期望 3072）、300% 档 `out_cnt=1920`。 / 根因：①25% 缩小档图像**垂直居中**，顶部黑边先耗掉十几行源行时间 → 3 行缓存被新行覆盖 → 死锁；②tb 喂数 32 拍/像素**快于实机**（SPI≈96 拍/像素），放大档输出/输入带宽不匹配 → 假死锁。 / 修复：`bmp_scale.v` 缩小档 `cfg_y0=0`（顶部对齐，放大档才中心裁剪）；`tb_bmp_scale.v` 喂数改 **96 拍/像素**、超时 400000→600000、加 `[STALL]` 诊断打印、缩小档期望改 `v=y`、档位表 y0 期望改 0。修复后 8 档配置 + 5 帧数据流**全部 PASS**。 / 归入分类：C8、C2。
- [2026-09-16] 现象：操作说明写「按 KEY4 进手动，再用 KEY2/KEY3 上一张/下一张」，但真机停在**亮度模式**时按 KEY4 → 屏上弹「手动」卡，按 KEY2/KEY3 **调的却是亮度**，不是切图。 / 根因：**功能模式与切图状态是两个独立条件**——`key_next_pl/key_prev_pl` 要求 `mode==MODE_PIC && pic_manual`，而 KEY4 只翻 `pic_manual`、没动 `mode`；操作说明只讲了后者，条件不充分。 / 修复（按用户定案）：**把「切图」并进 KEY1 的模式循环（模式0），释放 KEY4** —— 模式0 内 KEY3=下一张（并自动 `pic_manual<=1`）、KEY2=上一张（`img_no_l<=1` 时改为 `pic_manual<=0` 回自动）、`mode!=0` 时强制 `pic_manual<=0` 回自动轮播；`ui_key_ctrl.v` 删 `key4` 端口与 `u_k4`，`top.v` 删 `.key4` 连接（顶层 C1 引脚保留不接逻辑），`tb_ui_key_ctrl.v` 删 `press4/u_k4` 并重写第 5 段用例。 / 归入分类：设计评审（接口语义）、D1。
- [2026-09-16] 现象：对同一文件连续下多个 Edit，部分改动会被前一次的快照覆盖（如 `top.v` 的 `key4` 注释、`README.md` 的场景仲裁行改完又变回旧文本）。 / 根因：并行/连续编辑同一文件时后续编辑基于陈旧缓冲写回。 / 规避：**同一文件的多处改动改为逐次串行执行，改完 `Read` 回读确认**；批量改文档后务必用 `Grep` 复查关键旧字符串（如 `KEY4`/`20ms`）是否还有残留。 / 归入分类：D3（工具使用）。
- [2026-09-16] 现象：真机画面**发糊 + 彩色噪点**，但 ModelSim 全 PASS。 / 根因：`bmp_scale.v` 的「水平插值 3 通道 + 垂直插值 3 通道 + 钳位」全在一个组合 `always` 里 → 从行缓存采样寄存器 `v11_reg` 到 `out_data_reg` 为 **22.328ns / 16 级逻辑**，在 `sd_card_clk=100MHz(10ns)` 域 **Setup WNS -12.444ns**，`out_data` 全 24 位为失败端点 → 实机采到未稳定值。 / 修复：切成 **4 级寄存器流水**（`O_H1/O_H2/O_V1/O_V2`，状态位宽 4→5，`O_R4→O_H1`、`O_OUT` 取 `rs_r`，数学等价）；`O_BYP` 100% 档保持真·1:1 旁路。修后 `clk0 SWNS -12.444 → -2.153ns`、总 `Setup WNS -12444 → -5291ps`、`bmp_scale_m0` 退出违规列表；`run_sim_bmp_scale.do` 复跑 ALL PASS。 / 归入分类：C9、B6。
- [2026-09-16] 现象：按键**偶发失灵**（长按/连按会丢键或连跳）。 / 根因：消抖用「原始电平边沿」触发 + 计数器滤抖两套判据混用，抖动期首个边沿被吞、释放期抖动产生假触发。 / 修复：`ui_key_ctrl.ui_key_dbnc` 与 `scene_control.key_debounce` 统一为「以消抖后电平为唯一基准，连续 10ms(DEB_MAX=1_000_000@100MHz) 偏离才采纳，触发脉冲一律取自消抖后电平的边沿」；`tb_ui_key_ctrl.v` 补抖动沿/毛刺/连按/长按四类激励。 / 归入分类：C10。
- [2026-09-16] 现象：多场景同开时语义与需求不符（旧为静态 `SW4>SW3>SW2>SW1` 优先级）。 / 修复：`scene_control.v` 改 **「应急最高 + 无应急时先触发先锁定」**——SW1/2/3 以先被拨上者为准并锁定，持锁场景被拨回时让给仍开着的 `SW1>SW2>SW3`；SW4 电平直通最高优先级，应急期间拨动普通 SW 只更新锁定权不改画面。 / 归入分类：需求确认（设计评审）。
- [2026-09-16] 现象：调分辨率/亮度、切轮播手动时屏幕上没有任何反馈。 / 修复：`display_adjust.v` 内建三块 HUD（`res_cnt` 青条 8 档 / `bar_cnt` 金条 16 档亮度 / `man_cnt` 绿=自动、橙=手动状态卡），由 `res_level`/`bri_level`/`pic_manual` 跨域两级同步后的**变化沿**武装，保持 30 帧后自动消失；`tb_display_adjust.v` 扩为 42 帧用例全 PASS。 / 归入分类：D1、C2（HUD 计数时序要按「武装当帧即扣 1」核 TB 期望）。
