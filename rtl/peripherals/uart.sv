module uart #(
  parameter int FIFO_DEPTH = 8,
  parameter logic [15:0] DIVISOR = 16'd434
) (
  input logic clk, rst,
  input logic acc, wr,
  input logic [7:0] offset,
  input logic [63:0] wdata,
  input logic [7:0] mask,
  output logic [63:0] rdata,
  output logic ok,
  output logic irq,
  output logic tx,
  input logic rx
);
  localparam int AW = $clog2(FIFO_DEPTH);
  logic [7:0] tx_fifo [0:FIFO_DEPTH-1];
  logic [7:0] rx_fifo [0:FIFO_DEPTH-1];
  logic [AW:0] tx_count, rx_count;
  logic [AW-1:0] tx_head, tx_tail, rx_head, rx_tail;
  logic [15:0] divisor;
  logic [1:0] ctrl;
  logic overrun, frame_error, dropped;
  logic tx_full, tx_busy, tx_idle, rx_valid;
  logic [9:0] tx_shift;
  logic [3:0] tx_bits;
  logic [15:0] tx_timer, tx_div;
  logic rx_meta, rx_sync;
  logic rx_busy;
  logic [3:0] rx_bits;
  logic [15:0] rx_timer, rx_div;
  logic [7:0] rx_shift;
  logic push_tx, pop_rx, rx_push;

  assign tx_full = tx_count == FIFO_DEPTH;
  assign tx_idle = tx_count == 0 && !tx_busy;
  assign rx_valid = rx_count != 0;
  assign irq = (ctrl[0] && rx_valid) || (ctrl[1] && tx_idle);
  assign push_tx = acc && wr && offset == 8'h00 && mask[0] && !tx_full;
  assign pop_rx = acc && !wr && offset == 8'h08 && rx_valid;
  assign rx_push = rx_busy && rx_timer == 0 && rx_bits == 4'd9 && rx_sync;

  always_comb begin
    ok = 1; rdata = 0;
    case (offset)
      8'h00: rdata = 0;
      8'h08: rdata = rx_valid ? {55'b0, 1'b1, rx_fifo[rx_head]} : 64'b0;
      8'h10: rdata = {58'b0, dropped, frame_error, overrun, rx_valid, tx_idle, tx_full};
      8'h18: rdata = {62'b0, ctrl};
      8'h20: rdata = {48'b0, divisor};
      default: ok = 0;
    endcase
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      tx_count <= 0; rx_count <= 0; tx_head <= 0; tx_tail <= 0; rx_head <= 0; rx_tail <= 0;
      divisor <= DIVISOR; ctrl <= 0; overrun <= 0; frame_error <= 0; dropped <= 0;
      tx <= 1; tx_busy <= 0; tx_shift <= '1; tx_bits <= 0; tx_timer <= 0; tx_div <= DIVISOR;
      rx_meta <= 1; rx_sync <= 1; rx_busy <= 0; rx_bits <= 0; rx_timer <= 0; rx_shift <= 0; rx_div <= DIVISOR;
    end else begin
      if (acc && wr) begin
        if (offset == 8'h00 && mask[0] && tx_full) dropped <= 1;
        if (offset == 8'h10 && mask[0]) begin
          if (wdata[3]) overrun <= 0;
          if (wdata[4]) frame_error <= 0;
          if (wdata[5]) dropped <= 0;
        end
        if (offset == 8'h18 && mask[0]) ctrl <= wdata[1:0];
        if (offset == 8'h20) begin
          if (mask[0]) divisor[7:0] <= wdata[7:0];
          if (mask[1]) divisor[15:8] <= wdata[15:8];
        end
      end
      if (push_tx) begin tx_fifo[tx_tail] <= wdata[7:0]; tx_tail <= tx_tail + 1'b1; end
      if (!tx_busy && tx_count != 0) begin
        tx_shift <= {1'b1, tx_fifo[tx_head], 1'b0};
        tx_head <= tx_head + 1'b1;
        tx_busy <= 1; tx_bits <= 4'd10; tx_timer <= 0;
        tx_div <= divisor < 16'd4 ? 16'd4 : divisor;
      end else if (tx_busy) begin
        if (tx_timer == 0) begin
          if (tx_bits == 0) begin tx_busy <= 0; tx <= 1; end
          else begin
            tx <= tx_shift[0]; tx_shift <= {1'b1, tx_shift[9:1]};
            tx_bits <= tx_bits - 4'd1; tx_timer <= tx_div - 16'd1;
          end
        end else tx_timer <= tx_timer - 16'd1;
      end
      tx_count <= tx_count + (push_tx ? 1'b1 : 1'b0) - (!tx_busy && tx_count != 0 ? 1'b1 : 1'b0);
      rx_meta <= rx; rx_sync <= rx_meta;
      if (!rx_busy) begin
        if (!rx_sync) begin
          rx_busy <= 1; rx_bits <= 0; rx_div <= divisor < 16'd4 ? 16'd4 : divisor;
          rx_timer <= ((divisor < 16'd4 ? 16'd4 : divisor) >> 1) - 16'd1;
        end
      end else if (rx_timer == 0) begin
        rx_timer <= rx_div - 16'd1;
        if (rx_bits == 0) begin
          if (rx_sync) rx_busy <= 0;
          else rx_bits <= 1;
        end else if (rx_bits <= 8) begin
          rx_shift <= {rx_sync, rx_shift[7:1]};
          rx_bits <= rx_bits + 4'd1;
        end else begin
          rx_busy <= 0;
          if (!rx_sync) frame_error <= 1;
        end
      end else rx_timer <= rx_timer - 16'd1;
      if (rx_push) begin
        if (rx_count == FIFO_DEPTH) overrun <= 1;
        else begin rx_fifo[rx_tail] <= rx_shift; rx_tail <= rx_tail + 1'b1; end
      end
      if (pop_rx) rx_head <= rx_head + 1'b1;
      rx_count <= rx_count + (rx_push && rx_count != FIFO_DEPTH ? 1'b1 : 1'b0) - (pop_rx ? 1'b1 : 1'b0);
    end
  end
endmodule
