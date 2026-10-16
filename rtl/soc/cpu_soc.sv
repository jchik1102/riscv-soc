module cpu_soc #(
  parameter bit PIPELINE = 0,
  parameter logic [15:0] UART_DIVISOR = 16'd434,
  parameter bit SDRAM = 0,
  parameter bit CACHE = 0,
  parameter int ICACHE_BYTES = int'(platform_pkg::CACHES_ICACHE_BYTES),
  parameter int DCACHE_BYTES = int'(platform_pkg::CACHES_DCACHE_BYTES),
  parameter int ACCEL_N = 0,
  parameter bit ACCEL_PARALLEL = 1
) (
  input logic clk, rst,
  input logic loader_we,
  input logic [12:0] loader_word,
  input logic [63:0] loader_data,
  output logic trace_valid,
  output soc_pkg::retire_t trace,
  output logic halted,
  output logic event_retired, event_mem_wait, event_arith_wait,
  output logic event_fetch_wait, event_load_use, event_redirect,
  output logic uart_tx,
  input logic uart_rx,
  input logic [1:0] cache_enable_init,
  output logic sdram_req_valid,
  input logic sdram_req_ready,
  output soc_pkg::bus2_req_t sdram_req,
  input logic sdram_rsp_valid,
  output logic sdram_rsp_ready,
  input soc_pkg::bus2_rsp_t sdram_rsp
);
  import soc_pkg::*;
  bus_req_t req;
  bus_rsp_t rsp;
  logic req_valid, req_ready, rsp_valid, rsp_ready;
  // synthesis translate_off
  initial if (CACHE && !(PIPELINE && SDRAM)) $fatal(1, "cpu_soc: CACHE needs PIPELINE and SDRAM");
  initial if (!(ACCEL_N == 0 || (PIPELINE && (ACCEL_N == 2 || ACCEL_N == 4)))) $fatal(1, "cpu_soc: ACCEL_N must be 0, or 2/4 with PIPELINE");
  // synthesis translate_on
  generate if (PIPELINE) begin : pipeline
    bus_req_t ireq, dreq, ram_dreq, mmio_req, ram_ireq, sd_dreq;
    bus_rsp_t irsp, drsp, ram_drsp, mmio_rsp, ram_irsp, sd_drsp;
    logic ireq_valid, ireq_ready, irsp_valid, irsp_ready, dreq_valid, dreq_ready, drsp_valid, drsp_ready;
    logic ram_dreq_valid, ram_dreq_ready, ram_drsp_valid, ram_drsp_ready;
    logic ram_ireq_valid, ram_ireq_ready, ram_irsp_valid, ram_irsp_ready;
    logic sd_dreq_valid, sd_dreq_ready, sd_drsp_valid, sd_drsp_ready;
    logic mmio_req_valid, mmio_req_ready, mmio_rsp_valid, mmio_rsp_ready;
    logic acc_req_valid, acc_req_ready, acc_rsp_valid, acc_rsp_ready, uart_irq, accel_irq;
    bus_req_t acc_req;
    bus_rsp_t acc_rsp;
    logic msip, mtip, meip, icache_inv, icache_enable, dcache_enable;
    logic ev_i_access, ev_i_miss, ev_i_uncached, ev_d_access, ev_d_miss, ev_d_uncached, ev_d_write;
    logic ev_branch, ev_mispredict;
    logic [4:0] dev_sel, dev_ok;
    logic dev_acc, dev_wr;
    logic [7:0] dev_offset, dev_mask;
    logic [63:0] dev_wdata, uart_rdata, timer_rdata, counter_rdata, cache_rdata, intc_rdata;
    core_pipeline core(.clk(clk), .rst(rst),
      .ireq_valid(ireq_valid), .ireq_ready(ireq_ready), .ireq(ireq),
      .irsp_valid(irsp_valid), .irsp_ready(irsp_ready), .irsp(irsp),
      .dreq_valid(dreq_valid), .dreq_ready(dreq_ready), .dreq(dreq),
      .drsp_valid(drsp_valid), .drsp_ready(drsp_ready), .drsp(drsp),
      .trace_valid(trace_valid), .trace(trace), .halted(halted),
      .event_retired(event_retired), .event_mem_wait(event_mem_wait), .event_arith_wait(event_arith_wait),
      .event_fetch_wait(event_fetch_wait), .event_load_use(event_load_use), .event_redirect(event_redirect),
      .event_branch(ev_branch), .event_mispredict(ev_mispredict),
      .msip(msip), .mtip(mtip), .meip(meip), .icache_inv(icache_inv));
    bus_decoder #(.SDRAM_BYTES(SDRAM ? platform_pkg::SDRAM_BYTES : 64'h0),
                  .ACCEL_BYTES(ACCEL_N != 0 ? platform_pkg::ACCELERATOR_BYTES : 64'h0)) decoder(.clk(clk), .rst(rst),
      .req_valid(dreq_valid), .req_ready(dreq_ready), .req(dreq),
      .rsp_valid(drsp_valid), .rsp_ready(drsp_ready), .rsp(drsp),
      .ram_req_valid(ram_dreq_valid), .ram_req_ready(ram_dreq_ready), .ram_req(ram_dreq),
      .ram_rsp_valid(ram_drsp_valid), .ram_rsp_ready(ram_drsp_ready), .ram_rsp(ram_drsp),
      .mmio_req_valid(mmio_req_valid), .mmio_req_ready(mmio_req_ready), .mmio_req(mmio_req),
      .mmio_rsp_valid(mmio_rsp_valid), .mmio_rsp_ready(mmio_rsp_ready), .mmio_rsp(mmio_rsp),
      .sdram_req_valid(sd_dreq_valid), .sdram_req_ready(sd_dreq_ready), .sdram_req(sd_dreq),
      .sdram_rsp_valid(sd_drsp_valid), .sdram_rsp_ready(sd_drsp_ready), .sdram_rsp(sd_drsp),
      .accel_req_valid(acc_req_valid), .accel_req_ready(acc_req_ready), .accel_req(acc_req),
      .accel_rsp_valid(acc_rsp_valid), .accel_rsp_ready(acc_rsp_ready), .accel_rsp(acc_rsp));
    bus_arbiter arbiter(.clk(clk), .rst(rst),
      .m0_req_valid(ram_dreq_valid), .m0_req_ready(ram_dreq_ready), .m0_req(ram_dreq),
      .m0_rsp_valid(ram_drsp_valid), .m0_rsp_ready(ram_drsp_ready), .m0_rsp(ram_drsp),
      .m1_req_valid(ram_ireq_valid), .m1_req_ready(ram_ireq_ready), .m1_req(ram_ireq),
      .m1_rsp_valid(ram_irsp_valid), .m1_rsp_ready(ram_irsp_ready), .m1_rsp(ram_irsp),
      .req_valid(req_valid), .req_ready(req_ready), .req(req),
      .rsp_valid(rsp_valid), .rsp_ready(rsp_ready), .rsp(rsp));

    if (CACHE) begin : caches
      bus_req_t sd_ireq, unused_mmio_req, unused_accel_req;
      bus_rsp_t sd_irsp;
      bus2_req_t ic_mreq, dc_mreq;
      bus2_rsp_t ic_mrsp, dc_mrsp;
      logic sd_ireq_valid, sd_ireq_ready, sd_irsp_valid, sd_irsp_ready, unused_mmio_valid, unused_mmio_rsp_ready;
      logic unused_accel_valid, unused_accel_rsp_ready;
      logic ic_mreq_valid, ic_mreq_ready, ic_mrsp_valid, ic_mrsp_ready;
      logic dc_mreq_valid, dc_mreq_ready, dc_mrsp_valid, dc_mrsp_ready;
      bus_decoder #(.MMIO_BYTES(64'h0), .SDRAM_BYTES(platform_pkg::SDRAM_BYTES)) fetch_decoder(.clk(clk), .rst(rst),
        .req_valid(ireq_valid), .req_ready(ireq_ready), .req(ireq),
        .rsp_valid(irsp_valid), .rsp_ready(irsp_ready), .rsp(irsp),
        .ram_req_valid(ram_ireq_valid), .ram_req_ready(ram_ireq_ready), .ram_req(ram_ireq),
        .ram_rsp_valid(ram_irsp_valid), .ram_rsp_ready(ram_irsp_ready), .ram_rsp(ram_irsp),
        .mmio_req_valid(unused_mmio_valid), .mmio_req_ready(1'b0), .mmio_req(unused_mmio_req),
        .mmio_rsp_valid(1'b0), .mmio_rsp_ready(unused_mmio_rsp_ready), .mmio_rsp('0),
        .sdram_req_valid(sd_ireq_valid), .sdram_req_ready(sd_ireq_ready), .sdram_req(sd_ireq),
        .sdram_rsp_valid(sd_irsp_valid), .sdram_rsp_ready(sd_irsp_ready), .sdram_rsp(sd_irsp),
        .accel_req_valid(unused_accel_valid), .accel_req_ready(1'b0), .accel_req(unused_accel_req),
        .accel_rsp_valid(1'b0), .accel_rsp_ready(unused_accel_rsp_ready), .accel_rsp('0));
      cache #(.BYTES(ICACHE_BYTES), .WRITES(0)) icache(.clk(clk), .rst(rst),
        .enable(icache_enable), .invalidate(icache_inv),
        .req_valid(sd_ireq_valid), .req_ready(sd_ireq_ready), .req(sd_ireq),
        .rsp_valid(sd_irsp_valid), .rsp_ready(sd_irsp_ready), .rsp(sd_irsp),
        .mreq_valid(ic_mreq_valid), .mreq_ready(ic_mreq_ready), .mreq(ic_mreq),
        .mrsp_valid(ic_mrsp_valid), .mrsp_ready(ic_mrsp_ready), .mrsp(ic_mrsp),
        .ev_access(ev_i_access), .ev_miss(ev_i_miss), .ev_bypass(ev_i_uncached), .ev_write());
      cache #(.BYTES(DCACHE_BYTES), .WRITES(1)) dcache(.clk(clk), .rst(rst),
        .enable(dcache_enable), .invalidate(1'b0),
        .req_valid(sd_dreq_valid), .req_ready(sd_dreq_ready), .req(sd_dreq),
        .rsp_valid(sd_drsp_valid), .rsp_ready(sd_drsp_ready), .rsp(sd_drsp),
        .mreq_valid(dc_mreq_valid), .mreq_ready(dc_mreq_ready), .mreq(dc_mreq),
        .mrsp_valid(dc_mrsp_valid), .mrsp_ready(dc_mrsp_ready), .mrsp(dc_mrsp),
        .ev_access(ev_d_access), .ev_miss(ev_d_miss), .ev_bypass(ev_d_uncached), .ev_write(ev_d_write));
      burst_arbiter sdram_arbiter(.clk(clk), .rst(rst),
        .m0_req_valid(dc_mreq_valid), .m0_req_ready(dc_mreq_ready), .m0_req(dc_mreq),
        .m0_rsp_valid(dc_mrsp_valid), .m0_rsp_ready(dc_mrsp_ready), .m0_rsp(dc_mrsp),
        .m1_req_valid(ic_mreq_valid), .m1_req_ready(ic_mreq_ready), .m1_req(ic_mreq),
        .m1_rsp_valid(ic_mrsp_valid), .m1_rsp_ready(ic_mrsp_ready), .m1_rsp(ic_mrsp),
        .req_valid(sdram_req_valid), .req_ready(sdram_req_ready), .req(sdram_req),
        .rsp_valid(sdram_rsp_valid), .rsp_ready(sdram_rsp_ready), .rsp(sdram_rsp));
    end else begin : no_caches
      assign ram_ireq_valid = ireq_valid;
      assign ireq_ready = ram_ireq_ready;
      assign ram_ireq = ireq;
      assign irsp_valid = ram_irsp_valid;
      assign ram_irsp_ready = irsp_ready;
      assign irsp = ram_irsp;
      assign sdram_req_valid = sd_dreq_valid;
      assign sd_dreq_ready = sdram_req_ready;
      assign sdram_req = to_bus2(sd_dreq);
      assign sd_drsp_valid = sdram_rsp_valid;
      assign sdram_rsp_ready = sd_drsp_ready;
      assign sd_drsp = to_bus1(sdram_rsp);
      assign {ev_i_access, ev_i_miss, ev_i_uncached, ev_d_access, ev_d_miss, ev_d_uncached, ev_d_write} = '0;
    end

    mmio_bus peripherals(.clk(clk), .rst(rst),
      .req_valid(mmio_req_valid), .req_ready(mmio_req_ready), .req(mmio_req),
      .rsp_valid(mmio_rsp_valid), .rsp_ready(mmio_rsp_ready), .rsp(mmio_rsp),
      .dev_sel(dev_sel), .dev_acc(dev_acc), .dev_wr(dev_wr), .dev_offset(dev_offset),
      .dev_wdata(dev_wdata), .dev_mask(dev_mask),
      .uart_rdata(uart_rdata), .timer_rdata(timer_rdata), .counter_rdata(counter_rdata),
      .cache_rdata(cache_rdata), .intc_rdata(intc_rdata), .dev_ok(dev_ok));
    uart #(.DIVISOR(UART_DIVISOR)) serial(.clk(clk), .rst(rst), .acc(dev_acc && dev_sel[0]), .wr(dev_wr),
      .offset(dev_offset), .wdata(dev_wdata), .mask(dev_mask), .rdata(uart_rdata), .ok(dev_ok[0]),
      .irq(uart_irq), .tx(uart_tx), .rx(uart_rx));
    timer machine_timer(.clk(clk), .rst(rst), .acc(dev_acc && dev_sel[1]), .wr(dev_wr),
      .offset(dev_offset), .wdata(dev_wdata), .mask(dev_mask), .rdata(timer_rdata), .ok(dev_ok[1]),
      .msip(msip), .mtip(mtip));
    perf_counters counters(.clk(clk), .rst(rst), .acc(dev_acc && dev_sel[2]), .wr(dev_wr),
      .offset(dev_offset), .wdata(dev_wdata), .mask(dev_mask), .rdata(counter_rdata), .ok(dev_ok[2]),
      .ev_retired(event_retired), .ev_mem_wait(event_mem_wait), .ev_arith_wait(event_arith_wait),
      .ev_fetch_wait(event_fetch_wait), .ev_load_use(event_load_use), .ev_redirect(event_redirect),
      .ev_i_access(ev_i_access), .ev_i_miss(ev_i_miss), .ev_i_uncached(ev_i_uncached),
      .ev_d_access(ev_d_access), .ev_d_miss(ev_d_miss), .ev_d_uncached(ev_d_uncached), .ev_d_write(ev_d_write),
      .ev_branch(ev_branch), .ev_mispredict(ev_mispredict));
    cache_regs #(.PRESENT(CACHE), .ICACHE_BYTES(ICACHE_BYTES), .DCACHE_BYTES(DCACHE_BYTES)) cache_control(
      .clk(clk), .rst(rst), .acc(dev_acc && dev_sel[3]), .wr(dev_wr),
      .offset(dev_offset), .wdata(dev_wdata), .mask(dev_mask), .rdata(cache_rdata), .ok(dev_ok[3]),
      .enable_init(cache_enable_init), .icache_enable(icache_enable), .dcache_enable(dcache_enable));
    logic [1:0] irq_sources;
    always_comb begin
      irq_sources = '0;
      irq_sources[platform_pkg::INTERRUPTS_UART] = uart_irq;
      irq_sources[platform_pkg::INTERRUPTS_ACCELERATOR] = accel_irq;
    end
    irq_ctrl #(.SOURCES(2)) interrupt_controller(.clk(clk), .rst(rst), .acc(dev_acc && dev_sel[4]), .wr(dev_wr),
      .offset(dev_offset), .wdata(dev_wdata), .mask(dev_mask), .rdata(intc_rdata), .ok(dev_ok[4]),
      .sources(irq_sources), .meip(meip));
    if (ACCEL_N != 0) begin : accelerator
      matrix_accel #(.N(ACCEL_N), .PARALLEL(ACCEL_PARALLEL)) accel(.clk(clk), .rst(rst),
        .req_valid(acc_req_valid), .req_ready(acc_req_ready), .req(acc_req),
        .rsp_valid(acc_rsp_valid), .rsp_ready(acc_rsp_ready), .rsp(acc_rsp), .irq(accel_irq));
    end else begin : no_accelerator
      assign acc_req_ready = 0;
      assign acc_rsp_valid = 0;
      assign acc_rsp = '0;
      assign accel_irq = 0;
    end
  end else begin : multicycle
    core_multicycle core(.clk(clk), .rst(rst), .req_valid(req_valid), .req_ready(req_ready), .req(req),
      .rsp_valid(rsp_valid), .rsp_ready(rsp_ready), .rsp(rsp),
      .trace_valid(trace_valid), .trace(trace), .halted(halted),
      .event_retired(event_retired), .event_mem_wait(event_mem_wait), .event_arith_wait(event_arith_wait));
    assign event_fetch_wait = 0;
    assign event_load_use = 0;
    assign event_redirect = 0;
    assign uart_tx = 1;
    assign sdram_req_valid = 0;
    assign sdram_req = '0;
    assign sdram_rsp_ready = 0;
  end endgenerate
  onchip_ram ram(.clk(clk), .rst(rst), .req_valid(req_valid), .req_ready(req_ready), .req(req),
    .rsp_valid(rsp_valid), .rsp_ready(rsp_ready), .rsp(rsp),
    .loader_we(loader_we), .loader_word(loader_word), .loader_data(loader_data));
endmodule
