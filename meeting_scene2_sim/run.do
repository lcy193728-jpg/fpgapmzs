# ============================================================
# run.do —— meeting_scene_sim 编译 + 仿真脚本 (ModelSim)
# 用法：ModelSim 里  do run.do   （会自动编译、加载、显示波形并运行）
# ============================================================
cd [file dirname [info script]]

vlib work
vlog -work work \
    rtl/scene_selector.v \
    rtl/scroll_text_ctrl.v \
    rtl/fade_transition_ctrl.v \
    rtl/brightness_adjust.v \
    rtl/contrast_adjust.v \
    rtl/meeting_osd_overlay.v \
    rtl/meeting_page_ctrl.v \
    rtl/meeting_scene_top.v \
    tb/tb_meeting_scene.v

vsim work.tb_meeting_scene
add wave -r /*
run -all