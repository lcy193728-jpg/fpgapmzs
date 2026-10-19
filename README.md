# HX4S20C 多功能 FPGA 智能终端（10-19 稳定交付版）

> 当前稳定交付分支：`codex/final-10-19-delivery`。完整交付包位于
> [`delivery/10-19-final`](./delivery/10-19-final/README.md)，其中只保留一个推荐烧录位流、
> 同批次种子 59 的面积/时序报告、最终回归与数据采集材料、作品设计报告初稿及原始模板。
> 本版本已经完成实板烧录和核心功能复核；后续不再叠加功能，重点补齐功耗、冷启动、长稳和切换时延数据。

## 10-19 稳定交付摘要

- 推荐位流：`delivery/10-19-final/01_bitstream/ONLY_PROGRAM_FINAL_10_19_QOR_BEST.bit`
- 位流 SHA-256：`B44A60AA348C756FBC08373CCC06E3B3B7BA08C4C226C339237E8FF31A5D49A9`
- 器件：EG4S20BG256；LUT 17,288（88.20%）；REG 8,881（45.31%）
- 时序：SWNS +0.134 ns；HWNS +0.020 ns；STA 覆盖率 99.84%
- 最终功能回归：12/12 PASS；详细边界和证据见交付包验证目录。

---

## 历史基线：v10-12

基于安路 FPGA（**EG4S20BG256** / 开发板 **HX4S20C**）的 HDMI 多媒体播放系统：从 TF 卡读取 BMP 图片 → 写入片内 SDRAM 帧缓存 → 经 HDMI 输出画面，并同步输出 **48kHz HDMI 音频**。支持**上电自启**（固化 Flash，无需 PC 重下载）。

> 📖 **完整操作请见 [`使用手册.md`](./使用手册.md)**（逐按钮、逐场景）。

## v10-12 更新摘要

- 菜单进入迎新/会议/抢答时立即黑场，等待目标图片真正写完 SDRAM 后再在帧边界淡入，不再随机闪出默认迎新图或旧场景残帧。
- 抢答场景入口默认静音并清空音频可视化历史；只有倒计时末段、抢答成功等有效事件才播放音效和显示柱阵。
- 抢答结束页的总分等待 `QUIZ8` 完整帧提交，并与中心扩散转场共用可见区域，背景和分数同步出现。
- 增加上电首帧有效门控：第一帧完整写入前仅压黑 SDRAM 背景，首页菜单等后级 OSD 不受影响。
- 固化流程改为 BitWriter 列表只保留一个新位流；`PROGRAM_FLASH / 5MHz / 128Mbits` 完成后必须断电冷启动验证。

详细问题、原因、修改范围和验证结果见 [`RELEASE_NOTES_V10_12.md`](./RELEASE_NOTES_V10_12.md)。

---

## 平台与工具

| 项目 | 说明 |
| ---- | ---- |
| 开发板 | 康芯 HX4S20C（芯片 EG4S20BG256） |
| EDA | 安路 TD 6.2（`pic_sdram_audio_final.al`） |
| 顶层 | `audio_final/integrated/top_final.v`（`module top`） |
| 显示 | HDMI_B 口（可转 VGA），640×480 |
| 存储 | TF 卡（SPI 模式），**FAT32 文件名寻址** |
| 音频 | HDMI 48kHz，片内 DDS 合成 + TF 卡 WAV 背景乐 |
| 时钟 | 板载 50MHz 晶振 |

---

## 功能总览

四个场景（由板载拨码 SW1~SW4 直选）+ 一套全局人机交互（KEY1~KEY4）：

| 拨码 | 场景 | 内容 |
| ---- | ---- | ---- |
| 全关 | **首页菜单** | 全屏 OSD 矢量菜单（上电默认） |
| SW1 | **迎新** | 多图轮播 + 亮度/缩放/周期/对比度/音量 + WAV 背景乐 |
| SW2 | **会议** | 智能会议议程屏：TF 卡议程图 + 状态条 + MM:SS 倒计时 + 进度条，走完进空闲态 |
| SW3 | **抢答** | 4 路抢答 + 倒计时 + 评委判分 + 音效 + 音频可视化 |
| SW4 | **应急** | 4 类告警（火灾/地震/恶劣天气/疏散）+ 防空警报音 |

**核心能力**：TF 卡读 640×480/24bit BMP → SDRAM → HDMI；按键翻图 + 自动轮播（无闪烁切换）；HDMI 48kHz 音频音画同步；Flash 上电自启。扩展：OSD 图层/字幕、iris 转场 + **左→右 Wipe 转场**、双线性缩放、亮度/对比度/音量实时调节、音频可视化（时域波形）。

