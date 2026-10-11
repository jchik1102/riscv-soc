module matrix_accel #(
  parameter int N = 4,
  parameter bit PARALLEL = 1,
  parameter logic [63:0] BASE = platform_pkg::ACCELERATOR_BASE
) (
  input logic clk, rst,
  input logic req_valid,
  output logic req_ready,
  input soc_pkg::bus_req_t req,
  output logic rsp_valid,
  input logic rsp_ready,
  output soc_pkg::bus_rsp_t rsp,
  output logic irq
);
  localparam int L = PARALLEL ? N : N * N * N;
  localparam int IDX = $clog2(N);
  localparam logic [63:0] INFO = {24'b0, 8'd1, 16'(L), 8'(PARALLEL ? N * N : 1), 8'(N)};
  // synthesis translate_off
  initial if (N != 2 && N != 4) $fatal(1, "matrix_accel: N must be 2 or 4");
  // synthesis translate_on

  logic signed [7:0] a [N][N];
  logic signed [7:0] b [N][N];
  logic signed [31:0] c [N][N];
  logic signed [31:0] d [N][N];
  logic busy, done, start_ignored, ie, acc_c;
  logic [15:0] cycles;

  typedef enum logic [2:0] {K_NONE, K_CTRL, K_A, K_B, K_C, K_D} kind_t;
  logic [15:0] offset;
  kind_t kind [2];
  logic [5:0] word [2];
  logic [1:0] reg_index;
  logic sel [2];
  logic accept, bad, is_write;
  assign offset = 16'(req.addr - BASE);
  always_comb begin
    sel[0] = req.mask[3:0] == 4'hf;
    sel[1] = req.mask[7:4] == 4'hf;
    word[0] = {offset[7:3], 1'b0};
    word[1] = {offset[7:3], 1'b1};
    for (int h = 0; h < 2; h++) begin
      if (offset[15:5] == 0) kind[h] = K_CTRL;
      else if (offset[15:8] == 8'h01 && word[h] < N) kind[h] = K_A;
      else if (offset[15:8] == 8'h02 && word[h] < N) kind[h] = K_B;
      else if (offset[15:8] == 8'h03 && word[h] < N * N) kind[h] = K_C;
      else if (offset[15:8] == 8'h04 && word[h] < N * N) kind[h] = K_D;
      else kind[h] = K_NONE;
    end
    reg_index = offset[4:3];
    is_write = req.write;
    bad = !(req.mask == 8'h0f || req.mask == 8'hf0 || req.mask == 8'hff);
    for (int h = 0; h < 2; h++) if (sel[h]) begin
      if (kind[h] == K_NONE) bad = 1;
      if (is_write && kind[h] == K_D) bad = 1;
      if (is_write && busy && (kind[h] == K_A || kind[h] == K_B || kind[h] == K_C)) bad = 1;
    end
  end
  assign req_ready = !rst && !rsp_valid;
  assign accept = req_valid && req_ready;

  logic [63:0] regv;
  logic [31:0] rword [2];
  always_comb begin
    case (reg_index)
      2'd0: regv = {61'b0, acc_c, ie, 1'b0};
      2'd1: regv = {61'b0, start_ignored, done, busy};
      2'd2: regv = INFO;
      default: regv = {48'b0, cycles};
    endcase
    for (int h = 0; h < 2; h++) begin
      rword[h] = 0;
      case (kind[h])
        K_CTRL: rword[h] = h ? regv[63:32] : regv[31:0];
        K_A: for (int x = 0; x < N; x++) rword[h][8*x +: 8] = a[word[h][IDX-1:0]][x];
        K_B: for (int x = 0; x < N; x++) rword[h][8*x +: 8] = b[word[h][IDX-1:0]][x];
        K_C: rword[h] = c[word[h][2*IDX-1:IDX]][word[h][IDX-1:0]];
        K_D: rword[h] = d[word[h][2*IDX-1:IDX]][word[h][IDX-1:0]];
        default: rword[h] = 0;
      endcase
      if (!sel[h]) rword[h] = 0;
    end
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      rsp_valid <= 0; rsp <= '0;
    end else begin
      if (rsp_valid && rsp_ready) rsp_valid <= 0;
      if (accept) begin
        rsp_valid <= 1;
        rsp.error <= bad;
        rsp.rdata <= bad || is_write ? 64'b0 : {rword[1], rword[0]};
      end
    end
  end

  logic do_write, ctrl_write, status_write, start;
  logic [31:0] wword [2];
  assign do_write = accept && is_write && !bad;
  assign wword[0] = req.wdata[31:0];
  assign wword[1] = req.wdata[63:32];
  assign ctrl_write = do_write && sel[0] && kind[0] == K_CTRL && reg_index == 2'd0;
  assign status_write = do_write && sel[0] && kind[0] == K_CTRL && reg_index == 2'd1;
  assign start = ctrl_write && req.wdata[0] && !busy;
  always_ff @(posedge clk) begin
    for (int h = 0; h < 2; h++) if (do_write && sel[h]) begin
      case (kind[h])
        K_A: for (int x = 0; x < N; x++) a[word[h][IDX-1:0]][x] <= wword[h][8*x +: 8];
        K_B: for (int x = 0; x < N; x++) b[word[h][IDX-1:0]][x] <= wword[h][8*x +: 8];
        K_C: c[word[h][2*IDX-1:IDX]][word[h][IDX-1:0]] <= wword[h];
        default: begin end
      endcase
    end
  end

  logic step_last;
  logic new_acc;
  assign new_acc = req.wdata[2];
  always_ff @(posedge clk) begin
    if (rst) begin
      busy <= 0; done <= 0; start_ignored <= 0; ie <= 0; acc_c <= 0; cycles <= 0;
    end else begin
      if (status_write) begin
        if (req.wdata[1]) done <= 0;
        if (req.wdata[2]) start_ignored <= 0;
      end
      if (ctrl_write) begin
        ie <= req.wdata[1];
        acc_c <= req.wdata[2];
        if (req.wdata[0] && busy) start_ignored <= 1;
      end
      if (start) begin
        busy <= 1; done <= 0; cycles <= 0;
      end else if (busy) begin
        cycles <= cycles + 16'd1;
        if (step_last) begin busy <= 0; done <= 1; end
      end
    end
  end
  assign irq = done && ie;

  generate if (PARALLEL) begin : array
    logic [IDX-1:0] k;
    logic signed [15:0] product [N][N];
    always_comb
      for (int i = 0; i < N; i++)
        for (int j = 0; j < N; j++) product[i][j] = a[i][k] * b[k][j];
    assign step_last = k == IDX'(N - 1);
    always_ff @(posedge clk) begin
      if (rst) k <= 0;
      else if (start) k <= 0;
      else if (busy) k <= k + 1'b1;
    end
    always_ff @(posedge clk) begin
      if (start) begin
        for (int i = 0; i < N; i++) for (int j = 0; j < N; j++) d[i][j] <= new_acc ? c[i][j] : 32'sd0;
      end else if (busy && !rst) begin
        for (int i = 0; i < N; i++) for (int j = 0; j < N; j++) d[i][j] <= d[i][j] + {{16{product[i][j][15]}}, product[i][j]};
      end
    end
  end else begin : sequential
    logic [IDX-1:0] i, j, k;
    logic signed [15:0] product;
    assign product = a[i][k] * b[k][j];
    assign step_last = i == IDX'(N - 1) && j == IDX'(N - 1) && k == IDX'(N - 1);
    always_ff @(posedge clk) begin
      if (rst || start) begin
        i <= 0; j <= 0; k <= 0;
      end else if (busy) begin
        k <= k + 1'b1;
        if (k == IDX'(N - 1)) begin
          j <= j + 1'b1;
          if (j == IDX'(N - 1)) i <= i + 1'b1;
        end
      end
    end
    always_ff @(posedge clk) begin
      if (start) begin
        for (int r = 0; r < N; r++) for (int s = 0; s < N; s++) d[r][s] <= new_acc ? c[r][s] : 32'sd0;
      end else if (busy && !rst) begin
        d[i][j] <= d[i][j] + {{16{product[15]}}, product};
      end
    end
  end endgenerate
endmodule
