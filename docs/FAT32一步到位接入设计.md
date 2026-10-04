# FAT32 正规化 · 一步到位接入设计（scanner + streamer 全接）

> 基线：10-4 版位流 `artifacts/pic_sdram_audio_final_v10-4.bit`
> 原则：严格照搬小鹅通第七讲（第 5 节「最小改动方案」），同时因地制宜适配本工程的
>       `sd_card_top`（官方底层驱动不动，写适配层隔离——这正是小鹅通教程第七节原则 7 的原文要求）。

---

## 1. 目标与范围

把三个数据源从「固定扇区 + 魔数扫描」改为「FAT32 文件系统 + 文件名匹配 + FAT 链读取」：

| 数据源 | 现状 | 目标（文件化） |
|---|---|---|
| BMP 图片（10 张） | `bmp_read_auto` 每 8 扇区扫 `BM` 魔数 + 硬编码 `Z_*` 表 | `fat32_volume_scanner` 上电扫目录拿簇号/大小 → `fat32_file_streamer` 按 FAT 链读 |
| 会议配置 MTG1.CFG | `meeting_sd_rd` 固定扇区 200000 读 3 扇区 | scanner 拿 `MTG1.CFG` 簇号 → streamer 读 |
| 背景音乐 WEL.BIN | `wav_stream_player` 固定扇区 300000 读裸 PCM | scanner 拿 `WEL.BIN` 簇号 → streamer 读 |

**最终显示仍是 640×480**（多分辨率原图由 `bmp_read_auto` 内现有多分辨率缩放器统一缩到 640×480 后写入 SDRAM 单帧，SDRAM 只驻留当前一帧 ≈1.2MB << 8MB）。

---

## 2. 核心架构决策（照搬 vs 因地制宜）

### 2.1 照搬（不改）的部分
- `fat32_volume_scanner.v`：照搬小鹅通原版，仅把 4 资源扩展为 12 资源
  （`resource_valid` 4→12 bit，`dir_resource_index` 2→4 bit，`name_match` 组合逻辑替代
   `matching_resource` function）。**已恢复小鹅通原版 `ST_DIR_SCAN` 全命中校验语义**。
- `fat32_file_streamer.v`：**与小鹅通原版逐字一致**（diff 无差异）。
- `sd_sector_adapter.v`：小鹅通教程 5.3 节明确要求「自己写」的适配层，已与小鹅通
  5.3 参考代码逐行一致。

### 2.2 因地制宜（适配）的部分
- **不改 `sd_card_top`**（官方底层驱动，教程第七节原则 7 明文要求隔离）。
- **SDRAM 不搞「上电全量 ingest」**：10 张图全部驻留需 ~10.2MB > 8MB，物理装不下。
  改为「按需读一张 → 缩放 → 显示 → 切场景再读下一张」，即小鹅通第八讲「按 bank 选择
  显示」在本项目（单帧 640×480）下的正确落地形态。
- **scanner 开机独占一次**：扫完目录拿到 12 个簇号后即释放总线，之后不再读卡。

---

## 3. SD 总线仲裁改造（关键难点）

现状 `audio_sd_arbiter` 是「A 侧(图片+会议) vs B 侧(WAV)」两路。FAT32 化后多出
**scanner（开机独占一次）** 和 **streamer（替代 bmp_read_auto 的找图逻辑）** 两个 SD 使用者。

改造方案——**保持两路仲裁器不动，新增一个「FAT32 通路扇区源」合入 A 侧**：

```
                          ┌─────────────┐
  bmp_read_auto(改造后) ──┤  A 侧合并    │
  meeting_sd_rd(改造后) ──┤  (fat32_src) ├──► audio_sd_arbiter.A ──► sd_card_top
  fat32_streamer         ──┤             │
                          └─────────────┘
  fat32_scanner ──(开机独占, 独占窗口内直接挂 arbiter.A)──► ... ──► sd_card_top
```

**具体做法**（新增一个 `fat32_sd_mux` 仲裁/合路层，放在 `sd_card_bmp` 内）：
- scanner 开机独占阶段：`sd_sec_read = scanner.sector_req`，地址/数据/end 全路由给 scanner；
  此时 bmp_read_auto 被 `bmp_go` 钉在安全窗口，meeting/wav 也被门控（`sd_init_done & mtg_done_w`），
  故 scanner 独占期间无冲突。
