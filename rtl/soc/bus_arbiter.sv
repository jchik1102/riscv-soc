module bus_arbiter (
  input logic clk, rst,
  input logic m0_req_valid,
  output logic m0_req_ready,
  input soc_pkg::bus_req_t m0_req,
  output logic m0_rsp_valid,
  input logic m0_rsp_ready,
  output soc_pkg::bus_rsp_t m0_rsp,
  input logic m1_req_valid,
  output logic m1_req_ready,
  input soc_pkg::bus_req_t m1_req,
  output logic m1_rsp_valid,
  input logic m1_rsp_ready,
  output soc_pkg::bus_rsp_t m1_rsp,
  output logic req_valid,
  input logic req_ready,
  output soc_pkg::bus_req_t req,
  input logic rsp_valid,
  output logic rsp_ready,
  input soc_pkg::bus_rsp_t rsp
);
  logic busy, owner, locked, lock_owner, grant;
  always_comb begin
    grant = locked ? lock_owner : !m0_req_valid;
    req_valid = !rst && !busy && (grant ? m1_req_valid : m0_req_valid);
    req = grant ? m1_req : m0_req;
    m0_req_ready = !rst && !busy && !grant && req_ready;
    m1_req_ready = !rst && !busy && grant && req_ready;
    m0_rsp_valid = busy && !owner && rsp_valid;
    m1_rsp_valid = busy && owner && rsp_valid;
    m0_rsp = rsp;
    m1_rsp = rsp;
    rsp_ready = !rst && busy && (owner ? m1_rsp_ready : m0_rsp_ready);
  end
  always_ff @(posedge clk) begin
    if (rst) begin
      busy <= 0; owner <= 0; locked <= 0; lock_owner <= 0;
    end else begin
      if (req_valid && req_ready) begin
        busy <= 1; owner <= grant; locked <= 0;
      end else if (req_valid) begin
        locked <= 1; lock_owner <= grant;
      end
      if (rsp_valid && rsp_ready) busy <= 0;
    end
  end
endmodule
