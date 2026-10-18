// Asynchronous FIFO for a ready/valid stream between two unrelated clocks
// (Gray-code pointers, after Cummings, "Simulation and Synthesis Techniques
// for Asynchronous FIFO Design"). The same design as stream_cdc_fifo in the
// fpga-network-engine repository, where it has a formal proof, cocotb tests
// with two clocks and an equivalence-checked VHDL version.
//
// Each side keeps a binary pointer one bit wider than the address and a Gray
// copy of it. Only the Gray pointers cross domains, each through a two-flop
// synchronizer, so full and empty can only be pessimistic. The read port is
// first-word-fall-through. Resets are synchronous to their own clocks and must
// be asserted together (a system reset), so both sides start empty.
module async_fifo #(
  parameter int WIDTH = 64,
  parameter int ADDR = 3        // 2**ADDR entries
)(
  input  logic             s_clk, s_rst,
  input  logic [WIDTH-1:0] s_data,
  input  logic             s_valid,
  output logic             s_ready,
  input  logic             m_clk, m_rst,
  output logic [WIDTH-1:0] m_data,
  output logic             m_valid,
  input  logic             m_ready
);
  localparam int DEPTH = 1 << ADDR;

  logic [WIDTH-1:0] mem [0:DEPTH-1];
  logic [ADDR:0] w_bin, w_gray, r_bin, r_gray;
  (* ASYNC_REG = "TRUE" *) logic [ADDR:0] w_sync1, w_sync2;
  (* ASYNC_REG = "TRUE" *) logic [ADDR:0] r_sync1, r_sync2;

  function automatic logic [ADDR:0] to_gray(input logic [ADDR:0] b);
    return b ^ (b >> 1);
  endfunction

  wire [ADDR:0] w_bin_next = w_bin + 1'b1;
  wire full = w_gray == {~r_sync2[ADDR:ADDR-1], r_sync2[ADDR-2:0]};
  assign s_ready = !s_rst && !full;

  always_ff @(posedge s_clk) begin
    if (s_rst) begin
      w_bin <= '0; w_gray <= '0; r_sync1 <= '0; r_sync2 <= '0;
    end else begin
      r_sync1 <= r_gray; r_sync2 <= r_sync1;
      if (s_valid && s_ready) begin
        mem[w_bin[ADDR-1:0]] <= s_data;
        w_bin <= w_bin_next;
        w_gray <= to_gray(w_bin_next);
      end
    end
  end

  wire [ADDR:0] r_bin_next = r_bin + 1'b1;
  wire empty = r_gray == w_sync2;
  assign m_valid = !m_rst && !empty;
  assign m_data = mem[r_bin[ADDR-1:0]];

  always_ff @(posedge m_clk) begin
    if (m_rst) begin
      r_bin <= '0; r_gray <= '0; w_sync1 <= '0; w_sync2 <= '0;
    end else begin
      w_sync1 <= w_gray; w_sync2 <= w_sync1;
      if (m_valid && m_ready) begin
        r_bin <= r_bin_next;
        r_gray <= to_gray(r_bin_next);
      end
    end
  end
endmodule
