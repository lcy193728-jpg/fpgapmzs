`timescale 1ns/1ps
//=====================================================================
// ModelSim-only behavioral model of the Anlogic EG_LOGIC_BRAM primitive.
//
// Why this file exists: the vendor file E:\FPGA\TD\arch\eagle_macro.v only
// DECLARES the primitive (empty module body, see line 986), so compiling it
// in ModelSim leaves dob undriven (Z). TD elaborates the real hard macro,
// but ModelSim needs a functional model -> this file.
//
// Semantics modelled (matching the DUT's usage in audio_viz_overlay.v):
//   * port B is the synchronous read port with 1 clock of latency: dob is
//     updated on the clkb edge with mem[addrb] sampled BEFORE any write on
//     the same edge -> read-before-write (WRITEMODE="NORMAL"), i.e. exactly
//     what the real hard macro does when both ports share one clock.
//   * port A is the synchronous write port.
//   * memory powers up all-zero (EG4 block RAM default, INIT_FILE="NONE").
//   * REGMODE/BYTE_ENABLE/IMPLEMENT/MODE are accepted but need no extra
//     behaviour for the "NOREG" 8-bit configuration used here; rsta/rstb
//     (output register reset) are unused because REGMODE is "NOREG".
// This file is compiled ONLY into the simulation library; it is never added
// to the TD project (build_td.tcl lists RTL files explicitly).
//=====================================================================
module EG_LOGIC_BRAM #(
  parameter DATA_WIDTH_A = 8,
  parameter DATA_WIDTH_B = 8,
  parameter ADDR_WIDTH_A = 9,
  parameter ADDR_WIDTH_B = 9,
  parameter DATA_DEPTH_A = 512,
  parameter DATA_DEPTH_B = 512,
  parameter MODE = "DP",
  parameter REGMODE_A = "NOREG",
  parameter REGMODE_B = "NOREG",
  parameter IMPLEMENT = "9K"
)(
  output [DATA_WIDTH_A-1:0] doa,
  output [DATA_WIDTH_B-1:0] dob,
  input  [DATA_WIDTH_A-1:0] dia,
  input  [DATA_WIDTH_B-1:0] dib,
  input        cea, ocea, clka, wea, rsta,
  input  [0:0] bea,
  input        ceb, oceb, clkb, web, rstb,
  input  [0:0] beb,
  input  [ADDR_WIDTH_A-1:0] addra,
  input  [ADDR_WIDTH_B-1:0] addrb
);
  reg [DATA_WIDTH_A-1:0] mem [0:DATA_DEPTH_A-1];
  reg [DATA_WIDTH_A-1:0] doa_r;
  reg [DATA_WIDTH_B-1:0] dob_r;
  integer i;

  initial begin
    for (i = 0; i < DATA_DEPTH_A; i = i + 1) mem[i] = {DATA_WIDTH_A{1'b0}};
    doa_r = {DATA_WIDTH_A{1'b0}};
    dob_r = {DATA_WIDTH_B{1'b0}};
  end

  always @(posedge clka) if (cea && wea) mem[addra] <= dia;
  always @(posedge clka) if (cea) doa_r <= mem[addra];
  // 读在写之前采样 → 与真实硬宏的 read-before-write 一致
  always @(posedge clkb) if (ceb) dob_r <= mem[addrb];

  assign dob = dob_r;
  assign doa = doa_r;
endmodule
