`timescale 1ns/1ps

// Exhaustive proof over every signed 19-bit input that the optimized
// constant-volume datapath is bit-exact with the original implementation.
module tb_volume_scale_equiv;
    reg signed [18:0] value;
    wire signed [22:0] value_ext = {{4{value[18]}}, value};
    wire signed [22:0] value_x7 = (value_ext <<< 3) - value_ext;
    wire signed [15:0] optimized = value_x7 >>> 3;
    integer i;
    integer fails = 0;
    reg signed [15:0] reference;

    function signed [15:0] original_scale;
        input signed [18:0] input_value;
        reg signed [27:0] total;
        reg signed [27:0] term;
        integer bit_index;
        begin
            total = 0;
            term = input_value;
            for (bit_index=0; bit_index<9; bit_index=bit_index+1) begin
                if ((224 >> bit_index) & 1)
                    total = total + term;
                term = term <<< 1;
            end
            original_scale = total >>> 8;
        end
    endfunction

    initial begin
        for (i=-262144; i<262144; i=i+1) begin
            value = i;
            #1;
            reference = original_scale(value);
            if (optimized !== reference) begin
                fails = fails + 1;
                if (fails <= 8)
                    $display("[FAIL] value=%0d optimized=%0d reference=%0d",
                             value, optimized, reference);
            end
        end
        if (fails == 0)
            $display("[PASS] exhaustive 19-bit volume-scale equivalence (524288 vectors)");
        else
            $display("[FAIL] volume-scale mismatches=%0d", fails);
        $finish;
    end
endmodule
