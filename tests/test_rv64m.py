import random
import pytest
from model.reference import Machine, MASK, MAP, M_NAMES, m_result
from model.rv64m import as_signed, truncating_divide
from scripts.rv64_programs import m, reg

BASE = MAP['ram_base']
MIN = 1 << 63
MAX = MIN - 1
NEG = lambda x: (-x) & MASK
NAME = {"MUL":(0,0),"MULH":(1,0),"MULHSU":(2,0),"MULHU":(3,0),"DIV":(4,0),"DIVU":(5,0),
        "REM":(6,0),"REMU":(7,0),"MULW":(0,1),"DIVW":(4,1),"DIVUW":(5,1),"REMW":(6,1),"REMUW":(7,1)}

HAND = [
    ("MUL", 3, 7, 21), ("MUL", NEG(1), NEG(1), 1), ("MUL", MIN, NEG(1), MIN), ("MUL", MASK, 2, MASK - 1),
    ("MULH", NEG(1), NEG(1), 0), ("MULH", MIN, MIN, 1 << 62), ("MULH", NEG(1), 1, MASK),
    ("MULH", MAX, MAX, (1 << 62) - 1), ("MULH", MIN, MAX, 0xc000000000000000),
    ("MULHSU", NEG(1), MASK, MASK), ("MULHSU", NEG(1), 1, MASK), ("MULHSU", 1, MASK, 0),
    ("MULHSU", MIN, MASK, MIN), ("MULHSU", MAX, MASK, MAX - 1),
    ("MULHU", MASK, MASK, MASK - 1), ("MULHU", MIN, 2, 1), ("MULHU", 1 << 32, 1 << 32, 1),
    ("DIV", 7, 2, 3), ("DIV", NEG(7), 2, NEG(3)), ("DIV", 7, NEG(2), NEG(3)), ("DIV", NEG(7), NEG(2), 3),
    ("DIV", 5, 0, MASK), ("DIV", NEG(5), 0, MASK), ("DIV", MIN, NEG(1), MIN), ("DIV", 0, 5, 0), ("DIV", 3, 7, 0),
    ("DIVU", MASK, 2, MAX), ("DIVU", 5, 0, MASK), ("DIVU", 3, 7, 0), ("DIVU", MIN, NEG(1), 0),
    ("REM", 7, 2, 1), ("REM", NEG(7), 2, NEG(1)), ("REM", 7, NEG(2), 1), ("REM", NEG(7), NEG(2), NEG(1)),
    ("REM", NEG(5), 0, NEG(5)), ("REM", MIN, NEG(1), 0), ("REM", 3, 7, 3),
    ("REMU", 3, 7, 3), ("REMU", 5, 0, 5), ("REMU", MASK, 10, 5), ("REMU", NEG(7), 2, 1),
    ("MULW", 0x7fffffff, 2, MASK - 1), ("MULW", 0x1234567800000003, 0xabcdef0000000005, 15),
    ("MULW", 0xffffffff, 0xffffffff, 1), ("MULW", 0x10000, 0x10000, 0),
    ("DIVW", 0x0000000180000000, 0xffffffff, 0xffffffff80000000), ("DIVW", NEG(7), 2, NEG(3)),
    ("DIVW", 0xdead000000000009, 0, MASK), ("DIVW", 0xffffffff00000007, 0x0000000500000002, 3),
    ("DIVUW", 0xffffffff, 1, MASK), ("DIVUW", 0x80000000, 2, 0x40000000), ("DIVUW", 9, 0, MASK),
    ("DIVUW", 0xffffffff00000007, 2, 3), ("DIVUW", 0xfffffff9, 2, 0x7ffffffc),
    ("REMW", NEG(7), 2, MASK), ("REMW", 0x80000000, 0, 0xffffffff80000000),
    ("REMW", 0x80000000, 0xffffffff, 0), ("REMW", 0x1234567800000007, 0xffffffff00000003, 1),
    ("REMUW", 0xffffffff, 0, MASK), ("REMUW", 0x80000005, 0x80000000, 5),
    ("REMUW", 0xfffffffe, 0xffffffff, MASK - 1), ("REMUW", 0x7, 0x100000002, 1),
]

@pytest.mark.parametrize("name,a,b,expected", HAND)
def test_hand_calculated(name, a, b, expected):
    f3, word = NAME[name]
    assert m_result(f3, word, a, b) == expected

def test_truncation_differs_from_python_floor():
    assert -7 // 2 == -4 and truncating_divide(-7, 2) == (-3, -1)

