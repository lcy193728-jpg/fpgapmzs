# TF 卡图片自动轮播 → SDRAM → HDMI 显示（阶段一）

基于安路 FPGA 的 HDMI 多媒体显示系统。开发板读取 TF 卡中的 640×480、24bit 非压缩 BMP 图片，写入片内 SDRAM 帧缓存，经 HDMI 接口以 VGA 分辨率实时输出，实现**上电自动多图循环轮播**。

本工程是「校园多功能 FPGA 智能终端」的基础阶段，后续将在其之上叠加 OSD 字幕、抢答、告警、转场等场景功能。

## 平台与工具

| 项目 | 说明 |
| ---- | ---- |
| 开发板 | 安路 HX4S20C（芯片 EG4S20BG256） |
| 开发工具 | 安路 TD EDA 6.2.x |
| 显示输出 | HDMI（HDMI_B 口，可用 HDMI 转 VGA 转换器 + 显示器） |
| 存储 | TF 卡（SPI 模式只读） |
| 时钟 | 板载 50MHz 有源晶振 |

## 功能特性

- TF 卡 SPI 读取 640×480 / 24bit 非压缩 BMP，解析文件头后写入 SDRAM 帧缓存
- HDMI 实时输出 VGA 分辨率画面
- **上电自动轮播**：无需按键触发，自动扫描并循环显示多张图片
- **按键手动切图**：按 `key1`（引脚 B2）立即切到下一张，与自动轮播计时共存
- 数码管显示读图状态码（0=初始化 / 2=找图 / 4=读图 / 5=保持）
- 修正 BMP 自底向上存储导致的画面上下颠倒
- 严格 BMP 头校验 + 图片计数回卷，避免把卡内残留/已删除数据误判成图片（防花屏）

## 目录结构

```
fpgapmzs/
├── pic_sdram.al          # TD 工程文件（入口）
├── top.adc               # 引脚约束
├── top.sdc               # 时序约束
├── al_ip/                # TD IP 核（sys_pll / video_pll / afifo）
├── src/                  # RTL 源码
│   ├── top.v             # 顶层
│   ├── bmp_read_auto.v   # ★自研：自动轮播 + 按键切图状态机
│   ├── sd_card_bmp.v     # SD 卡 BMP 读取封装（含内联按键消抖）
│   ├── frame_fifo_write.v# ★自研：写地址行序翻转（修正上下颠倒）
│   ├── frame_fifo_read.v / frame_read_write.v  # 帧缓存读写控制
│   ├── sd_card/          # SD 卡 SPI 驱动（cmd / 扇区读写 / top / spi_master）
│   ├── sdram/            # SDRAM 控制器（含加密网表 enc_file）
│   ├── sdram_r/sdram_para.v  # SDRAM 参数定义
│   ├── hdmi/             # HDMI 发送器（hdmi_tx + 加密网表 enc_file）
│   ├── video_timing_data.v / video_delay.v / video_define.v  # VGA 时序
│   └── seg_decoder.v / seg_scan.v / color_bar.v   # 数码管 / 彩条
├── tb/                   # ModelSim 仿真测试平台
│   └── tb_bmp_read_auto.v
├── tools/                # 工具脚本
│   └── find_bmp.py       # 读取 TF 卡扇区，定位图片实际位置
└── 图片/                 # 示例测试图（640×480 24bit BMP）
```

## 编译与烧录

1. 用安路 TD EDA 打开工程文件 `pic_sdram.al`。
2. 顺序执行：综合（Synthesize）→ 布局布线（Place & Route）→ 生成比特流（Generate Bitstream）。
3. 将 TF 卡插入开发板，用下载线把生成的比特流固化到板内配置 Flash（上电自动运行，无需 PC 重下载）。

> 说明：SDRAM 控制器与 HDMI 发送器为安路官方加密网表（`*.enc.v / *.enc.vhd`），仅能在 TD EDA 中使用；PLL / FIFO 为 TD 生成的 IP 核。

## TF 卡准备（重要）

图片必须满足以下条件才能被正确识别：

- 分辨率 **640×480**
- 位深 **24bit** 真彩色，**非压缩**
- 文件大小 **921654 字节**（= 54 字节文件头 + 640×480×3）
- 放在 **卡根目录**，不要放子文件夹

推荐处理方式：

1. 用画图 / Photoshop / ImageMagick 把图片裁剪为 640×480 并另存为「24 位位图」。
2. TF 卡做一次**完整格式化**（Windows 格式化时**取消勾选「快速格式化」**，文件系统可用 exFAT 或 FAT32），以彻底擦除已删除文件的残留数据——否则裸扇区扫描可能把残留旧图当成图片，出现花屏。
3. 把图片复制到卡根目录。

> 为什么必须完整格式化：本工程沿用官方「不解析文件系统、按扇区扫描 BMP 文件头」的方式。删除文件时 FAT 只清目录项，原始像素数据仍残留在卡上，会被扫描器误认。

## 本阶段自研 / 改动点

| 模块 | 改动内容 |
| ---- | ---- |
| `src/bmp_read_auto.v` | 在官方 `bmp_read.v` 基础上改造为**上电自动轮播**，去掉按键触发；新增保持显示状态 `S_HOLD`；新增 `key_trigger` 端口实现**按键手动切图**（S_HOLD 状态按键立即切下一张，与自动计时共存）；严格校验文件头（BM + 宽640 + 高480 + 24bit + 长度921654）；新增 `MAX_IMAGES` 计数回卷，播满一圈回卷到扫描起点 |
| `src/sd_card_bmp.v` | 新增 `key` 输入端口，内部**内联两级同步 + 20ms 计数器消抖**（替代独立 `ax_debounce` 模块，避免 TD GUI 源文件列表丢失导致 black box），输出下降沿脉冲接 `key_trigger` |
| `src/frame_fifo_write.v` | 新增写地址**行序翻转**：从最后一行开始写，行内按列递增，行尾回跳到上一行起始地址，修正 BMP 自底向上存储导致的画面上下颠倒（`IMG_WIDTH=640` / `IMG_HEIGHT=480`） |
| `src/top.v` | 新增 `key1` 输入端口（引脚 B2），直接接入 `sd_card_bmp` 的 `key` |

## 关键参数

`bmp_read_auto.v` 顶部参数：

| 参数 | 默认值 | 含义 |
| ---- | ------ | ---- |
| `SLIDE_INTERVAL` | `300_000_000` | 每张图停留时钟周期数（100MHz 下约 3 秒） |
| `START_SECTOR` | `126000` | 扫描起始扇区（图片实际在 126656 之后，用 `tools/find_bmp.py` 实测） |
| `WRAP_SECTOR` | `400000` | 扫描上限扇区，超过回卷（约 200MB） |
| `MAX_IMAGES` | `5` | 卡内图片总数（轮播一圈张数），改图片数量需同步修改 |
| `BMP_FILE_LEN` | `921654` | 期望 BMP 文件长度（54 + 640×480×3），仿真可覆盖为小值加速 |

> ⚠️ **换卡后务必重测图片位置**：不同容量/文件系统的 TF 卡，FAT 表大小不同，图片实际扇区位置会变。用 `tools/find_bmp.py` 读取卡扇区定位图片，再改 `START_SECTOR`（需小于第一张图所在扇区）。