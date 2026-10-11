module load_store (
  input logic [2:0] funct3,
  input logic [63:0] address, store_data, read_data,
  output logic misaligned,
  output logic [7:0] mask,
  output logic [63:0] write_data, load_result
);
  logic [7:0] base_mask;
  logic [63:0] shifted_read, lane_mask;
  always_comb begin
    case (funct3[1:0])
      0: begin base_mask = 8'h01; misaligned = 0; end
      1: begin base_mask = 8'h03; misaligned = address[0] != 0; end
      2: begin base_mask = 8'h0f; misaligned = address[1:0] != 0; end
      3: begin base_mask = 8'hff; misaligned = address[2:0] != 0; end
    endcase
    mask = base_mask << address[2:0];
    lane_mask = 0;
    for (int i = 0; i < 8; i++) lane_mask[8*i +: 8] = {8{mask[i]}};
    write_data = (store_data << {address[2:0],3'b0}) & lane_mask;
    shifted_read = read_data >> {address[2:0],3'b0};
    case (funct3)
      0: load_result = {{56{shifted_read[7]}}, shifted_read[7:0]};
      1: load_result = {{48{shifted_read[15]}}, shifted_read[15:0]};
      2: load_result = {{32{shifted_read[31]}}, shifted_read[31:0]};
      3: load_result = shifted_read;
      4: load_result = {56'b0, shifted_read[7:0]};
      5: load_result = {48'b0, shifted_read[15:0]};
      6: load_result = {32'b0, shifted_read[31:0]};
      default: load_result = 0;
    endcase
  end
endmodule
