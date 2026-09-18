# 验证记录

基线 main `6586b66447375c1c4dfc9568b17a79df889cfbae`；TD EDA 6.2.168116，器件 EG4S20BG256。

**实际执行：综合、布局布线、最终静态时序分析、比特流生成。未运行 ModelSim，未连接开发板下载或试听。**

| 工程 | Setup WNS(ns) | Hold WNS(ns) | LUT | FF | BRAM9K | DSP | PLL |
|---|---:|---:|---:|---:|---:|---:|---:|
| tone | 0.091 | 0.034 | 1464 | 586 | 1 | 1 | 1 |
| integrated | 0.203 | 0.004 | 10802 | 4163 | 39 | 29 | 2 |

两个工程最终 Setup/Hold 均非负，成功生成 bit；不是零 warning。
pixel→serial 同源相关时钟路径参与真实 STA，没有 false-path 掩盖。

逐一核对 61 个基线 RTL/IP/工程/约束文件的 Git blob，与 main 相同。
14 份教程原件哈希一致，9 份直接复用协议文件逐字节一致；附加 AVI/Audio InfoFrame 校验和核对通过。
PowerShell 脚本语法检查、Python 生成器语法检查通过。下载脚本仅做语法检查，没有在硬件执行。

## 实际限制与警告

- 集成版 DSP 为 29/29，后续加入乘法型音量、频谱等功能前需做资源优化。
- 独立版查找表推断的 ROM 存在未使用 B 端口/写使能绑零的 SYN-5011，及匿名网命名警告，完整日志保留。
- 集成日志还包含基线 IP/RTL 的位宽、未使用端口和 SDRAM 映射警告。PHY-5079 指向 ext_mem_clk_sft / U3/u2_ram/SDRAM_CLK；SDRAM 单元位置重定位也有 CRITICAL-WARNING。
- 这些警告不作为已证明无影响的结论；队友需同时验证原图、缩放、TF 卡及长时间运行，见 README。
- 25 MHz 对应约 59.524 Hz，沿用原视频时钟；未做 EDID/DDC/HPD 协商，接收器兼容性尚待实测。
- 布线时序余量较小，修改或重新布局后必须重新检查，不以旧报告代替。
- 未实现各场景不同音源、WAV 读取、语音、应急抢占；本版是共用底层与连续测试音验收版。

## 证据

- reports/ 中保留最终完整 TD 日志、布线时序、资源/IO、时序例外及机器可读摘要。
- artifacts/ 中提供本次生成的两个 bit，SHA256SUMS.json 标识其哈希。
- reports/source_sha256_lf.json 标识生成 bit 所使用的源码（换行归一化 LF）。
- 队友按 README 保存照片、带声音的视频、设备型号、bit 哈希和运行时间后再确认上板通过。
