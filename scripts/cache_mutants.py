import json
import shutil
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

MUTANTS = {
    "hit_ignores_tag": ("  assign hit = cacheable && valid[index] && tags[index] == tag;", "  assign hit = cacheable && valid[index];"),
    "hit_ignores_region": ("  assign hit = cacheable && valid[index] && tags[index] == tag;", "  assign hit = valid[index] && tags[index] == tag;"),
    "tag_from_wrong_bits": ("  assign tag = offset[SPAN_BITS-1 -: TAG_BITS];", "  assign tag = offset[SPAN_BITS-2 -: TAG_BITS];"),
    "hit_returns_unselected_lanes": ("S_HIT: begin rsp_valid = 1; rsp.rdata = ram_q & op_lanes;", "S_HIT: begin rsp_valid = 1; rsp.rdata = ram_q;"),
    "fill_returns_wrong_beat": ("          if (fill_beat == op_beat) rsp_data <= mrsp.rdata & op_lanes;",
                                "          if (fill_beat == 2'd0) rsp_data <= mrsp.rdata & op_lanes;"),
    "fill_beats_written_to_one_word": ("      S_FILL: begin ram_addr = {op_index, fill_beat};", "      S_FILL: begin ram_addr = {op_index, op_beat};"),
    "fill_burst_too_short": ("      mreq.burst = 2'd3;", "      mreq.burst = 2'd1;"),
    "fill_error_validates_line": ("            if (!mrsp.error && !rsp_error && fill_beat == 2'd3 && !kill && enable && !invalidate) begin",
                                  "            if (fill_beat == 2'd3 && !kill && enable && !invalidate) begin"),
    "miss_keeps_old_line_valid": ("          valid[op_index] <= 0;\n", ""),
    "write_hit_not_updated": ("        ram_we = WRITES && op_write && op_hit && !kill", "        ram_we = 1'b0 && WRITES && op_write && op_hit && !kill"),
    "write_miss_allocates_data": ("        ram_we = WRITES && op_write && op_hit && !kill", "        ram_we = WRITES && op_write && !kill"),
    "write_error_updates_line": ("                 mrsp_valid && rsp_ready && !mrsp.error;", "                 mrsp_valid && rsp_ready;"),
    "store_accepted_before_memory": ("    req_ready = start_ok && (bypass ? mreq_ready : 1'b1);", "    req_ready = start_ok;"),
    "invalidate_ignored": ("      if (invalidate || !enable) valid <= '0;\n    end", "      if (!enable) valid <= '0;\n    end"),
    "disable_keeps_lines": ("      if (invalidate || !enable) valid <= '0;\n    end", "      if (invalidate) valid <= '0;\n    end"),
    "killed_fill_validates_line": ("fill_beat == 2'd3 && !kill && enable && !invalidate) begin", "fill_beat == 2'd3 && enable && !invalidate) begin"),
    "reset_keeps_lines": ("      state <= S_IDLE;\n      valid <= '0;", "      state <= S_IDLE;"),
}

def main():
    out = ROOT / "build/cache_mutants"
    if out.exists():
        shutil.rmtree(out)
    source = (ROOT / "rtl/memory/cache.sv").read_text()
    for name, (old, new) in MUTANTS.items():
        if source.count(old) != 1:
            raise AssertionError(f"Mutation anchor for {name} not unique in cache.sv")
        folder = out / name
        folder.mkdir(parents=True)
        (folder / "cache.sv").write_text(source.replace(old, new))
    (out / "mutants.json").write_text(json.dumps(sorted(MUTANTS), indent=2) + "\n")
    print(f"MUTANTS: {len(MUTANTS)} cache copies in {out}")

if __name__ == "__main__":
    main()
