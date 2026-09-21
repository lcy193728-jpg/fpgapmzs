# 四场景最终音频上板工程（暂不含语音播报）

本目录是独立增量版本。原 `src/`、`audio_board/`、`pic_sdram.al`、
`pic_sdram_audio.al`、既有模块接口和既有 bit 均未改写。新工程入口为仓库根目录
`pic_sdram_audio_final.al`，新顶层为 `audio_final/integrated/top_final.v`。

## 已实现行为

| 场景 | 音频 | 可视化 |
|---|---|---|
| 迎新(scene_id=0) | 每次从菜单/其他场景进入时，100 ms提示音后播放八音喜悦旋律（do-mi-sol-do′-sol-mi-re-do，每音0.25 s）；**在场景一内一直循环**，同场景切图不重播，离开场景一才停 | 最终PCM波形和峰值条；持续随旋律变化 |
| 会议(scene_id=1) | 无入场旋律、无背景音乐。进入后计时，60 s播放一次提醒音，120 s播放两次超时音；离开重置 | 不显示 |
| 抢答(scene_id=2) | 倒计时显示3、2、1时各响一次；选手锁定后播放成功旋律；无人抢答时播放两次超时音。暂不含“请抢答”和获胜选手语音 | 最终PCM波形和峰值条 |
| 应急(scene_id=3) | 最高优先级；片内DDS实时合成国标空袭警报音型（鸣6 s/停6 s连续循环），不再占用BRAM；解除后淡出并静音，不补播被中断声音 | 最终PCM波形和峰值条 |

所有声音保持48 kHz、16 bit双声道同值PCM，空闲时仍连续发送零样本。

## 警报音频来源（已改为片内合成）

QQ音乐铃声与 Wikimedia Commons 真实机械警报录音（`Sirene.ogg`，作者 GeoTrinity，
CC BY-SA 3.0）两版方案均已停用：前者上板只剩电子滴声，后者把前7秒重采样为3 kHz
有符号8 bit PCM 存进 21 KB ROM，既占约21块BRAM，听感也不符合国标音型。

当前应急音频由 `rtl/scene_audio_final.v` 内的 DDS 实时合成，不占用任何 BRAM/DSP：

- 三角波扫频 400 Hz↔1000 Hz（每 48 kHz 样本加一个常数增量步进，无乘法器），
  1.5 s 上升 + 1.5 s 下降 = 3 s 一个周期；
- 国标空袭警报音型：鸣 6 s / 停 6 s 连续循环，用 48 kHz 样本计数器分段
  （6 s × 48000 = 288000），段长精确、与 25 MHz→48 kHz 的非整数分频无关；
- 每个"鸣"段起点复位扫频与三个振荡器相位，段首/段尾各做 256 样本的起振/释放
  斜坡，避免爆音；"停"段输出恒零，为真静音。

因此 `assets/alarm_3k_pcm8.dath`、`assets/alarm_audio.json` 与
`tools/prepare_alarm_audio.py` 只作历史参照保留，不再参与构建；`build.ps1` 生成的
`rtl/alarm_init_path.vh` 也已无 RTL 引用。

## 编译与下载

1. 克隆/切换到 `dev_sim`，确认提交号与交付说明一致。
2. 保留原四分区图片TF卡，警报资源无需复制到卡。
3. 可直接使用已通过布局布线的 `audio_final/artifacts/pic_sdram_audio_final.bit`。
4. 如需重编译，运行下方脚本；脚本会完成综合、布局布线、时序检查和bitgen，并把新位流、
   报告及SHA-256自动发布到 `audio_final/artifacts/` 与 `audio_final/reports/`。
   不要从 `audio_final/build/` 手工挑选文件。
5. 检查本次资源报告：BRAM不得超限；Setup/Hold均不得为负。
6. 首次只JTAG/SRAM下载bit，不要先写Flash。

命令行编译：

```powershell
Set-ExecutionPolicy -Scope Process Bypass
& .\audio_final\tools\build.ps1 -TdRoot "D:\Anlogic\TD_6.2.1_Engineer_6.2.168.116"
```

下载可复用公共底层脚本：

```powershell
& .\audio_board\tools\download.ps1 `
  -TdRoot "D:\Anlogic\TD_6.2.1_Engineer_6.2.168.116" `
  -BitFile .\audio_final\artifacts\pic_sdram_audio_final.bit
```

## 上板验收

先降低显示器音量。依次检查：

1. 菜单无测试音，HDMI画面稳定。
2. 进入迎新先响100 ms提示音，随后喜悦旋律一直循环；手动/自动切图均不重播；底部波形随旋律持续变化。
3. 抢答开始后只在3、2、1响；抢答成功有成功旋律；无人抢答有双提示；画面状态和声音一致。
4. 进入会议后保持安静；约60 s一声提醒、约120 s双声超时；会议没有波形区域。
5. 任一普通声音播放中打开SW4，国标空袭警报（鸣6 s/停6 s循环）应立即抢占；鸣段波形与峰值条变化，停段归零。
6. 关闭SW4，警报短暂淡出后静音，原声音不恢复。
7. 连续运行10分钟，反复切场景，检查无黑屏、花屏、爆音、断音和按键功能回退。

保存本次bit哈希、TD资源/时序报告、显示器型号、整屏照片及带声音录像。只有全部
通过后再写配置Flash，并断电重启复查。

## 已完成的软件检查和交付物

- ModelSim 已编译 `scene_audio_final` 与 `tb_siren_dds`（0 error 0 warning），并跑完功能仿真：
  15/15 断言全 PASS —— 段长精确 288000（=6.000 s@48 kHz）、停段 PCM 恒 0（真静音）、
  段尾增益降到 0 / 段首从增益 1 起振（无爆音）、每段"鸣"都从 400 Hz 重新起频。
- TD EDA 已完成综合、布局布线、最终时序分析和bitgen：
  `SWNS=+0.264 ns`，`HWNS=+0.020 ns`。
- 最终资源：LUT 7948/19600（40.6%）、寄存器 5259/19600（26.8%）、BRAM 57/64（89.1%）、
  DSP 13/29（44.8%）；均未超限。
- 位流：`artifacts/pic_sdram_audio_final.bit`，SHA-256
  `1dcf21cd0acace4a8329a2c92697e7da2d96c44eb025ad2474ed7c0e47881393`；
  也已通过 JTAG 下载到 EG4S20BG256（`PRG-2014 : Chip validation success`）。
- 最终面积、时序和完整构建日志位于 `reports/`。这些是软件构建结果，不代表已经完成实板验收。

## 当前限制

- 会议工程当前没有独立发言计时端口，因此提醒以“进入会议场景”为计时起点；两个秒数
  是 `audio_feature_events.v` 的参数，后续接入正式会议计时事件时只需替换事件源。
- 可视化缓存与会议议程 BRAM 使全工程使用 57/64 个 BRAM（89.1%）；DSP 只用 13/29（44.8%），
  因为警报已改成片内 DDS 合成，不再占 ROM/DSP。TD若报告资源超限，应停止下载并回传资源报告，
  不能删除既有功能或改用旧报告判断。

## 上板问题修订

- 两次上板反馈警报只剩长短滴声，说明ADPCM软件参考结果不能代表器件内状态解码结果。
  当前版本已删除硬件ADPCM解码器，改为直接读取有符号PCM8，避免步长表、预测器和
  半字节状态产生板端差异。
- 首版进入迎新无声，是菜单同步状态与欢迎事件同拍时可能丢弃事件。当前音频模块直接
  检测“菜单→迎新”电平转换，不再依赖这一拍的外部事件。
