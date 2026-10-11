from model.accel_model import matmul, matmul_numpy, wrap32
from scripts.check_s8_demo import make_matrix, expected_results, windows_from_marks, CACHE_METRICS, DIM
from scripts.rv64_programs import s8_soc_cases, S8_RANDOM_SEEDS

def test_matrix_contract_matches_numpy():
    a, b, c = make_matrix()
    assert matmul(a, b, c) == matmul_numpy(a, b, c)

def test_tiled_accumulation_equals_full_product():
    a, b, c = make_matrix()
    want = matmul(a, b, c)
    for n in (2, 4):
        tiles = DIM // n
        for ti in range(tiles):
            for tj in range(tiles):
                acc = [row[tj * n:(tj + 1) * n] for row in c[ti * n:(ti + 1) * n]]
                for tk in range(tiles):
                    at = [row[tk * n:(tk + 1) * n] for row in a[ti * n:(ti + 1) * n]]
                    bt = [row[tj * n:(tj + 1) * n] for row in b[tk * n:(tk + 1) * n]]
                    acc = matmul(at, bt, acc)
                assert acc == [row[tj * n:(tj + 1) * n] for row in want[ti * n:(ti + 1) * n]]

def test_wrapping_element():
    a, b, c = make_matrix()
    exact = sum(a[0][k] * b[k][0] for k in range(DIM)) + c[0][0]
    assert exact == 16 * 16384 + (1 << 31) - 1
    assert expected_results("s8_board", 4)[0][0][0] == wrap32(exact) < 0

def test_board_and_simulation_checksums_differ_only_by_cases():
    big_sim, cases_sim, _ = expected_results("s8_bench", 4)
    big_board, cases_board, _ = expected_results("s8_board", 4)
    assert big_sim == big_board and len(cases_sim) == 10 and len(cases_board) == 64
    assert cases_board[:10] == cases_sim

def test_counter_windows_pairing():
    snap = lambda v: {k: v for k in CACHE_METRICS}
    marks = [0, 1, 0, 0, 1, 0]
    snapshots = [snap(0), snap(5), snap(9), snap(9), snap(20), snap(27)]
    assert windows_from_marks(marks, snapshots) == [snap(4), snap(7)]

def test_random_programs_deterministic_and_mixed():
    first, second = s8_soc_cases(), s8_soc_cases()
    assert first == second and sorted(first) == sorted(f"s8_random_{s}" for s in S8_RANDOM_SEEDS)
    for image in first.values():
        assert len(image) < 0x1000
        assert 0x0000100f in image
        assert 0x30200073 in image
        assert 0x00100073 in image
        opcodes = {w & 0x7f for w in image}
        assert {0x03, 0x23, 0x33, 0x13, 0x63, 0x73, 0x67}.issubset(opcodes)
