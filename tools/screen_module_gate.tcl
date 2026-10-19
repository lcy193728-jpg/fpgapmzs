# Module-level area screen.  The caller supplies MODULE_TOP and MODULE_TAG.
# No project or release artifact is overwritten.
if {![info exists ::env(MODULE_TOP)] || ![info exists ::env(MODULE_TAG)]} {
    error "MODULE_TOP and MODULE_TAG are required"
}

set root E:/FPGA/ALST/_dev_sim_0b18789
set top  $::env(MODULE_TOP)
set tag  $::env(MODULE_TAG)
set out  $root/_module_screen/$tag
file mkdir $out

# emergency_big_font_rom uses a project-relative ../../src init path.  A
# module-only build is two levels deeper than the normal run directory, so
# mirror only the five immutable initialization files into the equivalent
# sandbox path.  This does not touch design sources or release artifacts.
set mirror $root/_module_screen/src
file mkdir $mirror
foreach bank {0 1 2 3 4} {
    file copy -force $root/src/emergency_big_font_bank${bank}.dat $mirror/
}

cd $root
import_device eagle_s20.db -package EG4S20BG256
open_project $root/pic_sdram_audio_final.al -single_run
load_run_param -run syn_1

cd $out
elaborate -top $top
optimize_rtl
optimize_gate $out/gate.area
report_qor -step gate -file $out/gate.qor
report_area -io_info -file $out/final.area

puts "MODULE_SCREEN_DONE top=$top tag=$tag"
exit
