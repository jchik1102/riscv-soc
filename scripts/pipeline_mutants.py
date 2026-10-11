import json
import shutil
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FILES = ("core_pipeline.sv", "alu.sv", "load_store.sv", "csr_file.sv")

MUTANTS = {
    "no_mem_to_ex_forwarding": ("forwarding", "core_pipeline.sv", [(
        "assign mem_fwd = mem_valid &&", "assign mem_fwd = 1'b0 && mem_valid &&")]),
    "no_wb_to_ex_forwarding": ("forwarding", "core_pipeline.sv", [(
        "fwd_wb_a = wb_fwd && wb_rec.rd == ex_rs1;", "fwd_wb_a = 1'b0;")]),
    "no_wb_to_id_bypass": ("forwarding", "core_pipeline.sv", [(
        "assign id_a = wb_fwd && wb_rec.rd == id_insn[19:15] ? wb_rec.rd_data : rf_a;", "assign id_a = rf_a;")]),
    "store_data_not_forwarded": ("forwarding", "core_pipeline.sv", [(
        "store_lanes = (fb << {address[2:0], 3'b0}) & lane_mask;", "store_lanes = (ex_b << {address[2:0], 3'b0}) & lane_mask;")]),
    "branch_operand_not_forwarded": ("forwarding", "core_pipeline.sv", [(
        "1: take_branch = fa != fb;", "1: take_branch = ex_a != ex_b;")]),
    "no_load_use_stall": ("forwarding", "core_pipeline.sv", [(
        "load_hazard = ex_valid && mem_valid", "load_hazard = 1'b0 && ex_valid && mem_valid")]),
    "stalled_operands_not_refreshed": ("forwarding", "core_pipeline.sv", [(
        "        ex_a <= fa; ex_b <= fb;\n", "")]),
    "wrong_path_id_not_flushed": ("branch", "core_pipeline.sv", [(
        "if (flush_front) id_valid <= 0;", "if (ex_trap_fire || mem_trap_now) id_valid <= 0;")]),
    "wrong_path_ex_not_squashed": ("branch", "core_pipeline.sv", [(
        "ex_valid <= id_valid && !redirect && !ex_trap_fire;", "ex_valid <= id_valid && !ex_trap_fire;")]),
    "branch_target_off_by_four": ("branch", "core_pipeline.sv", [(
        "assign redirect_pc = executed.next_pc;", "assign redirect_pc = executed.next_pc + 64'd4;")]),
    "duplicate_store_issue": ("duplicate_store", "core_pipeline.sv", [
        ("  logic mem_fwd;\n", "  logic mem_fwd, dup_done;\n"),
        ("assign mem_done = !mem_access || (mem_issued && drsp_valid);",
         "assign mem_done = !mem_access || (mem_issued && drsp_valid && !(mem_req.write && !dup_done));"),
        ("        mem_issued <= 0;\n        mem_f3", "        mem_issued <= 0; dup_done <= 0;\n        mem_f3"),
        ("      end else if (dreq_valid && dreq_ready) mem_issued <= 1;",
         "      end else if (dreq_valid && dreq_ready) mem_issued <= 1;\n"
         "      else if (drsp_valid && drsp_ready && mem_req.write && !dup_done) begin mem_issued <= 0; dup_done <= 1; end")]),
    "load_word_zero_extended": ("sign_extension", "load_store.sv", [(
        "2: load_result = {{32{shifted_read[31]}}, shifted_read[31:0]};", "2: load_result = {32'b0, shifted_read[31:0]};")]),
    "word_alu_not_sign_extended": ("sign_extension", "alu.sv", [(
        "result = {{32{word_result[31]}}, word_result};", "result = {32'b0, word_result};")]),
    "sub_computes_add": ("arithmetic", "alu.sv", [(
        "OP_SUB: result = a - b;", "OP_SUB: result = a + b;")]),
    "flush_does_not_kill_m": ("arithmetic", "core_pipeline.sv", [(
        ".kill(mem_trap_now || wb_trap_take)", ".kill(1'b0)")]),
    "trap_mepc_is_next_pc": ("trap", "core_pipeline.sv", [(
        ".trap_epc(wb_rec.pc)", ".trap_epc(wb_rec.pc + 64'd4)")]),
    "trap_keeps_mie": ("trap", "csr_file.sv", [(
        "        mpie_bit <= mie_bit;\n        mie_bit <= 0;", "        mpie_bit <= mie_bit;")]),
    "mret_does_not_restore_mie": ("trap", "csr_file.sv", [(
        "        mie_bit <= mpie_bit;\n        mpie_bit <= 1;", "        mpie_bit <= 1;")]),
    "interrupt_ignores_mstatus_mie": ("interrupt", "csr_file.sv", [(
        "irq_pending = mie_bit && ((mip_now & mie_q) != 0);", "irq_pending = (mip_now & mie_q) != 0;")]),
    "minstret_counts_traps": ("counter", "core_pipeline.sv", [(
        ".retire_inc(wb_valid && !wb_rec.trap && !wb_noinc)", ".retire_inc(wb_valid && !wb_noinc)")]),
    "csr_not_serialized": ("csr", "core_pipeline.sv", [(
        "assign sys_wait = ex_sys && (mem_valid || wb_valid);", "assign sys_wait = 1'b0;")]),
    "trap_entry_keeps_front_end": ("interrupt", "core_pipeline.sv", [(
        "assign flush_front = redirect || ex_trap_fire || mem_trap_now || wb_trap_take;",
        "assign flush_front = redirect || ex_trap_fire || mem_trap_now;")]),
    "m_operand_b_takes_rs1": ("arithmetic", "core_pipeline.sv", [(
        ".a(fa), .b(fb),", ".a(fa), .b(fa),")]),
}

def main():
    out = ROOT / "build/pipeline_mutants"
    if out.exists():
        shutil.rmtree(out)
    for name, (_, file, edits) in MUTANTS.items():
        folder = out / name
        folder.mkdir(parents=True)
        for source in FILES:
            text = (ROOT / "rtl/core" / source).read_text()
            if source == file:
                for old, new in edits:
                    if text.count(old) != 1:
                        raise AssertionError(f"Mutation anchor for {name} not unique in {source}: {old!r}")
                    text = text.replace(old, new)
            (folder / source).write_text(text)
    (out / "mutants.json").write_text(json.dumps({k: v[0] for k, v in MUTANTS.items()}, indent=2) + "\n")
    print(f"MUTANTS: {len(MUTANTS)} pipeline RTL copies in {out}")

if __name__ == "__main__":
    main()
