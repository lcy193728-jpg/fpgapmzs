module emergency_latch(
    input  wire clk,
    input  wire rst_n,
    input  wire emergency_pulse,
    input  wire alarm_clear_pulse,
    output reg  emergency_active
);

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        emergency_active <= 1'b0;
    end else if (alarm_clear_pulse) begin
        emergency_active <= 1'b0;
    end else if (emergency_pulse) begin
        emergency_active <= 1'b1;
    end
end

endmodule
