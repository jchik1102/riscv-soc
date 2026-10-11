module boot_rom #(
  parameter int WORDS = 128,
  parameter INIT_FILE = "boot_words.hex"
) (
  input logic clk,
  input logic [$clog2(WORDS)-1:0] addr,
  output logic [63:0] q
);
  reg [63:0] rom [0:WORDS-1];
  initial $readmemh(INIT_FILE, rom);
  always_ff @(posedge clk) q <= rom[addr];
endmodule
