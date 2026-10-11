module synthesis_top #(
  parameter bit PIPELINE = 0,
  parameter int ACCEL_N = 0
) (
  input logic clk, rst,
  input logic loader_we,
  input logic [12:0] loader_word,
  input logic [63:0] loader_data,
  output logic trace_valid, halted,
  output logic [63:0] trace_pc, trace_result,
  output logic [4:0] trace_rd,
  output logic uart_tx,
  input logic uart_rx
);
  import soc_pkg::*;
  retire_t trace;
  logic event_retired, event_mem_wait, event_arith_wait, event_fetch_wait, event_load_use, event_redirect;
  cpu_soc #(.PIPELINE(PIPELINE), .ACCEL_N(ACCEL_N)) soc(.*, .cache_enable_init(2'b00), .sdram_req_valid(), .sdram_req_ready(1'b0), .sdram_req(),
    .sdram_rsp_valid(1'b0), .sdram_rsp_ready(), .sdram_rsp('0));
  assign trace_pc = trace.pc;
  assign trace_result = trace.rd_data;
  assign trace_rd = trace.rd;
endmodule
