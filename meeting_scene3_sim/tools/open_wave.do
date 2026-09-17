view wave
if {![info exists env(MEETING_TOP)]} {set env(MEETING_TOP) tb_meeting_scene3}
set top /$env(MEETING_TOP)
foreach signal {rst key_raw state current remaining overtime alarm alarm_paused config_ready warn_event timeout_event buzzer pcm_l} {catch {add wave -radix unsigned $top/$signal}}
if {$env(MEETING_TOP) eq "tb_meeting_io"} {
 foreach signal {start init_done read addr cfg_valid cfg_last busy done alarm warn_event timeout_event tone sample_valid pcm_l} {catch {add wave -radix unsigned $top/$signal}}
}
if {$env(MEETING_TOP) eq "tb_meeting_display"} {
 foreach signal {ready notice_sel vs_i dut/frames dut/phase} {catch {add wave -radix unsigned $top/$signal}}
}
configure wave -namecolwidth 240 -valuecolwidth 90
configure wave -timelineunits us
wave zoom full
update
if {[info exists env(MEETING_READY)]} {
 set ready_handle [open $env(MEETING_READY) w]
 puts $ready_handle ready
 close $ready_handle
}
vwait meeting_keep_open
