import csv
import io
import pytest
from model.reference import Machine, compare

PROGRAM = bytes.fromhex("9300f0ff13017000b38120001300200000000000")

def write_trace(path, mutate=None):
    model = Machine(PROGRAM)
    rows = []
    while not model.halted:
        rows.append(model.step())
    if mutate:
        mutate(rows)
    stream = io.StringIO()
    writer = csv.DictWriter(stream, fieldnames=list(rows[0]))
    writer.writeheader()
    for row in rows:
        writer.writerow({k: str(v) if k in {"order", "rd", "trap", "cause"} else f"{v:x}" for k, v in row.items()})
    path.write_text(stream.getvalue())

@pytest.mark.parametrize("fault", ["sign_extension", "arithmetic", "pc", "x0", "duplicate", "truncated", "trap", "instruction"])
def test_deliberate_fault_is_detected(tmp_path, fault):
    def corrupt(rows):
        if fault == "sign_extension": rows[0]["rd_data"] = 4095
        elif fault == "arithmetic": rows[2]["rd_data"] ^= 1
        elif fault == "pc": rows[1]["pc"] += 4
        elif fault == "x0": rows[3]["rd_data"] = 2
        elif fault == "duplicate": rows.insert(1, dict(rows[0]))
        elif fault == "truncated": rows.pop()
        elif fault == "trap": rows[-1]["cause"] = 3
        elif fault == "instruction": rows[0]["insn"] ^= 0x100000
    trace = tmp_path / "mutated.csv"
    write_trace(trace, corrupt)
    with pytest.raises((AssertionError, ValueError)):
        compare(PROGRAM, trace)

def test_valid_trace_is_accepted(tmp_path):
    trace = tmp_path / "good.csv"
    write_trace(trace)
    assert compare(PROGRAM, trace)[0] == 5
