interface bus_if (input logic clk, input logic rst);
  logic req_valid, req_ready, rsp_valid, rsp_ready;
  soc_pkg::bus_req_t req;
  soc_pkg::bus_rsp_t rsp;
  assert property (@(posedge clk) disable iff (rst) req_valid && !req_ready |=> req_valid && $stable(req))
    else $error("bus_if: request changed under backpressure");
  assert property (@(posedge clk) disable iff (rst) rsp_valid && !rsp_ready |=> rsp_valid && $stable(rsp))
    else $error("bus_if: response changed under backpressure");
  assert property (@(posedge clk) rst |-> !req_valid && !rsp_ready)
    else $error("bus_if: master active in reset");
endinterface

interface retire_if (input logic clk, input logic rst);
  logic trace_valid, halted;
  soc_pkg::retire_t trace;
  logic event_retired, event_mem_wait, event_arith_wait;
  logic event_fetch_wait, event_load_use, event_redirect;
  assert property (@(posedge clk) disable iff (rst) trace_valid && trace.rd == 0 |-> trace.rd_data == 0)
    else $error("retire_if: nonzero x0 value");
  assert property (@(posedge clk) disable iff (rst) halted |=> !trace_valid)
    else $error("retire_if: retirement after halt");
endinterface
