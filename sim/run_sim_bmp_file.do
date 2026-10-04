#====================================================================
# ModelSim 仿真脚本：bmp_read_auto FAT32 化(file 接口)专项测试
# 用法：批处理: vsim -c -do "do run_sim_bmp_file.do; quit -f"
# 说明：纯 RTL 单元测试, 无 BRAM 原语依赖。
#   验证 file 接口下的簇号锁存/读文件头/像素拼装/切图/坏图跳过。
#====================================================================

# 0. 清旧库
if {[file exists work]} { file delete -force work }

# 1. 建立工作库
vlib work
vmap work work

# 2. 编译源文件
vlog ../src/bmp_read_auto.v
vlog ../tb/tb_bmp_read_auto_file.v

# 3. 启动仿真
vsim -t 1ps work.tb_bmp_read_auto_file

# 4. 运行仿真
run -all

# 5. 批处理模式直接退出
if {[batch_mode]} {
    quit -f
}
