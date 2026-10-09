# HX4S20C 多功能 FPGA 智能终端（v10-9）

基于安路 FPGA（**EG4S20BG256** / 开发板 **HX4S20C**）的 HDMI 多媒体播放系统：从 TF 卡读取 BMP 图片 → 写入片内 SDRAM 帧缓存 → 经 HDMI 输出画面，并同步输出 **48kHz HDMI 音频**。支持**上电自启**（固化 Flash，无需 PC 重下载）。

> 📖 **完整操作请见 [`使用手册.md`](./使用手册.md)**（逐按钮、逐场景）。

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
| SW2 | 预留（原会议） | 走菜单画面（会议场景已于 v11 移除） |
| SW3 | **抢答** | 4 路抢答 + 倒计时 + 评委判分 + 音效 + 音频可视化 |
| SW4 | **应急** | 4 类告警（火灾/地震/恶劣天气/疏散）+ 防空警报音 |

**核心能力**：TF 卡读 640×480/24bit BMP → SDRAM → HDMI；按键翻图 + 自动轮播（无闪烁切换）；HDMI 48kHz 音频音画同步；Flash 上电自启。扩展：OSD 图层/字幕、iris 转场、双线性缩放、亮度/对比度/音量实时调节、音频可视化（时域波形）。

---

## 时钟与复位

- **时钟**：50MHz 输入 → `sys_pll` 输出 `sd_card_clk`(100MHz) / `ext_mem_clk`(125MHz) / `ext_mem_clk_sft`(180° 相移)；`video_pll` 输出 `video_clk`(25MHz)。
- **复位**（小鹅通第六讲规范）：上电自动复位 POR(约 10.5ms) **且** 两个 PLL 均锁定后释放，再由 `reset_sync` 分域（clk/sd/mem/vid/audio）同步释放，无物理复位引脚。

---

## 场景选择（拨码仲裁）

| 开关 | 引脚 | 场景 |
| ---- | ---- | ---- |
| SW1 | C8 | 迎新（场景 0） |
| SW2 | C7 | 预留（场景 1，原会议） |
| SW3 | C6 | 抢答（场景 2） |
| SW4 | C5 | 应急（场景 3，**最高优先级**） |

仲裁规则：
1. **应急最高**：SW4 电平直通，拨上立即切应急、拨回即解除。
2. **先触发先锁定**：无应急时 SW1/SW2/SW3 先拨上者得锁（同拍按 `SW1>SW2>SW3`）；持锁者拨回让给仍开着的优先者。
3. 四个全关 = 回首页菜单。

---

## 三场景档位映射（KEY1 循环，核心）

KEY1 的**模式号序列随场景不同**，这是本版本的关键设计：

| 场景 | 模式0 | 模式1 | 模式2 | 模式3 | 模式4 | 模式5 |
| ---- | ---- | ---- | ---- | ---- | ---- | ---- |
| **迎新** | 图片/切图 | 亮度 | 缩放 | 轮播周期 | **对比度** | 音量 |
| **抢答** | 图片/切图 | 亮度 | 缩放 | **对比度** | 抢答计分 | 音量 |
| **应急** | 图片/切告警 | 亮度 | **对比度** | **音量** | — | — |

- 迎新/抢答 KEY1 循环 `0→1→2→3→4→5→0`；**应急 `0→1→2→3→0`**（无缩放/周期/计分档）。
- **KEY4**（C1）：迎新场景模式 0 切「自动轮播 ↔ 手动单张」；KEY2/KEY3 只切上/下一张。
- **对比度**（小鹅通口径）：`out = saturate((in−128)×k/128 + 128)`，`k = 8 + con×15`（con=8 → 128 精确中性、con>8 增强、con<8 减弱）。档位 0..15，默认 8。

各档参数：亮度 0..15(默认8)；缩放 0..7(默认4=100%，25%~300%)；周期 2/3/5/10/30s；音量 0..15(默认8)；抢答计分 KEY3=判对+2 / KEY2=判错−1。

---

## 视频处理链路

```
video_timing_data → frame_read_write(读) → video_delay → osd_engine
  → osd_menu → osd_welcome → osd_scene → emergency_multi_overlay
  → audio_viz_overlay → display_adjust → hdmi_tx
```

| 模块 | 职责 |
| ---- | ---- |
| `osd_engine` | 重建 0 基坐标（px_x/px_y，与 de/data 同拍） |
| `osd_menu` | 菜单态/预留位全屏矢量菜单 + 应急顶部红条 |
| `osd_welcome` | 迎新信息 OSD（欢迎语横幅/报到地点卡/联系方式卡/滚动流程） |
| `osd_scene` | 抢答 OSD（标题/状态面板/倒计时/滚动须知）；应急画面由下级绘制 |
| `emergency_multi_overlay` | 4 类应急告警页（图标/大字/信息行/滚动提醒，矢量自绘） |
| `audio_viz_overlay` | 音频可视化（时域波形 + 峰值条，迎新/抢答/应急） |
| `display_adjust` | 末级：亮度 + 对比度 + 淡入淡出 + HUD 提示条（亮度金/缩放青/对比度品红/音量/轮播状态卡） |

