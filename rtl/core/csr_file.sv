module csr_file (
  input logic clk, rst,
  input logic [11:0] addr,
  input logic [2:0] funct3,
  input logic [63:0] operand,
  input logic write_intent,
  output logic [63:0] rdata,
  output logic illegal,
  input logic commit,
  output logic writes_minstret,
  input logic trap_take,
  input logic [63:0] trap_cause, trap_epc, trap_tval,
  input logic mret,
  input logic retire_inc,
  input logic msip, mtip, meip,
  output logic irq_pending,
  output logic [63:0] irq_cause,
  output logic [63:0] mtvec_q, mepc_q,
  output logic mie_global
);
  logic mie_bit, mpie_bit;
  logic [63:0] mie_q, mscratch_q, mcause_q, mtval_q, mcycle_q, minstret_q, mip_now, wdata;
  logic known, read_only;

  assign mip_now = {52'b0, meip, 3'b0, mtip, 3'b0, msip, 3'b0};
  assign mie_global = mie_bit;
  always_comb begin
    known = 1; rdata = 0;
    case (addr)
      12'h300: rdata = {51'b0, 2'b11, 3'b0, mpie_bit, 3'b0, mie_bit, 3'b0};
      12'h301: rdata = 64'h8000000000001100;
      12'h304: rdata = mie_q;
      12'h305: rdata = mtvec_q;
      12'h340: rdata = mscratch_q;
      12'h341: rdata = mepc_q;
      12'h342: rdata = mcause_q;
      12'h343: rdata = mtval_q;
      12'h344: rdata = mip_now;
      12'hb00: rdata = mcycle_q;
      12'hb02: rdata = minstret_q;
      12'hf11, 12'hf12, 12'hf13, 12'hf14: rdata = 0;
      default: known = 0;
    endcase
    read_only = addr[11:10] == 2'b11;
    illegal = !known || (read_only && write_intent);
    case (funct3[1:0])
      2'd1: wdata = operand;
      2'd2: wdata = rdata | operand;
      default: wdata = rdata & ~operand;
    endcase
    writes_minstret = commit && !illegal && write_intent && addr == 12'hb02;
    irq_pending = mie_bit && ((mip_now & mie_q) != 0);
    if (mip_now[11] && mie_q[11]) irq_cause = {1'b1, 63'd11};
    else if (mip_now[3] && mie_q[3]) irq_cause = {1'b1, 63'd3};
    else irq_cause = {1'b1, 63'd7};
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      mie_bit <= 0; mpie_bit <= 0;
      mie_q <= 0; mtvec_q <= 0; mscratch_q <= 0; mepc_q <= 0; mcause_q <= 0; mtval_q <= 0;
      mcycle_q <= 0; minstret_q <= 0;
    end else begin
      mcycle_q <= mcycle_q + 64'd1;
      if (retire_inc) minstret_q <= minstret_q + 64'd1;
      if (commit && !illegal && write_intent) case (addr)
        12'h300: begin mie_bit <= wdata[3]; mpie_bit <= wdata[7]; end
        12'h304: mie_q <= wdata & 64'h888;
        12'h305: mtvec_q <= {wdata[63:2], 2'b00};
        12'h340: mscratch_q <= wdata;
        12'h341: mepc_q <= {wdata[63:2], 2'b00};
        12'h342: mcause_q <= wdata;
        12'h343: mtval_q <= wdata;
        12'hb00: mcycle_q <= wdata;
        12'hb02: minstret_q <= wdata;
        default: begin end
      endcase
      if (trap_take) begin
        mepc_q <= {trap_epc[63:2], 2'b00};
        mcause_q <= trap_cause;
        mtval_q <= trap_tval;
        mpie_bit <= mie_bit;
        mie_bit <= 0;
      end else if (mret) begin
        mie_bit <= mpie_bit;
        mpie_bit <= 1;
      end
    end
  end
endmodule
