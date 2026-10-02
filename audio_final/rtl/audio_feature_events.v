`timescale 1ns/1ps
// Meeting reminders come directly from meeting_ctrl, so HDMI audio follows the
// actual agenda countdown (including pause/resume and re-timing).
module audio_feature_events #(
    parameter integer CLOCK_HZ=25000000
)(
    input wire clk,rst_n,
    input wire menu_active,emergency,
    input wire [1:0] scene_id,q_state,
    input wire [3:0] q_t_tens,q_t_ones,
    input wire meeting_warn_event,meeting_timeout_event,
    output reg event_valid,
    output reg [1:0] event_kind,event_media
);
    reg menu0,menu1,em0,em1;
    reg [1:0] sc0,sc1,qs0,qs1;
    reg [3:0] qt0a,qt0b,qt1a,qt1b;
    reg [1:0] sc_d,qs_d; reg menu_d;
    reg [7:0] qsec_d;
    reg [31:0] repeat_delay;
    reg repeat_pending;
    wire [7:0] qsec={qt1a,qt1b};
    wire enter_welcome=!menu1 && !em1 && sc1==2'd0 && (menu_d || sc_d!=2'd0);
    wire in_meeting=!menu1 && !em1 && sc1==2'd1;
    wire in_quiz=!menu1 && !em1 && sc1==2'd2;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            menu0<=1;menu1<=1;em0<=0;em1<=0;sc0<=0;sc1<=0;qs0<=0;qs1<=0;
            qt0a<=0;qt0b<=0;qt1a<=0;qt1b<=0;sc_d<=0;qs_d<=0;qsec_d<=0;menu_d<=1;
            repeat_delay<=0;repeat_pending<=0;
            event_valid<=0;event_kind<=0;event_media<=0;
        end else begin
            menu0<=menu_active;menu1<=menu0;em0<=emergency;em1<=em0;
            sc0<=scene_id;sc1<=sc0;qs0<=q_state;qs1<=qs0;
            qt0a<=q_t_tens;qt0b<=q_t_ones;qt1a<=qt0a;qt1b<=qt0b;
            sc_d<=sc1;qs_d<=qs1;qsec_d<=qsec;menu_d<=menu1;event_valid<=0;
            if(in_meeting && meeting_warn_event) begin
                event_valid<=1;event_kind<=1;event_media<=1;
            end else if(in_meeting && meeting_timeout_event) begin
                event_valid<=1;event_kind<=1;event_media<=1;
                repeat_pending<=1;repeat_delay<=CLOCK_HZ/5; // timeout = two short tones
            end

            if(repeat_pending) begin
                if(repeat_delay==0) begin
                    event_valid<=1;event_kind<=1;event_media<=1;repeat_pending<=0;
                end else repeat_delay<=repeat_delay-1'b1;
            end

            if(enter_welcome) begin
                event_valid<=1;event_kind<=2;event_media<=0;
            end else if(in_quiz) begin
                if(qs1==2 && qs_d!=2) begin
                    event_valid<=1;event_kind<=2;event_media<=2; // success motif
                end else if(qs1==3 && qs_d!=3) begin
                    event_valid<=1;event_kind<=1;event_media<=2;
                    repeat_pending<=1;repeat_delay<=CLOCK_HZ/5;
                end else if(qs1==1 && qsec!=qsec_d &&
                            (qsec==8'h03 || qsec==8'h02 || qsec==8'h01)) begin
                    event_valid<=1;event_kind<=1;event_media<=2;
                end
            end
            if(menu1 || em1) repeat_pending<=0;
        end
    end
endmodule
