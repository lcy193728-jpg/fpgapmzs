# 四场景最终音频上板工程（暂不含语音播报）

本目录是独立增量版本。原 `src/`、`audio_board/`、`pic_sdram.al`、
`pic_sdram_audio.al`、既有模块接口和既有 bit 均未改写。新工程入口为仓库根目录
`pic_sdram_audio_final.al`，新顶层为 `audio_final/integrated/top_final.v`。

## 已实现行为

| 场景 | 音频 | 可视化 |
|---|---|---|
| 迎新(scene_id=0) | 每次从菜单/其他场景进入时，100 ms提示音后播放现有六音欢迎旋律两遍，约3.1 s；切图不重播，结束后静音 | 最终PCM波形和峰值条；结束后归零 |
| 会议(scene_id=1) | 无入场旋律、无背景音乐。进入后计时，60 s播放一次提醒音，120 s播放两次超时音；离开重置 | 不显示 |
| 抢答(scene_id=2) | 倒计时显示3、2、1时各响一次；选手锁定后播放成功旋律；无人抢答时播放两次超时音。暂不含“请抢答”和获胜选手语音 | 最终PCM波形和峰值条 |
| 应急(scene_id=3) | 最高优先级；循环播放用户提供录音的前7秒；解除后淡出并静音，不补播被中断声音 | 最终PCM波形和峰值条 |

所有声音保持48 kHz、16 bit双声道同值PCM，空闲时仍连续发送零样本。

## 真实警报资源

来源文件为用户本机 `D:\App\QQMusic\铃声 - 防空警报_L.ogg`。工具截取前7秒、
立体声合成单声道、重采样为4 kHz后编码为IMA-ADPCM；FPGA每个解码样本保持12个
48 kHz采样周期。有效压缩数据为14000字节，`assets/alarm_4k_adpcm.dath` 补齐为
16384字节并随bit进入片内BRAM，不占TF卡扇区和SDRAM，不影响现有图片读取。转换参数、原文件哈希和
资源哈希见 `assets/alarm_audio.json`。`alarm_4k_reference.wav` 供上板前试听。

重新生成资源需要Codex Python运行环境中的 `numpy`、`scipy`、`soundfile`：

```powershell
& "C:\Users\18441\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe" `
  .\audio_final\tools\prepare_alarm_audio.py
```

## 编译与下载

1. 克隆/切换到 `dev_sim`，确认提交号与交付说明一致。
2. 保留原四分区图片TF卡，警报资源无需复制到卡。
3. 可直接使用已通过布局布线的 `audio_final/artifacts/pic_sdram_audio_final.bit`。
4. 如需重编译，运行下方脚本；脚本会按当前仓库绝对路径自动生成TD所需的警报ROM路径，
   然后完成综合、布局布线、时序检查和bitgen。不要把工程搬动后直接复用旧的中间数据库。
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
2. 进入迎新只播放一次欢迎旋律；手动/自动切图均不重播；底部波形随旋律变化后归零。
3. 抢答开始后只在3、2、1响；抢答成功有成功旋律；无人抢答有双提示；画面状态和声音一致。
4. 进入会议后保持安静；约60 s一声提醒、约120 s双声超时；会议没有波形区域。
5. 任一普通声音播放中打开SW4，真实防空警报应立即抢占并循环；波形和峰值条持续变化。
6. 关闭SW4，警报短暂淡出后静音，原声音不恢复。
7. 连续运行10分钟，反复切场景，检查无黑屏、花屏、爆音、断音和按键功能回退。

保存本次bit哈希、TD资源/时序报告、显示器型号、整屏照片及带声音录像。只有全部
通过后再写配置Flash，并断电重启复查。

## 已完成的软件检查和交付物

- ModelSim `vlog`已执行新增RTL和集成顶层的语法编译：0 error；按用户要求未运行功能仿真。
- TD EDA 6.2.168.116已完成综合、布局布线、最终时序分析和bitgen：
  `SWNS=+0.218 ns`，`HWNS=0 ns`。
- 最终资源：LUT 8956/19600、寄存器4594、BRAM 56/64、DSP 29/29；均未超限。
- 位流：`artifacts/pic_sdram_audio_final.bit`；SHA-256见 `artifacts/SHA256SUMS.txt`。
- 最终面积、时序和完整构建日志位于 `reports/`。这些是软件构建结果，不代表已经完成实板验收。

## 当前限制

- 会议工程当前没有独立发言计时端口，因此提醒以“进入会议场景”为计时起点；两个秒数
  是 `audio_feature_events.v` 的参数，后续接入正式会议计时事件时只需替换事件源。
- 真实警报和可视化缓存使全工程使用56/64个BRAM，DSP已使用29/29。TD若报告资源超限，应停止下载并回传资源报告，
  不能删除既有功能或改用旧报告判断。
