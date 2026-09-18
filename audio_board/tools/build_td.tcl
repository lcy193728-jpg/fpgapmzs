# TD command-line build; no simulation and no hardware download.
# Usage: set env(AUDIO_TARGET)=tone|integrated, then invoke td_commands_prompt.
set board_dir [file normalize [file join [file dirname [info script]] ..]]
set target tone
if {[info exists ::env(AUDIO_TARGET)]} { set target $::env(AUDIO_TARGET) }
if {$target eq "tone"} {
    set prj [file join $board_dir standalone hdmi_tone.al]
    set adc [file join $board_dir standalone tone.adc]
    set sdc [file join $board_dir standalone tone.sdc]
    set name hdmi_tone
} elseif {$target eq "integrated"} {
    set prj [file join $board_dir .. pic_sdram_audio.al]
    set adc [file join $board_dir .. top.adc]
    set sdc [file join $board_dir integrated audio.sdc]
    set name pic_sdram_audio
} else { error "AUDIO_TARGET must be tone or integrated" }
set out [file join $board_dir build $target]
file mkdir $out
cd [file dirname $prj]
import_device eagle_s20.db -package EG4S20BG256
open_project $prj -single_run
load_run_param -run syn_1
cd $out
elaborate -top top
read_adc $adc
read_sdc $sdc
optimize_rtl
report_area -file ${name}_rtl.area
optimize_gate ${name}_gate.area
legalize_phy_inst
update_timing
report_timing_status -file ${name}_gate.ts
report_timing_summary -file ${name}_gate.timing
export_db ${name}_gate.db
load_run_param -run phy_1
place
route
update_timing -mode final
report_area -io_info -file ${name}_phy.area
report_timing_status -file ${name}_phy.ts
report_timing_summary -file ${name}_pr.timing
report_timing_exception -file ${name}_exception.timing
bitgen -bit ${name}.bit
puts "AUDIO_BUILD_COMPLETE: [file join $out ${name}.bit]"