---

## 时钟与复位

- **时钟**：50MHz 输入 → `sys_pll` 输出 `sd_card_clk`(100MHz) / `ext_mem_clk`(125MHz) / `ext_mem_clk_sft`(180° 相移)；`video_pll` 输出 `video_clk`(25MHz)。
- **复位**（小鹅通第六讲规范）：上电自动复位 POR(约 10.5ms) **且** 两个 PLL 均锁定后释放，再由 `reset_sync` 分域（clk/sd/mem/vid/audio）同步释放，无物理复位引脚。

---

## 场景选择（拨码仲裁）

| 开关 | 引脚 | 场景 |
| ---- | ---- | ---- |
| SW1 | C8 | 迎新（场景 0） |
| SW2 | C7 | 会议（场景 1） |
| SW3 | C6 | 抢答（场景 2） |
| SW4 | C5 | 应急（场景 3，**最高优先级**） |

仲裁规则：
1. **应急最高**：SW4 电平直通，拨上立即切应急、拨回即解除。
2. **先触发先锁定**：无应急时 SW1/SW2/SW3 先拨上者得锁（同拍按 `SW1>SW2>SW3`）；持锁者拨回让给仍开着的优先者。
3. 四个全关 = 回首页菜单。

---

## 四场景档位映射（KEY1 循环，核心）

KEY1 的**模式号序列随场景不同**，这是本版本的关键设计：

| 场景 | 模式0 | 模式1 | 模式2 | 模式3 | 模式4 | 模式5 |
| ---- | ---- | ---- | ---- | ---- | ---- | ---- |
| **迎新** | 图片/切图 | 亮度 | 缩放 | 轮播周期 | **对比度** | 音量 |
| **会议** | 议程/切场 | 亮度 | 缩放 | **对比度** | **音量** | — |
| **抢答** | 图片/切图 | 亮度 | 缩放 | **对比度** | 抢答计分 | 音量 |
| **应急** | 图片/切告警 | 亮度 | **对比度** | **音量** | — | — |

- 迎新/抢答 KEY1 循环 `0→1→2→3→4→5→0`；**会议 `0→1→2→3→4→0`**（无轮播周期档，倒计时驱动切场）；**应急 `0→1→2→3→0`**（无缩放/周期/计分档）。
- **KEY4**（C1）：迎新场景模式 0 切「自动轮播 ↔ 手动单张」；KEY2/KEY3 只切上/下一张。
- **会议**：进入场景自动开跑第 1 场，KEY3/KEY2 手动切场（重置倒计时并计入场次），倒计时归零自动切场。
- **对比度**（小鹅通口径）：`out = saturate((in−128)×k/128 + 128)`，`k = 8 + con×15`（con=8 → 128 精确中性、con>8 增强、con<8 减弱）。档位 0..15，默认 8。

各档参数：亮度 0..15(默认8)；缩放 0..7(默认4=100%，25%~300%)；周期 2/3/5/10/30s；音量 0..15(默认8)；抢答计分 KEY3=判对+2 / KEY2=判错−1。

---

## 视频处理链路

```
video_timing_data → frame_read_write(读) → video_delay → osd_engine
  → osd_menu → osd_welcome → osd_scene → meeting_osd → emergency_multi_overlay
  → audio_viz_overlay → display_adjust → hdmi_tx
```

| 模块 | 职责 |
| ---- | ---- |
| `osd_engine` | 重建 0 基坐标（px_x/px_y，与 de/data 同拍） |
| `osd_menu` | 菜单态全屏矢量菜单 + 应急顶部红条 |
| `osd_welcome` | 迎新信息 OSD（欢迎语横幅/报到地点卡/联系方式卡/滚动流程） |
| `osd_scene` | 抢答 OSD（标题/状态面板/倒计时/滚动须知） |
| `meeting_osd` | ★会议议程屏叠加（顶部状态条 红/黄/绿 + MM:SS 7 段大数字倒计时 + 进度条） |
| `emergency_multi_overlay` | 4 类应急告警页（图标/大字/信息行/滚动提醒，矢量自绘） |
| `audio_viz_overlay` | 音频可视化（时域波形 + 峰值条，迎新/抢答/应急；会议仅 WARN 期间） |
| `display_adjust` | 末级：亮度 + 对比度 + 淡入淡出 + iris/Wipe 转场 + HUD 提示条 |

