import json
import shutil
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FILES = ("core_pkg.sv", "mul_iter.sv", "div_iter.sv", "muldiv_unit.sv")

MUTANTS = {
    "mulh_no_signed_correction": ("mul_iter.sv", "default: finished = hi - correction;", "default: finished = hi;"),
    "mulhsu_rs2_treated_signed": ("mul_iter.sv", "b_signed = op == MD_MULH;", "b_signed = op == MD_MULH || op == MD_MULHSU;"),
    "mulw_low_half_not_sign_extended": ("mul_iter.sv", "{{32{lo[63]}}, lo[63:32]}", "{32'b0, lo[63:32]}"),
    "div_by_zero_quotient_negated": ("div_iter.sv", "quotient_out = divide_by_zero ? '1 : (negate_quotient ? -quotient : quotient);",
                                     "quotient_out = negate_quotient ? -quotient : quotient;"),
    "remainder_takes_divisor_sign": ("div_iter.sv", "negate_remainder <= is_signed && dividend_ext[63];",
                                     "negate_remainder <= is_signed && divisor_ext[63];"),
    "divuw_result_zero_extended": ("div_iter.sv", "result <= word_q ? {{32{selected[31]}}, selected[31:0]} : selected;",
                                   "result <= word_q ? {(want_remainder || negate_quotient) ? {32{selected[31]}} : 32'b0, selected[31:0]} : selected;"),
    "w_operands_not_extended": ("div_iter.sv", "dividend_ext = is_signed ? {{32{a[31]}}, a[31:0]} : {32'b0, a[31:0]};",
                                "dividend_ext = is_signed ? a : {32'b0, a[31:0]};"),
    "kill_ignored_by_multiplier": ("mul_iter.sv", "if (rst || kill) begin", "if (rst) begin"),
    "reset_keeps_divider_busy": ("div_iter.sv", "    if (rst || kill) begin\n      busy <= 0;", "    if (rst || kill) begin\n      busy <= busy;"),
    "done_pulse_repeated": ("mul_iter.sv", "      done <= 0;\n      if (!busy) begin", "      if (!busy) begin"),
    "unit_accepts_start_while_busy": ("muldiv_unit.sv", "assign accept = start && !busy;", "assign accept = start;"),
    "off_by_one_latency": ("div_iter.sv", "remaining <= word ? 7'd32 : 7'd64;", "remaining <= word ? 7'd33 : 7'd65;"),
}

def main():
    out = ROOT / "build/muldiv_mutants"
    if out.exists():
        shutil.rmtree(out)
    for name, (file, old, new) in MUTANTS.items():
        folder = out / name
        folder.mkdir(parents=True)
        for source in FILES:
            text = (ROOT / "rtl/core" / source).read_text()
            if source == file:
                if text.count(old) != 1:
                    raise AssertionError(f"Mutation anchor for {name} not unique in {source}")
                text = text.replace(old, new)
            (folder / source).write_text(text)
    (out / "mutants.json").write_text(json.dumps(sorted(MUTANTS), indent=2) + "\n")
    print(f"MUTANTS: {len(MUTANTS)} RTL copies in {out}")

if __name__ == "__main__":
    main()
