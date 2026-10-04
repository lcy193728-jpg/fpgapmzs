#!/bin/bash
MSIM=/d/Quat/modelsim_ase/win32aloem
mkdir -p regress_final
rm -f regress_final/*.log
for dofile in $(ls run_sim*.do | sort); do
  name=$(basename "$dofile" .do)
  ( cd /e/FPGA/ALST/_dev_sim_0b18789/sim && "$MSIM/vsim.exe" -c -do "do $dofile; quit -f" ) > "regress_final/${name}.log" 2>&1
done
echo done
