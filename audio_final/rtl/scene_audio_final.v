`timescale 1ns/1ps
// DDS scene cues plus an ON-CHIP SYNTHESIZED air-raid siren for the emergency
// scene: a continuous triangle frequency sweep 400 <-> 1000 Hz (1.5 s up,
// 1.5 s down) whose timbre is 4:2:1 on the 1st/2nd/3rd harmonic, i.e. the
// rich, brassy "wu-wu" wail of a real siren -- not a soft pure tone.
//   - no audio file, no BRAM, no host-specific INIT_FILE path
//   - identical waveform to siren_preview_400-1000Hz.wav (same sine table,
//     same harmonic mix, same volume_scale): PC preview == what the board plays
module scene_audio_final #(
    parameter integer CLOCK_HZ=25000000,SAMPLE_HZ=48000,
    parameter integer BLIP_SAMPLES=4800,NOTE_SAMPLES=12000,
    parameter integer RAMP_SAMPLES=256,VOLUME=224,
    // 32-bit phase increment per 48 kHz tick = round(f * 2^32 / 48000):
    //   400 Hz -> 35791394, 1000 Hz -> 89478485
    // sweep step = (89478485-35791394) / (1.5 s * 48000) = 745.65 -> 746
    parameter integer SIREN_INC_LOW=35791394,SIREN_INC_HIGH=89478485,
    parameter integer SIREN_INC_STEP=746
)(
    input wire clk,rst_n,event_valid,menu_active,emergency,
    input wire [1:0] active_scene,
    input wire [1:0] event_kind,media_id,
    output wire sample_valid,input wire sample_ready,
    output wire signed [15:0] sample_left,sample_right,
    output wire [8:0] sample_gain,
    output reg overflow,output wire [2:0] state_debug,
    output reg [31:0] sample_count
);
    localparam [2:0] IDLE=0,BLIP=1,MELODY=2,ALARM=3;
    localparam [31:0] PH_BLIP=134217728,PH_A4=39370534,PH_C5=46819617,
        PH_D5=52553399,PH_E5=58988691,PH_G5=70150238,PH_A5=78741067,
        PH_C6=93639235;
    reg [2:0] state; reg [1:0] scene_q; reg [2:0] note_index;
    reg repeat_index,with_melody; reg [15:0] age; reg [31:0] rate_acc,phase;
    reg signed [15:0] sine_q; reg pending,transition; reg [2:0] pending_state;
    reg [1:0] pending_scene; reg pending_melody; reg [8:0] fade_gain;
    reg emergency_d,menu_d; reg [24:0] fifo[0:31]; reg [4:0] wp,rp;
    reg [5:0] count; wire tick=rate_acc>=CLOCK_HZ-SAMPLE_HZ;
    wire pop=sample_valid&&sample_ready; wire push=tick&&(count<32||pop);
    assign sample_valid=count!=0; assign sample_left=$signed(fifo[rp][15:0]);
    assign sample_right=sample_left; assign sample_gain=fifo[rp][24:16];
    assign state_debug=state;
    `include "../rtl/audio_sine_init.vh"
    always @(posedge clk) sine_q<=audio_sine(phase[31:24]);
    //---- on-chip siren: phase/phase2/phase3 (1x/2x/3x) advance once per
    //     48 kHz tick while in ALARM; siren_inc ramps low->high->low (triangle)
    //     so the tone wails. freq = siren_inc * 48000 / 2^32.
    //     out = 4*s1 + 2*s2 + s3 (18-bit signed): peak ~22676, i.e. the same
    //     loudness the preview WAV has, with 2nd/3rd harmonics at -6 dB/-12 dB
    //     for the brassy, unmistakable siren timbre.
    //     All three phases run off the same increment and are mixed with
    //     shifts and adds only, so no DSP block is used.
    reg [31:0] siren_inc;reg siren_rising;reg [31:0] phase2,phase3;
    reg signed [15:0] sine2_q,sine3_q;
    always @(posedge clk) begin
      sine2_q<=audio_sine(phase2[31:24]);
      sine3_q<=audio_sine(phase3[31:24]);
    end
    wire [32:0] siren_inc2={siren_inc,1'b0};                                   //2*siren_inc
    wire [32:0] siren_inc3={1'b0,siren_inc}+{siren_inc,1'b0};                  //3*siren_inc
    //     NOTE: each harmonic MUST stay inside its own parentheses -- Verilog
    //     gives "+" higher precedence than "<<<", so an unparenthesised
    //     "a<<<2 + b" would parse as "a <<< (2+b)" and shift everything away.
    wire signed [18:0] siren_out=({{3{sine_q[15]}},sine_q}<<<2)                //4*s1
                                +({{3{sine2_q[15]}},sine2_q}<<<1)              //2*s2
                                + {{3{sine3_q[15]}},sine3_q};                  //1*s3
    function [31:0] note_phase; input [1:0] scene;input [2:0] note;
    begin case({scene,note})
      5'b00_000:note_phase=PH_C5;5'b00_001:note_phase=PH_E5;
      5'b00_010:note_phase=PH_G5;5'b00_011:note_phase=PH_C6;
      5'b00_100:note_phase=PH_G5;5'b00_101:note_phase=PH_E5;
      5'b01_000:note_phase=PH_A4;5'b01_001:note_phase=PH_C5;
      5'b01_010:note_phase=PH_E5;5'b01_011:note_phase=PH_A5;
      5'b01_100:note_phase=PH_E5;5'b01_101:note_phase=PH_C5;
      5'b10_000:note_phase=PH_C5;5'b10_001:note_phase=PH_D5;
      5'b10_010:note_phase=PH_E5;5'b10_011:note_phase=PH_G5;
      5'b10_100:note_phase=PH_A5;5'b10_101:note_phase=PH_C6;
      default:note_phase=PH_C5; endcase end endfunction
    wire [31:0] increment=state==ALARM?siren_inc:
                             (state==BLIP?PH_BLIP:note_phase(scene_q,note_index));
    wire [15:0] duration=state==BLIP?BLIP_SAMPLES:NOTE_SAMPLES;

    reg [15:0] envelope;
    always @(*) begin
      envelope=RAMP_SAMPLES;
      if(age<RAMP_SAMPLES) envelope=age+1'b1;
      if(state!=ALARM && duration-age<envelope) envelope=duration-age;
      if(state==IDLE) envelope=0;
    end
    wire [8:0] gain=transition?fade_gain:envelope[8:0];
    function signed [15:0] volume_scale; input signed [18:0] value;
      reg signed [27:0] total,term;integer b;begin total=0;term=value;
      for(b=0;b<9;b=b+1) begin if((VOLUME>>b)&1) total=total+term;term=term<<<1;end
      volume_scale=total>>>8;end endfunction
    wire signed [18:0] full_raw=state==IDLE?19'sd0:
      state==ALARM?siren_out:(state==MELODY?(sine_q<<<1):(sine_q<<<2));
    wire signed [15:0] raw=volume_scale(full_raw);

    always @(posedge clk or negedge rst_n) begin
      if(!rst_n) begin
        state<=IDLE;scene_q<=0;note_index<=0;repeat_index<=0;with_melody<=0;age<=0;rate_acc<=0;phase<=0;
        pending<=0;transition<=0;pending_state<=IDLE;pending_scene<=0;pending_melody<=0;fade_gain<=0;
        emergency_d<=0;menu_d<=1;wp<=0;rp<=0;count<=0;overflow<=0;sample_count<=0;
        siren_inc<=SIREN_INC_LOW;siren_rising<=1'b1;phase2<=0;phase3<=0;
      end else begin
        emergency_d<=emergency;menu_d<=menu_active;
        if(tick) begin
          rate_acc<=rate_acc+SAMPLE_HZ-CLOCK_HZ;sample_count<=sample_count+1'b1;phase<=phase+increment;if(!push)overflow<=1;
          phase2<=state==ALARM?phase2+siren_inc2[31:0]:32'd0;
          phase3<=state==ALARM?phase3+siren_inc3[31:0]:32'd0;
          if(pending) begin
            if(!transition&&gain!=0)begin transition<=1;fade_gain<=gain-1'b1;end
            else if(transition&&fade_gain!=0)fade_gain<=fade_gain-1'b1;
            else begin state<=pending_state;scene_q<=pending_scene;with_melody<=pending_melody;pending<=0;transition<=0;
              age<=0;phase<=0;note_index<=0;repeat_index<=0;
              if(pending_state==ALARM)begin siren_inc<=SIREN_INC_LOW;siren_rising<=1'b1;phase2<=0;phase3<=0;end
            end
          end else if(state==ALARM) begin
            if(age<RAMP_SAMPLES) age<=age+1'b1;
            // triangle frequency sweep: siren_inc ramps low -> high -> low, so
            // the tone wails up in 1.5 s and back down in 1.5 s (3 s per cycle).
            // A constant step per tick needs no multiplier, so no extra DSP
            // block is used.
            if(siren_rising) begin
              if(siren_inc>=SIREN_INC_HIGH-SIREN_INC_STEP) begin
                siren_inc<=SIREN_INC_HIGH;siren_rising<=1'b0;
              end else siren_inc<=siren_inc+SIREN_INC_STEP;
            end else begin
              if(siren_inc<=SIREN_INC_LOW+SIREN_INC_STEP) begin
                siren_inc<=SIREN_INC_LOW;siren_rising<=1'b1;
              end else siren_inc<=siren_inc-SIREN_INC_STEP;
            end
          end else if(state!=IDLE) begin
            if(age==duration-1'b1) begin age<=0;
              if(state==BLIP)state<=with_melody?MELODY:IDLE;
              else if(note_index==5)begin note_index<=0;if(repeat_index)state<=IDLE;else repeat_index<=1;end
              else note_index<=note_index+1'b1;
            end else age<=age+1'b1;
          end
        end else rate_acc<=rate_acc+SAMPLE_HZ;
        if(emergency&&!emergency_d)begin pending<=1;pending_state<=ALARM;pending_scene<=3;pending_melody<=0;end
        else if(!emergency&&emergency_d)begin pending<=1;pending_state<=IDLE;pending_melody<=0;end
        else if(!emergency&&menu_active&&!menu_d)begin pending<=1;pending_state<=IDLE;pending_melody<=0;end
        else if(!emergency&&!menu_active&&menu_d&&active_scene==0)begin
          pending<=1;pending_state<=BLIP;pending_scene<=0;pending_melody<=1;
        end
        else if(event_valid&&!emergency)begin pending<=1;pending_state<=menu_active||event_kind==0?IDLE:BLIP;
          pending_scene<=media_id;pending_melody<=event_kind==2&&!menu_active;end
        if(push)begin fifo[wp]<={gain,raw};wp<=wp+1'b1;end if(pop)rp<=rp+1'b1;
        case({push,pop})2'b10:count<=count+1'b1;2'b01:count<=count-1'b1;default:count<=count;endcase
      end
    end
endmodule

