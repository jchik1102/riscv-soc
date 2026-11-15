// Formal harness for rtl/memory/async_fifo.sv (the copy of the network engine's stream_cdc_fifo), two independent clocks.
// Run with SymbiYosys "multiclock on": s_clk and m_clk are free inputs, so the
// solver explores every interleaving of their edges (any frequency ratio and
// phase). Both resets are held until each side has seen one clock edge in
// reset, then released for good. Checks are immediate assertions evaluated at
// every solver step. Read with: read_slang -D FORMAL.
`ifdef FORMAL
module async_fifo_formal #(parameter int WIDTH = 4, ADDR = 2) (
  input logic s_clk, m_clk, s_rst, m_rst,
  input logic [WIDTH-1:0] s_data,
  input logic s_valid, m_ready,
  input logic track_this     // the solver picks which write to follow
);
  localparam int DEPTH = 1 << ADDR;
  localparam logic [ADDR:0] MASK = '1;
  logic s_ready, m_valid;
  logic [WIDTH-1:0] m_data;

  async_fifo #(.WIDTH(WIDTH), .ADDR(ADDR)) dut(.*);

  function automatic logic [ADDR:0] to_bin(input logic [ADDR:0] g);
    logic [ADDR:0] b;
    b[ADDR] = g[ADDR];
    for (int i = ADDR - 1; i >= 0; i--) b[i] = b[i+1] ^ g[i];
    return b;
  endfunction

  // ---------------------------------------------------------------- resets
  // Each reset stays high until its side has had a clock edge in reset, then
  // stays low (resets are synchronous and asserted together).
  logic s_reset_done = 1'b0, m_reset_done = 1'b0;
  always_ff @(posedge s_clk) if (s_rst) s_reset_done <= 1'b1;
  always_ff @(posedge m_clk) if (m_rst) m_reset_done <= 1'b1;
  wire both_done = s_reset_done && m_reset_done;
  always_comb begin
    if (!s_reset_done) assume (s_rst);
    if (!m_reset_done) assume (m_rst);
    if (s_reset_done) assume (!s_rst);
    if (m_reset_done) assume (!m_rst);
  end
  // A clock edge in one domain must not happen before the other has reset,
  // or the first side would run against an unreset partner.
  always_ff @(posedge s_clk) if (!m_reset_done) assume (s_rst);
  always_ff @(posedge m_clk) if (!s_reset_done) assume (m_rst);

  // -------------------------------------------------------------- pointers
  wire [ADDR:0] count = dut.w_bin - dut.r_bin;
  wire [ADDR:0] r_seen_by_w = to_bin(dut.r_sync2);   // write side's view of the read pointer
  wire [ADDR:0] w_seen_by_r = to_bin(dut.w_sync2);   // read side's view of the write pointer

  always_comb if (both_done) begin
    // Occupancy never exceeds the depth: no overflow.
    ap_no_overflow: assert (count <= DEPTH);
    // Data is only offered when something was written: no underflow.
    if (m_valid) ap_no_underflow: assert (count != 0);
    // Gray copies always encode their binary pointers.
    ap_w_gray: assert (dut.w_gray == (dut.w_bin ^ (dut.w_bin >> 1)));
    ap_r_gray: assert (dut.r_gray == (dut.r_bin ^ (dut.r_bin >> 1)));
    // Synchronized pointers only lag: the write side never thinks the reader
    // is further ahead than it is (so full is pessimistic), and the read side
    // never thinks more has been written than has (so empty is pessimistic).
    // (the view lies between w_bin - DEPTH and the real read pointer)
    ap_r_view_lags: assert (((dut.r_bin - r_seen_by_w) & MASK) <= ((dut.w_bin - r_seen_by_w) & MASK)
                            && ((dut.w_bin - r_seen_by_w) & MASK) <= DEPTH);
    ap_w_view_lags: assert (((w_seen_by_r - dut.r_bin) & MASK) <= count);
    // Every synchronizer stage holds a valid Gray pointer between its source's
    // past and present values (each stage lags the one before it).
    ap_r_stages: assert (((dut.r_bin - to_bin(dut.r_sync1)) & MASK) <= ((dut.r_bin - r_seen_by_w) & MASK));
    ap_w_stages: assert (((dut.w_bin - to_bin(dut.w_sync1)) & MASK) <= ((dut.w_bin - w_seen_by_r) & MASK));
  end

  // ------------------------------------------------------- data integrity
  // Follow one write the solver chooses: the value read from the same
  // position must be the value written there.
  // armed is set on the write clock and seen on the read clock, so each flag
  // has a single driver.
  logic armed = 1'b0, seen = 1'b0;
  logic [ADDR:0] track_pos;
  logic [WIDTH-1:0] track_data;
  wire tracking = armed && !seen;
  always_ff @(posedge s_clk)
    if (!s_rst && s_valid && s_ready && track_this && !armed) begin
      armed <= 1'b1; track_pos <= dut.w_bin; track_data <= s_data;
    end
  always_ff @(posedge m_clk)
    if (!m_rst && tracking && m_valid && m_ready && dut.r_bin == track_pos) seen <= 1'b1;
  always_comb if (both_done && tracking) begin
    // The tracked word is still in the FIFO, between the read and write pointers.
    ap_track_inside: assert (((track_pos - dut.r_bin) & MASK) < count);
    ap_track_held: assert (dut.mem[track_pos[ADDR-1:0]] == track_data);
    if (m_valid && dut.r_bin == track_pos) ap_data: assert (m_data == track_data);
  end

  // ---------------------------------------------------------------- covers
  always_comb if (both_done) begin
    cp_full: cover (!s_ready);
    cp_tracked_word_drained: cover (seen && count == 0);
    cp_tracked_word_read: cover (seen);
  end
endmodule
`endif
