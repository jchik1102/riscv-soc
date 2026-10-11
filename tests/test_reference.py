import pytest
from model.reference import Machine, MASK, signed
from scripts.programs import add, addi

def execute(words):
    machine = Machine(b"".join(w.to_bytes(4, "little") for w in words))
    rows = [machine.step() for _ in words]
    return machine, rows

def test_first_program_hand_calculated():
    m, rows = execute([0x00500093, 0x00700113, 0x002081b3])
    assert m.regs[:4] == [0, 5, 7, 12]
    assert [r["pc"] for r in rows] == [0x80000000, 0x80000004, 0x80000008]

def test_negative_wrap_and_zero():
    m, _ = execute([0xfff00093, 0x00100113, 0x002081b3, 0xfff00013])
    assert m.regs[:4] == [0, MASK, 1, 0]

@pytest.mark.parametrize("imm", [-2048, -1, 0, 1, 2047])
def test_immediate_boundaries(imm):
    m, _ = execute([addi(31, 0, imm)])
    assert m.regs[31] == imm & MASK

def test_reset():
    m, _ = execute([addi(1, 0, 99), add(2, 1, 1)])
    m.reset()
    assert m.regs == [0] * 32 and m.pc == 0x80000000 and m.order == 0
    assert m.step()["rd_data"] == 99

@pytest.mark.parametrize("word", [0, 0x0200103b, 0x40001033, 0xffffffff])
def test_illegal_decode(word):
    m, rows = execute([word])
    assert rows[0]["trap"] == 1 and rows[0]["cause"] == 2
    assert m.pc == 0x80000000 and m.regs == [0] * 32
    with pytest.raises(ValueError):
        m.step()

def test_signed():
    assert signed(0x800, 12) == -2048
    assert signed(0x7ff, 12) == 2047
    assert signed(0xffffffffffffffff) == -1