- **缩放引擎** `bmp_scale`（双线性插值）串在 TF→SDRAM **写通路**：`sd_card_bmp → bmp_scale → frame_read_write`。
- 三路 OSD（menu/welcome/scene）**共用一片** `osd_font_rom`（BRAM，读请求互斥仲裁），省资源。

---

## 会议场景（智能会议议程屏，★10-10 新重建）

`meeting_ctrl`（sd_card_clk 100MHz 域）是一个 **4 态议程状态机**：

| 状态 | 表现 |
| ---- | ---- |
| `IDLE` 空闲 | 未开会 / 会议全部结束 —— **绿条 + 显示 `00:00` + 停在末图** |
| `RUN` 会议中 | 红条，倒计时 `MEET_SEC→0` 逐秒递减 |
| `WARN` 即将结束 | 黄条 + 提示音（剩余 ≤ `WARN_SEC`=3s 时进入） |
| `NEXT` 切场 | 归零瞬态（1 拍），发 `next_pl` 后按场次决定去向 |

- **进入会议场景**（拨码 SW2 拨上，`scene_en` 0→1 上升沿）自动开跑第 1 场，无需按键。
- **每场 20s**（演示缩短）；倒计时是**硬件计数器**（100MHz 逐拍计数），帧级精确。
- **自行计场次**（`MEET_NUM`=3，对应卡上 `MEET1..3.BMP`）：每切一场 +1；手动 KEY3/KEY2 切场也计入。
- **走满 3 场 → 回 `IDLE` 并停留**（绿条 + `00:00` + 停在末图），这就是「没会议」的空闲态。
- **重新开始** = 拨码离开会议场景再拨回（`scene_en` 0→1 时重置场次并开跑第 1 场）。
- 每次切场 `wipe_trig` 翻转 → 驱动 `display_adjust` 的**左→右 Wipe 转场**（对照小鹅通第十讲模式②）。

> OSD 叠加细节：顶部状态条 `y=0..51`；倒计时为 `MM:SS` 4 位 7 段大数字（48×64 字格 / 8px 段厚）+ 冒号，置于近黑面板 + 状态色描边之上，远距离可读；进度条按剩余时间比例着色。全部组合逻辑 + 1 拍输出寄存器，**零 BRAM、零 DSP**。

---

## 音频系统

```
scene_audio_final(DDS 合成) ─┐
wav_stream_player(TF 卡 WAV) ─┼→ audio_src_sel(按场景切源) → audio_src_mux
                             │        → 音量末级(vol 0..15) → HDMI 48kHz 发送
audio_feature_events(抢答门控)┘
```

| 模块 | 职责 |
| ---- | ---- |
| `scene_audio_final` | 片内 DDS 合成音（抢答/应急提示音 + 防空警报音，无需 TF 卡） |
| `wav_stream_player` | TF 卡 WAV 背景乐播放（迎新，裸扇区 16bit/48k/mono PCM） |
| `audio_src_sel` | 按场景切源：迎新读 WAV，其余走 DDS |
| `audio_sd_arbiter` | 音频读卡与图片轮播**共用 SD 总线**的逐扇区仲裁（水位流控） || `audio_feature_events` | 抢答音乐门控（题目静音，抢到/倒计时最后几秒才播音）+ **会议 WARN 提示音**（进入即将结束态触发一声） |
| `audio_viz_overlay` | 时域波形 + 峰值条（有声音才显示；会议场景仅 WARN 期间出现） |

- 音频跑在 `video_clk` 域，`audio_rate_tick` 分频到 **48kHz**，音画同步。
- 迎新音乐写在卡裸扇区 `WAV_START_LBA=300000`（偏移 153.6MB，不经文件系统）；`WAV_SECTORS=0` 自动退回 DDS。

---

## 存储与素材（FAT32 文件名寻址）

**v11 起不再硬编码扇区**：上电由 `fat32_lookup` 读卡 MBR→BPB→根目录，按**文件名前缀**查出各场景 BMP 的物理位置，缓存成段表；换素材只需往卡根目录拷文件，**无需重跑脚本、无需重新综合**。

| 分区 | 文件名前缀 | 数量 |
| ---- | ---- | ---- |
| 迎新 | `WEL1.BMP … WEL8.BMP` | 动态，扫到几张算几张 |
| 会议 | `MEET1.BMP … MEET3.BMP` | 3 张议程图（无则回退迎新区底图） |
| 抢答 | `QUIZ1.BMP … QUIZ8.BMP` | 同上（8 张连排：3 题 + 4 队 + 1 结束页） |
| 应急 | `ALM1.BMP … ALM8.BMP` | 同上（无则回退抢答区底图） |
| 菜单 | 复用迎新区素材做底图 | — |

