`timescale 1ns/1ps

// Audio-video linked melody source for the player. Each loaded image bank
// plays its own six-note arpeggio loop (C-major rise, A-minor, pentatonic,
// low-high swing), so a picture switch is audible as a new melody after a
// short 1.5 kHz cue blip, and the persisted volume setting scales the output.
// The FIFO/valid/ready contract matches hdmi_pcm_tone_fifo so the audio
// packetizer chain is unchanged.
module pcm_media_tone #(
    parameter integer CLOCK_HZ = 25000000,
    parameter integer SAMPLE_HZ = 48000,
    parameter [19:0] BLIP_INC = 20'd32768,   // ~1500 Hz switch cue
    parameter integer BLIP_SAMPLES = 4800,   // 100 ms at 48 kHz
    parameter integer NOTE_SAMPLES = 12000   // 250 ms per melody note
) (
    input  wire               clk,
    input  wire               rst_n,
    input  wire [1:0]         media_id,
    input  wire [7:0]         volume,
    output wire               sample_valid,
    input  wire               sample_ready,
    output wire signed [15:0] sample_left,
    output wire signed [15:0] sample_right,
    output reg                overflow,
    output wire               blip_active
);
    reg [24:0] rate_accumulator;
    reg [19:0] phase;
    reg [1:0] media_id_q;
    reg [12:0] blip_countdown;
    reg [2:0] note_index;
    reg [14:0] note_sample_count;
    reg signed [15:0] fifo [0:7];
    reg [2:0] write_pointer;
    reg [2:0] read_pointer;
    reg [3:0] fifo_count;
    wire sample_pop;
    wire sample_tick;
    wire sample_push;

    assign sample_valid = fifo_count != 0;
    assign sample_left = fifo[read_pointer];
    assign sample_right = fifo[read_pointer];
    assign sample_pop = sample_valid && sample_ready;
    assign sample_tick = rate_accumulator >= CLOCK_HZ - SAMPLE_HZ;
    assign sample_push = sample_tick && (fifo_count != 8 || sample_pop);
    assign blip_active = blip_countdown != 0;

    // phase_inc = freq * 2**20 / SAMPLE_HZ (freq * 21.8453)
    function [19:0] melody_inc;
        input [1:0] melody;
        input [2:0] note;
        begin
            case ({melody, note})
                // 0: C-major rise C5 E5 G5 C6 G5 E5
                5'b00_000: melody_inc = 20'd11426;  // C5 523 Hz
                5'b00_001: melody_inc = 20'd14396;  // E5 659 Hz
                5'b00_010: melody_inc = 20'd17127;  // G5 784 Hz
                5'b00_011: melody_inc = 20'd22860;  // C6 1046 Hz
                5'b00_100: melody_inc = 20'd17127;  // G5
                5'b00_101: melody_inc = 20'd14396;  // E5
                // 1: A-minor A4 C5 E5 A5 E5 C5
                5'b01_000: melody_inc = 20'd9634;   // A4 440 Hz
                5'b01_001: melody_inc = 20'd11426;  // C5
                5'b01_010: melody_inc = 20'd14396;  // E5
                5'b01_011: melody_inc = 20'd19269;  // A5 880 Hz
                5'b01_100: melody_inc = 20'd14396;  // E5
                5'b01_101: melody_inc = 20'd11426;  // C5
                // 2: pentatonic rise C5 D5 E5 G5 A5 C6
                5'b10_000: melody_inc = 20'd11426;  // C5
                5'b10_001: melody_inc = 20'd12833;  // D5 587 Hz
                5'b10_010: melody_inc = 20'd14396;  // E5
                5'b10_011: melody_inc = 20'd17127;  // G5
                5'b10_100: melody_inc = 20'd19269;  // A5
                5'b10_101: melody_inc = 20'd22860;  // C6
                // 3: low-high swing C5 G4 E5 C5 G4 E5
                5'b11_000: melody_inc = 20'd11426;  // C5
                5'b11_001: melody_inc = 20'd8566;   // G4 392 Hz
                5'b11_010: melody_inc = 20'd14396;  // E5
                5'b11_011: melody_inc = 20'd11426;  // C5
                5'b11_100: melody_inc = 20'd8566;   // G4
                5'b11_101: melody_inc = 20'd14396;  // E5
                default:   melody_inc = 20'd11426;
            endcase
        end
    endfunction

    wire [19:0] melody_note_inc = melody_inc(media_id_q, note_index);
    wire [19:0] phase_inc = (blip_countdown != 0) ? BLIP_INC : melody_note_inc;

    function signed [15:0] sine_sample;
        input [3:0] index;
        begin
            case (index)
                4'd0: sine_sample = 16'sd0;
                4'd1: sine_sample = 16'sd4592;
                4'd2: sine_sample = 16'sd8485;
                4'd3: sine_sample = 16'sd11087;
                4'd4: sine_sample = 16'sd12000;
                4'd5: sine_sample = 16'sd11087;
                4'd6: sine_sample = 16'sd8485;
                4'd7: sine_sample = 16'sd4592;
                4'd8: sine_sample = 16'sd0;
                4'd9: sine_sample = -16'sd4592;
                4'd10: sine_sample = -16'sd8485;
                4'd11: sine_sample = -16'sd11087;
                4'd12: sine_sample = -16'sd12000;
                4'd13: sine_sample = -16'sd11087;
                4'd14: sine_sample = -16'sd8485;
                default: sine_sample = -16'sd4592;
            endcase
        end
    endfunction

    wire signed [15:0] raw_sample = sine_sample(phase[19:16]);
    wire signed [23:0] scaled = raw_sample * $signed({1'b0, volume});
    wire signed [15:0] scaled_clamped =
        (scaled > 24'sd8388352)  ? 16'sd32767 :
        (scaled < -24'sd8388608) ? -16'sd32768 : scaled >>> 8;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rate_accumulator <= 25'd0;
            phase <= 20'd0;
            media_id_q <= 2'd0;
            blip_countdown <= 13'd0;
            note_index <= 3'd0;
            note_sample_count <= 14'd0;
            write_pointer <= 3'd0;
            read_pointer <= 3'd0;
            fifo_count <= 4'd0;
            overflow <= 1'b0;
        end else begin
            media_id_q <= media_id;

            if (sample_tick)
                rate_accumulator <= rate_accumulator + SAMPLE_HZ - CLOCK_HZ;
            else
                rate_accumulator <= rate_accumulator + SAMPLE_HZ;

            if (sample_push) begin
                fifo[write_pointer] <= scaled_clamped;
                write_pointer <= write_pointer + 1'b1;
                phase <= phase + phase_inc;
                if (blip_countdown != 0) begin
                    blip_countdown <= blip_countdown - 1'b1;
                end else if (note_sample_count >= NOTE_SAMPLES - 1) begin
                    note_sample_count <= 15'd0;
                    note_index <= (note_index == 3'd5) ? 3'd0 : note_index + 1'b1;
                end else begin
                    note_sample_count <= note_sample_count + 1'b1;
                end
            end else if (sample_tick) begin
                overflow <= 1'b1;
            end

            if (sample_pop)
                read_pointer <= read_pointer + 1'b1;

            case ({sample_push, sample_pop})
                2'b10: fifo_count <= fifo_count + 1'b1;
                2'b01: fifo_count <= fifo_count - 1'b1;
                default: fifo_count <= fifo_count;
            endcase

            // A switch reloads the cue blip and restarts the melody from its
            // first note. Load last so a reload wins over the same-edge
            // decrement or note advance.
            if (media_id != media_id_q) begin
                blip_countdown <= BLIP_SAMPLES[12:0];
                note_index <= 3'd0;
                note_sample_count <= 15'd0;
            end
        end
    end
endmodule
