package core_pkg;
  typedef enum logic [3:0] {
    OP_ADD, OP_SUB, OP_SLL, OP_SLT, OP_SLTU,
    OP_XOR, OP_SRL, OP_SRA, OP_OR, OP_AND
  } alu_op_t;
  typedef enum logic [2:0] {
    MD_MUL = 3'd0, MD_MULH = 3'd1, MD_MULHSU = 3'd2, MD_MULHU = 3'd3,
    MD_DIV = 3'd4, MD_DIVU = 3'd5, MD_REM = 3'd6, MD_REMU = 3'd7
  } md_op_t;
  typedef enum logic [3:0] {
    K_ILLEGAL, K_ALU, K_LUI, K_AUIPC, K_JAL, K_JALR,
    K_BRANCH, K_LOAD, K_STORE, K_FENCE, K_ECALL, K_EBREAK, K_MULDIV,
    K_CSR, K_MRET, K_WFI
  } kind_t;
  typedef struct packed {
    kind_t kind;
    alu_op_t alu_op;
    md_op_t md_op;
    logic word_op;
    logic use_imm;
    logic writes_rd;
    logic [63:0] imm;
  } decode_t;
endpackage
