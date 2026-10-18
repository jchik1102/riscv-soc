"""Write mutants of rtl/peripherals/fir_filter.sv for scripts/run_fir.ps1.

Each mutant is one deliberate defect; the unit bench (tb/unit/fir_tb.sv with
the MATLAB cases) must fail on every one. Mutants run with LANES=4 unless a
different value is given. Output: build/fir_mutants/<name>/fir_filter.sv and
build/fir_mutants/mutants.json.
"""
import json
import shutil
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

ROUND = "    r = (a + HALF) >>> 15;"
PRODUCT = "      p = h[step * LANES + l] * x[step * LANES + l];"
HOLD = "    hold = busy && !bad && (kind == R_DATA || kind == R_COEFF || kind == R_CTRL);"
MUTANTS = {
    "no_rounding": (ROUND, "    r = a >>> 15;"),
    "ties_round_down": (ROUND, "    r = (a + HALF - 1) >>> 15;"),
    "no_positive_saturation": ("    if (r > Y_MAX) return 16'sh7fff;\n", ""),
    "no_negative_saturation": ("    if (r < Y_MIN) return 16'sh8000;\n", ""),
    "accumulator_32_bits": ("  localparam int ACC = 32 + $clog2(TAPS) + 1;", "  localparam int ACC = 32;"),
    "unsigned_product": (PRODUCT, "      p = $unsigned(h[step * LANES + l]) * $unsigned(x[step * LANES + l]);"),
    "lanes_misaligned": (PRODUCT, "      p = h[step * LANES + l] * x[step * LANES + (LANES - 1 - l)];"),
    "delay_line_not_shifted": ("              for (int k = 1; k < TAPS; k++) x[k] <= x[k-1];\n", ""),
    "oldest_tap_dropped": ("              for (int k = 1; k < TAPS; k++) x[k] <= x[k-1];",
                           "              for (int k = 1; k < TAPS - 1; k++) x[k] <= x[k-1];"),
    "one_step_short": ("        if (step == SW'(STEPS - 1)) begin", "        if (step == SW'(STEPS - 2)) begin"),
    "accumulator_not_cleared": ("              busy <= 1; step <= '0; acc <= '0;", "              busy <= 1; step <= '0;"),
    "no_hold_while_busy": ("  assign req_ready = !rst && !rsp_valid && !hold;", "  assign req_ready = !rst && !rsp_valid;"),
    "coeff_write_not_held": (HOLD, "    hold = busy && !bad && (kind == R_DATA || kind == R_CTRL);"),
    "status_held": (HOLD, "    hold = busy && !bad && (kind == R_DATA || kind == R_COEFF || kind == R_CTRL || kind == R_STATUS);"),
    "clear_keeps_delay_line": ("              for (int k = 0; k < TAPS; k++) x[k] <= '0;\n", ""),
    "byte_lanes_ignored": ("    if (req.write && req.mask[1:0] != 2'b11) bad = 1;\n", ""),
    "error_write_applied": ("        if (!bad && req.write) begin", "        if (req.write) begin"),
    "cycles_not_counted": ("        cycles <= cycles + 1;\n", ""),
}


def main():
    out = ROOT / "build/fir_mutants"
    if out.exists():
        shutil.rmtree(out)
    source = (ROOT / "rtl/peripherals/fir_filter.sv").read_text()
    listing = []
    for name, (old, new) in MUTANTS.items():
        if source.count(old) != 1:
            raise AssertionError(f"Mutation anchor for {name} not unique in fir_filter.sv")
        folder = out / name
        folder.mkdir(parents=True)
        (folder / "fir_filter.sv").write_text(source.replace(old, new))
        listing.append({"name": name, "lanes": 4})
    (out / "mutants.json").write_text(json.dumps(listing, indent=1) + "\n")
    print(f"FIR mutants: {len(listing)}")


if __name__ == "__main__":
    main()
