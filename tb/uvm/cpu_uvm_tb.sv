`timescale 1ns/1ps
module cpu_uvm_tb;
  import uvm_pkg::*;
  import cpu_uvm_pkg::*;
  logic clk = 0, rst = 1;
  always #5 clk = ~clk;
  always @(negedge clk) rst <= cpu_uvm_ctrl::rst_request;
  bus_if ibus(clk, rst);
  bus_if dbus(clk, rst);
  retire_if ret(clk, rst);
`ifdef MULTICYCLE
  core_multicycle dut(.clk(clk), .rst(rst),
    .req_valid(ibus.req_valid), .req_ready(ibus.req_ready), .req(ibus.req),
    .rsp_valid(ibus.rsp_valid), .rsp_ready(ibus.rsp_ready), .rsp(ibus.rsp),
    .trace_valid(ret.trace_valid), .trace(ret.trace), .halted(ret.halted),
    .event_retired(ret.event_retired), .event_mem_wait(ret.event_mem_wait), .event_arith_wait(ret.event_arith_wait));
  assign ret.event_fetch_wait = 0;
  assign ret.event_load_use = 0;
  assign ret.event_redirect = 0;
  assign dbus.req_valid = 0;
  assign dbus.rsp_ready = 0;
  assign dbus.req = '0;
  assign dbus.req_ready = 0;
  assign dbus.rsp_valid = 0;
  assign dbus.rsp = '0;
  localparam bit UNIFIED = 1;
`else
  core_pipeline dut(.clk(clk), .rst(rst),
    .ireq_valid(ibus.req_valid), .ireq_ready(ibus.req_ready), .ireq(ibus.req),
    .irsp_valid(ibus.rsp_valid), .irsp_ready(ibus.rsp_ready), .irsp(ibus.rsp),
    .dreq_valid(dbus.req_valid), .dreq_ready(dbus.req_ready), .dreq(dbus.req),
    .drsp_valid(dbus.rsp_valid), .drsp_ready(dbus.rsp_ready), .drsp(dbus.rsp),
    .trace_valid(ret.trace_valid), .trace(ret.trace), .halted(ret.halted),
    .event_retired(ret.event_retired), .event_mem_wait(ret.event_mem_wait), .event_arith_wait(ret.event_arith_wait),
    .event_fetch_wait(ret.event_fetch_wait), .event_load_use(ret.event_load_use), .event_redirect(ret.event_redirect),
    .msip(1'b0), .mtip(1'b0), .meip(1'b0), .icache_inv());
  localparam bit UNIFIED = 0;
  assert property (@(posedge clk) disable iff (rst) dut.md_start |-> !dut.md_busy)
    else $error("pipeline: M start while unit busy");
  assert property (@(posedge clk) disable iff (rst) dut.md_done |-> dut.ex_md && dut.ex_md_started && !dut.ex_md_have_q)
    else $error("pipeline: M completion without its EX instruction");
  assert property (@(posedge clk) disable iff (rst) dut.md_wait |-> !dut.ex_go && !dut.ex_take)
    else $error("pipeline: younger work passed a pending M operation");
  assert property (@(posedge clk) disable iff (rst) dut.dreq_valid |-> dut.mem_valid && !dut.mem_issued)
    else $error("pipeline: data request outside MEM issue");
`endif
  initial begin
    uvm_config_db#(virtual bus_if)::set(null, "uvm_test_top.env.fetch_agent", "vif", ibus);
    uvm_config_db#(virtual bus_if)::set(null, "uvm_test_top.env.data_agent", "vif", dbus);
    uvm_config_db#(virtual retire_if)::set(null, "*", "retire_vif", ret);
    uvm_config_db#(bit)::set(null, "uvm_test_top.env", "unified", UNIFIED);
    uvm_config_db#(bit)::set(null, "uvm_test_top", "unified", UNIFIED);
    run_test();
  end
endmodule
