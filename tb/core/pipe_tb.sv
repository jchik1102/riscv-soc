`timescale 1ns/1ps
module pipe_tb;
  import soc_pkg::*;
  import platform_pkg::*;
  logic clk = 0, rst = 1;
  always #5 clk = ~clk;
  logic ireq_valid, ireq_ready, irsp_valid, irsp_ready;
  logic dreq_valid, dreq_ready, drsp_valid, drsp_ready;
  logic trace_valid, halted;
  logic msip = 0, mtip = 0, meip = 0;
  logic icache_inv;
  logic event_retired, event_mem_wait, event_arith_wait, event_fetch_wait, event_load_use, event_redirect;
  bus_req_t ireq, dreq, isaved, dsaved;
  bus_rsp_t irsp, drsp;
  retire_t trace;
  byte unsigned mem [0:RAM_BYTES-1];
  bit ibusy = 0, dbusy = 0;
  int idelay, ddelay, cycle_count = 0, retire_count = 0;
  int irq_rate = 0, irq_taken = 0, handled_traps = 0, irq_during_m = 0, irq_during_mem = 0;
  int unsigned irng2;
  int seed = 1, max_delay = 5, reset_cycle = -1, reset_mode = 0, reset_at = -1, fd, mem_fd;
  int unsigned irng, drng;
  string image_path, trace_path;
  bit reset_done = 0;
  int unsigned iaccepts = 0, daccepts = 0;
  int request_stalls = 0, response_stalls = 0, fetch_request_stalls = 0;
  int fwd_mem = 0, fwd_wb = 0, id_bypass = 0, store_data_fwd = 0, branch_fwd = 0, jalr_fwd = 0;
  int load_use = 0, redirects = 0, flushed_id = 0, flushed_ex_trap = 0, mem_flush = 0;
  int m_back_to_back = 0, m_with_mem_wait = 0, older_retire_during_m = 0, m_kills = 0;
  int fetch_wait = 0, mem_wait = 0, arith_wait_cycles = 0, arith_wait_run = 0;
  int m_ops = 0, m_x0 = 0, arith_starts = 0, arith_dones = 0, lost_commits = 0, m_discarded = 0;
  bit arith_reset = 0, done_last_cycle = 0, done_seen = 0, last_done = 0;
  logic [63:0] last_order = 0;
  bit any_retired = 0;
  function automatic bit is_m(logic [31:0] insn);
    return (insn[6:0] == 7'h33 || insn[6:0] == 7'h3b) && insn[31:25] == 7'h01;
  endfunction
  function automatic bit in_ram(logic [63:0] addr);
    return addr >= RAM_BASE && addr <= RAM_BASE + RAM_BYTES - 8 && addr[2:0] == 0;
  endfunction
  function automatic int unsigned next_rng(input int unsigned x);
    x ^= x << 13; x ^= x >> 17; x ^= x << 5; return x;
  endfunction

  core_pipeline dut(.*);

  initial begin
    if (!$value$plusargs("IMAGE=%s", image_path)) $fatal(1, "IMAGE required");
    if (!$value$plusargs("TRACE=%s", trace_path)) $fatal(1, "TRACE required");
    if ($value$plusargs("SEED=%d", seed)) begin end
    if ($value$plusargs("IRQ_RATE=%d", irq_rate)) begin end
    irng2 = (seed == 0 ? 1 : seed) * 32'h85ebca6b + 3;
    if ($value$plusargs("MAX_DELAY=%d", max_delay)) begin end
    if ($value$plusargs("RESET_CYCLE=%d", reset_cycle)) begin end
    if ($value$plusargs("RESET_MODE=%d", reset_mode)) begin end
    if (max_delay < 0 || max_delay > 100) $fatal(1, "Bad MAX_DELAY");
    irng = seed == 0 ? 1 : seed;
    drng = (seed == 0 ? 1 : seed) * 32'h9e3779b1 + 7;
    foreach (mem[i]) mem[i] = 0;
    $readmemh(image_path, mem);
    fd = $fopen(trace_path, "w");
    if (fd == 0) $fatal(1, "Cannot open trace");
    $fdisplay(fd, "order,pc,insn,next_pc,rd,rd_data,mem_addr,mem_rmask,mem_wmask,mem_rdata,mem_wdata,trap,cause,intr");
    repeat (3) @(negedge clk);
    rst = 0;
  end

  always @(negedge clk) begin
    ireq_ready = 0; dreq_ready = 0;
    if (rst) begin
      ibusy = 0; dbusy = 0; irsp_valid = 0; drsp_valid = 0; irsp = '0; drsp = '0;
    end else begin
      irng = next_rng(irng); drng = next_rng(drng);
      if (irq_rate != 0) begin
        irng2 = next_rng(irng2);
        if (irng2 % irq_rate == 0) case ((irng2 >> 8) % 3)
          0: msip = 1;
          1: mtip = 1;
          default: meip = 1;
        endcase
      end
      ireq_ready = !ibusy && !irsp_valid && (max_delay == 0 || irng % 3 != 0);
      dreq_ready = !dbusy && !drsp_valid && (max_delay == 0 || drng % 3 != 0);
      if (reset_mode == 3 && !reset_done && dreq_valid && dreq.write) dreq_ready = 0;
    end
  end

  always @(posedge clk) begin
    if (!rst) begin
      if (ireq_valid && !ireq_ready) fetch_request_stalls++;
      if (dreq_valid && !dreq_ready) request_stalls++;
      if (drsp_ready && !drsp_valid) response_stalls++;
      if (irsp_valid && irsp_ready) begin
        $fdisplay(fd, "IR,%01h,%016h", irsp.error, irsp.rdata);
        irsp_valid <= 0; ibusy <= 0;
      end
      if (ireq_valid && ireq_ready) begin
        if (ibusy || irsp_valid) $fatal(1, "More than one outstanding fetch");
        isaved <= ireq; ibusy <= 1; idelay <= irng % (max_delay + 1); iaccepts++;
        $fdisplay(fd, "IQ,%016h,%01h,%02h,%016h", ireq.addr, ireq.write, ireq.mask, ireq.wdata);
      end else if (ibusy && !irsp_valid) begin
        if (idelay != 0) idelay <= idelay - 1;
        else begin
          irsp <= '0; irsp_valid <= 1;
          if (!in_ram(isaved.addr) || isaved.write) irsp.error <= 1;
          else for (int lane = 0; lane < 8; lane++)
            if (isaved.mask[lane]) irsp.rdata[8*lane +: 8] <= mem[isaved.addr - RAM_BASE + lane];
        end
      end
      if (drsp_valid && drsp_ready) begin
        $fdisplay(fd, "R,%01h,%016h", drsp.error, drsp.rdata);
        drsp_valid <= 0; dbusy <= 0;
      end
      if (dreq_valid && dreq_ready) begin
        if (dbusy || drsp_valid) $fatal(1, "More than one outstanding data request");
        dsaved <= dreq; dbusy <= 1; ddelay <= drng % (max_delay + 1); daccepts++;
        $fdisplay(fd, "Q,%016h,%01h,%02h,%016h", dreq.addr, dreq.write, dreq.mask, dreq.wdata);
        if (dreq.write && in_ram(dreq.addr))
          for (int lane = 0; lane < 8; lane++)
            if (dreq.mask[lane]) mem[dreq.addr - RAM_BASE + lane] <= dreq.wdata[8*lane +: 8];
      end else if (dbusy && !drsp_valid) begin
        if (ddelay != 0) ddelay <= ddelay - 1;
        else begin
          drsp <= '0; drsp_valid <= 1;
          if (!in_ram(dsaved.addr)) drsp.error <= 1;
          else for (int lane = 0; lane < 8; lane++)
            if (!dsaved.write && dsaved.mask[lane]) drsp.rdata[8*lane +: 8] <= mem[dsaved.addr - RAM_BASE + lane];
        end
      end
      if (dut.ex_go) begin
        if ((dut.use_rs1 && dut.fwd_mem_a) || (dut.use_rs2 && dut.fwd_mem_b)) fwd_mem++;
        if ((dut.use_rs1 && dut.fwd_wb_a && !dut.fwd_mem_a) || (dut.use_rs2 && dut.fwd_wb_b && !dut.fwd_mem_b)) fwd_wb++;
        if (dut.ex_dec.kind == core_pkg::K_STORE && (dut.fwd_mem_b || dut.fwd_wb_b)) store_data_fwd++;
        if (dut.ex_dec.kind == core_pkg::K_BRANCH && (dut.fwd_mem_a || dut.fwd_wb_a || dut.fwd_mem_b || dut.fwd_wb_b)) branch_fwd++;
        if (dut.ex_dec.kind == core_pkg::K_JALR && (dut.fwd_mem_a || dut.fwd_wb_a)) jalr_fwd++;
      end
      if (dut.id_valid && dut.ex_take && dut.wb_fwd && dut.wb_rec.rd inside {dut.id_insn[19:15], dut.id_insn[24:20]}) id_bypass++;
      if (event_load_use) load_use++;
      if (event_redirect) begin redirects++; if (dut.id_valid) flushed_id++; end
      if (dut.ex_trap_fire && dut.id_valid) flushed_ex_trap++;
      if (dut.mem_trap_now && dut.ex_valid) mem_flush++;
      if (dut.md_start) begin arith_starts++; if (last_done) m_back_to_back++; end
      last_done = dut.md_done;
      if (dut.md_done) arith_dones++;
      if (dut.mem_trap_now && dut.md_busy) m_kills++;
      if (dut.mem_trap_now && dut.md_done) m_discarded++;
      if (event_arith_wait && event_mem_wait) m_with_mem_wait++;
      if (event_arith_wait && trace_valid) older_retire_during_m++;
      if (event_fetch_wait) fetch_wait++;
      if (event_mem_wait) mem_wait++;
      if ((msip || mtip || meip) && dut.csrs.irq_pending && event_arith_wait) irq_during_m++;
      if ((msip || mtip || meip) && dut.csrs.irq_pending && event_mem_wait) irq_during_mem++;
    end
  end

  assert property (@(posedge clk) disable iff (rst) ireq_valid && !ireq_ready |=> ireq_valid && $stable(ireq))
    else $fatal(1, "Fetch request changed under backpressure");
  assert property (@(posedge clk) disable iff (rst) dreq_valid && !dreq_ready |=> dreq_valid && $stable(dreq))
    else $fatal(1, "Data request changed under backpressure");
  assert property (@(posedge clk) rst |-> !ireq_valid && !irsp_ready && !dreq_valid && !drsp_ready)
    else $fatal(1, "Bus active in reset");
  assert property (@(posedge clk) disable iff (rst) ireq_valid |-> !ireq.write && ireq.mask == 8'hff && ireq.addr[2:0] == 0)
    else $fatal(1, "Malformed fetch request");
  assert property (@(posedge clk) disable iff (rst) halted |=> !dreq_valid && !trace_valid)
    else $fatal(1, "Activity after halt");
  assert property (@(posedge clk) disable iff (rst) dut.md_start |-> !dut.md_busy)
    else $fatal(1, "Arithmetic start while unit busy");
  assert property (@(posedge clk) disable iff (rst) dut.md_start |=> !dut.md_start)
    else $fatal(1, "Arithmetic start repeated");
  assert property (@(posedge clk) disable iff (rst) dut.md_done |-> dut.ex_md && dut.ex_md_started && !dut.ex_md_have_q)
    else $fatal(1, "Arithmetic completion without its EX instruction");
  assert property (@(posedge clk) disable iff (rst) dut.md_wait |-> !dut.ex_go && !dut.ex_take)
    else $fatal(1, "Younger work advanced past a pending M operation");

  always @(negedge clk) begin
    cycle_count++;
    if (cycle_count > 400000) $fatal(1, "Watchdog expired");
    if (!rst && trace_valid) begin
      if (trace.rd == 0 && trace.rd_data != 0) $fatal(1, "Nonzero x0 trace");
      if (any_retired && trace.order != last_order + 1) $fatal(1, "Retirement order skipped or repeated");
      last_order = trace.order; any_retired = 1;
      $fdisplay(fd, "%0d,%016h,%08h,%016h,%0d,%016h,%016h,%02h,%02h,%016h,%016h,%0d,%0d,%0d",
        trace.order, trace.pc, trace.insn, trace.next_pc, trace.rd, trace.rd_data,
        trace.mem_addr, trace.mem_rmask, trace.mem_wmask, trace.mem_rdata, trace.mem_wdata,
        trace.trap, trace.cause, trace.intr);
      if (!trace.trap) begin
        retire_count++;
        if (is_m(trace.insn)) begin m_ops++; if (trace.rd == 0) m_x0++; end
      end else if (!halted) begin
        if (trace.intr) begin
          irq_taken++;
          if (trace.cause == 3) msip = 0;
          else if (trace.cause == 7) mtip = 0;
          else if (trace.cause == 11) meip = 0;
          else $fatal(1, "Unknown interrupt cause %0d", trace.cause);
        end else handled_traps++;
      end else begin
        if (reset_mode != 0 && !reset_done) $fatal(1, "Requested targeted reset was not exercised");
        if (reset_mode inside {4, 5} && !arith_reset) $fatal(1, "Arithmetic reset did not occur while waiting");
        if (reset_mode == 6 && lost_commits != 1) $fatal(1, "Mode 6 reset did not cancel a completed M result");
        if (arith_starts != arith_dones + arith_reset + m_kills || m_ops + lost_commits + m_discarded != arith_dones)
          $fatal(1, "Arithmetic accounting: starts=%0d dones=%0d reset=%0d kills=%0d retired=%0d lost=%0d",
                 arith_starts, arith_dones, arith_reset, m_kills, m_ops, lost_commits);
        for (int i = 0; i < 70; i++) begin
          @(negedge clk);
          if (dut.md_done) $fatal(1, "Arithmetic completion after the terminal record (operation not cancelled)");
          if (trace_valid || dreq_valid) $fatal(1, "Activity after the terminal record");
        end
        if (dut.md_busy) $fatal(1, "Arithmetic unit still busy after the terminal record");
        mem_fd = $fopen({trace_path, ".mem"}, "w");
        if (mem_fd == 0) $fatal(1, "Cannot open final memory dump");
        foreach (mem[i]) $fdisplay(mem_fd, "%02h", mem[i]);
        $fclose(mem_fd);
        $fclose(fd);
        $display("CORE_TB_DONE cycles=%0d retired=%0d fetches=%0d data=%0d", cycle_count, retire_count, iaccepts, daccepts);
        $display("EXECUTED_COVERAGE reset=%0d request_stalls=%0d response_stalls=%0d fetch_request_stalls=%0d fwd_mem=%0d fwd_wb=%0d id_bypass=%0d store_data_fwd=%0d branch_fwd=%0d jalr_fwd=%0d load_use=%0d redirects=%0d flushed_id=%0d flushed_ex_trap=%0d mem_flush=%0d m_ops=%0d m_x0=%0d arith_starts=%0d arith_dones=%0d m_back_to_back=%0d m_with_mem_wait=%0d older_retire_during_m=%0d m_kills=%0d arith_reset=%0d arith_wait_cycles=%0d fetch_wait=%0d mem_wait=%0d irq_taken=%0d handled_traps=%0d irq_during_m=%0d irq_during_mem=%0d",
          reset_done, request_stalls, response_stalls, fetch_request_stalls, fwd_mem, fwd_wb, id_bypass, store_data_fwd, branch_fwd, jalr_fwd,
          load_use, redirects, flushed_id, flushed_ex_trap, mem_flush, m_ops, m_x0, arith_starts, arith_dones, m_back_to_back,
          m_with_mem_wait, older_retire_during_m, m_kills, arith_reset, arith_wait_cycles, fetch_wait, mem_wait,
          irq_taken, handled_traps, irq_during_m, irq_during_mem);
        $finish;
      end
    end
    if (!rst) begin
      if (event_arith_wait) begin arith_wait_cycles++; arith_wait_run++; end
      else arith_wait_run = 0;
    end
    done_last_cycle = done_seen;
    done_seen = !rst && dut.md_done;
    if (!reset_done && ((reset_mode == 0 && cycle_count == reset_cycle) ||
        (reset_mode == 4 && !rst && event_arith_wait && arith_wait_run == reset_cycle + 1) ||
        (reset_mode == 5 && !rst && dut.md_done) ||
        (reset_mode == 6 && !rst && done_last_cycle) ||
        (reset_mode == 1 && dbusy && dsaved.write) ||
        (reset_mode == 2 && dbusy && !dsaved.write) ||
        (reset_mode == 3 && dreq_valid && dreq.write && !dreq_ready))) begin
      rst = 1;
      reset_done = 1;
      arith_reset = dut.md_busy || dut.md_done;
      lost_commits = arith_dones - m_ops - m_discarded;
      reset_at = cycle_count;
      any_retired = 0;
      $fdisplay(fd, "RESET");
    end else if (reset_done && cycle_count == reset_at + 3) rst = 0;
  end
endmodule