- scanner 完成后：进入正常轮播，streamer 与（改造后的）bmp_read_auto 共享 A 侧——
  但 streamer 只在「bmp_read_auto 请求读某张图」时被驱动，两者本质是「bmp_read_auto
  发 file_start → streamer 读文件 → 字节回给 bmp_read_auto」，**同一时刻只有 streamer 在发扇区请求**，
  故 streamer 的 `sector_req/lba` 直接作为 A 侧的图片通路请求即可，无需再额外仲裁。

**结论：总线仲裁器 `audio_sd_arbiter` 本身不需要改**，只需在它前面加一层「scanner 独占 vs 正常轮播」
的二选一 mux（开机时 scanner 独占，之后 streamer 顶替 bmp_read_auto 的扇区请求）。

---

## 4. 各模块改造明细

### 4.1 `sd_card_bmp.v`（改造最重）
1. 顶部 include 新增：`fat32_volume_scanner.v`、`fat32_file_streamer.v`、`sd_sector_adapter.v`。
2. 新增 scanner 例化 + 开机独占状态机：
   - `sd_init_done` 后立即 `scan_start=1`，scanner 经 `sd_sector_adapter` 读 LBA0/BPB/根目录。
   - `scan_done` 后锁存 12 个 `resourceX_cluster/size` + `sectors_per_cluster/fat_start_lba/data_start_lba/max_cluster`。
   - 扫描期间，把 scanner 的 `sector_req` 路由给 `audio_sd_arbiter.A`（此时 bmp/meeting/wav 都被门控，独占安全）。
3. 新增 streamer 例化，其 `sector_req/lba` 作为「图片通路扇区请求」接 A 侧。
4. 改造 `bmp_read_auto` 的「找图」逻辑：把「逐扇区扫 BM」改为「`file_start(簇号)` →
   收 `file_valid/file_byte` 字节流 → BMP 头解析 → 现有多分辨率缩放」。
   - 分区切换 `zone_load` 时，不再给扇区表，而是给「该场景对应的文件簇号」（从 scanner 结果查表）。
5. 改造 `meeting_sd_rd`：从「固定扇区 3 扇区」改为「`file_start(MTG1.CFG 簇号)` → 收字节流 → 现有 MTG1 解析」。
6. 改造 `wav_stream_player` 的扇区源：从「固定 LBA 顺序读」改为「`file_start(WEL.BIN 簇号)` → streamer 读」。

### 4.2 `bmp_read_auto.v`（改造重）
- 保留：BMP 头解析、多分辨率缩放器、轮播状态机、分区切换、容错重试。
- 替换：`sd_sec_read` 直读扇区 + `rd_cnt` 找 BM 魔数 → 改为从 `fat32_file_streamer` 收
  `file_valid/file_byte/file_byte_offset/file_done` 字节流。
- 新增接口：`file_start`、`first_cluster`、`file_size`（由上层 `sd_card_bmp` 从 scanner 结果查表给出）。

### 4.3 顶层 `top_final.v`
- `Z_*` 扇区常量表**删除**（不再需要），改为「场景 → 资源号」的映射表（资源号对应 scanner 扫出的文件）。
- `mtg_start_sector`、`wav_start_lba/wav_sectors` 常量**删除**，改为由 scanner 结果驱动。
- `find_bmp.py` 工具退居二线（仅用于素材制作阶段确认文件在卡上，不再生成 `Z_*` 常量）。

---

## 5. 验证计划（先仿真后上板）

1. `tb_fat32_scanner`（已有）：18 PASS，验证 12 文件簇号/大小。
2. `tb_fat32_streamer`（已有）：碎片化文件 FAT 链读取。
3. `tb_sd_sector_adapter`（新增）：14 PASS，验证桥接层握手 + 512 字节顺序对齐。
4. 新增 `tb_bmp_read_auto_fat32`：验证 bmp_read_auto 改造成从 streamer 字节流收图后，
   多分辨率缩放 + 轮播 + 分区切换行为与改造前一致。
5. 上板：先 JTAG/SRAM，再固化 Flash（遵守项目纪律）。

---

## 6. 风险与回退

- **最大风险**：`bmp_read_auto` 是「找图+缩放+轮播」三位一体的 1200 行大模块，改造它的
  「找图」部分需极小心，绝不能破坏现有多分辨率缩放器（已有 10 套仿真护栏）。
- **回退**：scanner/streamer/adapter 三模块独立，若接入出问题，可临时切回 `bmp_read_auto`
  的「扫魔数」路径（保留原代码分支），不影响已上板的 10-4 版。
