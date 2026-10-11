`timescale 1ns/1ps
module core_tb;
  import soc_pkg::*;
  import platform_pkg::*;
  logic clk = 0, rst = 1;
  always #5 clk = ~clk;
  logic req_valid, req_ready, rsp_valid, rsp_ready, trace_valid, halted;
  logic event_retired, event_mem_wait, event_arith_wait;
  bus_req_t req, saved_req;
  bus_rsp_t rsp;
  retire_t trace;
  byte unsigned mem [0:RAM_BYTES-1];
  bit busy = 0;
  int delay_left, cycle_count = 0, retire_count = 0;
  int seed = 1, max_delay = 5, reset_cycle = -1, reset_mode = 0, reset_at = -1, fd, mem_fd;
  int unsigned rng;
  string image_path, trace_path;
  bit reset_done = 0;
  int unsigned accept_count = 0, response_count = 0;
  bit [1:0] opcode_hits = 0;
  bit negative_hit = 0, x0_hit = 0, dependency_hit = 0;
  logic [4:0] last_rd = 0;
  int request_stalls = 0, response_stalls = 0;
  int m_ops = 0, m_x0 = 0, m_dependency = 0, arith_wait_cycles = 0, arith_wait_run = 0;
  int arith_starts = 0, arith_dones = 0;
  bit last_was_m = 0, arith_reset = 0, done_last_cycle = 0, done_seen = 0;
  int lost_commits = 0;
  function automatic bit is_m(logic [31:0] insn);
    return (insn[6:0] == 7'h33 || insn[6:0] == 7'h3b) && insn[31:25] == 7'h01;
  endfunction
  core_multicycle dut(.*);

  function automatic int unsigned next_rng(input int unsigned x);
    x ^= x << 13; x ^= x >> 17; x ^= x << 5; return x;
  endfunction

  initial begin
    if (!$value$plusargs("IMAGE=%s", image_path)) $fatal(1, "IMAGE required");
    if (!$value$plusargs("TRACE=%s", trace_path)) $fatal(1, "TRACE required");
    if ($value$plusargs("SEED=%d", seed)) begin end
    if ($value$plusargs("MAX_DELAY=%d", max_delay)) begin end
    if ($value$plusargs("RESET_CYCLE=%d", reset_cycle)) begin end
    if ($value$plusargs("RESET_MODE=%d", reset_mode)) begin end
    if (max_delay < 0 || max_delay > 100) $fatal(1, "Bad MAX_DELAY");
    rng = seed == 0 ? 1 : seed;
    foreach (mem[i]) mem[i] = 0;
    $readmemh(image_path, mem);
    fd = $fopen(trace_path, "w");
    if (fd == 0) $fatal(1, "Cannot open trace");
    $fdisplay(fd, "order,pc,insn,next_pc,rd,rd_data,mem_addr,mem_rmask,mem_wmask,mem_rdata,mem_wdata,trap,cause");
    repeat (3) @(negedge clk);
    rst = 0;
  end

  always @(negedge clk) begin
    req_ready = 0;
    if (rst) begin
      busy = 0;
      rsp_valid = 0;
      rsp = '0;
    end else begin
      rng = next_rng(rng);
      req_ready = !busy && !rsp_valid && (max_delay == 0 || rng % 3 != 0);
    end
  end

  always @(posedge clk) begin
    if (!rst) begin
      if (dut.arith_start) arith_starts++;
      if (dut.arith_done) arith_dones++;
      if (req_valid && !req_ready) request_stalls++;
      if (rsp_ready && !rsp_valid) response_stalls++;
      if (rsp_valid && rsp_ready) begin
        $fdisplay(fd, "R,%01h,%016h", rsp.error, rsp.rdata);
        rsp_valid <= 0;
        busy <= 0;
        response_count <= response_count + 1;
      end
      if (req_valid && req_ready) begin
        if (busy || rsp_valid) $fatal(1, "More than one outstanding request");
        saved_req <= req;
        busy <= 1;
        delay_left <= rng % (max_delay + 1);
        accept_count <= accept_count + 1;
        $fdisplay(fd, "Q,%016h,%01h,%02h,%016h", req.addr, req.write, req.mask, req.wdata);
        if (req.write && req.addr >= RAM_BASE && req.addr <= RAM_BASE + RAM_BYTES - 8 && req.addr[2:0] == 0)
          for (int lane = 0; lane < 8; lane++)
            if (req.mask[lane]) mem[req.addr - RAM_BASE + lane] <= req.wdata[8*lane +: 8];
      end else if (busy && !rsp_valid) begin
        if (delay_left != 0) delay_left <= delay_left - 1;
        else begin
          rsp <= '0;
          rsp_valid <= 1;
          if (saved_req.addr < RAM_BASE || saved_req.addr > RAM_BASE + RAM_BYTES - 8 || saved_req.addr[2:0] != 0)
            rsp.error <= 1;
          else begin
            for (int lane = 0; lane < 8; lane++) begin
              if (!saved_req.write && saved_req.mask[lane])
                rsp.rdata[8*lane +: 8] <= mem[saved_req.addr - RAM_BASE + lane];
            end
          end
        end
      end
    end
  end

  assert property (@(posedge clk) disable iff (rst)
    req_valid && !req_ready |=> req_valid && $stable(req))
    else $fatal(1, "Request changed under backpressure");
  assert property (@(posedge clk) disable iff (rst)
    rsp_valid && !rsp_ready |=> rsp_valid && $stable(rsp))
    else $fatal(1, "Response changed under backpressure");
  assert property (@(posedge clk) rst |-> !req_valid && !rsp_ready)
    else $fatal(1, "Bus active in reset");
  assert property (@(posedge clk) disable iff (rst) dut.arith_start |-> !dut.arith_busy)
    else $fatal(1, "Arithmetic start while unit busy");
  assert property (@(posedge clk) disable iff (rst) dut.arith_start |=> !dut.arith_start)
    else $fatal(1, "Arithmetic start repeated");
  assert property (@(posedge clk) disable iff (rst) dut.arith_done |-> event_arith_wait)
    else $fatal(1, "Arithmetic completion outside wait (duplicate or canceled result)");
  assert property (@(posedge clk) disable iff (rst) event_arith_wait |-> !req_valid && !rsp_ready && !dut.rf.we && !trace_valid)
    else $fatal(1, "Activity while arithmetic pending");
  assert property (@(posedge clk) disable iff (rst) event_arith_wait |-> dut.arith_busy || dut.arith_done)
    else $fatal(1, "Core waits on an idle arithmetic unit");

  always @(negedge clk) begin
    cycle_count++;
    if (cycle_count > 400000) $fatal(1, "Watchdog expired");
    if (!rst && trace_valid) begin
      if (trace.rd == 0 && trace.rd_data != 0) $fatal(1, "Nonzero x0 trace");
      $fdisplay(fd, "%0d,%016h,%08h,%016h,%0d,%016h,%016h,%02h,%02h,%016h,%016h,%0d,%0d",
        trace.order, trace.pc, trace.insn, trace.next_pc, trace.rd, trace.rd_data,
        trace.mem_addr, trace.mem_rmask, trace.mem_wmask, trace.mem_rdata, trace.mem_wdata,
        trace.trap, trace.cause);
      if (!trace.trap) retire_count++;
      if (!trace.trap) begin
        if (is_m(trace.insn)) begin
          m_ops++;
          if (trace.rd == 0) m_x0++;
        end
        if (last_rd != 0 && (is_m(trace.insn) || last_was_m) && (trace.insn[19:15] == last_rd ||
            (trace.insn[6:0] inside {7'h33, 7'h3b, 7'h23, 7'h63} && trace.insn[24:20] == last_rd))) m_dependency++;
        last_was_m = is_m(trace.insn);
        if (trace.insn[6:0] == 7'h13 && trace.insn[14:12] == 0) opcode_hits[0] = 1;
        if (trace.insn[6:0] == 7'h33 && trace.insn[31:25] == 0 && trace.insn[14:12] == 0) opcode_hits[1] = 1;
        if (trace.insn[6:0] == 7'h13 && trace.insn[31]) negative_hit = 1;
        if (trace.rd == 0) x0_hit = 1;
        if (last_rd != 0 && (trace.insn[19:15] == last_rd ||
            (trace.insn[6:0] == 7'h33 && trace.insn[24:20] == last_rd))) dependency_hit = 1;
        last_rd = trace.rd;
      end
      if (trace.trap) begin
        if (reset_mode != 0 && !reset_done) $fatal(1, "Requested targeted reset was not exercised");
        if (reset_mode inside {4, 5} && !arith_reset) $fatal(1, "Arithmetic reset did not occur while waiting");
        if (reset_mode == 6 && lost_commits != 1) $fatal(1, "Mode 6 reset did not cancel a completed M commit");
        if (arith_starts != arith_dones + arith_reset || m_ops + lost_commits != arith_dones)
          $fatal(1, "Arithmetic accounting: starts=%0d dones=%0d canceled=%0d retired=%0d", arith_starts, arith_dones, arith_reset, m_ops);
        mem_fd = $fopen({trace_path,".mem"}, "w");
        if (mem_fd == 0) $fatal(1, "Cannot open final memory dump");
        foreach (mem[i]) $fdisplay(mem_fd, "%02h", mem[i]);
        $fclose(mem_fd);
        $fclose(fd);
        $display("CORE_TB_DONE cycles=%0d retired=%0d requests=%0d responses=%0d", cycle_count, retire_count, accept_count, response_count);
        $display("EXECUTED_COVERAGE addi=%0d add=%0d negative=%0d x0=%0d dependency=%0d reset=%0d request_stalls=%0d response_stalls=%0d m_ops=%0d m_x0=%0d m_dependency=%0d arith_starts=%0d arith_dones=%0d arith_wait_cycles=%0d arith_reset=%0d", opcode_hits[0], opcode_hits[1], negative_hit, x0_hit, dependency_hit, reset_done, request_stalls, response_stalls, m_ops, m_x0, m_dependency, arith_starts, arith_dones, arith_wait_cycles, arith_reset);
        $finish;
      end
    end
    if (!rst) begin
      if (event_arith_wait) begin arith_wait_cycles++; arith_wait_run++; end
      else arith_wait_run = 0;
    end
    done_last_cycle = done_seen;
    done_seen = !rst && dut.arith_done;
    if (!reset_done && ((reset_mode == 0 && cycle_count == reset_cycle) ||
        (reset_mode == 4 && !rst && event_arith_wait && arith_wait_run == reset_cycle + 1) ||
        (reset_mode == 5 && !rst && dut.arith_done) ||
        (reset_mode == 6 && !rst && done_last_cycle) ||
        (reset_mode == 1 && busy && saved_req.write) ||
        (reset_mode == 2 && busy && dut.pending.mem_rmask != 0) ||
        (reset_mode == 3 && req_valid && req.write && !req_ready))) begin
      rst = 1;
      reset_done = 1;
      arith_reset = event_arith_wait;
      if (reset_mode == 6 && !(dut.arith_done == 0 && arith_dones == m_ops + 1)) $fatal(1, "Mode 6 reset not in M commit cycle");
      lost_commits = arith_dones - m_ops;
      last_was_m = 0;
      reset_at = cycle_count;
      last_rd = 0;
      $fdisplay(fd, "RESET");
    end else if (reset_done && cycle_count == reset_at + 3) rst = 0;
  end
endmodule
