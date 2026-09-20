这些 14 个原始 Verilog 文件来自用户提供的“米醋工作室安路赛道完赛教程”音频配套代码。
导入位置为用户本机 `D:/18441/QQ/pcm_test_tone.v 等14项`，由用户明确要求纳入 GitHub 上板工程。
原件逐字节保留，SHA256.json 记录哈希。未增加或推断原作者的许可证。

实际 TD 工程只编译 `../rtl/` 中的文件，不编译此目录。

`rtl/hdmi_audio_symbol_core.v` 在原核心基础上增加：

- 垂直消隐行不发送无后续视频的视频前导/保护带。
- AVI 信息包与 Audio InfoFrame 共享既有信息包调度入口。

其余九个被复用的协议模块保持原始字节。原 pcm_test_tone、pcm_media_tone、
media_hdmi_audio_bridge、m06_pcm_contract_adapter 仅保留为参考，不进入本版综合。
本版使用新写的 48 kHz DDS 测试音和带缓冲、握手检查的公共 PCM 输入层。

教程注释中的 verified 不作为本工程验证结论；以 ../VALIDATION.md 为准。
