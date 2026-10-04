# 对照实验 A —— 历史位流 e32809c (2026-10-02 22:18)
# 目的: 判定"只有图片花"是本次改动引入, 还是卡上素材布局与 Z_* 不匹配
#   · Z_* 与当前完全相同 (Z_MENU/WEL=15936, MEET=8512, QUIZ/ALARM=10368)
#   · 该版本此前图片正常, 唯一已知问题是数码管模式号显示
# SHA-256: a8c0c935775fc1b27ac46d2b742a97cd165fae26278f51015d3319a9ee513823
# 面积/时序: 690152 B, seed=17, SWNS +0.102ns, HWNS +0.020ns, 0 违例
# 用法: bw_commands_prompt.exe E:/FPGA/ALST/_dev_sim_0b18789/_jtag_cmp_e32809c.tcl
download -bit "E:/tmp/bit_e32809c.bit" -mode jtag -spd 7 -sec 64 -cable 0
exit