> ⚠ **8.3 短名约束**：文件名必须大写 8.3 短名（Windows 拷贝不能生成 `WEL1~1.BMP` 自动编号）。
> `zone_launch` 负责「查表停车/交棒」握手（fat32_lookup 与 bmp_read_auto 共用 SD 总线 A 侧，须串行化）。

### BMP 规格（严格校验）

| 项目 | 要求 |
| ---- | ---- |
| 格式 | Windows BMP，54 字节头，非压缩（BI_RGB） |
| 分辨率 | 640×480（或 320×240 / 1024×768 多分辨率轮播） |
| 位深 | 24bit 真彩色（RGB888） |
| 方向 | 正高度（bottom-up） |
| 位置 | 卡根目录 |

---

## 目录结构

```
fpgapmzs/
├── pic_sdram_audio_final.al   # TD 工程文件
├── top.adc                    # 引脚约束
├── src/                       # RTL 源码
│   ├── bmp_read_auto.v        # 自动轮播 + 按键切图（zone_start/wrap/max 运行时重载）
│   ├── fat32_lookup.v         # ★FAT32 文件名寻址层（替代硬编码扇区常量）
│   ├── zone_launch.v          # ★查表停车/交棒握手（与轮播共用 SD 总线）
│   ├── scene_control.v        # 场景主状态机（SW 直选 + 应急 + 菜单）
│   ├── ui_key_ctrl.v          # 人机交互（四场景 KEY1 模式循环 / KEY2/3 参数加减 / KEY4）
│   ├── meeting_ctrl.v         # ★会议议程状态机（4 态 + 20s 倒计时 + 场次计数→空闲态）
│   ├── meeting_osd.v          # ★会议议程屏 OSD（状态条 + MM:SS 倒计时 + 进度条）
│   ├── bmp_scale.v            # 双线性插值缩放引擎（写通路）
│   ├── display_adjust.v       # 亮度/对比度/iris+Wipe 转场/HUD 末级
│   ├── osd_engine.v / osd_menu.v / osd_welcome.v / osd_scene.v  # OSD 叠加链
│   ├── osd_font_rom.v         # 16×16 汉字字形 ROM（BRAM，三路 OSD 共用）
│   ├── emergency_alarm_ctrl.v # 应急计时器（四类选择已移交 ui_key_ctrl）
│   ├── emergency_multi_overlay.v / emergency_font_rom.v  # 4 类应急告警页
│   ├── quiz_ctrl.v            # 抢答仲裁（4 路消抖 + 倒计时 + 状态机）
│   ├── quiz_scene_ctrl.v      # ★抢答跳图桥接（题目/队伍/结束图 + iris 转场）
│   ├── sd_card_bmp.v          # SD 卡 BMP 读取封装
│   ├── audio_sd_arbiter.v     # ★音频/图片共用 SD 总线仲裁
│   ├── reset_sync.v / sync_2ff.v  # 复位同步 / 两级同步
│   ├── frame_fifo_write.v / frame_fifo_read.v / frame_read_write.v  # 帧缓存
│   ├── video_timing_data.v / video_delay.v / video_define.v  # VGA 时序
│   ├── seg_decoder.v / seg_scan.v / color_bar.v  # 数码管 / 彩条
│   └── sd_card/ sdram/ hdmi/  # SPI 驱动 / SDRAM 控制器 / HDMI 发送器（含加密网表）
├── audio_final/
│   ├── integrated/top_final.v # ★顶层（module top，含音频全链路）
│   ├── rtl/                   # 音频 RTL：scene_audio_final / wav_stream_player /
│   │                          #   audio_src_sel / audio_feature_events / audio_viz_overlay
│   ├── tools/                 # 构建脚本：build_td.tcl / make_bit_seed.tcl / lint_td.tcl /
│   │                          #   sweep_*.sh / find_bmp.py / make_audio_corpus.py …
│   ├── artifacts/             # 位流 + SHA256SUMS
│   └── reports/               # 综合/时序报告
├── tb/                        # ModelSim 仿真平台（tb_*.v）
├── sim/                       # ModelSim 脚本（run_sim*.do / run_regress_all.sh）
├── README.md                  # 本文件
├── 使用手册.md                 # ★完整操作手册（逐按钮、逐场景）
├── 抢答按钮引脚接入表.md       # 抢答外接按钮接线表
└── 优化方案_逻辑优化与低功耗.md # ★评测加分项梳理（逻辑优化 / 低功耗设计）
```

