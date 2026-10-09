#!/usr/bin/env bash
# 并行 place seed 【择优】扫描 —— v11(删会议 + FAT32 寻址层) 新 netlist。
#
#   为什么是"择优"而不是"取首个通过": 本 netlist 在 seed=7 已经达标
#   (SWNS +0.135 / 0 违例), 现在要在**全部达标的种子里挑余量最大的一颗**,
#   故不早退, 跑完再按 SWNS 排序。
#   判据: 无 PHY-8023/RUN-8102 布线错误; 记录每颗种子的 SWNS/HWNS。
#   复用 build/pic_sdram_audio_final_gate.db(不改 RTL)。
#
#   产物统一带 v11 前缀, 避免与仓库里 Oct-3/Oct-4 的 sweep4_*/sweep5_* 遗留混淆。
set -u
BD=/e/FPGA/ALST/_dev_sim_0b18789/audio_final
OUT=$BD/build
TCL=E:/FPGA/ALST/_dev_sim_0b18789/audio_final/tools/sweep_place_seed.tcl
EXE=E:/FPGA/TD/bin/td_commands_prompt.exe
DONE=$OUT/sweep_v11_done.txt
: > "$DONE"

worker() {
  local w=$1; shift
  for s in "$@"; do
    echo "W$w start seed $s" >> "$DONE"
    rm -f "$OUT/pic_sdram_audio_final_seed$s.timing"
    TD_PLACE_SEED=$s "$EXE" "$TCL" > "$OUT/sweep_v11_seed$s.log" 2>&1
    if grep -q "PHY-8023 ERROR\|RUN-8102 ERROR" "$OUT/sweep_v11_seed$s.log"; then
      echo "SEED $s : ROUTE FAIL" >> "$DONE"; continue
    fi
    if ! grep -q "SEED_DONE $s" "$OUT/sweep_v11_seed$s.log"; then
      echo "SEED $s : NO SEED_DONE" >> "$DONE"; continue
    fi
    local SW HW
    SW=$(grep -m1 "SWNS:" "$OUT/pic_sdram_audio_final_seed$s.timing" | sed -n 's/.*SWNS: *\(-\?[0-9.]*\)ns.*/\1/p')
    HW=$(grep -m1 "HWNS:" "$OUT/pic_sdram_audio_final_seed$s.timing" | sed -n 's/.*HWNS: *\(-\?[0-9.]*\)ns.*/\1/p')
    echo "SEED $s : SWNS=$SW HWNS=$HW" >> "$DONE"
  done
}

# 本工程历史命中种子清一色奇数(5/7/11/17/29/31/57) → 只扫奇数; 24 颗 / 6 worker。
worker 1 1 13 25 37 &
worker 2 3 15 27 39 &
worker 3 5 17 29 41 &
worker 4 7 19 31 43 &
worker 5 9 21 33 45 &
worker 6 11 23 35 57 &
wait
echo "ALL WORKERS DONE" >> "$DONE"
echo "==================== 按 SWNS 排序 ===================="
grep '^SEED .*SWNS=' "$DONE" \
  | sed 's/^SEED \([0-9]*\) : SWNS=\([-0-9.]*\) HWNS=\([-0-9.]*\)/\2 \1 \3/' \
  | sort -g -r | awk '{printf "seed %-3s SWNS=%-8s HWNS=%s\n",$2,$1,$3}'
echo "==================== 布线失败/异常 ===================="
grep -v 'SWNS=' "$DONE" | grep -v 'start seed' | grep -v 'ALL WORKERS' || true
