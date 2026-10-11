import json
import shutil
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PAR, SEQ = "4,1", "4,0"

MUTANTS = {
    "unsigned_product": (PAR, "product[i][j] = a[i][k] * b[k][j];", "product[i][j] = $unsigned(a[i][k]) * $unsigned(b[k][j]);"),
    "product_zero_extended": (PAR, "{{16{product[i][j][15]}}, product[i][j]}", "{16'b0, product[i][j]}"),
    "b_transposed": (PAR, "product[i][j] = a[i][k] * b[k][j];", "product[i][j] = a[i][k] * b[j][k];"),
    "c_always_added": (PAR, "for (int i = 0; i < N; i++) for (int j = 0; j < N; j++) d[i][j] <= new_acc ? c[i][j] : 32'sd0;",
                       "for (int i = 0; i < N; i++) for (int j = 0; j < N; j++) d[i][j] <= c[i][j];"),
    "c_never_added": (PAR, "for (int i = 0; i < N; i++) for (int j = 0; j < N; j++) d[i][j] <= new_acc ? c[i][j] : 32'sd0;",
                      "for (int i = 0; i < N; i++) for (int j = 0; j < N; j++) d[i][j] <= 32'sd0;"),
    "one_step_short": (PAR, "assign step_last = k == IDX'(N - 1);", "assign step_last = k == IDX'(N - 2);"),
    "seq_unsigned_product": (SEQ, "assign product = a[i][k] * b[k][j];", "assign product = $unsigned(a[i][k]) * $unsigned(b[k][j]);"),
    "seq_wrong_loop_order": (SEQ, "          if (j == IDX'(N - 1)) i <= i + 1'b1;", "          i <= i + 1'b1;"),
    "seq_one_step_short": (SEQ, "assign step_last = i == IDX'(N - 1) && j == IDX'(N - 1) && k == IDX'(N - 1);",
                           "assign step_last = i == IDX'(N - 1) && j == IDX'(N - 1) && k == IDX'(N - 2);"),
    "a_row_bytes_reversed": (PAR, "K_A: for (int x = 0; x < N; x++) a[word[h][IDX-1:0]][x] <= wword[h][8*x +: 8];",
                             "K_A: for (int x = 0; x < N; x++) a[word[h][IDX-1:0]][N-1-x] <= wword[h][8*x +: 8];"),
    "high_word_uses_low_index": (PAR, "    word[1] = {offset[7:3], 1'b1};", "    word[1] = {offset[7:3], 1'b0};"),
    "row_bound_ignored": (PAR, "else if (offset[15:8] == 8'h01 && word[h] < N) kind[h] = K_A;", "else if (offset[15:8] == 8'h01) kind[h] = K_A;"),
    "byte_access_allowed": (PAR, "    bad = !(req.mask == 8'h0f || req.mask == 8'hf0 || req.mask == 8'hff);", "    bad = 0;"),
    "d_writable": (PAR, "      if (is_write && kind[h] == K_D) bad = 1;\n", ""),
    "write_while_busy_allowed": (PAR, "      if (is_write && busy && (kind[h] == K_A || kind[h] == K_B || kind[h] == K_C)) bad = 1;\n", ""),
    "start_while_busy_restarts": (PAR, "assign start = ctrl_write && req.wdata[0] && !busy;", "assign start = ctrl_write && req.wdata[0];"),
    "start_ignored_not_flagged": (PAR, "        if (req.wdata[0] && busy) start_ignored <= 1;\n", ""),
    "done_cleared_by_wrong_bit": (PAR, "        if (req.wdata[1]) done <= 0;", "        if (req.wdata[2]) done <= 0;"),
    "done_clear_beats_completion": (PAR, "if (step_last) begin busy <= 0; done <= 1; end",
                                    "if (step_last) begin busy <= 0; done <= !(status_write && req.wdata[1]); end"),
    "irq_ignores_enable": (PAR, "  assign irq = done && ie;", "  assign irq = done;"),
    "cycles_not_cleared": (PAR, "        busy <= 1; done <= 0; cycles <= 0;", "        busy <= 1; done <= 0;"),
    "reset_keeps_busy": (PAR, "      busy <= 0; done <= 0; start_ignored <= 0;", "      done <= 0; start_ignored <= 0;"),
}

def main():
    out = ROOT / "build/accel_mutants"
    if out.exists():
        shutil.rmtree(out)
    source = (ROOT / "rtl/peripherals/matrix_accel.sv").read_text()
    configs = {}
    for name, (config, old, new) in MUTANTS.items():
        if source.count(old) != 1:
            raise AssertionError(f"Mutation anchor for {name} not unique in matrix_accel.sv")
        folder = out / name
        folder.mkdir(parents=True)
        (folder / "matrix_accel.sv").write_text(source.replace(old, new))
        configs[name] = config
    (out / "mutants.json").write_text(json.dumps([{"name": k, "n": int(v.split(",")[0]), "parallel": int(v.split(",")[1])}
                                                  for k, v in sorted(configs.items())], indent=2) + "\n")
    print(f"MUTANTS: {len(MUTANTS)} accelerator copies in {out}")

if __name__ == "__main__":
    main()
