module core_multicycle #(
  parameter logic [63:0] RESET_PC = platform_pkg::RESET_PC
) (
  input logic clk, rst,
  output logic req_valid,
  input logic req_ready,
  output soc_pkg::bus_req_t req,
  input logic rsp_valid,
  output logic rsp_ready,
  input soc_pkg::bus_rsp_t rsp,
  output logic trace_valid,
  output soc_pkg::retire_t trace,
  output logic halted,
  output logic event_retired, event_mem_wait, event_arith_wait
);
  import soc_pkg::*;
  import core_pkg::*;
  typedef enum logic [2:0] {FETCH_REQ, FETCH_RSP, EXECUTE, DATA_REQ, DATA_RSP, ARITH_WAIT, COMMIT, STOP} state_t;
  state_t state;
  logic [63:0] pc, order_count;
  logic [31:0] insn;
  logic [63:0] a, b, result, operand_b, address, load_result, store_lanes;
  logic misaligned, take_branch, control_taken;
  logic [7:0] byte_mask;
  decode_t dec;
  retire_t pending, executed;
  bus_req_t data_req;
  logic arith_start, arith_busy, arith_done;
  logic [63:0] arith_result;

  regfile rf(.clk(clk), .rst(rst), .rs1(insn[19:15]), .rs2(insn[24:20]),
    .rdata1(a), .rdata2(b), .we(state == COMMIT && !pending.trap && !rst),
    .rd(pending.rd), .wdata(pending.rd_data));

  decoder decode(.insn(insn), .dec(dec));
  assign operand_b = dec.use_imm ? dec.imm : b;
  alu arithmetic(.op(dec.alu_op), .word_op(dec.word_op), .a(a), .b(operand_b), .result(result));
  assign address = a + dec.imm;

  assign arith_start = state == EXECUTE && dec.kind == K_MULDIV;
  muldiv_unit arithmetic_unit(.clk(clk), .rst(rst), .kill(1'b0), .start(arith_start),
    .op(dec.md_op), .word(dec.word_op), .a(a), .b(b),
    .busy(arith_busy), .done(arith_done), .result(arith_result));
  load_store memory_format(.funct3(insn[14:12]), .address(address), .store_data(b),
    .read_data(rsp.rdata), .misaligned(misaligned), .mask(byte_mask),
    .write_data(store_lanes), .load_result(load_result));

  always_comb begin
    take_branch = 0;
    case (insn[14:12])
      0: take_branch = a == b;
      1: take_branch = a != b;
      4: take_branch = $signed(a) < $signed(b);
      5: take_branch = $signed(a) >= $signed(b);
      6: take_branch = a < b;
      7: take_branch = a >= b;
      default: take_branch = 0;
    endcase
    executed = '0;
    executed.pc = pc; executed.order = order_count; executed.insn = insn;
    executed.next_pc = pc + 4;
    executed.rd = dec.writes_rd ? insn[11:7] : 5'b0;
    control_taken = 0;
    case (dec.kind)
      K_ALU: executed.rd_data = result;
      K_LUI: executed.rd_data = dec.imm;
      K_AUIPC: executed.rd_data = pc + dec.imm;
      K_JAL, K_JALR: begin
        executed.rd_data = pc + 4;
        executed.next_pc = dec.kind == K_JAL ? pc + dec.imm : address & ~64'b1;
        control_taken = 1;
      end
      K_BRANCH: if (take_branch) begin executed.next_pc = pc + dec.imm; control_taken = 1; end
      K_LOAD, K_STORE: begin
        if (misaligned) begin executed.trap = 1; executed.cause = dec.kind == K_LOAD ? 6'd4 : 6'd6; end
        else begin
          executed.mem_addr = address;
          if (dec.kind == K_LOAD) executed.mem_rmask = byte_mask;
          else begin executed.mem_wmask = byte_mask; executed.mem_wdata = store_lanes; end
        end
      end
      K_FENCE, K_MULDIV: begin end
      K_ECALL: begin executed.trap = 1; executed.cause = 11; end
      K_EBREAK: begin executed.trap = 1; executed.cause = 3; end
      default: begin executed.trap = 1; executed.cause = 2; end
    endcase
    if (control_taken && executed.next_pc[1:0] != 0) begin executed.trap = 1; executed.cause = 0; end
    if (executed.trap) begin
      executed.next_pc = pc; executed.rd = 0; executed.rd_data = 0;
    end
    if (executed.rd == 0) executed.rd_data = 0;
  end

  always_comb begin
    req = '0;
    req.addr = {pc[63:3], 3'b0};
    req.mask = pc[2] ? 8'hf0 : 8'h0f;
    if (state == DATA_REQ) req = data_req;
    req_valid = !rst && ((state == FETCH_REQ && pc[1:0] == 0) || state == DATA_REQ);
    rsp_ready = !rst && (state == FETCH_RSP || state == DATA_RSP);
    halted = state == STOP;
    event_retired = trace_valid && !trace.trap;
    event_mem_wait = !rst && ((req_valid && !req_ready) || (rsp_ready && !rsp_valid));
    event_arith_wait = !rst && state == ARITH_WAIT;
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      state <= FETCH_REQ;
      pc <= RESET_PC;
      insn <= 0;
      order_count <= 0;
      pending <= '0;
      data_req <= '0;
      trace <= '0;
      trace_valid <= 0;
    end else begin
      trace_valid <= 0;
      case (state)
        FETCH_REQ: begin
          if (pc[1:0] != 0) begin
            pending <= '0;
            pending.pc <= pc;
            pending.next_pc <= pc;
            pending.order <= order_count;
            pending.trap <= 1;
            pending.cause <= 0;
            state <= COMMIT;
          end else if (req_ready) state <= FETCH_RSP;
        end
        FETCH_RSP: if (rsp_valid) begin
          insn <= pc[2] ? rsp.rdata[63:32] : rsp.rdata[31:0];
          if (rsp.error) begin
            pending <= '0;
            pending.pc <= pc;
            pending.next_pc <= pc;
            pending.order <= order_count;
            pending.trap <= 1;
            pending.cause <= 1;
            state <= COMMIT;
          end else state <= EXECUTE;
        end
        EXECUTE: begin
          pending <= executed;
          if (!executed.trap && (dec.kind == K_LOAD || dec.kind == K_STORE)) begin
            data_req.addr <= {address[63:3], 3'b0};
            data_req.mask <= byte_mask;
            data_req.write <= dec.kind == K_STORE;
            data_req.wdata <= dec.kind == K_STORE ? store_lanes : 64'b0;
            state <= DATA_REQ;
          end else if (dec.kind == K_MULDIV) state <= ARITH_WAIT;
          else state <= COMMIT;
        end
        ARITH_WAIT: if (arith_done) begin
          pending.rd_data <= pending.rd == 0 ? 64'b0 : arith_result;
          state <= COMMIT;
        end
        DATA_REQ: if (req_ready) state <= DATA_RSP;
        DATA_RSP: if (rsp_valid) begin
          if (rsp.error) begin
            pending.trap <= 1; pending.cause <= data_req.write ? 6'd7 : 6'd5;
            pending.next_pc <= pc; pending.rd <= 0; pending.rd_data <= 0;
          end else if (!data_req.write) begin
            pending.rd_data <= pending.rd == 0 ? 64'b0 : load_result;
            pending.mem_rdata <= rsp.rdata;
          end
          state <= COMMIT;
        end
        COMMIT: begin
          trace <= pending;
          trace_valid <= 1;
          pc <= pending.next_pc;
          order_count <= order_count + 1;
          state <= pending.trap ? STOP : FETCH_REQ;
        end
        STOP: state <= STOP;
        default: state <= STOP;
      endcase
    end
  end
endmodule
