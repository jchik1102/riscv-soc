module core_pipeline #(
  parameter logic [63:0] RESET_PC = platform_pkg::RESET_PC
) (
  input logic clk, rst,
  output logic ireq_valid,
  input logic ireq_ready,
  output soc_pkg::bus_req_t ireq,
  input logic irsp_valid,
  output logic irsp_ready,
  input soc_pkg::bus_rsp_t irsp,
  output logic dreq_valid,
  input logic dreq_ready,
  output soc_pkg::bus_req_t dreq,
  input logic drsp_valid,
  output logic drsp_ready,
  input soc_pkg::bus_rsp_t drsp,
  output logic trace_valid,
  output soc_pkg::retire_t trace,
  output logic halted,
  output logic event_retired, event_mem_wait, event_arith_wait,
  output logic event_fetch_wait, event_load_use, event_redirect,
  input logic msip, mtip, meip,
  output logic icache_inv
);
  import soc_pkg::*;
  import core_pkg::*;

  logic stopped;
  logic halt_q;
  logic redirect, ex_trap_fire, mem_trap_now, flush_front;
  logic [63:0] redirect_pc;
  logic [63:0] csr_rdata, csr_operand, irq_cause, mtvec_q, mepc_q, ex_tval, mem_tval, wb_tval;
  logic csr_illegal, csr_write_intent, csr_commit, csr_writes_minstret, mie_global;
  logic irq_pending, irq_hold, pipe_empty, irq_inject, sys_wait, ex_sys;
  logic mem_noinc, wb_noinc, wb_handled, wb_trap_take;
  logic ex_fence_i, fence_wait;

  logic [63:0] pc_f;
  logic [1:0] fb_valid, fb_error;
  logic [60:0] fb_tag [0:1];
  logic [63:0] fb_data [0:1];
  logic out_valid, hold_valid;
  logic [60:0] out_tag, hold_tag;
  logic [60:0] pc_beat, next_beat, want_tag;
  logic misfetch, cur_hit, next_hit, rsp_hit, want_req;
  logic [63:0] beat_data;
  logic beat_error;
  logic if_valid, if_trap, if_fire;
  logic [31:0] if_insn;
  logic [5:0] if_cause;

  assign pc_beat = pc_f[63:3];
  assign next_beat = pc_beat + 61'd1;
  assign misfetch = pc_f[1:0] != 0;
  assign cur_hit = fb_valid[pc_beat[0]] && fb_tag[pc_beat[0]] == pc_beat;
  assign next_hit = fb_valid[next_beat[0]] && fb_tag[next_beat[0]] == next_beat;
  assign rsp_hit = out_valid && irsp_valid && out_tag == pc_beat;

  always_comb begin
    beat_data = cur_hit ? fb_data[pc_beat[0]] : irsp.rdata;
    beat_error = cur_hit ? fb_error[pc_beat[0]] : irsp.error;
    if_valid = !stopped && !irq_hold && (misfetch || cur_hit || rsp_hit);
    if_trap = misfetch || beat_error;
    if_cause = misfetch ? 6'd0 : 6'd1;
    if_insn = if_trap ? 32'b0 : (pc_f[2] ? beat_data[63:32] : beat_data[31:0]);
    want_req = !stopped && !misfetch && !out_valid && !hold_valid && (!cur_hit || !next_hit) && !ex_fence_i;
    want_tag = cur_hit ? next_beat : pc_beat;
    ireq_valid = !rst && (hold_valid || want_req);
    ireq = '0;
    ireq.addr = {hold_valid ? hold_tag : want_tag, 3'b0};
    ireq.mask = 8'hff;
    irsp_ready = !rst && out_valid;
  end

  logic id_valid, id_trap, id_take;
  logic [63:0] id_pc;
  logic [31:0] id_insn;
  logic [5:0] id_cause;
  decode_t id_dec;
  logic [63:0] rf_a, rf_b, id_a, id_b;
  decoder decode(.insn(id_insn), .dec(id_dec));

  logic ex_valid, ex_trap, ex_take, ex_go;
  logic [63:0] ex_pc, ex_a, ex_b;
  logic [31:0] ex_insn;
  logic [5:0] ex_cause;
  decode_t ex_dec;
  logic ex_md_started, ex_md_have_q;
  logic [63:0] ex_md_result;
  logic [4:0] ex_rs1, ex_rs2;
  logic use_rs1, use_rs2, load_hazard;
  logic [63:0] fa, fb, operand_b, alu_result, address, store_lanes;
  logic misaligned, take_branch, control_taken;
  logic [7:0] byte_mask;
  logic ex_md, md_start, md_wait, md_busy, md_done;
  logic [63:0] md_result, md_value;
  retire_t executed;
  logic fwd_mem_a, fwd_mem_b, fwd_wb_a, fwd_wb_b;

  logic mem_valid, mem_access, mem_is_load, mem_issued, mem_done, mem_accept;
  logic [2:0] mem_f3;
  retire_t mem_rec, mem_final;
  bus_req_t mem_req;
  logic [63:0] load_result;
  logic unused_misaligned;
  logic [7:0] unused_mask;
  logic [63:0] unused_lanes;
  logic mem_fwd;

  logic wb_valid, wb_fwd;
  retire_t wb_rec;
  logic [63:0] order_count;

  regfile rf(.clk(clk), .rst(rst), .rs1(id_insn[19:15]), .rs2(id_insn[24:20]),
    .rdata1(rf_a), .rdata2(rf_b), .we(wb_valid && !wb_rec.trap && !rst),
    .rd(wb_rec.rd), .wdata(wb_rec.rd_data));

  assign wb_fwd = wb_valid && !wb_rec.trap && wb_rec.rd != 0;
  assign id_a = wb_fwd && wb_rec.rd == id_insn[19:15] ? wb_rec.rd_data : rf_a;
  assign id_b = wb_fwd && wb_rec.rd == id_insn[24:20] ? wb_rec.rd_data : rf_b;

  assign ex_rs1 = ex_insn[19:15];
  assign ex_rs2 = ex_insn[24:20];
  assign mem_fwd = mem_valid && !mem_rec.trap && mem_rec.rd != 0 && !mem_is_load;
  always_comb begin
    use_rs1 = ex_dec.kind == K_ALU || ex_dec.kind == K_JALR || ex_dec.kind == K_BRANCH ||
              ex_dec.kind == K_LOAD || ex_dec.kind == K_STORE || ex_dec.kind == K_MULDIV ||
              (ex_dec.kind == K_CSR && !ex_insn[14]);
    use_rs2 = (ex_dec.kind == K_ALU && !ex_dec.use_imm) || ex_dec.kind == K_BRANCH ||
              ex_dec.kind == K_STORE || ex_dec.kind == K_MULDIV;
    fwd_mem_a = mem_fwd && mem_rec.rd == ex_rs1;
    fwd_mem_b = mem_fwd && mem_rec.rd == ex_rs2;
    fwd_wb_a = wb_fwd && wb_rec.rd == ex_rs1;
    fwd_wb_b = wb_fwd && wb_rec.rd == ex_rs2;
    fa = fwd_mem_a ? mem_rec.rd_data : fwd_wb_a ? wb_rec.rd_data : ex_a;
    fb = fwd_mem_b ? mem_rec.rd_data : fwd_wb_b ? wb_rec.rd_data : ex_b;
    load_hazard = ex_valid && mem_valid && mem_is_load && !mem_rec.trap && mem_rec.rd != 0 &&
      ((use_rs1 && ex_rs1 == mem_rec.rd) || (use_rs2 && ex_rs2 == mem_rec.rd));
  end

  assign operand_b = ex_dec.use_imm ? ex_dec.imm : fb;
  alu arithmetic(.op(ex_dec.alu_op), .word_op(ex_dec.word_op), .a(fa), .b(operand_b), .result(alu_result));
  assign address = fa + ex_dec.imm;
  logic [7:0] base_mask;
  logic [63:0] lane_mask;
  always_comb begin
    case (ex_insn[13:12])
      2'd0: begin base_mask = 8'h01; misaligned = 0; end
      2'd1: begin base_mask = 8'h03; misaligned = address[0] != 0; end
      2'd2: begin base_mask = 8'h0f; misaligned = address[1:0] != 0; end
      default: begin base_mask = 8'hff; misaligned = address[2:0] != 0; end
    endcase
    byte_mask = base_mask << address[2:0];
    for (int i = 0; i < 8; i++) lane_mask[8*i +: 8] = {8{byte_mask[i]}};
    store_lanes = (fb << {address[2:0], 3'b0}) & lane_mask;
  end

  assign ex_md = ex_valid && !ex_trap && ex_dec.kind == K_MULDIV;
  assign md_start = ex_md && !ex_md_started && !load_hazard && !mem_trap_now && !wb_trap_take;
  assign md_wait = ex_md && !(ex_md_have_q || (ex_md_started && md_done));
  assign md_value = ex_md_have_q ? ex_md_result : md_result;
  muldiv_unit arithmetic_unit(.clk(clk), .rst(rst), .kill(mem_trap_now || wb_trap_take), .start(md_start),
    .op(ex_dec.md_op), .word(ex_dec.word_op), .a(fa), .b(fb),
    .busy(md_busy), .done(md_done), .result(md_result));

  assign csr_operand = ex_insn[14] ? {59'b0, ex_insn[19:15]} : fa;
  assign csr_write_intent = ex_insn[13:12] == 2'b01 || ex_insn[19:15] != 0;
  assign ex_sys = ex_valid && !ex_trap && (ex_dec.kind == K_CSR || ex_dec.kind == K_MRET);
  assign sys_wait = ex_sys && (mem_valid || wb_valid);
  assign csr_commit = ex_go && !ex_trap && ex_dec.kind == K_CSR;
  csr_file csrs(.clk(clk), .rst(rst), .addr(ex_insn[31:20]), .funct3(ex_insn[14:12]),
    .operand(csr_operand), .write_intent(csr_write_intent), .rdata(csr_rdata), .illegal(csr_illegal),
    .commit(csr_commit), .writes_minstret(csr_writes_minstret),
    .trap_take(wb_trap_take), .trap_cause({wb_rec.intr, 57'b0, wb_rec.cause}), .trap_epc(wb_rec.pc),
    .trap_tval(wb_tval), .mret(ex_go && !ex_trap && ex_dec.kind == K_MRET),
    .retire_inc(wb_valid && !wb_rec.trap && !wb_noinc),
    .msip(msip), .mtip(mtip), .meip(meip), .irq_pending(irq_pending), .irq_cause(irq_cause),
    .mtvec_q(mtvec_q), .mepc_q(mepc_q), .mie_global(mie_global));

  always_comb begin
    take_branch = 0;
    case (ex_insn[14:12])
      0: take_branch = fa == fb;
      1: take_branch = fa != fb;
      4: take_branch = $signed(fa) < $signed(fb);
      5: take_branch = $signed(fa) >= $signed(fb);
      6: take_branch = fa < fb;
      7: take_branch = fa >= fb;
      default: take_branch = 0;
    endcase
    executed = '0;
    executed.pc = ex_pc; executed.insn = ex_insn;
    executed.next_pc = ex_pc + 4;
    executed.rd = ex_dec.writes_rd ? ex_insn[11:7] : 5'b0;
    control_taken = 0;
    case (ex_dec.kind)
      K_ALU: executed.rd_data = alu_result;
      K_LUI: executed.rd_data = ex_dec.imm;
      K_AUIPC: executed.rd_data = ex_pc + ex_dec.imm;
      K_JAL, K_JALR: begin
        executed.rd_data = ex_pc + 4;
        executed.next_pc = ex_dec.kind == K_JAL ? ex_pc + ex_dec.imm : address & ~64'b1;
        control_taken = 1;
      end
      K_BRANCH: if (take_branch) begin executed.next_pc = ex_pc + ex_dec.imm; control_taken = 1; end
      K_LOAD, K_STORE: begin
        if (misaligned) begin executed.trap = 1; executed.cause = ex_dec.kind == K_LOAD ? 6'd4 : 6'd6; end
        else begin
          executed.mem_addr = address;
          if (ex_dec.kind == K_LOAD) executed.mem_rmask = byte_mask;
          else begin executed.mem_wmask = byte_mask; executed.mem_wdata = store_lanes; end
        end
      end
      K_MULDIV: executed.rd_data = md_value;
      K_FENCE: if (ex_insn[12]) control_taken = 1;
      K_WFI: begin end
      K_CSR: begin
        if (csr_illegal) begin executed.trap = 1; executed.cause = 2; end
        else executed.rd_data = csr_rdata;
      end
      K_MRET: begin executed.next_pc = mepc_q; control_taken = 1; end
      K_ECALL: begin executed.trap = 1; executed.cause = 11; end
      K_EBREAK: begin executed.trap = 1; executed.cause = 3; end
      default: begin executed.trap = 1; executed.cause = 2; end
    endcase
    if (control_taken && executed.next_pc[1:0] != 0) begin executed.trap = 1; executed.cause = 0; end
    case (executed.cause)
      6'd0: ex_tval = executed.next_pc;
      6'd2: ex_tval = {32'b0, ex_insn};
      6'd3: ex_tval = ex_pc;
      6'd4, 6'd6: ex_tval = address;
      default: ex_tval = 0;
    endcase
    if (ex_trap) begin
      executed = '0;
      executed.pc = ex_pc; executed.trap = 1; executed.cause = ex_cause;
      ex_tval = ex_pc;
    end
    if (executed.trap) begin
      executed.next_pc = ex_pc; executed.rd = 0; executed.rd_data = 0;
      control_taken = 0;
    end
    if (executed.rd == 0) executed.rd_data = 0;
  end

  assign mem_done = !mem_access || (mem_issued && drsp_valid);
  assign mem_accept = !mem_valid || mem_done;
  assign mem_trap_now = mem_valid && mem_access && mem_issued && drsp_valid && drsp.error;
  assign dreq_valid = !rst && mem_valid && mem_access && !mem_issued;
  assign dreq = mem_req;
  assign drsp_ready = !rst && mem_valid && mem_issued;
  load_store mem_format(.funct3(mem_f3), .address(mem_rec.mem_addr), .store_data(64'b0),
    .read_data(drsp.rdata), .misaligned(unused_misaligned), .mask(unused_mask),
    .write_data(unused_lanes), .load_result(load_result));
  logic mem_load_done;
  assign mem_load_done = !mem_trap_now && mem_access && mem_is_load;
  assign mem_final = '{
    order: mem_rec.order, pc: mem_rec.pc, insn: mem_rec.insn,
    next_pc: mem_trap_now ? mem_rec.pc : mem_rec.next_pc,
    rd: mem_trap_now ? 5'd0 : mem_rec.rd,
    rd_data: mem_trap_now || mem_rec.rd == 0 ? 64'b0 : mem_load_done ? load_result : mem_rec.rd_data,
    mem_addr: mem_rec.mem_addr, mem_rmask: mem_rec.mem_rmask, mem_wmask: mem_rec.mem_wmask,
    mem_rdata: mem_load_done ? drsp.rdata : mem_rec.mem_rdata,
    mem_wdata: mem_rec.mem_wdata,
    trap: mem_trap_now || mem_rec.trap,
    cause: mem_trap_now ? (mem_req.write ? 6'd7 : 6'd5) : mem_rec.cause,
    intr: 1'b0};

  assign ex_fence_i = ex_valid && !ex_trap && ex_dec.kind == K_FENCE && ex_insn[12];
  assign fence_wait = ex_fence_i && (mem_valid || wb_valid || out_valid || hold_valid);
  assign icache_inv = ex_go && ex_fence_i;
  assign ex_go = ex_valid && !load_hazard && !md_wait && !sys_wait && !fence_wait && mem_accept && !mem_trap_now;
  assign ex_take = !ex_valid || ex_go;
  assign id_take = !id_valid || ex_take;
  assign redirect = ex_go && control_taken;
  assign redirect_pc = executed.next_pc;
  assign ex_trap_fire = ex_go && executed.trap;
  assign flush_front = redirect || ex_trap_fire || mem_trap_now || wb_trap_take;
  assign if_fire = if_valid && id_take && !flush_front;

  assign wb_handled = mtvec_q != 0;
  assign wb_trap_take = wb_valid && wb_rec.trap && wb_handled;
  assign pipe_empty = !id_valid && !ex_valid && !mem_valid && !wb_valid;
  assign irq_hold = irq_pending && !halted;
  assign irq_inject = irq_hold && pipe_empty && !stopped;
  assign trace_valid = wb_valid;
  always_comb begin
    trace = wb_rec;
    trace.order = order_count;
    if (wb_trap_take) trace.next_pc = mtvec_q;
  end
  assign event_retired = wb_valid && !wb_rec.trap;
  assign event_mem_wait = !rst && mem_valid && mem_access && !mem_done;
  assign event_arith_wait = !rst && ex_md && ex_md_started && !ex_md_have_q;
  assign halted = halt_q || (wb_valid && wb_rec.trap && !wb_handled);
  assign event_fetch_wait = !rst && !stopped && !halted && !if_valid;
  assign event_load_use = !rst && load_hazard;
  assign event_redirect = !rst && redirect;

  always_ff @(posedge clk) begin
    if (rst) begin
      stopped <= 0;
      halt_q <= 0;
      pc_f <= RESET_PC;
      fb_valid <= 0; fb_error <= 0;
      fb_tag[0] <= 0; fb_tag[1] <= 0; fb_data[0] <= 0; fb_data[1] <= 0;
      out_valid <= 0; out_tag <= 0; hold_valid <= 0; hold_tag <= 0;
      id_valid <= 0; id_pc <= 0; id_insn <= 0; id_trap <= 0; id_cause <= 0;
      ex_valid <= 0; ex_pc <= 0; ex_insn <= 0; ex_trap <= 0; ex_cause <= 0; ex_dec <= '0;
      ex_a <= 0; ex_b <= 0; ex_md_started <= 0; ex_md_have_q <= 0; ex_md_result <= 0;
      mem_valid <= 0; mem_access <= 0; mem_is_load <= 0; mem_issued <= 0; mem_f3 <= 0;
      mem_rec <= '0; mem_req <= '0; mem_tval <= 0; mem_noinc <= 0;
      wb_valid <= 0; wb_rec <= '0; order_count <= 0; wb_tval <= 0; wb_noinc <= 0;
    end else begin
      if (ireq_valid && ireq_ready) begin
        out_valid <= 1; out_tag <= ireq.addr[63:3]; hold_valid <= 0;
      end else if (ireq_valid) begin
        hold_valid <= 1; hold_tag <= ireq.addr[63:3];
      end
      if (irsp_valid && irsp_ready) begin
        out_valid <= 0;
        fb_valid[out_tag[0]] <= 1;
        fb_error[out_tag[0]] <= irsp.error;
        fb_tag[out_tag[0]] <= out_tag;
        fb_data[out_tag[0]] <= irsp.rdata;
      end
      if (icache_inv) fb_valid <= 0;
      if (wb_trap_take) pc_f <= mtvec_q;
      else if (redirect) pc_f <= redirect_pc;
      else if (if_fire) pc_f <= pc_f + 64'd4;
      if (wb_trap_take) stopped <= 0;
      else if (ex_trap_fire || mem_trap_now) stopped <= 1;

      if (flush_front) id_valid <= 0;
      else if (id_take) begin
        id_valid <= if_valid;
        id_pc <= pc_f; id_insn <= if_insn; id_trap <= if_trap; id_cause <= if_cause;
      end

      if (mem_trap_now || wb_trap_take) begin
        ex_valid <= 0;
      end else if (ex_take) begin
        ex_valid <= id_valid && !redirect && !ex_trap_fire;
        ex_pc <= id_pc; ex_insn <= id_insn; ex_trap <= id_trap; ex_cause <= id_cause;
        ex_dec <= id_dec; ex_a <= id_a; ex_b <= id_b;
        ex_md_started <= 0; ex_md_have_q <= 0;
      end else begin
        ex_a <= fa; ex_b <= fb;
        if (md_start) ex_md_started <= 1;
        if (ex_md_started && md_done) begin ex_md_have_q <= 1; ex_md_result <= md_result; end
      end

      if (mem_accept) begin
        mem_valid <= ex_go;
        mem_rec <= executed;
        mem_tval <= ex_tval;
        mem_noinc <= csr_writes_minstret;
        mem_access <= !executed.trap && (ex_dec.kind == K_LOAD || ex_dec.kind == K_STORE);
        mem_is_load <= ex_dec.kind == K_LOAD;
        mem_issued <= 0;
        mem_f3 <= ex_insn[14:12];
        mem_req.addr <= {address[63:3], 3'b0};
        mem_req.mask <= byte_mask;
        mem_req.write <= ex_dec.kind == K_STORE;
        mem_req.wdata <= ex_dec.kind == K_STORE ? store_lanes : 64'b0;
      end else if (dreq_valid && dreq_ready) mem_issued <= 1;

      wb_valid <= mem_valid && mem_done;
      wb_rec <= mem_final;
      wb_tval <= mem_trap_now ? mem_rec.mem_addr : mem_tval;
      wb_noinc <= mem_noinc;
      if (irq_inject) begin
        wb_valid <= 1;
        wb_rec <= '0;
        wb_rec.pc <= pc_f; wb_rec.next_pc <= pc_f;
        wb_rec.trap <= 1; wb_rec.intr <= 1; wb_rec.cause <= irq_cause[5:0];
        wb_tval <= 0; wb_noinc <= 0;
      end
      if (wb_valid) order_count <= order_count + 1;
      if (wb_valid && wb_rec.trap && !wb_handled) halt_q <= 1;
    end
  end
endmodule
