module decoder(input logic [31:0] insn, output core_pkg::decode_t dec);
  import core_pkg::*;
  logic valid_encoding;
  always_comb begin
    dec = '0;
    dec.kind = K_ILLEGAL;
    dec.alu_op = OP_ADD;
    dec.imm = {{52{insn[31]}}, insn[31:20]};
    valid_encoding = 1;
    case (insn[6:0])
      7'h13, 7'h1b: begin
        dec.kind = K_ALU; dec.use_imm = 1; dec.writes_rd = 1;
        dec.word_op = insn[6:0] == 7'h1b;
        case (insn[14:12])
          0: dec.alu_op = OP_ADD;
          2: begin dec.alu_op = OP_SLT; valid_encoding = !dec.word_op; end
          3: begin dec.alu_op = OP_SLTU; valid_encoding = !dec.word_op; end
          4: begin dec.alu_op = OP_XOR; valid_encoding = !dec.word_op; end
          6: begin dec.alu_op = OP_OR; valid_encoding = !dec.word_op; end
          7: begin dec.alu_op = OP_AND; valid_encoding = !dec.word_op; end
          1: begin
            dec.alu_op = OP_SLL;
            valid_encoding = dec.word_op ? insn[31:25] == 0 : insn[31:26] == 0;
          end
          5: begin
            dec.alu_op = insn[30] ? OP_SRA : OP_SRL;
            valid_encoding = dec.word_op ? (insn[31:25] == 0 || insn[31:25] == 7'h20) :
                                                   (insn[31:26] == 0 || insn[31:26] == 6'h10);
          end
          default: valid_encoding = 0;
        endcase
      end
      7'h33, 7'h3b: begin
        dec.kind = K_ALU; dec.writes_rd = 1;
        dec.word_op = insn[6:0] == 7'h3b;
        valid_encoding = insn[31:25] == 0;
        if (insn[31:25] == 7'h01) begin
          dec.kind = K_MULDIV;
          dec.md_op = md_op_t'(insn[14:12]);
          valid_encoding = !dec.word_op || insn[14:12] == 0 || insn[14];
        end else case (insn[14:12])
          0: begin
            dec.alu_op = insn[30] ? OP_SUB : OP_ADD;
            valid_encoding = insn[31:25] == 0 || insn[31:25] == 7'h20;
          end
          1: dec.alu_op = OP_SLL;
          2: begin dec.alu_op = OP_SLT; valid_encoding = valid_encoding && !dec.word_op; end
          3: begin dec.alu_op = OP_SLTU; valid_encoding = valid_encoding && !dec.word_op; end
          4: begin dec.alu_op = OP_XOR; valid_encoding = valid_encoding && !dec.word_op; end
          5: begin
            dec.alu_op = insn[30] ? OP_SRA : OP_SRL;
            valid_encoding = insn[31:25] == 0 || insn[31:25] == 7'h20;
          end
          6: begin dec.alu_op = OP_OR; valid_encoding = valid_encoding && !dec.word_op; end
          7: begin dec.alu_op = OP_AND; valid_encoding = valid_encoding && !dec.word_op; end
          default: valid_encoding = 0;
        endcase
      end
      7'h37, 7'h17: begin
        dec.kind = insn[6:0] == 7'h37 ? K_LUI : K_AUIPC;
        dec.imm = {{32{insn[31]}}, insn[31:12], 12'b0}; dec.writes_rd = 1;
      end
      7'h6f: begin
        dec.kind = K_JAL; dec.writes_rd = 1;
        dec.imm = {{43{insn[31]}},insn[31],insn[19:12],insn[20],insn[30:21],1'b0};
      end
      7'h67: begin dec.kind = K_JALR; dec.writes_rd = 1; valid_encoding = insn[14:12] == 0; end
      7'h63: begin
        dec.kind = K_BRANCH;
        dec.imm = {{51{insn[31]}},insn[31],insn[7],insn[30:25],insn[11:8],1'b0};
        valid_encoding = insn[14:12] != 2 && insn[14:12] != 3;
      end
      7'h03: begin dec.kind = K_LOAD; dec.writes_rd = 1; valid_encoding = insn[14:12] != 7; end
      7'h23: begin
        dec.kind = K_STORE; valid_encoding = insn[14:12] < 4;
        dec.imm = {{52{insn[31]}},insn[31:25],insn[11:7]};
      end
      7'h0f: begin dec.kind = K_FENCE; valid_encoding = insn[14:13] == 2'b00; end
      7'h73: begin
        if (insn == 32'h00000073) dec.kind = K_ECALL;
        else if (insn == 32'h00100073) dec.kind = K_EBREAK;
        else if (insn == 32'h30200073) dec.kind = K_MRET;
        else if (insn == 32'h10500073) dec.kind = K_WFI;
        else if (insn[13:12] != 2'b00) begin dec.kind = K_CSR; dec.writes_rd = 1; end
        else valid_encoding = 0;
      end
      default: valid_encoding = 0;
    endcase
    if (!valid_encoding) begin dec.kind = K_ILLEGAL; dec.writes_rd = 0; end
  end
endmodule
