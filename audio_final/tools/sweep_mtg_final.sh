#!/usr/bin/env bash
# 会议倒计时 MM:SS + 可视化门控版 —— 用【当轮综合 gate.db】重扫 place seed。
#   netlist 在 21:19~21:40 变过(meeting_osd 重写/audio_viz_overlay 门控/top_final 接线)。
#   判据: 无布线错误 + SWNS>=0 + HWNS>=0; 全部扫完再排序(不提前退出)。
set -u
BD=/e/FPGA/ALST/_dev_sim_0b18789/audio_final
OUT=$BD/build
TCL=E:/FPGA/ALST/_dev_sim_0b18789/audio_final/tools/sweep_place_seed.tcl
EXE=E:/FPGA/TD/bin/td_commands_prompt.exe
DONE=$OUT/sweep_mtg_done.txt
: > "$DONE"

ALL="1 3 5 7 9 11 13 15 17 19 21 23 25 27 29 31 33 35 37 39 41 43 45 47 49 51 53 55 57 59 61 63"

# 单个种子处理函数
run_seed() {
  local s=$1
  echo "start seed $s" >> "$DONE"
  rm -f "$OUT/pic_sdram_audio_final_seed$s.timing"
  TD_PLACE_SEED=$s "$EXE" "$TCL" > "$OUT/sweep_mtg_seed$s.log" 2>&1
  if grep -q "PHY-8023 ERROR\|RUN-8102 ERROR" "$OUT/sweep_mtg_seed$s.log"; then
    echo "SEED $s : ROUTE FAIL" >> "$DONE"; return
  fi
  if ! grep -q "SEED_DONE $s" "$OUT/sweep_mtg_seed$s.log"; then
    echo "SEED $s : NO SEED_DONE" >> "$DONE"; return
  fi
  local SW HW
  SW=$(grep -m1 "SWNS:" "$OUT/pic_sdram_audio_final_seed$s.timing" | sed -n 's/.*SWNS: *\(-\?[0-9.]*\)ns.*/\1/p')
  HW=$(grep -m1 "HWNS:" "$OUT/pic_sdram_audio_final_seed$s.timing" | sed -n 's/.*HWNS: *\(-\?[0-9.]*\)ns.*/\1/p')
  echo "SEED $s : SWNS=$SW HWNS=$HW" >> "$DONE"
}
export -f run_seed
export BD OUT TCL EXE DONE

# 12 路并发, 用 xargs 分发
printf '%s\n' $ALL | xargs -P 12 -I {} bash -c 'run_seed {}'

echo "=== ALL DONE ===" >> "$DONE"
