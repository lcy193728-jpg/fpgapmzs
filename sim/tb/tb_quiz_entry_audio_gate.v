`timescale 1ns/1ps

// 菜单→抢答跨域竞态专项：menu 已离开而 scene_id 仍短暂为 0 时，
// welcome_active 始终为 0，因此不得误触发迎新音乐；倒计时 3 秒事件仍保留。
module tb_quiz_entry_audio_gate;
    reg clk=0, rst_n=0;
    always #5 clk=~clk;

    reg menu_active=1, emergency=0, welcome_active=0;
    reg [1:0] scene_id=0, q_state=0;
    reg [3:0] q_t_tens=0, q_t_ones=0;
    wire event_valid;
    wire [1:0] event_kind,event_media;
    wire sample_valid;
    wire signed [15:0] sample_left,sample_right;
    wire [8:0] sample_gain;
    wire [2:0] audio_state;

    audio_feature_events #(.CLOCK_HZ(100)) dut_evt(
        .clk(clk),.rst_n(rst_n),.menu_active(menu_active),.emergency(emergency),
        .welcome_active(welcome_active),.scene_id(scene_id),.q_state(q_state),
        .q_t_tens(q_t_tens),.q_t_ones(q_t_ones),
        .meeting_warn_event(1'b0),.meeting_timeout_event(1'b0),
        .event_valid(event_valid),.event_kind(event_kind),.event_media(event_media));

    scene_audio_final #(
        .CLOCK_HZ(100),.SAMPLE_HZ(10),.BLIP_SAMPLES(8),.NOTE_SAMPLES(12),
        .RAMP_SAMPLES(2)
    ) dut_audio(
        .clk(clk),.rst_n(rst_n),.event_valid(event_valid),
        .menu_active(menu_active),.emergency(emergency),
        .welcome_active(welcome_active),.active_scene(scene_id),
        .event_kind(event_kind),.media_id(event_media),
        .sample_valid(sample_valid),.sample_ready(1'b1),
        .sample_left(sample_left),.sample_right(sample_right),
        .sample_gain(sample_gain),.overflow(),.state_debug(audio_state),.sample_count());

    integer unexpected=0;
    reg allow_event=0;
    always @(posedge clk)
        if(rst_n && event_valid && !allow_event) unexpected=unexpected+1;

    integer seen;
    initial begin
        repeat(4) @(posedge clk); rst_n=1;
        repeat(6) @(posedge clk);

        // 模拟两路同步先后不一致的非法中间态：已离开菜单，但 scene 仍为 0。
        menu_active=0;
        repeat(6) @(posedge clk);
        scene_id=2;
        repeat(12) @(posedge clk);
        if(unexpected!=0 || audio_state!=0 || dut_audio.pending!=0)begin
            $display("[FAIL] quiz entry leaked welcome audio events=%0d state=%0d pending=%0d",
                     unexpected,audio_state,dut_audio.pending);
            $finish;
        end

        // 正常抢答倒计时末段仍应在 3 秒产生提示事件。
        q_state=1; q_t_ones=4;
        repeat(8) @(posedge clk);
        allow_event=1; q_t_ones=3; seen=0;
        repeat(12)begin
            @(posedge clk);
            if(event_valid && event_kind==1 && event_media==2)seen=1;
        end
        if(!seen)begin
            $display("[FAIL] countdown cue was removed");
            $finish;
        end
        $display("[PASS] quiz entry stays silent; countdown cue remains event-driven");
        $finish;
    end
endmodule
