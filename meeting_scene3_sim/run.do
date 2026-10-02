onerror {quit -code 2 -force}
onbreak {resume}
if {![file exists work]} {vlib work}
vmap work work
vlog baseline/scene_control.v baseline/seg_scan.v baseline/seg_decoder.v
vlog +incdir+rtl rtl/meeting_glyph_rom.v rtl/meeting_config.v rtl/meeting_keys.v rtl/meeting_ctrl.v rtl/meeting_audio.v rtl/meeting_osd.v rtl/meeting_sd_reader.v rtl/meeting_scene3.v tb/tb_meeting_scene3.v
if {![info exists env(MEETING_RUN)]} {set env(MEETING_RUN) runs/manual}
file mkdir $env(MEETING_RUN)
vsim -wlf $env(MEETING_RUN)/meeting.wlf -voptargs=+acc work.tb_meeting_scene3 +RUN_DIR=$env(MEETING_RUN)
log /tb_meeting_scene3/clk /tb_meeting_scene3/rst /tb_meeting_scene3/key_raw /tb_meeting_scene3/state /tb_meeting_scene3/current /tb_meeting_scene3/remaining /tb_meeting_scene3/overtime /tb_meeting_scene3/alarm /tb_meeting_scene3/alarm_paused /tb_meeting_scene3/config_ready /tb_meeting_scene3/warn_event /tb_meeting_scene3/timeout_event /tb_meeting_scene3/buzzer /tb_meeting_scene3/pcm_l
run -all
set errors [examine -radix decimal /tb_meeting_scene3/errors]
quit -code $errors -force
