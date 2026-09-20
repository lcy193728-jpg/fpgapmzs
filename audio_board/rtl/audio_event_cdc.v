`timescale 1ns/1ps
// Event mailbox: payload held until request is acknowledged. Newest event wins
// in the pending slot; mechanical events are much slower than the round trip.
module audio_event_cdc #(
    parameter integer CONTROL_HZ=100000000
)(
    input wire control_clk,control_rst_n,pixel_clk,pixel_rst_n,
    input wire key_next,key_prev,scene_change,menu_active,emergency,
    input wire [1:0] scene_id,
    input wire [7:0] img_no,
    input wire img_busy,pic_manual,reload_req,
    input wire [3:0] bmp_error,
    output reg event_valid,
    output reg [1:0] event_kind,media_id,
    output wire menu_pixel,emergency_pixel,
    output wire [1:0] scene_pixel,
    output reg event_overrun
);
    reg busy_d;
    reg [7:0] completed_image;
    reg [25:0] suppress_count;
    reg load_owned,reload_pending;
    reg request_toggle,ack_toggle;
    reg [3:0] payload_hold,pending_payload;
    reg pending_valid;
    wire request_pixel,ack_control;
    audio_event_sync u_req(.clk(pixel_clk),.rst_n(pixel_rst_n),.d(request_toggle),.q(request_pixel));
    audio_event_sync u_ack(.clk(control_clk),.rst_n(control_rst_n),.d(ack_toggle),.q(ack_control));
    audio_event_sync u_menu(.clk(pixel_clk),.rst_n(pixel_rst_n),.d(menu_active),.q(menu_pixel));
    audio_event_sync u_alarm(.clk(pixel_clk),.rst_n(pixel_rst_n),.d(emergency),.q(emergency_pixel));
    audio_event_sync u_scene0(.clk(pixel_clk),.rst_n(pixel_rst_n),.d(scene_id[0]),.q(scene_pixel[0]));
    audio_event_sync u_scene1(.clk(pixel_clk),.rst_n(pixel_rst_n),.d(scene_id[1]),.q(scene_pixel[1]));
    wire load_done=busy_d && !img_busy && img_no!=0 && bmp_error==0;
    wire manual_event=(key_next || key_prev) && !menu_active && !emergency;
    // 0=cancel/menu, 1=blip only, 2=blip plus melody.
    wire automatic_event=load_done && !load_owned && !pic_manual &&
                         suppress_count==0 && !(reload_pending && img_no==completed_image) &&
                         !menu_active && !emergency;
    wire send_event=scene_change || manual_event || automatic_event;
    wire [1:0] kind=menu_active ? 2'd0 : (scene_change || manual_event ? 2'd2 : 2'd1);
    wire [3:0] event_payload={scene_id,kind};
    always @(posedge control_clk or negedge control_rst_n) begin
        if(!control_rst_n) begin
            busy_d<=1;completed_image<=0;suppress_count<=0;load_owned<=0;reload_pending<=0;
            request_toggle<=0;payload_hold<=0;pending_payload<=0;
            pending_valid<=0;event_overrun<=0;
        end else begin
            busy_d<=img_busy;
            if(suppress_count!=0) suppress_count<=suppress_count-1'b1;
            if(load_done) begin
                completed_image<=img_no;load_owned<=0;
                if(img_no==completed_image) reload_pending<=0;
            end
            // A parameter-driven reload is not an automatic slideshow step.
            // Keep a queued reload pending across completion of the current image.
            if(reload_req) reload_pending<=1;
            // Remember ownership until completion even if loading takes >500ms.
            if(scene_change || manual_event) begin
                suppress_count<=CONTROL_HZ/2;load_owned<=1;
            end
            if(request_toggle==ack_control) begin
                if(send_event) begin
                    payload_hold<=event_payload;request_toggle<=~request_toggle;
                    if(pending_valid) event_overrun<=1;
                    pending_valid<=0;
                end else if(pending_valid) begin
                    payload_hold<=pending_payload;request_toggle<=~request_toggle;
                    pending_valid<=0;
                end
            end else if(send_event) begin
                if(pending_valid) event_overrun<=1;
                pending_payload<=event_payload;pending_valid<=1;
            end
        end
    end
    reg capture_wait;
    always @(posedge pixel_clk or negedge pixel_rst_n) begin
        if(!pixel_rst_n) begin
            ack_toggle<=0;capture_wait<=0;event_valid<=0;
            event_kind<=0;media_id<=0;
        end else begin
            event_valid<=0;
            if(capture_wait) begin
                ack_toggle<=request_pixel;capture_wait<=0;
            end else if(request_pixel!=ack_toggle) capture_wait<=1;
            // Payload has been held for two synchronizer cycles plus one wait cycle.
            if(capture_wait) begin
                media_id<=payload_hold[3:2];event_kind<=payload_hold[1:0];
                event_valid<=1;
            end
        end
    end
endmodule
module audio_event_sync(input wire clk,rst_n,d,output wire q);
    reg [1:0] sync_ff;
    always @(posedge clk or negedge rst_n)
        if(!rst_n) sync_ff<=0;else sync_ff<={sync_ff[0],d};
    assign q=sync_ff[1];
endmodule
