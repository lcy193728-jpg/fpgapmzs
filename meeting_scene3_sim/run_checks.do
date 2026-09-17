onerror {quit -code 2 -force}
onbreak {resume}
if {![file exists work]} {vlib work}
vmap work work
vlog rtl/meeting_ctrl.v rtl/meeting_audio.v rtl/meeting_sd_reader.v tb/tb_meeting_edges.v tb/tb_meeting_io.v
if {![info exists env(MEETING_RUN)]} {set env(MEETING_RUN) runs/manual_checks}
if {![info exists env(MEETING_TB)]} {set env(MEETING_TB) tb_meeting_edges}
file mkdir $env(MEETING_RUN)
vsim -wlf $env(MEETING_RUN)/meeting.wlf -voptargs=+acc work.$env(MEETING_TB)
log -r /*
run -all
set errors [examine -radix decimal /$env(MEETING_TB)/errors]
quit -code $errors -force
