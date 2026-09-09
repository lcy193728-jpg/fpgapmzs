module scene_selector(
    input  wire       clk,
    input  wire       rst_n,
    input  wire       next_pulse,
    input  wire       prev_pulse,
    input  wire       direct_en,
    input  wire [1:0] direct_scene,
    output reg  [1:0] scene_normal,
    output reg        scene_changed
);

localparam [1:0] SCENE_WELCOME = 2'd0;
localparam [1:0] SCENE_MEETING = 2'd1;
localparam [1:0] SCENE_QUIZ    = 2'd2;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        scene_normal  <= SCENE_WELCOME;
        scene_changed <= 1'b0;
    end else begin
        scene_changed <= 1'b0;

        if (direct_en) begin
            if (direct_scene <= SCENE_QUIZ) begin
                scene_changed <= (scene_normal != direct_scene);
                scene_normal  <= direct_scene;
            end
        end else if (next_pulse && !prev_pulse) begin
            scene_changed <= 1'b1;
            if (scene_normal == SCENE_QUIZ)
                scene_normal <= SCENE_WELCOME;
            else
                scene_normal <= scene_normal + 1'b1;
        end else if (prev_pulse && !next_pulse) begin
            scene_changed <= 1'b1;
            if (scene_normal == SCENE_WELCOME)
                scene_normal <= SCENE_QUIZ;
            else
                scene_normal <= scene_normal - 1'b1;
        end
    end
end

endmodule
