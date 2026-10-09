#!/usr/bin/env bash
#====================================================================
# 全量仿真回归（v11）—— 逐个跑 sim/run_sim*.do, 判据 = 计数
#
# 用法:  bash sim/run_regress_all.sh
# 输出:  sim/_regress_v11/<用例>.log(.utf8)  +  summary.txt
#
# 判定纪律（项目硬要求，见 .workbuddy/memory/MEMORY.md §4.7）:
#   ★ 必须用 **计数**（grep -c '[FAIL]' == 0），单关键词 grep 会漏判；
#   ★ 同时检查编译错误（** Error）与超时（rc == 124）——
#     编译失败的用例会掉回 ModelSim 交互提示符挂住, 故必须加 timeout。
#====================================================================
set -u
cd "$(dirname "$0")"

VSIM="D:/Quat/modelsim_ase/win32aloem/vsim.exe"
OUT="_regress_v11"
PER_CASE_TIMEOUT=1200          # 单用例秒数上限（超时判 FAIL 并继续）

mkdir -p "$OUT"
SUM="$OUT/summary.txt"
: > "$SUM"

n_case_pass=0
n_case_fail=0
n_total=0

{
echo "==================== v11 全量仿真回归 ===================="

for do in run_sim*.do; do
    name="${do%.do}"
    raw="$OUT/${name}.log"
    txt="$OUT/${name}.log.utf8"

    rm -rf work
    timeout "$PER_CASE_TIMEOUT" "$VSIM" -c -do "do $do" > "$raw" 2>&1
    rc=$?

    if iconv -f GBK -t UTF-8 "$raw" > "$txt" 2>/dev/null; then :; else cp "$raw" "$txt"; fi

    cnt_fail=$(grep -c '\[FAIL\]' "$txt" 2>/dev/null || true)
    cnt_err=$(grep -c '\*\* Error' "$txt" 2>/dev/null || true)
    to=0; [ "$rc" -eq 124 ] && to=1
    bad=$((cnt_fail + cnt_err + to))

    n_total=$((n_total + 1))
    if [ "$bad" -eq 0 ]; then
        n_case_pass=$((n_case_pass + 1))
        printf '  [PASS] %-22s FAIL=0  Error=0  TMO=0\n' "$name"
    else
        n_case_fail=$((n_case_fail + 1))
        printf '  [FAIL] %-22s FAIL=%s  Error=%s  TMO=%s  (rc=%s)\n' \
               "$name" "$cnt_fail" "$cnt_err" "$to" "$rc"
    fi
done

echo "----------------------------------------------------------"
printf '用例总数=%s   全绿=%s   有问题=%s\n' "$n_total" "$n_case_pass" "$n_case_fail"
echo "=========================================================="
} 2>&1 | tee -a "$SUM"