def random_pairs(seed, count=3000):
    rng = random.Random(seed)
    edges = [0, 1, 2, MASK, MASK - 1, MIN, MAX, MIN + 1, 0x80000000, 0x7fffffff, 0xffffffff]
    for _ in range(count):
        values = []
        for _ in range(2):
            if rng.randrange(4) == 0: values.append(rng.choice(edges))
            else: values.append(rng.getrandbits(rng.randint(1, 64)))
        yield values

def test_product_identities():
    for a, b in random_pairs(5):
        sa, sb = as_signed(a, 64), as_signed(b, 64)
        low = m_result(0, 0, a, b)
        assert as_signed(m_result(1, 0, a, b), 64) * 2**64 + low == sa * sb
        assert as_signed(m_result(2, 0, a, b), 64) * 2**64 + low == sa * b
        assert m_result(3, 0, a, b) * 2**64 + low == a * b
        assert m_result(0, 1, a, b) == as_signed((a * b) & 0xffffffff, 32) & MASK

def test_division_identities():
    for a, b in random_pairs(9):
        for word in (0, 1):
            bits = 32 if word else 64
            for signed_op, (qf3, rf3) in ((True, (4, 6)), (False, (5, 7))):
                n = as_signed(a, bits) if signed_op else a & ((1 << bits) - 1)
                d = as_signed(b, bits) if signed_op else b & ((1 << bits) - 1)
                q = as_signed(m_result(qf3, word, a, b), 64)
                r = as_signed(m_result(rf3, word, a, b), 64)
                if word:
                    assert -2**31 <= q < 2**31 and -2**31 <= r < 2**31
                    q, r = (as_signed(q, 32), as_signed(r, 32)) if signed_op else (q & 0xffffffff, r & 0xffffffff)
                elif not signed_op:
                    q, r = q & MASK, r & MASK
                if d == 0:
                    assert q == (-1 if signed_op else (1 << bits) - 1) and r == n
                elif signed_op and n == -(1 << (bits - 1)) and d == -1:
                    assert q == n and r == 0
                else:
                    assert q * d + r == n and abs(r) < abs(d)
                    assert r == 0 or (r < 0) == (n < 0)

def one(instruction, a=0, b=0):
    machine = Machine(instruction.to_bytes(4, 'little'))
    machine.regs[1], machine.regs[2] = a, b
    return machine, machine.step()

@pytest.mark.parametrize("name", sorted(M_NAMES))
def test_every_instruction_executes_in_machine(name):
    f3, word = NAME[name]
    machine, row = one(m(3, 1, 2, f3, bool(word)), NEG(7), 2)
    assert row['trap'] == 0 and row['rd'] == 3 and row['next_pc'] == BASE + 4
    assert row['rd_data'] == m_result(f3, word, NEG(7), 2) == machine.regs[3]
    assert machine.coverage[name] == 1

def test_destination_dependencies_and_x0():
    machine, row = one(m(1, 1, 2, 0), 6, 7)
    assert machine.regs[1] == 42
    machine, row = one(m(2, 1, 2, 4), 42, 7)
    assert machine.regs[2] == 6
    machine, row = one(m(0, 1, 2, 4), 42, 0)
    assert row['rd'] == 0 and row['rd_data'] == 0 and machine.regs[0] == 0
    assert machine.coverage['M_divide_by_zero'] == 1
    machine, row = one(m(3, 1, 1, 0), NEG(3))
    assert row['rd_data'] == 9

@pytest.mark.parametrize("instruction", [m(1, 1, 2, 1, True), m(1, 1, 2, 2, True), m(1, 1, 2, 3, True),
                                         reg(1, 1, 2, 0, 2), reg(1, 1, 2, 0, 3, True), 0x0200103b])
def test_reserved_m_encodings_stay_illegal(instruction):
    machine, row = one(instruction, 5, 7)
    assert row['trap'] == 1 and row['cause'] == 2 and row['next_pc'] == BASE and machine.regs[1] == 5

def test_promoted_s1_negative_encodings():
    assert one(0x02000033)[1]['trap'] == 0
    machine, row = one(reg(1, 1, 2, 5, 1, True), 0xffffffff, 2)
    assert row['trap'] == 0 and machine.regs[1] == 0x7fffffff

def test_signed_overflow_coverage():
    machine, row = one(m(3, 1, 2, 6, True), 0x80000000, 0xffffffff)
    assert row['rd_data'] == 0 and machine.coverage['M_signed_overflow'] == 1

def test_vector_file_matches_model():
    from scripts.muldiv_vectors import vectors
    rows = vectors(seed=3, random_count=8)
    assert {(f3, word) for f3, word, *_ in rows} == {(f3, w) for f3, w in NAME.values()}
    assert all(m_result(f3, word, a, b) == e for f3, word, a, b, e in rows)
