`timescale 1ns/1ps
`include "alarm_init_path.vh"
// DDS scene cues plus a real seven-second siren recording stored as 4 kHz
// IMA-ADPCM. It is decoded in hardware and held 12 samples for 48 kHz HDMI.
module scene_audio_final #(
    parameter integer CLOCK_HZ=25000000,SAMPLE_HZ=48000,
    parameter integer BLIP_SAMPLES=4800,NOTE_SAMPLES=12000,
    parameter integer RAMP_SAMPLES=256,VOLUME=224,
    parameter integer ALARM_BYTES=14000,ALARM_HOLD=12
)(
    input wire clk,rst_n,event_valid,menu_active,emergency,
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
    wire [31:0] increment=state==BLIP?PH_BLIP:note_phase(scene_q,note_index);
    wire [15:0] duration=state==BLIP?BLIP_SAMPLES:NOTE_SAMPLES;

    // Use the Anlogic logical BRAM primitive so the compressed recording is
    // guaranteed to occupy block RAM instead of thousands of LUTs.
    wire [7:0] alarm_byte;
    reg [13:0] alarm_addr; reg alarm_high; reg [3:0] alarm_hold_count;
    reg signed [17:0] alarm_predictor; reg [6:0] alarm_index;
    integer code_i,step_i,delta_i,pred_i,index_i;
    EG_LOGIC_BRAM #(
      .DATA_WIDTH_A(8),.DATA_WIDTH_B(8),.ADDR_WIDTH_A(14),.ADDR_WIDTH_B(14),
      .DATA_DEPTH_A(16384),.DATA_DEPTH_B(16384),.MODE("SP"),
      .REGMODE_A("NOREG"),.INIT_FILE(`ALARM_INIT_FILE),
      .FILL_ALL("NONE"),.IMPLEMENT("9K")
    ) u_alarm_rom (
      .doa(alarm_byte),.dob(),.dia(8'b0),.dib(8'b0),
      .cea(1'b1),.ocea(1'b1),.clka(clk),.wea(1'b0),.rsta(1'b0),.bea(1'b0),
      .ceb(1'b0),.oceb(1'b0),.clkb(clk),.web(1'b0),.rstb(1'b0),.beb(1'b0),
      .addra(alarm_addr),.addrb(14'b0)
    );
    function integer ima_step; input integer idx; begin case(idx)
      0:ima_step=7;1:ima_step=8;2:ima_step=9;3:ima_step=10;4:ima_step=11;5:ima_step=12;6:ima_step=13;7:ima_step=14;
      8:ima_step=16;9:ima_step=17;10:ima_step=19;11:ima_step=21;12:ima_step=23;13:ima_step=25;14:ima_step=28;15:ima_step=31;
      16:ima_step=34;17:ima_step=37;18:ima_step=41;19:ima_step=45;20:ima_step=50;21:ima_step=55;22:ima_step=60;23:ima_step=66;
      24:ima_step=73;25:ima_step=80;26:ima_step=88;27:ima_step=97;28:ima_step=107;29:ima_step=118;30:ima_step=130;31:ima_step=143;
      32:ima_step=157;33:ima_step=173;34:ima_step=190;35:ima_step=209;36:ima_step=230;37:ima_step=253;38:ima_step=279;39:ima_step=307;
      40:ima_step=337;41:ima_step=371;42:ima_step=408;43:ima_step=449;44:ima_step=494;45:ima_step=544;46:ima_step=598;47:ima_step=658;
      48:ima_step=724;49:ima_step=796;50:ima_step=876;51:ima_step=963;52:ima_step=1060;53:ima_step=1166;54:ima_step=1282;55:ima_step=1411;
      56:ima_step=1552;57:ima_step=1707;58:ima_step=1878;59:ima_step=2066;60:ima_step=2272;61:ima_step=2499;62:ima_step=2749;63:ima_step=3024;
      64:ima_step=3327;65:ima_step=3660;66:ima_step=4026;67:ima_step=4428;68:ima_step=4871;69:ima_step=5358;70:ima_step=5894;71:ima_step=6484;
      72:ima_step=7132;73:ima_step=7845;74:ima_step=8630;75:ima_step=9493;76:ima_step=10442;77:ima_step=11487;78:ima_step=12635;79:ima_step=13899;
      80:ima_step=15289;81:ima_step=16818;82:ima_step=18500;83:ima_step=20350;84:ima_step=22385;85:ima_step=24623;86:ima_step=27086;87:ima_step=29794;
      default:ima_step=32767; endcase end endfunction
    function integer ima_adjust; input integer c; begin case(c&7)
      0,1,2,3:ima_adjust=-1;4:ima_adjust=2;5:ima_adjust=4;6:ima_adjust=6;default:ima_adjust=8;
    endcase end endfunction

    reg [15:0] envelope;
    always @(*) begin
      envelope=RAMP_SAMPLES;
      if(age<RAMP_SAMPLES) envelope=age+1'b1;
      if(state!=ALARM && duration-age<envelope) envelope=duration-age;
      if(state==IDLE) envelope=0;
    end
    wire [8:0] gain=transition?fade_gain:envelope[8:0];
    function signed [15:0] volume_scale; input signed [17:0] value;
      reg signed [27:0] total,term;integer b;begin total=0;term=value;
      for(b=0;b<9;b=b+1) begin if((VOLUME>>b)&1) total=total+term;term=term<<<1;end
      volume_scale=total>>>8;end endfunction
    wire signed [17:0] full_raw=state==IDLE?18'sd0:
      state==ALARM?alarm_predictor:(state==MELODY?(sine_q<<<1):(sine_q<<<2));
    wire signed [15:0] raw=volume_scale(full_raw);

    always @(posedge clk or negedge rst_n) begin
      if(!rst_n) begin
        state<=IDLE;scene_q<=0;note_index<=0;repeat_index<=0;with_melody<=0;age<=0;rate_acc<=0;phase<=0;
        pending<=0;transition<=0;pending_state<=IDLE;pending_scene<=0;pending_melody<=0;fade_gain<=0;
        emergency_d<=0;menu_d<=1;wp<=0;rp<=0;count<=0;overflow<=0;sample_count<=0;
        alarm_addr<=0;alarm_high<=0;alarm_hold_count<=0;alarm_predictor<=0;alarm_index<=0;
      end else begin
        emergency_d<=emergency;menu_d<=menu_active;
        if(tick) begin
          rate_acc<=rate_acc+SAMPLE_HZ-CLOCK_HZ;sample_count<=sample_count+1'b1;phase<=phase+increment;if(!push)overflow<=1;
          if(pending) begin
            if(!transition&&gain!=0)begin transition<=1;fade_gain<=gain-1'b1;end
            else if(transition&&fade_gain!=0)fade_gain<=fade_gain-1'b1;
            else begin state<=pending_state;scene_q<=pending_scene;with_melody<=pending_melody;pending<=0;transition<=0;
              age<=0;phase<=0;note_index<=0;repeat_index<=0;
              if(pending_state==ALARM)begin alarm_addr<=0;alarm_high<=0;alarm_hold_count<=0;alarm_predictor<=0;alarm_index<=0;end
            end
          end else if(state==ALARM) begin
            if(age<RAMP_SAMPLES) age<=age+1'b1;
            if(alarm_hold_count==ALARM_HOLD-1) begin
              alarm_hold_count<=0;code_i=alarm_high?alarm_byte[7:4]:alarm_byte[3:0];step_i=ima_step(alarm_index);
              delta_i=step_i>>>3;if(code_i&4)delta_i=delta_i+step_i;if(code_i&2)delta_i=delta_i+(step_i>>>1);if(code_i&1)delta_i=delta_i+(step_i>>>2);
              pred_i=alarm_predictor+((code_i&8)?-delta_i:delta_i);if(pred_i>32767)pred_i=32767;if(pred_i< -32768)pred_i=-32768;
              index_i=alarm_index+ima_adjust(code_i);if(index_i>88)index_i=88;if(index_i<0)index_i=0;
              alarm_predictor<=pred_i;alarm_index<=index_i;
              if(alarm_high) begin alarm_high<=0;
                if(alarm_addr==ALARM_BYTES-1)begin alarm_addr<=0;alarm_predictor<=0;alarm_index<=0;end
                else alarm_addr<=alarm_addr+1'b1;
              end
              else alarm_high<=1;
            end else alarm_hold_count<=alarm_hold_count+1'b1;
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
        else if(event_valid&&!emergency)begin pending<=1;pending_state<=menu_active||event_kind==0?IDLE:BLIP;
          pending_scene<=media_id;pending_melody<=event_kind==2&&!menu_active;end
        if(push)begin fifo[wp]<={gain,raw};wp<=wp+1'b1;end if(pop)rp<=rp+1'b1;
        case({push,pop})2'b10:count<=count+1'b1;2'b01:count<=count-1'b1;default:count<=count;endcase
      end
    end
endmodule

