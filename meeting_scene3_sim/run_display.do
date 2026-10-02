onerror {quit -code 2 -force}
onbreak {resume}
if {![file exists work]} {vlib work}
vmap work work
vlog +incdir+rtl rtl/meeting_glyph_rom.v rtl/meeting_config.v rtl/meeting_osd.v tb/tb_meeting_display.v
if {![info exists env(MEETING_RUN)]} {set env(MEETING_RUN) runs/manual_display}
file mkdir $env(MEETING_RUN)
vsim -wlf $env(MEETING_RUN)/meeting.wlf -voptargs=+acc work.tb_meeting_display +RUN_DIR=$env(MEETING_RUN)
log /tb_meeting_display/state /tb_meeting_display/current /tb_meeting_display/remaining /tb_meeting_display/overtime /tb_meeting_display/alarm /tb_meeting_display/alarm_paused /tb_meeting_display/ready /tb_meeting_display/notice_sel /tb_meeting_display/vs_i /tb_meeting_display/dut/frames /tb_meeting_display/dut/phase
run -all
set errors [examine -radix decimal /tb_meeting_display/errors]
quit -code $errors -force
