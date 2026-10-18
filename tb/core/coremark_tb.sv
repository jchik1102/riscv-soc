// CoreMark run on the pipeline core (scripts/run_coremark.ps1). The core gets a
// 64 KiB memory at the reset PC that answers every fetch and data request one
// cycle after accepting it, so the cycle count measures the core, not the
// SoC's caches or SDRAM. Byte stores to CONSOLE are printed; the run ends when
// the core halts (ECALL with mtvec = 0) and prints CYCLES and RETIRED. JALR
// counts (resolved, mispredicted) are read from the EX stage, to show the
// return-address stack's effect separately from the branches'.
// +IMAGE=<hex> selects the program, +MAX_CYCLES=<n> the watchdog.
module coremark_tb;
  import soc_pkg::*;
  import platform_pkg::*;
  localparam logic [63:0] CONSOLE = 64'h1000_0000;
  logic clk = 0, rst = 1;
  logic ireq_valid, ireq_ready, irsp_valid, irsp_ready, dreq_valid, dreq_ready, drsp_valid, drsp_ready;
  bus_req_t ireq, dreq;
  bus_rsp_t irsp, drsp;
  logic trace_valid, halted, msip = 0, mtip = 0, meip = 0, icache_inv;
  retire_t trace;
  logic event_retired, event_mem_wait, event_arith_wait, event_fetch_wait, event_load_use, event_redirect;
  logic event_branch, event_mispredict;
  byte unsigned mem [0:RAM_BYTES-1];
  bus_req_t isaved, dsaved;
  bit ibusy = 0, dbusy = 0;
  longint unsigned cycles = 0, retired = 0, redirects = 0, branches = 0, mispredicts = 0, max_cycles = 200_000_000;
  longint unsigned jalrs = 0, jalr_mispredicts = 0, returns = 0, return_mispredicts = 0;
  logic ex_return;
  string image_path;

  core_pipeline dut(.*);
  always #10 clk = ~clk;

  function automatic logic [63:0] word(int unsigned offset);
    for (int i = 0; i < 8; i++) word[8*i +: 8] = mem[offset + i];
  endfunction
  function automatic bit in_ram(logic [63:0] addr);
    return addr >= RAM_BASE && addr <= RAM_BASE + RAM_BYTES - 8;
  endfunction

  initial begin
    if (!$value$plusargs("IMAGE=%s", image_path)) $fatal(1, "IMAGE required");
    if ($value$plusargs("MAX_CYCLES=%d", max_cycles)) begin end
    foreach (mem[i]) mem[i] = 0;
    $readmemh(image_path, mem);
    repeat (3) @(negedge clk);
    rst = 0;
  end

  assign ex_return = dut.ex_dec.kind == core_pkg::K_JALR && dut.ex_insn[11:7] == 0 &&
    (dut.ex_insn[19:15] == 1 || dut.ex_insn[19:15] == 5);

  always @(negedge clk) begin
    ireq_ready = !rst && !ibusy && !irsp_valid;
    dreq_ready = !rst && !dbusy && !drsp_valid;
  end

  always @(posedge clk) begin
    if (rst) begin
      ibusy <= 0; dbusy <= 0; irsp_valid <= 0; drsp_valid <= 0; irsp <= '0; drsp <= '0;
    end else begin
      cycles++;
      if (cycles > max_cycles) $fatal(1, "COREMARK_TB watchdog after %0d cycles", cycles);
      if (trace_valid && !trace.trap) retired++;
      if (event_redirect) redirects++;
      if (event_branch) branches++;
      if (event_mispredict) mispredicts++;
      if (event_branch && dut.ex_dec.kind == core_pkg::K_JALR) jalrs++;
      if (event_mispredict && dut.ex_dec.kind == core_pkg::K_JALR) jalr_mispredicts++;
      // a return: JALR with rd = x0 and rs1 = x1 or x5
      if (event_branch && ex_return) returns++;
      if (event_mispredict && ex_return) return_mispredicts++;
      if (irsp_valid && irsp_ready) begin irsp_valid <= 0; ibusy <= 0; end
      if (ireq_valid && ireq_ready) begin isaved <= ireq; ibusy <= 1; end
      else if (ibusy && !irsp_valid) begin
        irsp <= '0; irsp_valid <= 1;
        if (!in_ram(isaved.addr)) irsp.error <= 1;
        else for (int lane = 0; lane < 8; lane++) irsp.rdata[8*lane +: 8] <= mem[isaved.addr - RAM_BASE + lane];
      end
      if (drsp_valid && drsp_ready) begin drsp_valid <= 0; dbusy <= 0; end
      if (dreq_valid && dreq_ready) begin
        dsaved <= dreq; dbusy <= 1;
        if (dreq.write && dreq.addr == CONSOLE) $write("%c", dreq.wdata[7:0]);
        else if (dreq.write && in_ram(dreq.addr))
          for (int lane = 0; lane < 8; lane++)
            if (dreq.mask[lane]) mem[dreq.addr - RAM_BASE + lane] <= dreq.wdata[8*lane +: 8];
      end else if (dbusy && !drsp_valid) begin
        drsp <= '0; drsp_valid <= 1;
        if (dsaved.addr == CONSOLE) begin end
        else if (!in_ram(dsaved.addr)) drsp.error <= 1;
        else for (int lane = 0; lane < 8; lane++)
          if (!dsaved.write && dsaved.mask[lane]) drsp.rdata[8*lane +: 8] <= mem[dsaved.addr - RAM_BASE + lane];
      end
      if (halted) begin
        $display("COREMARK_TB_DONE cycles=%0d retired=%0d redirects=%0d branches=%0d mispredicts=%0d jalrs=%0d jalr_mispredicts=%0d returns=%0d return_mispredicts=%0d halt_cause=%0d",
                 cycles, retired, redirects, branches, mispredicts, jalrs, jalr_mispredicts, returns, return_mispredicts, dut.wb_rec.cause);
        // Programs with a report block at RAM+0x8000 (magic, checksum, status), e.g. sw/fir.c.
        $display("REPORT magic=%h checksum=%h status=%0d", word(32'h8000), word(32'h8008), word(32'h8010));
        $finish;
      end
    end
  end
endmodule
