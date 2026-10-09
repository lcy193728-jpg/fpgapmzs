#!/usr/bin/env bash
# 并行 place seed 【择优】扫描 —— iris 中心扩散转场版新 netlist。
#
#   背景: 本版(中心扩散 iris 转场 + 抢答队图 + 整卡重排常量)在 seed=7 下
#   SWNS = -0.009ns (SD 域 sd_card_clk 1 个 setup 违例) → 未过闸门。
#   资源: LUT 14444(73.69%) / slices 7939(81.01%) / BRAM9K 39 —— 均低于历史,
#   但 SD 域最差路径落点( img_cnt -> sd_sec_read_addr )对布局敏感, 属纯布局问题
#   → 按纪律【扫 seed 别动 RTL】。
#
#   判据: 无 PHY-8023/RUN-8102 布线错误; 记录每颗种子的 SWNS/HWNS;
#   择 SWNS 余量最大者。复用 build/pic_sdram_audio_final_gate.db(不改 RTL)。
set -u
BD=/e/FPGA/ALST/_dev_sim_0b18789/audio_final
OUT=$BD/build
TCL=E:/FPGA/ALST/_dev_sim_0b18789/audio_final/tools/sweep_place_seed.tcl
EXE=E:/FPGA/TD/bin/td_commands_prompt.exe
DONE=$OUT/sweep_iris_done.txt
: > "$DONE"

worker() {
  local w=$1; shift
  for s in "$@"; do
    echo "W$w start seed $s" >> "$DONE"
    rm -f "$OUT/pic_sdram_audio_final_seed$s.timing"
    TD_PLACE_SEED=$s "$EXE" "$TCL" > "$OUT/sweep_iris_seed$s.log" 2>&1
    if grep -q "PHY-8023 ERROR\|RUN-8102 ERROR" "$OUT/sweep_iris_seed$s.log"; then
      echo "SEED $s : ROUTE FAIL" >> "$DONE"; continue
    fi
    if ! grep -q "SEED_DONE $s" "$OUT/sweep_iris_seed$s.log"; then
      echo "SEED $s : NO SEED_DONE" >> "$DONE"; continue
    fi
    local SW HW
    SW=$(grep -m1 "SWNS:" "$OUT/pic_sdram_audio_final_seed$s.timing" | sed -n 's/.*SWNS: *\(-\?[0-9.]*\)ns.*/\1/p')
    HW=$(grep -m1 "HWNS:" "$OUT/pic_sdram_audio_final_seed$s.timing" | sed -n 's/.*HWNS: *\(-\?[0-9.]*\)ns.*/\1/p')
    echo "SEED $s : SWNS=$SW HWNS=$HW" >> "$DONE"
  done
}

# 历史命中种子清一色奇数 → 只扫奇数; 60 颗 / 12 worker (24 核)。
worker  1  1 25 49 73 97 &
worker  2  3 27 51 75 99 &
worker  3  5 29 53 77 101 &
worker  4  7 31 55 79 103 &
worker  5  9 33 57 81 105 &
worker  6 11 35 59 83 107 &
worker  7 13 37 61 85 109 &
worker  8 15 39 63 87 111 &
worker  9 17 41 65 89 113 &
worker 10 19 43 67 91 115 &
worker 11 21 45 69 93 117 &
worker 12 23 47 71 95 119 &
wait
echo "ALL WORKERS DONE" >> "$DONE"
echo "==================== 按 SWNS 排序 ===================="
grep '^SEED .*SWNS=' "$DONE" \
  | sed 's/^SEED \([0-9]*\) : SWNS=\([-0-9.]*\) HWNS=\([-0-9.]*\)/\2 \1 \3/' \
  | sort -g -r | awk '{printf "seed %-3s SWNS=%-8s HWNS=%s\n",$2,$1,$3}'
echo "==================== 布线失败/异常 ===================="
grep -v 'SWNS=' "$DONE" | grep -v 'start seed' | grep -v 'ALL WORKERS' || true
