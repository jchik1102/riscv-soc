import random
import pytest
import numpy as np
from model.accel_model import (AccelModel, BASE, matmul, matmul_numpy, wrap32, info_value,
                               CTRL, STATUS, INFO, CYCLES, A_OFF, B_OFF, C_OFF, D_OFF)

I32_MIN, I32_MAX = -(1 << 31), (1 << 31) - 1

def test_hand_2x2():
    assert matmul([[1, 2], [3, 4]], [[5, 6], [7, 8]]) == [[19, 22], [43, 50]]
    assert matmul([[1, 2], [3, 4]], [[5, 6], [7, 8]], [[1, -1], [100, -100]]) == [[20, 21], [143, -50]]
    assert matmul([[-1, 2], [3, -4]], [[5, -6], [-7, 8]]) == [[-19, 22], [43, -50]]

def test_hand_4x4_identity_and_zero():
    eye = [[int(i == j) for j in range(4)] for i in range(4)]
    b = [[-128, 127, 0, 1], [5, -6, 7, -8], [9, 10, -11, 12], [-13, 14, 15, -16]]
    assert matmul(eye, b) == b
    assert matmul(b, eye) == b
    zero = [[0] * 4 for _ in range(4)]
    assert matmul(zero, b) == zero
    assert matmul(zero, b, [[7] * 4] * 4) == [[7] * 4] * 4

def test_boundaries_and_wrap():
    full_min = [[-128] * 4 for _ in range(4)]
    full_max = [[127] * 4 for _ in range(4)]
    assert matmul(full_min, full_min) == [[65536] * 4] * 4
    assert matmul(full_min, full_max) == [[-65024] * 4] * 4
    assert matmul(full_min, full_min, [[I32_MAX] * 4] * 4) == [[-2147418113] * 4] * 4
    assert matmul(full_min, full_max, [[I32_MIN] * 4] * 4) == [[2147418624] * 4] * 4
    assert wrap32(1 << 31) == I32_MIN and wrap32((1 << 32) - 1) == -1 and wrap32(I32_MAX) == I32_MAX

def test_numpy_matches_python_and_promotion_matters():
    rng = random.Random(7)
    for _ in range(500):
        n = rng.choice((2, 4))
        a = [[rng.randint(-128, 127) for _ in range(n)] for _ in range(n)]
        b = [[rng.randint(-128, 127) for _ in range(n)] for _ in range(n)]
        c = [[rng.choice((rng.randint(I32_MIN, I32_MAX), I32_MIN, I32_MAX, 0)) for _ in range(n)] for _ in range(n)]
        assert matmul_numpy(a, b, c) == matmul(a, b, c)
        assert matmul_numpy(a, b) == matmul(a, b)
    a = np.full((2, 2), 100, dtype=np.int8)
    assert (a @ a).tolist() != matmul(a.tolist(), a.tolist())
    assert matmul(a.tolist(), a.tolist()) == [[20000, 20000], [20000, 20000]]

def test_rejects_out_of_range_operands():
    with pytest.raises(ValueError): matmul([[128, 0], [0, 0]], [[0, 0], [0, 0]])
    with pytest.raises(ValueError): matmul([[0, 0], [0, 0]], [[0, 0], [0, 0]], [[1 << 31, 0], [0, 0]])

def _word(x): return x & 0xffffffff

