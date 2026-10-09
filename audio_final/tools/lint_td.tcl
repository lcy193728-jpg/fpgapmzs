#====================================================================
# lint_td.tcl —— 只做 analyze + elaborate 的快速语法/连线检查(v11)
#
# 为什么需要它:
#   TD 的 `elaborate` 会抓出所有"例化端口对不上"(HDL-8007)之类的问题。
#   而 build_td.tcl 一旦在中途报错, 脚本会中止在报错处、走不到文件末尾的
#   `exit`, 于是 td_commands_prompt.exe 不退出进程, 上层 PowerShell
#   `& $taskExe` 会永久阻塞(实测挂 10 分钟以上)。
#   故本脚本全程用 catch 包住 + **无条件 exit**, 永远快速返回, 只当"编译探针"。
#
# 用法(路径必须正斜杠):
#   E:/FPGA/TD/bin/td_commands_prompt.exe <本脚本的绝对路径, 正斜杠>
# 成功判据: 输出里有 LINT_V11_ELABORATE_OK 且没有 HDL-8007 ERROR
#====================================================================
set board_dir [file normalize [file join [file dirname [info script]] ..]]
set prj [file join $board_dir .. pic_sdram_audio_final.al]
set adc [file join $board_dir .. top.adc]
set sdc [file join $board_dir .. audio_board integrated audio.sdc]
set out [file join $board_dir _lint_v11]
file mkdir $out

if {[catch {
    cd [file dirname $prj]
    import_device eagle_s20.db -package EG4S20BG256
    open_project $prj -single_run
    load_run_param -run syn_1
    cd $out
    elaborate -top top
    read_adc $adc
    read_sdc $sdc
    puts "LINT_V11_ELABORATE_OK"
} err]} {
    puts "LINT_V11_FAIL: $err"
}

exit
