`timescale 1ns/1ps
module fault_tb;
  import soc_pkg::*;
  logic clk = 0, rst = 1;
  always #5 clk = ~clk;
  logic [1:0] done = 0;
  genvar instance_id;
  generate for (instance_id = 0; instance_id < 2; instance_id = instance_id + 1) begin : faults
    localparam logic [63:0] START = instance_id == 0 ? platform_pkg::RESET_PC + 2 : platform_pkg::RAM_BASE + 64'h100000000;
    logic req_valid, req_ready = 1, rsp_valid = 0, rsp_ready, trace_valid, halted;
    logic event_retired, event_mem_wait, event_arith_wait;
    bus_req_t req;
    bus_rsp_t rsp = '{rdata:64'hffffffffffffffff, error:1'b1};
    retire_t trace;
    core_multicycle #(.RESET_PC(START)) dut(.*);
    always @(posedge clk) if (!rst) begin
      if (instance_id == 0 && req_valid) $fatal(1, "Misaligned fetch was issued");
      if (req_valid && req_ready) begin
        if (req.addr != START) $fatal(1, "Fetch address high bits lost");
        rsp_valid <= 1;
      end else if (rsp_ready) rsp_valid <= 0;
    end
    always @(negedge clk) if (!rst && trace_valid) begin
      if (done[instance_id]) $fatal(1, "Duplicate terminal trace");
      if (!trace.trap || trace.cause != instance_id || trace.pc != START || trace.next_pc != START ||
          trace.insn != 0 || trace.rd != 0 || trace.rd_data != 0 || event_retired || !halted)
        $fatal(1, "Incorrect fault diagnostic");
      done[instance_id] = 1;
    end
  end endgenerate
  initial begin
    repeat (3) @(negedge clk); rst = 0;
    wait (&done);
    repeat (5) @(negedge clk);
    $display("FAULT_TEST_PASS: misaligned PC and fetch bus error halt without retirement");
    $finish;
  end
  initial begin #10000; $fatal(1, "Fault watchdog"); end
endmodule