- **缩放引擎** `bmp_scale`（双线性插值）串在 TF→SDRAM **写通路**：`sd_card_bmp → bmp_scale → frame_read_write`。
- 三路 OSD（menu/welcome/scene）**共用一片** `osd_font_rom`（BRAM，读请求互斥仲裁），省资源。

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
| `audio_sd_arbiter` | 音频读卡与图片轮播**共用 SD 总线**的逐扇区仲裁（水位流控） |
| `audio_feature_events` | 抢答音乐门控：题目静音，抢到/倒计时最后几秒才播音 |
| `audio_viz_overlay` | 时域波形 + 峰值条（有声音才显示） |

- 音频跑在 `video_clk` 域，`audio_rate_tick` 分频到 **48kHz**，音画同步。
- 迎新音乐写在卡裸扇区 `WAV_START_LBA=300000`（偏移 153.6MB，不经文件系统）；`WAV_SECTORS=0` 自动退回 DDS。

---

## 存储与素材（FAT32 文件名寻址）

**v11 起不再硬编码扇区**：上电由 `fat32_lookup` 读卡 MBR→BPB→根目录，按**文件名前缀**查出各场景 BMP 的物理位置，缓存成段表；换素材只需往卡根目录拷文件，**无需重跑脚本、无需重新综合**。

| 分区 | 文件名前缀 | 数量 |
| ---- | ---- | ---- |
| 迎新 | `WEL1.BMP … WEL8.BMP` | 动态，扫到几张算几张 |
| 抢答 | `QUIZ1.BMP … QUIZ8.BMP` | 同上（8 张连排：3 题 + 4 队 + 1 结束页） |
| 应急 | `ALM1.BMP … ALM8.BMP` | 同上 |
| 菜单/预留 | 复用迎新区素材做底图 | — |

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
│   ├── ui_key_ctrl.v          # 人机交互（KEY1 模式循环 / KEY2/3 参数加减 / KEY4）
│   ├── bmp_scale.v            # 双线性插值缩放引擎（写通路）
│   ├── display_adjust.v       # 亮度/对比度/淡入淡出/HUD 末级
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
└── 抢答按钮引脚接入表.md       # 抢答外接按钮接线表
```

> `osd_welcome.v`、`display_adjust.v`、`ui_key_ctrl.v`、`osd_scene.v`、`quiz_ctrl.v`、`quiz_scene_ctrl.v`、`bmp_scale.v`、`emergency_*`、`audio_*.v` 等由顶层 `` `include `` 并入综合，**不在** `.al` 源码列表登记。

---

## 编译与烧录

1. 用安路 TD EDA 打开 `pic_sdram_audio_final.al`，综合 → 布局布线 → 生成比特流。
2. 命令行构建：`audio_final/tools/build_td.tcl`（seed 17）；复用网表生成位流：`make_bit_seed.tcl`。
3. TF 卡插入开发板，下载器烧录：JTAG/SRAM 验证 → 确认后固化 Flash（上电自启）。

> SDRAM 控制器与 HDMI 发送器为安路官方加密网表（仅 TD 可用）；PLL/FIFO 为 TD 生成的 IP。

---

## 资源与时序（TD 6.2 实测，seed 17）

| 资源 | 用量 | 总量 | 占用 |
| ---- | ---- | ---- | ---- |
| slices | 8030 | 9800 | **81.94%** |
| LUT | 14619 | 19600 | 74.59% |
| REG | 7686 | 19600 | 39.21% |
| BRAM9K | 39 | 64 | 60.94% |
| BRAM32K | 8 | 16 | 50.00% |
| DSP | 14 | 29 | 48.28% |

- 时序：**SWNS +0.141ns / HWNS +0.020ns / 0 违例**（clk0 = sd_card_clk 100MHz 域）。
- 位流：`audio_final/artifacts/pic_sdram_audio_final.bit`（SHA `723d54a1…`）。

---

## 仿真验证

`sim/run_regress_all.sh` 一键回归（22 套用例全绿，0 FAIL）：bmp_read_auto / scene_control / ui_key_ctrl / osd_engine / osd_menu / osd_welcome / osd_scene / quiz_ctrl / bmp_scale / display_adjust(对比度) / fat32_lookup / audio_sd_arbiter / wav_stream_player / audio_viz 等。

---

## 版本说明

| 版本 | 内容 |
| ---- | ---- |
| v10-4 | 多分辨率缩放 + 对比度(旧 4+con*8，只能压灰) + 会议/抢答/应急三场景 |
| **v10-9** | 对比度重写(k=8+con×15) + 应急去缩放档 + 会议移除 + 抢答音乐门控/音频可视化 + FAT32 文件名寻址 + 使用手册 |
