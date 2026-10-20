# 10-19 最终交付包

GitHub 分支：`codex/final-10-19-delivery`

本目录对应已经完成上板验证的 10 月 19 日最终版本。仓库根目录保存可综合工程源码，本目录集中保存唯一可烧录位流、与该位流匹配的物理实现报告、验证记录、参赛文档和官方模版。

## 唯一烧录文件

`01_bitstream/ONLY_PROGRAM_FINAL_10_19_QOR_BEST.bit`

SHA256：`B44A60AA348C756FBC08373CCC06E3B3B7BA08C4C226C339237E8FF31A5D49A9`

请勿烧录仓库历史记录、构建缓存或名称包含 `REJECTED`、`CANDIDATE` 的文件。

## 目录说明

- `01_bitstream`：唯一可烧录最终位流。
- `02_physical_reports`：该位流对应的 TD seed59 面积、时序及 QoR 原始报告。
- `03_verification`：优化闭环、低功耗收敛和 UART 使用资料。
- `04_documents`：根据竞赛模版形成的作品设计报告。正式提交评委时使用 `作品设计报告_10-20评委提交版.docx/.pdf`；其余版本仅保留作修订对照。
- `05_requirements_templates`：作品上传要求和未修改的原始 Word 模版。

## 源码位置

完整可综合工程位于仓库根目录，工程入口为：

- `pic_sdram_audio_final.al`
- 顶层：`audio_final/integrated/top_final.v`
- 约束：`audio_board/integrated/audio.sdc`、`top.adc`
- 应用 RTL：`src/`
- HDMI 音频 RTL：`audio_board/rtl/`、`audio_final/rtl/`
- 仿真：`tb/`、`sim/tb/`、`audio_final/tb/`
- 发布门禁：`tools/qualify_10_18_final.ps1`

## 已验证结果

| 指标 | 结果 |
|---|---:|
| LUT | 17288 / 19600 |
| REG | 8881 / 19600 |
| Slice | 9377 / 9800 |
| BRAM9K | 52 / 64 |
| BRAM32K | 13 / 16 |
| DSP | 14 / 29 |
| Setup WNS | +0.134 ns |
| Hold WNS | +0.020 ns |
| STA Coverage | 99.84% |
| 功能与专项回归 | 12 / 12 通过 |

## 当前状态

功能、仿真、布局布线和实板烧录均已完成。后续不继续修改正式 RTL，主要补充冷启动、长时间运行、异常素材、响应延迟和板级功耗数据，并将实物照片及测试结果填入作品设计报告。

10-20 评委提交版以“校园多场景确定性音视频信息终端”为产品主线，先呈现应用价值和四场景产品形态，再用帧事务显示、流式低资源算法、活动驱动低功耗、异常恢复和物理实现结果证明作品优势；资源及时序数据均来自最终 seed59。

本次最终功能回归结果见 `03_verification/最终回归结果_10-19.md`；全部交付文件的校验值见根目录 `SHA256SUMS.txt`。

