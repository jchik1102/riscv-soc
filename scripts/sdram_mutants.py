import json
import shutil
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

MUTANTS = {
    "refresh_trc_too_short": ("            refresh_due <= 0;\n            wait_count <= 16'(C_RC - 1) + 16'(extra_wait);",
                              "            refresh_due <= 0;\n            wait_count <= 16'(C_RC - 2) + 16'(extra_wait);"),
    "write_recovery_tdal_too_short": ("            wait_count <= 16'(C_DAL - 1) + 16'(extra_wait);",
                                      "            wait_count <= 16'(C_DAL - 2) + 16'(extra_wait);"),
    "power_up_wait_skipped": ("      wait_count <= 16'(C_POWERUP - 1);", "      wait_count <= 16'(10);"),
    "refresh_never_requested": ("          refresh_due <= 1;\n", ""),
    "too_few_init_refreshes": ("          init_refreshes <= 4'(INIT_REFRESHES);", "          init_refreshes <= 4'(2);"),
    "write_dqm_inverted": ("          sdram_dqm <= ~op_mask[word*2 +: 2];", "          sdram_dqm <= op_mask[word*2 +: 2];"),
    "column_from_wrong_address_bits": ("          sdram_a <= {2'b00, 1'b1, op_offset[10:1]};",
                                       "          sdram_a <= {2'b00, 1'b1, op_offset[11:2]};"),
    "bank_row_bits_swapped": ("            sdram_ba <= op_offset[12:11];\n            sdram_a <= op_offset[25:13];",
                              "            sdram_ba <= op_offset[14:13];\n            sdram_a <= {op_offset[25:15], op_offset[12:11]};"),
    "read_captured_one_cycle_early": ("  assign capture = 4'(READ_LATENCY) + 4'(extra_capture);",
                                      "  assign capture = 4'(READ_LATENCY) + 4'(extra_capture) - 4'd1;"),
    "read_captured_one_cycle_late": ("  assign capture = 4'(READ_LATENCY) + 4'(extra_capture);",
                                     "  assign capture = 4'(READ_LATENCY) + 4'(extra_capture) + 4'd1;"),
    "mode_register_cas_latency_3": ("3'(CAS_LATENCY), 1'b0, 3'b010};", "3'(CAS_LATENCY + 1), 1'b0, 3'b010};"),
    "unselected_read_lanes_not_zeroed": ("rsp.rdata <= {dq_q, read_data[47:0]} & lane_mask;", "rsp.rdata <= {dq_q, read_data[47:0]};"),
    "cpu_reset_does_not_drop_response": ("        if (pending) drop <= 1;\n", ""),
    "cpu_reset_loses_accepted_store": ("        if (pending) drop <= 1;\n", "        if (pending && state == S_IDLE) pending <= 0;\n        if (pending) drop <= 1;\n"),
    "write_repeated_after_completion": ("            wait_count <= 16'(C_DAL - 1) + 16'(extra_wait);\n            state <= S_IDLE;\n            pending <= 0;",
                                        "            wait_count <= 16'(C_DAL - 1) + 16'(extra_wait);\n            state <= S_IDLE;"),
    "read_response_repeated": ("      if (rsp_valid && rsp_ready) rsp_valid <= 0;",
                               "      if (rsp_valid && rsp_ready) rsp_valid <= op_write || rsp.error ? 1'b0 : 1'b1;"),
    "misaligned_request_accepted": ("&& req.addr[2:0] == 0;", ";"),
    "burst_repeats_a_beat": ("op_offset[4:3] + reads_more + 2'd1, 2'b00};", "op_offset[4:3] + reads_more, 2'b00};"),
    "burst_last_flag_on_every_beat": ("              rsp.last <= beat == op_len;", "              rsp.last <= 1'b1;"),
    "burst_row_left_open": ("sdram_a <= {2'b00, reads_more + 2'd1 == op_len,", "sdram_a <= {2'b00, 1'b0,"),
    "burst_first_read_precharges": ("sdram_a <= {2'b00, op_len == 2'd0, op_offset[10:1]};", "sdram_a <= {2'b00, 1'b1, op_offset[10:1]};"),
    "read_column_from_wrong_address_bits": ("sdram_a <= {2'b00, op_len == 2'd0, op_offset[10:1]};", "sdram_a <= {2'b00, op_len == 2'd0, op_offset[11:2]};"),
    "illegal_burst_accepted": ("  assign legal_burst = req.burst == 0 ||", "  assign legal_burst = 1'b1 ||"),
}

def main():
    out = ROOT / "build/sdram_mutants"
    if out.exists():
        shutil.rmtree(out)
    source = (ROOT / "rtl/memory/sdram_ctrl.sv").read_text()
    for name, (old, new) in MUTANTS.items():
        if source.count(old) != 1:
            raise AssertionError(f"Mutation anchor for {name} not unique in sdram_ctrl.sv")
        folder = out / name
        folder.mkdir(parents=True)
        (folder / "sdram_ctrl.sv").write_text(source.replace(old, new))
    (out / "mutants.json").write_text(json.dumps(sorted(MUTANTS), indent=2) + "\n")
    print(f"MUTANTS: {len(MUTANTS)} SDRAM controller copies in {out}")

if __name__ == "__main__":
    main()
