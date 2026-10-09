#!/usr/bin/env bash
# 并行 place seed 【择优】扫描 —— 对比度功能版新 netlist（2026-10-09d）。
#
#   本轮 RTL 变化: display_adjust 新增对比度运算 + 品红 HUD 条(y64..71);
#     ui_key_ctrl 场景相关模式重映射 + down_lv 双输出 + con_level;
#     quiz_ctrl 改按住电平 + 100ms 节拍判定;
#     audio_viz_overlay 条带位置回退(几何)。
#   → netlist 变化 ⇒ 必须重扫种子。
#
#   择优判据: 无 PHY-8023/RUN-8102 布线错误; 记录每颗种子 SWNS/HWNS;
#     并按历史经验避开"最差路径扎进 bmp_read_auto.v 32bit 比较进位链"的落点。
#   复用 build/pic_sdram_audio_final_gate.db(本轮综合产物, 12:20)。
set -u
BD=/e/FPGA/ALST/_dev_sim_0b18789/audio_final
OUT=$BD/build
TCL=E:/FPGA/ALST/_dev_sim_0b18789/audio_final/tools/sweep_place_seed.tcl
EXE=E:/FPGA/TD/bin/td_commands_prompt.exe
DONE=$OUT/sweep_contrast_done.txt
: > "$DONE"

worker() {
  local w=$1; shift
  for s in "$@"; do
    echo "W$w start seed $s" >> "$DONE"
    rm -f "$OUT/pic_sdram_audio_final_seed$s.timing"
    TD_PLACE_SEED=$s "$EXE" "$TCL" > "$OUT/sweep_contrast_seed$s.log" 2>&1
    if grep -q "PHY-8023 ERROR\|RUN-8102 ERROR" "$OUT/sweep_contrast_seed$s.log"; then
      echo "SEED $s : ROUTE FAIL" >> "$DONE"; continue
    fi
    if ! grep -q "SEED_DONE $s" "$OUT/sweep_contrast_seed$s.log"; then
      echo "SEED $s : NO SEED_DONE" >> "$DONE"; continue
    fi
    local SW HW
    SW=$(grep -m1 "SWNS:" "$OUT/pic_sdram_audio_final_seed$s.timing" | sed -n 's/.*SWNS: *\(-\?[0-9.]*\)ns.*/\1/p')
    HW=$(grep -m1 "HWNS:" "$OUT/pic_sdram_audio_final_seed$s.timing" | sed -n 's/.*HWNS: *\(-\?[0-9.]*\)ns.*/\1/p')
    echo "SEED $s : SWNS=$SW HWNS=$HW" >> "$DONE"
  done
}

# 本工程历史命中种子清一色奇数 → 只扫奇数; 24 颗 / 12 worker(本机 24 核)。
worker 1 1 25 &
worker 2 3 27 &
worker 3 5 29 &
worker 4 7 31 &
worker 5 9 33 &
worker 6 11 35 &
worker 7 13 37 &
worker 8 15 39 &
worker 9 17 41 &
worker 10 19 43 &
worker 11 21 45 &
worker 12 23 57 &
wait
echo "ALL WORKERS DONE" >> "$DONE"
echo "==================== 按 SWNS 排序 ===================="
grep '^SEED .*SWNS=' "$DONE" \
  | sed 's/^SEED \([0-9]*\) : SWNS=\([-0-9.]*\) HWNS=\([-0-9.]*\)/\2 \1 \3/' \
  | sort -g -r | awk '{printf "seed %-3s SWNS=%-8s HWNS=%s\n",$2,$1,$3}'
echo "==================== 布线失败/异常 ===================="
grep -v 'SWNS=' "$DONE" | grep -v 'start seed' | grep -v 'ALL WORKERS' || true
