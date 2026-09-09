module priority_scheduler(
    input  wire [1:0] scene_normal,
    input  wire       quiz_active,
    input  wire       emergency_active,
    output reg  [1:0] scene_current,
    output reg        quiz_visible,
    output reg        emergency_visible
);

localparam [1:0] SCENE_WELCOME   = 2'd0;
localparam [1:0] SCENE_MEETING   = 2'd1;
localparam [1:0] SCENE_QUIZ      = 2'd2;
localparam [1:0] SCENE_EMERGENCY = 2'd3;

always @(*) begin
    if (emergency_active) begin
        scene_current     = SCENE_EMERGENCY;
        quiz_visible      = 1'b0;
        emergency_visible = 1'b1;
    end else begin
        scene_current     = scene_normal;
        quiz_visible      = (scene_normal == SCENE_QUIZ) && quiz_active;
        emergency_visible = 1'b0;
    end
end

endmodule
