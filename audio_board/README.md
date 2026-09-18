# HDMI 公共音频底层：上板验证版

基线：main `6586b66447375c1c4dfc9568b17a79df889cfbae`。
开发及交付分支：`dev_sim`。不改写 main。

本版在已上板出声的公共底层基础上，完成新版文档要求的场景旋律、切图提示音、
自动轮播提示音与应急报警音。菜单/音效结束仍输出48 kHz、16位、1 kHz测试音。
本次实际执行TD编译、布局布线及比特流生成，没有运行ModelSim。
**新增联动功能的具体行为与逐项上板验收请先阅读 [MEDIA_AUDIO.md](MEDIA_AUDIO.md)。**

## 两个工程入口

| 工程 | 入口 | 用途 |
|---|---|---|
| 独立测试 | `audio_board/standalone/hdmi_tone.al` | 彩条+音频，无需 TF 卡、SDRAM、抢答台 |
| 原功能集成 | 仓库根目录 `pic_sdram_audio.al` | 原菜单/四场景/图片/OSD/按键保持，末级改用 HDMI 音视频输出 |

原 `pic_sdram.al`、`src/top.v` 及基线模块保持原样。
新集成顶层 `audio_board/integrated/top_audio.v` 仍使用 `module top` 和原顶层端口，
只改变 include 的相对定位，并替换最后的 HDMI 发送实例及增加音频连线。
不要在同一工程同时加入旧 `src/top.v` 与新顶层，否则 top 重复定义。

集成版声音随实际生效场景及切图事件变化；KEY1/2/3、KEY4 和 SW 约定不改变。
没有加入WAV、语音或音量按键，音符采用FPGA DDS生成。

## 公共接口

`rtl/audio_hdmi_output.v` 接收最终 `hs/vs/de/rgb` 和
`pcm_valid/pcm_ready/pcm_left/pcm_right`，输出 HDMI 原有四个 P 端口。

- 固定像素时钟 25 MHz、串行时钟 125 MHz、同相位且同一个 PLL。
- 固定 640×480，800×525 总时序，负极性 HS/VS。
- PCM 左右各 16 位，采样率 48 kHz。静音时继续送零样本。
- PCM 与 pixel_clk 同域；valid 在 ready=0 时必须保持，样本不得变化。
- 本层的 FIFO 是同步 FIFO，不是跨时钟 FIFO。未来 SD/WAV 音源需异步 FIFO。
- 核心每包承载四个立体声采样帧，ACR N=6144 / CTS=25000。
- AVI RGB 全范围、4:3、VIC=0：25 MHz 并非严格标准 25.175 MHz VGA。
  实际刷新率约 59.524 Hz，沿用现有工程。若某接收器不兼容，应整体更新
  视频 PLL、采样器 CLOCK_HZ、ACR CTS 与约束，不能只改其中一个。
- 外部音源选择、播放请求、优先级、暂停恢复属于上层，后续复用此底层。
- 不经旧 DVITransmitter 二次编码。新增 EG_LOGIC_ODDR + EG_LOGIC_OBUF 完成 PHY。
- 不额外占用音频 PLL，不新增板外引脚。

## 队友上板步骤

### 1. 获取分支

推荐单独克隆，防止覆盖本地未提交的上板代码：

```powershell
git clone --branch dev_sim https://github.com/lcy193728-jpg/fpgapmzs.git D:\fpga_audio_board
cd D:\fpga_audio_board
git status --short --branch
```

不要将 dev_sim 直接覆盖 main。目录尽量使用短英文路径。
GUI 编译前，关闭 TD，执行一次路径配置（只更新两个新增工程的路径元数据）：

```powershell
powershell -ExecutionPolicy Bypass -File .\audio_board\tools\setup_gui.ps1
```

CLI build.ps1 会在正确工程目录分析源码，不依赖这一步。

### 2. 连接

开发板 HX4S20C / EG4S20BG256，上电，下载线连接。
使用原 HDMI_B 口，直接接支持音频的显示器；选择对应 HDMI 输入、打开扬声器，
先将显示器音量设为较低值。独立测试无需 TF 卡；集成测试使用原素材 TF 卡。

### 3. 首先下载独立测试

若本次交付含 artifacts/hdmi_tone.bit，可以先用 TD 下载器选择它进行 JTAG/SRAM 下载。
否则用 TD EDA 6.2 打开 `audio_board/standalone/hdmi_tone.al`，顶层 top，
器件 EG4S20BG256，执行综合→布局布线→生成比特流，再下载本次生成的 hdmi_tone.bit。

不要把原 `pic_sdram.al` 编译出来的纯视频 bit 当作音频版。

CLI 编译（将 TD 路径替换为队友本机实际目录）：

```powershell
powershell -ExecutionPolicy Bypass -File .\audio_board\tools\build.ps1 -TdRoot "E:\FPGA\TD" -Target tone
```

CLI 下载刚编译的 bit：

```powershell
powershell -ExecutionPolicy Bypass -File .\audio_board\tools\download.ps1 -TdRoot "E:\FPGA\TD" -BitFile .\audio_board\build\tone\hdmi_tone.bit
```

脚本默认 jtag，约束不需要手动重新分配引脚。首次不要写配置 Flash。
若使用预编译 bit，将 BitFile 改为 `audio_board/artifacts/hdmi_tone.bit`。

### 4. 独立测试预期

- 稳定的八色彩条，不需要按键或拨码。
- 画面顶部 16 行为绿色（内部时序锁定，未记录错误）。
- 左右声道连续的 1 kHz 正弦音；初始声音有短渐变。
- 正常播放至少 10 分钟，检查黑屏、杂音、断音及错误条变化。

