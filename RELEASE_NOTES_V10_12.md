# v10-12 发布说明（2026-10-12）

## 版本定位

v10-12 以 v10-10 的四场景功能为基线，只修正场景切换、抢答音画时序和冷启动首帧问题，不改变按键映射、场景功能、TF 卡素材布局、亮度/缩放/对比度/音量算法及会议流程。

## 已解决问题

| 现象 | 根因 | v10-12 处理 |
|---|---|---|
| 菜单进入抢答、迎新或会议时，黑场后随机先闪出迎新图或旧图 | `img_busy` 只表示 SD/BMP 源端状态；请求发出到 busy 拉高之间存在旧空闲窗口，缩放 FIFO 和 SDRAM 还未完成整帧提交 | `scene_load_guard` 以 `frame_write_finish` 为提交凭据，吞掉迟到旧提交；菜单进入场景立即遮黑，观察到本次 busy 完整高低周期后才淡入 |
| 首次进入抢答时偶发迎新音乐，或可视化柱阵继承上一场景 | `menu_active` 和 `scene_id` 独立跨域同步，过渡期可能短暂形成非法“迎新”组合；BRAM 柱高历史没有随场景清理 | 上游先生成单一 `welcome_active` 再同步；音频事件和 WAV 选择统一使用该资格位；场景变化时清理可视化统计和有效历史 |
| 抢答结束分数先于 QUIZ8 背景出现 | `q_end` 早于图片写完，分数层又没有服从 iris 的逐像素揭示区 | `quiz_end_commit_guard` 等待 QUIZ8 完整帧提交后产生 `q_end_ready`；分数只在帧边界放行，并与 iris 可见区域同步 |
| 为避免分数抢跑而直接门控后，结束分数完全不显示 | 通用 busy 电平不能可靠表达“本次结束图已提交”，可能错过短完成事件 | 改用专用、跨域保持的完整帧提交令牌，不再用瞬时 busy 猜测 |
| 冷启动或重新配置后，第一张有效图之前可能显示 SDRAM 随机内容 | HDMI 读侧早于首张 BMP 完整写入 SDRAM | `video_first_frame_gate` 在第一次 `frame_write_finish` 前压黑背景，完成信号跨域后仍等待 VS 上升沿才整帧放行 |
| `PROGRAM_FLASH success` 后误以为断电仍丢失 | BitWriter 列表中同时存在多个旧/重复位流；烧完后的在线画面不是严格冷启动验证 | 固化时清空列表，只保留 10-12 的 `best_result` 位流；完成 verify 后不再下载 SRAM，完全断电再验证 |

## 主要修改文件

- `audio_final/integrated/top_final.v`
- `src/display_adjust.v`
- `src/quiz_scene_ctrl.v`
- `src/scene_load_guard.v`
- `src/quiz_end_commit_guard.v`
- `src/video_first_frame_gate.v`
- `audio_final/rtl/audio_feature_events.v`
- `audio_final/rtl/scene_audio_final.v`
- `audio_final/rtl/audio_viz_overlay.v`
- 对应 `audio_final/tb/`、`sim/tb/` 和 `tb/` 测试文件

## 验证结果

- `video_first_frame_gate` 冷启动专项 ModelSim：通过，423 ns 结束。
- `top_final.v` 集成编译：零错误，顶层 `top` 成功展开。
- TD 6.2：综合、布局布线、bitgen 完成；SWNS `+0.070ns`，HWNS `+0.003ns`。
- 位流大小：685496 B，生成于 2026-10-12 10:27:34。
- 全量 ModelSim 回归：27 项中 25 项通过。

### 已知回归差异

- `run_sim_score`：旧 testbench 未驱动 v10-12 新增的 `q_end_ready`，记录 11 个像素期望失败。
- `run_sim_viz_gate`：旧用例仍期待跨场景保留可视化历史，与 v10-12 的清场策略不一致，记录 1 个期望失败。

两项用例均不实例化 `video_first_frame_gate`。为遵守“只修目标问题、不改变其他效果”的范围，本版本没有顺手重写这两个旧用例；后续如调整测试契约，应单独提交。

## 固化基线

生成位流：

`pic_sdram_audio_final_Runs/best_result/pic_sdram_audio_final.bit`

BitWriter 参数：

- Mode：`PROGRAM_FLASH`
- Speed：`5MHz`
- MemorySize：`128Mbits`
- Verify：启用（日志出现 `verify_spi`）

File Selection 必须只有一个 10-12 位流。固化后不要再次运行 `PROGRAM_SRAM`，完全断电约 10 秒后验证上电自启动。
