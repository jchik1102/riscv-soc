package soc_pkg;
  typedef struct packed {
    logic [63:0] addr;
    logic write;
    logic [7:0] mask;
    logic [63:0] wdata;
  } bus_req_t;
  typedef struct packed {
    logic [63:0] rdata;
    logic error;
  } bus_rsp_t;
  typedef struct packed {
    logic [63:0] addr;
    logic write;
    logic [7:0] mask;
    logic [63:0] wdata;
    logic [1:0] burst;
  } bus2_req_t;
  typedef struct packed {
    logic [63:0] rdata;
    logic error;
    logic last;
  } bus2_rsp_t;
  function automatic bus2_req_t to_bus2(input bus_req_t r);
    bus2_req_t v;
    v.addr = r.addr; v.write = r.write; v.mask = r.mask; v.wdata = r.wdata; v.burst = 2'd0;
    return v;
  endfunction
  function automatic bus_rsp_t to_bus1(input bus2_rsp_t r);
    bus_rsp_t v;
    v.rdata = r.rdata; v.error = r.error;
    return v;
  endfunction
  typedef struct packed {
    logic [63:0] order;
    logic [63:0] pc;
    logic [31:0] insn;
    logic [63:0] next_pc;
    logic [4:0] rd;
    logic [63:0] rd_data;
    logic [63:0] mem_addr;
    logic [7:0] mem_rmask;
    logic [7:0] mem_wmask;
    logic [63:0] mem_rdata;
    logic [63:0] mem_wdata;
    logic trap;
    logic [5:0] cause;
    logic intr;
  } retire_t;
endpackage