记录：commit、bit SHA256、显示器型号、接口、是否出声、顶部颜色、播放时长、
整屏照片和能记录声音的视频。预编译文件哈希见 artifacts/SHA256SUMS.json。

顶部颜色诊断（按优先级显示，错误为粘性直到复位）：

| 颜色 | 含义 | 排查 |
|---|---|---|
| 绿色 | 时序已锁定，无以下错误 | 正常状态，但仍需试听确认接收器识别音频 |
| 青色 | 尚未锁定行时序 | 检查 PLL/复位/视频同步 |
| 品红 | HS/DE 与完整行坐标不匹配 | 检查时序及视频对齐 |
| 红色 | 数据岛序列错误 | 检查坐标、消隐长度、包锁定 |
| 蓝色 | 测试音 FIFO 溢出 | 检查发送背压、音频包消费能力 |
| 橙色 | PCM valid/ready 契约违反 | 检查音源在阻塞时是否改变数据 |

### 5. 左右声道验证

可选：在 `standalone/top_tone.v` 将 AUDIO_PROFILE 改为 1（仅左）或 2（仅右），
重新编译 tone 工程并下载。若显示器内部混成单声道，需要用双声道耳机输出或
HDMI 音频提取设备确认左右。测试结束恢复 0。

### 6. 再验证集成工程

TD 打开仓库根目录 `pic_sdram_audio.al`；不要同时打开原工程并手工混加源码。
新文件已在工程内登记。临时 JTAG/SRAM 下载 pic_sdram_audio.bit。

```powershell
powershell -ExecutionPolicy Bypass -File .\audio_board\tools\build.ps1 -TdRoot "E:\FPGA\TD" -Target integrated
powershell -ExecutionPolicy Bypass -File .\audio_board\tools\download.ps1 -TdRoot "E:\FPGA\TD" -BitFile .\audio_board\build\integrated\pic_sdram_audio.bit
```

验证原操作：

1. 四个 SW 全关：菜单显示，同时有测试音。
2. SW1：迎新图片和字幕；KEY1 模式0下 KEY3/KEY2 切图。
3. KEY1 切亮度、缩放、轮播周期模式，KEY2/KEY3 调参数。
4. SW2/SW3：会议和抢答画面；按原先触发锁定规则切换。
5. SW4：应急画面；解除后恢复原场景。
6. 声音应符合MEDIA_AUDIO.md：切场景/手动切图提示音＋旋律，自动换图仅提示音，应急800/1200 Hz交替；结束后恢复测试音。

确认图片/文字/按键无回退，以及音频无断音；保留 10 分钟运行记录。

### 7. 通过后固化

只在上述验收通过后，将已验收的集成 bit 写入配置 Flash：

```powershell
powershell -ExecutionPolicy Bypass -File .\audio_board\tools\download.ps1 -TdRoot "E:\FPGA\TD" -BitFile .\audio_board\build\integrated\pic_sdram_audio.bit -Mode program_spi
```

检查器件验证 EG4S20BG256、SPI 写入及校验成功，然后断电再上电确认画面和声音。
保存原已验证比特流以便恢复。队友验收后再按团队流程整理到 main。

## 排查方法

### 彩条正常、绿色但没有声音

1. 确认下载的是本次音频 bit，核对哈希，非旧 DVI bit。
2. 检查显示器音频源=当前 HDMI，扬声器未静音，耳机插入是否切走声音。
3. HDMI 重新插拔或显示器重新上电，促使接收器重新识别。
4. 若能查看输入格式，检查是否识别双声道 PCM；换另一个支持 HDMI 音频的设备
   区分本机设置与数据包兼容问题。
5. 绿色只说明本机内部检查未触发；不能证明接收端已成功解码所有音频字段。
   如多个设备均无声，回传日志、型号、bit 哈希，由开发者继续查 ACR/包格式/串行位序。

### 无图像或图像不稳定

先用独立工程排除 TF/SDRAM，确认 HDMI_B 和引脚报告：
CLK K1/J1、D0 F5/F4、D1 E3/E4、D2 B3/D3；P 引脚 LVDS33、DDR 输出。
检查 PLL 锁定、25/125 MHz、比例及 0° 相位，不能随意反转 d0/d1。
如果原纯视频 bit 正常而新 bit 不正常，回传 TD 布线时序、IO 报告和接收设备型号。
不要用 set_false_path 隐藏 pixel→serial 符号传输的真实问题。

### 声音刺耳、杂音或断续

先降低接收器音量，确认音频采样节拍与 N/CTS；观察顶部是否转蓝/红。
TEST_PROFILE 左右测试区分声道混合问题。回传带声音的视频和错误状态。
当前电路没有 EDID/DDC/HPD 协商，也不支持 HDMI 高码率、多声道或 HDCP。

### 编译问题

- GUI 改工程文件时先保存关闭再外部操作，防止 TD 回写覆盖文件清单。
- 不要重复添加已经被顶层 include 的基线模块。
- 如果报 `./src/sdram/enc_file/global_def.v` 找不到，集成工程必须从仓库根目录
  `pic_sdram_audio.al` 打开；CLI 脚本也会使用该目录分析源码。
- 时序是否通过以本次报告及具体端点为准，不沿用旧文档的负 WNS 免责结论。
  新增 audio_* / hdmi_audio_* / pixel→serial 路径不能存在未经解释的违规。

## 维护

项目、集成顶层、查找表已生成，队友正常编译不需要 Python。
如 main 顶层变更，先人工核对后运行 `python audio_board/tools/prepare_projects.py`，
然后重新编译。它会覆盖生成的集成顶层，所以测试参数修改应在生成之后进行。
来源和验证证据见 vendor/PROVENANCE.md、VALIDATION.md。
