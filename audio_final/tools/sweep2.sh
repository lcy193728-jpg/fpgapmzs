#!/usr/bin/env bash
# 多分辨率改动后重扫 place seed: 复用 build/pic_sdram_audio_final_gate.db
#   判据: 日志无 PHY-8023/RUN-8102 布线错误, 且 SWNS>=0 且 HWNS>=0
set -u
BD=/e/FPGA/ALST/_dev_sim_0b18789/audio_final
OUT=$BD/build
TCL=E:/FPGA/ALST/_dev_sim_0b18789/audio_final/tools/sweep_place_seed.tcl
EXE=E:/FPGA/TD/bin/td_commands_prompt.exe
GOOD=""
for s in 35 31 19 21 25 29 23 33; do
  echo "===== SEED $s ====="
  rm -f "$OUT/pic_sdram_audio_final_seed$s.timing" "$OUT/pic_sdram_audio_final_seed$s.area"
  TD_PLACE_SEED=$s "$EXE" "$TCL" > "$OUT/sweep2_seed$s.log" 2>&1
  if grep -q "PHY-8023 ERROR\|RUN-8102 ERROR" "$OUT/sweep2_seed$s.log"; then
    echo "SEED $s : ROUTE FAIL"
    continue
  fi
  if ! grep -q "SEED_DONE $s" "$OUT/sweep2_seed$s.log"; then
    echo "SEED $s : NO SEED_DONE (异常退出)"
    continue
  fi
  LINE=$(grep -m1 "SWNS:" "$OUT/pic_sdram_audio_final_seed$s.timing")
  HLINE=$(grep -m1 "HWNS:" "$OUT/pic_sdram_audio_final_seed$s.timing")
  SW=$(echo "$LINE" | sed -n 's/.*SWNS: *\(-\?[0-9.]*\)ns.*/\1/p')
  HW=$(echo "$HLINE" | sed -n 's/.*HWNS: *\(-\?[0-9.]*\)ns.*/\1/p')
  echo "SEED $s : $LINE | $HLINE"
  OKS=$(awk -v a="$SW" 'BEGIN{print (a>=0)?1:0}')
  OKH=$(awk -v a="$HW" 'BEGIN{print (a>=0)?1:0}')
  if [ "$OKS" = "1" ] && [ "$OKH" = "1" ]; then
    echo "SEED $s : PASS  (SWNS=$SW HWNS=$HW)"
    GOOD="$s"
    break
  else
    echo "SEED $s : 时序不达标"
  fi
done
if [ -n "$GOOD" ]; then
  echo "BEST_SEED=$GOOD"
else
  echo "BEST_SEED=NONE"
fi