> `osd_welcome.v`、`display_adjust.v`、`ui_key_ctrl.v`、`osd_scene.v`、`meeting_ctrl.v`、`meeting_osd.v`、`quiz_ctrl.v`、`quiz_scene_ctrl.v`、`bmp_scale.v`、`emergency_*`、`audio_*.v` 等由顶层 `` `include `` 并入综合，**不在** `.al` 源码列表登记。

---

## 编译与烧录

1. 用安路 TD EDA 打开仓库根目录的 `pic_sdram_audio_final.al`，综合 → 布局布线 → 生成比特流。
2. 命令行构建：`audio_final/tools/build_td.tcl`（seed 29）；复用网表生成位流：`make_bit_seed.tcl`。
3. 本次发布只使用 `artifacts/ONLY_PROGRAM_10_18_FINAL_ARCH_LP.bit`；先用 `PROGRAM_SRAM` 验证。
4. 固化时清空 BitWriter 文件列表，只添加上述一个位流，选择 `PROGRAM_FLASH / 5MHz / 128Mbits` 并启用 Verify。不要烧录任何名称含 `REJECTED` 的文件。
5. 看到 `program_spi`、`verify_spi` 和 `PROGRAM_FLASH success` 后，不再执行 `PROGRAM_SRAM`；完全断电约 10 秒再重新上电验证自启动。

发布位流 SHA-256：`318747763FB4682EF21923C4DC95A4D1D48BBB40291D83A1246DF97F6C891B3D`。

> SDRAM 控制器与 HDMI 发送器为安路官方加密网表（仅 TD 可用）；PLL/FIFO 为 TD 生成的 IP。

---

## 资源与时序（TD 6.2，v10-18 最终实测）

| 资源 | 用量 | 总量 | 占用 |
| ---- | ---- | ---- | ---- |
| LUT | 17381 | 19600 | 88.68% |
| REG | 8886 | 19600 | 45.34% |
| LE | 18196 | 19600 | 92.84% |
| Slice | 9395 | 9800 | 95.87% |
| BRAM9K | 52 | 64 | 81.25% |
| BRAM32K | 13 | 16 | 81.25% |
| DSP | 14 | 29 | 48.28% |
| IO | 57 | 188 | 30.32% |

- 固定 seed=59 的综合、布局布线和 bitgen 全流程完成；Setup WNS `+0.114ns`，Hold WNS `+0.020ns`。
- seed=83 与 seed=97 虽能完成实现，但面积或建立时间均劣于 seed=59，已标记为 `REJECTED_NOT_FOR_PROGRAMMING`。
- 发布位流大小 722744 B。Slice 仅余 405，后续不再用“堆功能”方式修改主线。

---

## 仿真验证

执行 `powershell -ExecutionPolicy Bypass -File tools/qualify_10_18_final.ps1` 可完成最终发布准入：

- 8 组核心功能回归全部通过；
- 迎新马赛克、BMP 缩放 BRAM、应急箭头 3 组专项全部通过；
- 低功耗活动率专项通过：空闲/静音保持阶段相位停止，激活阶段恢复翻转；
- 物理资源、Setup/Hold WNS、位流 SHA-256 全部通过门限；
- 总计 12 组功能/专项验证无失败，最终输出 `FINAL_10_18_PASS`。

低功耗 VCD 只用于证明门控行为和相对翻转差异；未接板测电流前，不虚报具体 mW 或节电百分比。

---

## 版本说明

| 版本 | 内容 |
| ---- | ---- |
| v10-4 | 多分辨率缩放 + 对比度(旧 4+con*8，只能压灰) + 会议/抢答/应急三场景 |
| v10-9 | 对比度重写(k=8+con×15) + 应急去缩放档 + 会议移除 + 抢答音乐门控/音频可视化 + FAT32 文件名寻址 + 使用手册 |
| **v10-10** | **会议场景重建**（议程状态机 + MM:SS 倒计时 + 状态条/进度条 + 走完进空闲态）+ **左→右 Wipe 转场** + 会议 WARN 提示音/音频可视化 + 会议档位映射（0议程/1亮度/2缩放/3对比度/4音量） |
| **v10-12** | **完整帧提交门控**：切场旧图隔离、抢答入口音频/可视化清场、结束页分数与 QUIZ8 同步揭示、上电首帧有效门控；补充冷启动仿真和 Flash 固化排障文档 |
| **v10-18** | **架构与低功耗收敛版**：保持上板效果不变，完成帧边界配置提交、串口可调字幕、场景音频静态门控、共享字体/缩放存储优化、严格物理 QoR 准入；以 VCD 活动率、12 组回归和 seed=59 正时序共同封版 |
