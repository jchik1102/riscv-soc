`timescale 1ns/1ps
module pipe_fault_tb;
  import soc_pkg::*;
  logic clk = 0, rst = 1;
  always #5 clk = ~clk;
  logic [1:0] done = 0;
  genvar instance_id;
  generate for (instance_id = 0; instance_id < 2; instance_id = instance_id + 1) begin : faults
    localparam logic [63:0] START = instance_id == 0 ? platform_pkg::RESET_PC + 2 : platform_pkg::RAM_BASE + 64'h100000000;
    logic ireq_valid, ireq_ready = 1, irsp_valid = 0, irsp_ready;
    logic dreq_valid, dreq_ready = 1, drsp_valid = 0, drsp_ready;
    logic trace_valid, halted;
    logic msip = 0, mtip = 0, meip = 0;
    logic icache_inv;
    logic event_retired, event_mem_wait, event_arith_wait, event_fetch_wait, event_load_use, event_redirect;
    logic event_branch, event_mispredict;
    bus_req_t ireq, dreq;
    bus_rsp_t irsp = '{rdata:64'hffffffffffffffff, error:1'b1};
    bus_rsp_t drsp = '0;
    retire_t trace;
    core_pipeline #(.RESET_PC(START)) dut(.*);
    always @(posedge clk) if (!rst) begin
      if (instance_id == 0 && ireq_valid) $fatal(1, "Misaligned fetch was issued");
      if (dreq_valid) $fatal(1, "Data request from a fetch diagnostic");
      if (ireq_valid && ireq_ready) begin
        if (ireq.addr != START && ireq.addr != START + 8) $fatal(1, "Fetch address high bits lost");
        irsp_valid <= 1;
      end else if (irsp_ready) irsp_valid <= 0;
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
    $display("PIPE_FAULT_TEST_PASS: misaligned reset PC and fetch bus error halt without retirement");
    $finish;
  end
  initial begin #10000; $fatal(1, "Fault watchdog"); end
endmodule
