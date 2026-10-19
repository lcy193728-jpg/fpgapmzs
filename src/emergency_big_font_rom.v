`timescale 1ns/1ps
module emergency_big_font_rom(input wire clk,input wire en,input wire [16:0] addr,output reg [1:0] q);
  wire [2:0] bank=addr[16:14]; wire [10:0] local_addr=addr[13:3];
  reg [2:0] bank_q,lane_q; wire [15:0] q0,q1,q2,q3,q4; reg [15:0] word_q;
  always @(posedge clk) if(en) begin bank_q<=bank; lane_q<=addr[2:0]; end
  EG_LOGIC_BRAM #(
    .DATA_WIDTH_A(16),.DATA_WIDTH_B(16),.ADDR_WIDTH_A(11),.ADDR_WIDTH_B(11),
    .DATA_DEPTH_A(2048),.DATA_DEPTH_B(2048),.MODE("SP"),
    .REGMODE_A("NOREG"),.REGMODE_B("NOREG"),.IMPLEMENT("32K"),
    .INIT_FILE("../../src/emergency_big_font_bank0.dat")
  ) u_bank0(.doa(q0),.dob(),.dia(16'b0),.dib(16'b0),
    .cea(en&&(bank==3'd0)),.ocea(1'b1),.clka(clk),.wea(1'b0),.rsta(1'b0),.bea(1'b0),
    .ceb(1'b0),.oceb(1'b1),.clkb(clk),.web(1'b0),.rstb(1'b0),.beb(1'b0),
    .addra(local_addr),.addrb(11'd0));
  EG_LOGIC_BRAM #(
    .DATA_WIDTH_A(16),.DATA_WIDTH_B(16),.ADDR_WIDTH_A(11),.ADDR_WIDTH_B(11),
    .DATA_DEPTH_A(2048),.DATA_DEPTH_B(2048),.MODE("SP"),
    .REGMODE_A("NOREG"),.REGMODE_B("NOREG"),.IMPLEMENT("32K"),
    .INIT_FILE("../../src/emergency_big_font_bank1.dat")
  ) u_bank1(.doa(q1),.dob(),.dia(16'b0),.dib(16'b0),
    .cea(en&&(bank==3'd1)),.ocea(1'b1),.clka(clk),.wea(1'b0),.rsta(1'b0),.bea(1'b0),
    .ceb(1'b0),.oceb(1'b1),.clkb(clk),.web(1'b0),.rstb(1'b0),.beb(1'b0),
    .addra(local_addr),.addrb(11'd0));
  EG_LOGIC_BRAM #(
    .DATA_WIDTH_A(16),.DATA_WIDTH_B(16),.ADDR_WIDTH_A(11),.ADDR_WIDTH_B(11),
    .DATA_DEPTH_A(2048),.DATA_DEPTH_B(2048),.MODE("SP"),
    .REGMODE_A("NOREG"),.REGMODE_B("NOREG"),.IMPLEMENT("32K"),
    .INIT_FILE("../../src/emergency_big_font_bank2.dat")
  ) u_bank2(.doa(q2),.dob(),.dia(16'b0),.dib(16'b0),
    .cea(en&&(bank==3'd2)),.ocea(1'b1),.clka(clk),.wea(1'b0),.rsta(1'b0),.bea(1'b0),
    .ceb(1'b0),.oceb(1'b1),.clkb(clk),.web(1'b0),.rstb(1'b0),.beb(1'b0),
    .addra(local_addr),.addrb(11'd0));
  EG_LOGIC_BRAM #(
    .DATA_WIDTH_A(16),.DATA_WIDTH_B(16),.ADDR_WIDTH_A(11),.ADDR_WIDTH_B(11),
    .DATA_DEPTH_A(2048),.DATA_DEPTH_B(2048),.MODE("SP"),
    .REGMODE_A("NOREG"),.REGMODE_B("NOREG"),.IMPLEMENT("32K"),
    .INIT_FILE("../../src/emergency_big_font_bank3.dat")
  ) u_bank3(.doa(q3),.dob(),.dia(16'b0),.dib(16'b0),
    .cea(en&&(bank==3'd3)),.ocea(1'b1),.clka(clk),.wea(1'b0),.rsta(1'b0),.bea(1'b0),
    .ceb(1'b0),.oceb(1'b1),.clkb(clk),.web(1'b0),.rstb(1'b0),.beb(1'b0),
    .addra(local_addr),.addrb(11'd0));
  EG_LOGIC_BRAM #(
    .DATA_WIDTH_A(16),.DATA_WIDTH_B(16),.ADDR_WIDTH_A(11),.ADDR_WIDTH_B(11),
    .DATA_DEPTH_A(2048),.DATA_DEPTH_B(2048),.MODE("SP"),
    .REGMODE_A("NOREG"),.REGMODE_B("NOREG"),.IMPLEMENT("32K"),
    .INIT_FILE("../../src/emergency_big_font_bank4.dat")
  ) u_bank4(.doa(q4),.dob(),.dia(16'b0),.dib(16'b0),
    .cea(en&&(bank==3'd4)),.ocea(1'b1),.clka(clk),.wea(1'b0),.rsta(1'b0),.bea(1'b0),
    .ceb(1'b0),.oceb(1'b1),.clkb(clk),.web(1'b0),.rstb(1'b0),.beb(1'b0),
    .addra(local_addr),.addrb(11'd0));
  always @(*) begin
    case(bank_q)
      3'd0:word_q=q0; 3'd1:word_q=q1; 3'd2:word_q=q2; 3'd3:word_q=q3; 3'd4:word_q=q4; default:word_q=16'd0;
    endcase
    case(lane_q)
      3'd0:q=word_q[1:0]; 3'd1:q=word_q[3:2]; 3'd2:q=word_q[5:4]; 3'd3:q=word_q[7:6];
      3'd4:q=word_q[9:8]; 3'd5:q=word_q[11:10]; 3'd6:q=word_q[13:12]; default:q=word_q[15:14];
    endcase
  end
endmodule
