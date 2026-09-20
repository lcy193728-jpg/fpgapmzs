// Public HDMI bottom layer reused unchanged; document (2) scene-linked sources.
localparam integer AUDIO_TEST_PROFILE=0;
wire audio_rst_n_ser;
reset_sync u_audio_serial_reset(.clk(hdmi_5x_clk),.rst_n_async(ext_rst_n),.rst_n_sync(audio_rst_n_ser));
wire audio_pcm_valid,audio_pcm_ready;
wire signed [15:0] audio_left,audio_right;
wire audio_tone_overflow,audio_media_overflow,audio_event_overrun;
wire audio_timing_locked,audio_timing_error,audio_sequence_error,audio_contract_error;
wire [31:0] audio_generated_samples,audio_media_samples,audio_accepted_samples,audio_mux_pairs;
wire [6:0] audio_fifo_level;
wire audio_event_valid,audio_menu,audio_emergency;
wire [1:0] audio_event_kind,audio_media_id,audio_scene_level;
wire test_valid,test_ready,media_valid,media_ready;
wire signed [15:0] test_left,test_right,media_left,media_right;
wire [8:0] media_gain;
wire [2:0] audio_media_state;
audio_event_cdc u_audio_events(
    .control_clk(sd_card_clk),.control_rst_n(rst_n_sd),.pixel_clk(video_clk),.pixel_rst_n(rst_n_vid),
    .key_next(key_next_pl),.key_prev(key_prev_pl),.scene_change(scene_change_pulse),
    .menu_active(menu_active),.emergency(emergency),.scene_id(scene_id),
    .img_no(img_no),.img_busy(img_busy),.pic_manual(pic_manual),.reload_req(res_chg_pl),.bmp_error(bmp_error),
    .event_valid(audio_event_valid),.event_kind(audio_event_kind),.media_id(audio_media_id),
    .menu_pixel(audio_menu),.emergency_pixel(audio_emergency),.scene_pixel(audio_scene_level),
    .event_overrun(audio_event_overrun));
audio_pcm_tone #(.PROFILE(AUDIO_TEST_PROFILE)) u_audio_test_source(
    .clk(video_clk),.rst_n(rst_n_vid),.enable(1'b1),
    .sample_valid(test_valid),.sample_ready(test_ready),.sample_left(test_left),.sample_right(test_right),
    .overflow(audio_tone_overflow),.sample_count(audio_generated_samples));
pcm_media_tone u_audio_media_source(
    .clk(video_clk),.rst_n(rst_n_vid),.event_valid(audio_event_valid),
    .event_kind(audio_event_kind),.media_id(audio_media_id),.resume_media_id(audio_scene_level),
    .menu_active(audio_menu),.emergency(audio_emergency),
    .sample_valid(media_valid),.sample_ready(media_ready),.sample_left(media_left),.sample_right(media_right),
    .sample_gain(media_gain),.overflow(audio_media_overflow),.state_debug(audio_media_state),
    .sample_count(audio_media_samples));
audio_src_mux u_audio_mux(
    .clk(video_clk),.rst_n(rst_n_vid),.test_valid(test_valid),.media_valid(media_valid),
    .test_ready(test_ready),.media_ready(media_ready),.test_left(test_left),.test_right(test_right),
    .media_left(media_left),.media_right(media_right),.media_gain(media_gain),
    .sample_valid(audio_pcm_valid),.sample_ready(audio_pcm_ready),.sample_left(audio_left),.sample_right(audio_right),
    .accepted_pairs(audio_mux_pairs));
audio_hdmi_output u_audio_hdmi(
    .pixel_clk(video_clk),.serial_clk(hdmi_5x_clk),.pixel_rst_n(rst_n_vid),.serial_rst_n(audio_rst_n_ser),
    .hs(fin_hs),.vs(fin_vs),.de(fin_de),.rgb(fin_data),
    .pcm_valid(audio_pcm_valid),.pcm_ready(audio_pcm_ready),.pcm_left(audio_left),.pcm_right(audio_right),
    .HDMI_CLK_P(HDMI_CLK_P),.HDMI_D0_P(HDMI_D0_P),.HDMI_D1_P(HDMI_D1_P),.HDMI_D2_P(HDMI_D2_P),
    .timing_locked(audio_timing_locked),.timing_error(audio_timing_error),
    .sequence_error(audio_sequence_error),.pcm_contract_error(audio_contract_error),
    .fifo_level(audio_fifo_level),.accepted_samples(audio_accepted_samples));
