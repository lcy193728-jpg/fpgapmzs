#!/usr/bin/env bash
# 并行扫描 place seed(多分辨率+双线性改动后的新 netlist)。
#   判据: 无 PHY-8023/RUN-8102 布线错误, 且全局 SWNS>=0 且 HWNS>=0。
#   复用本次综合的 build/pic_sdram_audio_final_gate.db(不改 RTL)。
set -u
BD=/e/FPGA/ALST/_dev_sim_0b18789/audio_final
OUT=$BD/build
TCL=E:/FPGA/ALST/_dev_sim_0b18789/audio_final/tools/sweep_place_seed.tcl
EXE=E:/FPGA/TD/bin/td_commands_prompt.exe
DONE=$OUT/sweep3_done.txt
: > "$DONE"

worker() {
  local w=$1; shift
  for s in "$@"; do
    [ -s "$OUT/sweep3_pass.txt" ] && return 0
    echo "W$w start seed $s" >> "$DONE"
    rm -f "$OUT/pic_sdram_audio_final_seed$s.timing"
    TD_PLACE_SEED=$s "$EXE" "$TCL" > "$OUT/sweep3_seed$s.log" 2>&1
    if grep -q "PHY-8023 ERROR\|RUN-8102 ERROR" "$OUT/sweep3_seed$s.log"; then
      echo "SEED $s : ROUTE FAIL" >> "$DONE"; continue
    fi
    if ! grep -q "SEED_DONE $s" "$OUT/sweep3_seed$s.log"; then
      echo "SEED $s : NO SEED_DONE" >> "$DONE"; continue
    fi
    local SW HW
    SW=$(grep -m1 "SWNS:" "$OUT/pic_sdram_audio_final_seed$s.timing" | sed -n 's/.*SWNS: *\(-\?[0-9.]*\)ns.*/\1/p')
    HW=$(grep -m1 "HWNS:" "$OUT/pic_sdram_audio_final_seed$s.timing" | sed -n 's/.*HWNS: *\(-\?[0-9.]*\)ns.*/\1/p')
    echo "SEED $s : SWNS=$SW HWNS=$HW" >> "$DONE"
    if awk -v a="$SW" 'BEGIN{exit !(a>=0)}' && awk -v a="$HW" 'BEGIN{exit !(a>=0)}'; then
      echo "$s SWNS=$SW HWNS=$HW" > "$OUT/sweep3_pass.txt"
      echo "SEED $s : PASS" >> "$DONE"
      return 0
    fi
  done
}

worker 1 31 19 21 25 &
worker 2 29 35 23 33 &
worker 3 37 39 41 43 &
worker 4 17 13 11 15 &
wait
echo "ALL WORKERS DONE" >> "$DONE"
if [ -s "$OUT/sweep3_pass.txt" ]; then cat "$OUT/sweep3_pass.txt"; else echo "NO_PASS"; fi