def load(model, edge, a, b, c=None):
    n = model.n
    for i in range(n):
        assert model.access(edge, BASE + A_OFF + 8 * (i // 2), True, 0x0f << (4 * (i % 2)),
                            sum((v & 0xff) << (8 * k) for k, v in enumerate(a[i])) << (32 * (i % 2))) == (0, 0)
        assert model.access(edge, BASE + B_OFF + 8 * (i // 2), True, 0x0f << (4 * (i % 2)),
                            sum((v & 0xff) << (8 * k) for k, v in enumerate(b[i])) << (32 * (i % 2))) == (0, 0)
    if c is not None:
        for w in range(0, n * n, 2):
            value = _word(c[w // n][w % n]) | (_word(c[(w + 1) // n][(w + 1) % n]) << 32)
            assert model.access(edge, BASE + C_OFF + 4 * w, True, 0xff, value) == (0, 0)

@pytest.mark.parametrize("n,parallel", [(2, True), (4, True), (2, False), (4, False)])
def test_timing_status_irq(n, parallel):
    m = AccelModel(n, parallel)
    latency = n if parallel else n ** 3
    rng = random.Random(n)
    a = [[rng.randint(-128, 127) for _ in range(n)] for _ in range(n)]
    b = [[rng.randint(-128, 127) for _ in range(n)] for _ in range(n)]
    c = [[rng.randint(I32_MIN, I32_MAX) for _ in range(n)] for _ in range(n)]
    load(m, 10, a, b, c)
    assert m.access(20, BASE + INFO, False, 0xff) == (0, info_value(n, parallel))
    assert m.access(30, BASE + CTRL, True, 0x0f, 0b111) == (0, 0)
    assert m.access(31, BASE + STATUS, False, 0xff) == (0, 1)
    assert m.access(31, BASE + D_OFF, False, 0x0f) == (0, None)
    assert m.access(31, BASE + A_OFF, True, 0x0f, 0) == (1, 0)
    assert m.access(31, BASE + A_OFF, False, 0x0f)[0] == 0
    assert m.access(32, BASE + CTRL, True, 0x0f, 0b111) == (0, 0)
    assert m.access(30 + latency, BASE + STATUS, False, 0x0f) == (0, 0b101)
    assert not m.irq(30 + latency) and m.irq(31 + latency)
    assert m.access(31 + latency, BASE + STATUS, False, 0x0f) == (0, 0b110)
    assert m.access(31 + latency, BASE + CYCLES, False, 0xff) == (0, latency)
    expected = matmul(a, b, c)
    for w in range(n * n):
        error, data = m.access(40 + latency, BASE + D_OFF + 8 * (w // 2), False, 0x0f << (4 * (w % 2)))
        assert error == 0 and wrap32(data >> (32 * (w % 2))) == expected[w // n][w % n]
    for w in range(0, n * n, 2):
        error, data = m.access(40 + latency, BASE + D_OFF + 4 * w, False, 0xff)
        assert error == 0 and [wrap32(data), wrap32(data >> 32)] == [expected[w // n][w % n], expected[(w + 1) // n][(w + 1) % n]]
    assert m.access(50 + latency, BASE + STATUS, True, 0x0f, 0b110) == (0, 0)
    assert not m.irq(51 + latency)

def test_access_rules():
    m = AccelModel(2, True)
    assert m.access(1, BASE + A_OFF, True, 0x01, 0) == (1, 0)
    assert m.access(1, BASE + A_OFF, True, 0x03, 0) == (1, 0)
    assert m.access(1, BASE + A_OFF, True, 0xff, 0) == (0, 0)
    assert m.access(1, BASE + A_OFF + 8, True, 0x0f, 0) == (1, 0)
    assert m.access(1, BASE + D_OFF, True, 0x0f, 0) == (1, 0)
    assert m.access(1, BASE + 0x20, False, 0xff) == (1, 0)
    assert m.access(1, BASE + INFO, True, 0xff, 123) == (0, 0)
    assert m.access(2, BASE + A_OFF, False, 0x0f) == (0, 0)
    assert m.access(3, BASE + A_OFF, True, 0x0f, 0x7f80_ff01) == (0, 0)
    assert m.access(4, BASE + A_OFF, False, 0x0f) == (0, 0xff01)

def test_done_clear_loses_to_completion_and_restart():
    m = AccelModel(2, True)
    load(m, 1, [[1, 0], [0, 1]], [[2, 3], [4, 5]])
    m.access(10, BASE + CTRL, True, 0x0f, 0b011)
    m.access(12, BASE + STATUS, True, 0x0f, 0b010)
    assert m.irq(13) and m.access(13, BASE + STATUS, False, 0x0f) == (0, 0b010)
    m.access(14, BASE + CTRL, True, 0x0f, 0b011)
    assert not m.irq(15) and m.irq(17)
    assert m.access(17, BASE + D_OFF, False, 0xff) == (0, 2 | (3 << 32))
    m.reset()
    assert m.access(18, BASE + STATUS, False, 0xff) == (0, 0) and m.access(18, BASE + D_OFF, False, 0x0f) == (0, None)

def test_s7_software_program_matches_contract():
    from scripts.rv64_programs import s7_cases, s7_matmul_layout, s7_matmul_operands
    from model.rv64s4 import MachineS4
    from model.rv64i import MAP
    words = s7_cases()["s7_matmul_sw"] + [0]
    machine = MachineS4(b"".join(w.to_bytes(4, "little") for w in words), sdram=True)
    for _ in range(100000):
        machine.step()
        if machine.halted: break
    assert machine.halted
    sdram = MAP["memories"]["sdram"]["base"]
    for index, (n, a, b, c) in enumerate(s7_matmul_operands()):
        d_base = s7_matmul_layout(index)[3] - sdram
        got = [wrap32(int.from_bytes(bytes(machine.sdram[d_base + 4 * w:d_base + 4 * w + 4]), "little")) for w in range(n * n)]
        assert got == [x for row in matmul(a, b, c) for x in row]
