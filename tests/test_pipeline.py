import pytest
from model.pipeline_check import compare_pipeline
from model.rv64i import MAP, Machine
from scripts import fir_reference

BASE = MAP["ram_base"]
WORDS = [0x00004a17, 0x00500093, 0x001a3023, 0x000a3103, 0x00000463, 0x001a3423, 0x00100073]
PROGRAM = b"".join(w.to_bytes(4, "little") for w in WORDS)
HEADER = "order,pc,insn,next_pc,rd,rd_data,mem_addr,mem_rmask,mem_wmask,mem_rdata,mem_wdata,trap,cause"

def row(r):
    return ",".join(str(r[k]) if k in ("order", "rd", "trap", "cause") else f"{r[k]:x}" for k in HEADER.split(","))

def beat(address):
    offset = address - BASE
    return int.from_bytes((PROGRAM + bytes(64))[offset:offset + 8], "little")

def transcript(mutate=None):
    model = Machine(PROGRAM)
    rows = []
    while not model.halted: rows.append(model.step())
    lines = [HEADER]
    for address in (BASE, BASE + 8, BASE + 16, BASE + 24):
        lines += [f"IQ,{address:016x},0,ff,0000000000000000", f"IR,0,{beat(address):016x}"]
    for r in rows:
        if r["mem_wmask"] or r["mem_rmask"]:
            write = int(bool(r["mem_wmask"]))
            lines.append(f"Q,{r['mem_addr'] & ~7:016x},{write},{r['mem_wmask'] or r['mem_rmask']:02x},{r['mem_wdata']:016x}")
            lines.append(f"R,0,{r['mem_rdata']:016x}")
        lines.append(row(r))
    if mutate: mutate(lines)
    return "\n".join(lines) + "\n", rows

def run(tmp_path, mutate=None):
    text, rows = transcript(mutate)
    trace = tmp_path / "t.csv"
    trace.write_text(text)
    memory = bytearray(MAP["ram_bytes"])
    memory[:len(PROGRAM)] = PROGRAM
    memory[0x4000:0x4008] = (5).to_bytes(8, "little")
    (tmp_path / "t.csv.mem").write_text("\n".join(f"{b:02x}" for b in memory) + "\n")
    return compare_pipeline(PROGRAM, trace)

def test_legal_transcript_with_speculative_fetch_is_accepted(tmp_path):
    count, model, checker = run(tmp_path)
    assert count == 6 and model.regs[2] == 5 and checker.fetches == 4 and checker.accesses == 2

def index_of(lines, prefix, n=0):
    return [i for i, l in enumerate(lines) if l.startswith(prefix)][n]

@pytest.mark.parametrize("fault", ["wrong_path_store", "duplicate_store", "retire_before_ack", "missing_access",
                                   "bad_fetch_data", "fetch_mask", "second_fetch_outstanding", "load_data"])
def test_pipeline_transcript_fault_is_detected(tmp_path, fault):
    def mutate(lines):
        if fault == "wrong_path_store":
            i = index_of(lines, "Q,", 1) + 2
            lines[i:i] = ["Q,0000000080004008,1,ff,0000000000000005", "R,0,0000000000000000"]
        elif fault == "duplicate_store":
            i = index_of(lines, "Q,")
            lines[i:i] = lines[i:i + 2]
        elif fault == "retire_before_ack":
            i = index_of(lines, "R,")
            lines.insert(i + 2, lines.pop(i))
        elif fault == "missing_access":
            i = index_of(lines, "Q,", 1)
            del lines[i:i + 2]
        elif fault == "bad_fetch_data":
            i = index_of(lines, "IR,")
            lines[i] = lines[i][:-1] + ("0" if lines[i][-1] != "0" else "1")
        elif fault == "fetch_mask":
            i = index_of(lines, "IQ,")
            lines[i] = lines[i].replace(",ff,", ",0f,")
        elif fault == "second_fetch_outstanding":
            i = index_of(lines, "IR,")
            lines.insert(i, "IQ,0000000080000040,0,ff,0000000000000000")
        elif fault == "load_data":
            i = index_of(lines, "R,", 1)
            lines[i] = "R,0,0000000000000006"
    with pytest.raises((AssertionError, IndexError)):
        run(tmp_path, mutate)

def test_fir_rounding_and_saturation_by_hand():
    assert fir_reference.fir([16384], [3, -3, 1, -1]) == [2, -1, 1, 0]
    assert fir_reference.fir([32767, 32767], [32767, 32767]) == [32766, 32767]
    assert fir_reference.fir([-32768, -32768], [32767, 32767]) == [-32767, -32768]
    assert fir_reference.checksum([1, -1]) == 1 * 1 + 2 * 0xffff

def test_fir_contract_data_exercise_saturation():
    coeff, samples = fir_reference.data()
    outputs = fir_reference.fir(coeff, samples)
    assert len(coeff) == 16 and len(samples) == 128
    assert any(y == 32767 for y in outputs) and any(y == -32768 for y in outputs)
