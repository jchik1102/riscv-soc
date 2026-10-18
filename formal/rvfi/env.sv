// Environment for riscv-formal around the pipeline core (RVFI, one
// retirement per cycle). wrapper.v, read by Yosys's own frontend, supplies
// the free inputs (yosys-slang has no $anyseq) and connects this module to
// riscv-formal's testbench.
//
// Environment (the free inputs take any value every cycle):
//  - Each bus accepts a request whenever it chooses and answers one cycle or
//    more later with any data. The core keeps at most one fetch and one data
//    access outstanding, and so does this model. Bus errors never happen.
//  - Fetched instructions are assumed not to be SYSTEM or MISC-MEM (CSR,
//    ECALL, EBREAK, MRET, WFI, FENCE, FENCE.I): riscv-formal's rv64im model
//    has no specification for them, and its "ill" check would otherwise
//    demand that they trap. With RVFI_EXCLUDE_M (checks.cfg), M-extension
//    encodings are excluded too; checks_m.cfg allows them. With no CSR writes, mtvec
//    stays 0, so any trap halts the core (rvfi_halt).
//  - Interrupt inputs are 0.
module rvfi_core_env (
  input logic clock, reset,
  input logic ireq_free, irsp_free, dreq_free, drsp_free,
  input logic [63:0] irdata, drdata,
  output logic [0:0] rvfi_valid,
  output logic [63:0] rvfi_order,
  output logic [31:0] rvfi_insn,
  output logic [0:0] rvfi_trap, rvfi_halt, rvfi_intr,
  output logic [1:0] rvfi_mode, rvfi_ixl,
  output logic [4:0] rvfi_rs1_addr, rvfi_rs2_addr,
  output logic [63:0] rvfi_rs1_rdata, rvfi_rs2_rdata,
  output logic [4:0] rvfi_rd_addr,
  output logic [63:0] rvfi_rd_wdata, rvfi_pc_rdata, rvfi_pc_wdata, rvfi_mem_addr,
  output logic [7:0] rvfi_mem_rmask, rvfi_mem_wmask,
  output logic [63:0] rvfi_mem_rdata, rvfi_mem_wdata
);
  import soc_pkg::*;

  logic ireq_valid, ireq_ready, irsp_valid, irsp_ready;
  logic dreq_valid, dreq_ready, drsp_valid, drsp_ready;
  bus_req_t ireq, dreq;
  bus_rsp_t irsp, drsp;
  logic i_pending, d_pending;

  assign ireq_ready = ireq_free && !i_pending;
  assign irsp_valid = irsp_free && i_pending;
  assign irsp = '{rdata: irdata, error: 1'b0};
  assign dreq_ready = dreq_free && !d_pending;
  assign drsp_valid = drsp_free && d_pending;
  assign drsp = '{rdata: drdata, error: 1'b0};

  always_ff @(posedge clock) begin
    if (reset) begin
      i_pending <= 0; d_pending <= 0;
    end else begin
      if (ireq_valid && ireq_ready) i_pending <= 1;
      else if (irsp_valid && irsp_ready) i_pending <= 0;
      if (dreq_valid && dreq_ready) d_pending <= 1;
      else if (drsp_valid && drsp_ready) d_pending <= 0;
    end
  end

  function automatic logic excluded(input logic [31:0] insn);
    logic [6:0] opcode;
    opcode = insn[6:0];
`ifdef RVFI_EXCLUDE_M
    if ((opcode == 7'b0110011 || opcode == 7'b0111011) && insn[31:25] == 7'b0000001) return 1;
`endif
    return opcode == 7'b1110011 || opcode == 7'b0001111;
  endfunction
  always_comb
    if (!reset && irsp_valid) assume (!excluded(irdata[31:0]) && !excluded(irdata[63:32]));

  logic trace_valid, halted;
  retire_t trace;
  core_pipeline core(
    .clk(clock), .rst(reset),
    .ireq_valid, .ireq_ready, .ireq, .irsp_valid, .irsp_ready, .irsp,
    .dreq_valid, .dreq_ready, .dreq, .drsp_valid, .drsp_ready, .drsp,
    .trace_valid, .trace, .halted,
    .event_retired(), .event_mem_wait(), .event_arith_wait(), .event_fetch_wait(),
    .event_load_use(), .event_redirect(), .event_branch(), .event_mispredict(),
    .msip(1'b0), .mtip(1'b0), .meip(1'b0), .icache_inv(),
    .rvfi_rs1_addr, .rvfi_rs2_addr, .rvfi_rs1_rdata, .rvfi_rs2_rdata);

  // The first instruction after a trap is the first of its handler.
  logic after_trap;
  always_ff @(posedge clock)
    if (reset) after_trap <= 0;
    else if (trace_valid) after_trap <= trace.trap;

  assign rvfi_valid = trace_valid;
  assign rvfi_order = trace.order;
  assign rvfi_insn = trace.insn;
  assign rvfi_trap = trace.trap;
  assign rvfi_halt = trace_valid && trace.trap && halted;
  assign rvfi_intr = trace_valid && after_trap;
  assign rvfi_mode = 2'b11;
  assign rvfi_ixl = 2'b10;
  assign rvfi_rd_addr = trace.rd;
  assign rvfi_rd_wdata = trace.rd_data;
  assign rvfi_pc_rdata = trace.pc;
  assign rvfi_pc_wdata = trace.next_pc;
  // The core reports the byte address and lanes within the aligned 64-bit
  // word; RISCV_FORMAL_ALIGNED_MEM expects the word address.
  assign rvfi_mem_addr = {trace.mem_addr[63:3], 3'b000};
  assign rvfi_mem_rmask = trace.mem_rmask;
  assign rvfi_mem_wmask = trace.mem_wmask;
  assign rvfi_mem_rdata = trace.mem_rdata;
  assign rvfi_mem_wdata = trace.mem_wdata;
endmodule
