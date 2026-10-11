import pytest
from model.rv64i import MAP, SparseMemory, UninitializedRead
from model.rv64s4 import MachineS4
from model.pipeline_check import PipelineChecker, read_sdram_dump, sdram_offset

BASE = MAP["memories"]["sdram"]["base"]

def encode_li_sdram_base(rd):
    return [(0x90000 << 12) | (rd << 7) | 0x37, (32 << 20) | (rd << 15) | (1 << 12) | (rd << 7) | 0x13,
            (32 << 20) | (rd << 15) | (5 << 12) | (rd << 7) | 0x13]

def program(words):
    return b"".join(w.to_bytes(4, "little") for w in words + [0])

def test_sparse_memory_defines_only_written_bytes():
    memory = SparseMemory(1 << 26)
    memory[0x1000:0x1002] = b"\x34\x12"
    assert memory[0x1000:0x1002] == b"\x34\x12"
    with pytest.raises(UninitializedRead):
        memory[0x1001:0x1003]
    assert dict(memory.items()) == {0x1000: 0x34, 0x1001: 0x12}

def test_documented_mapping_is_hand_checked():
    assert sdram_offset(0, 0, 0, 0) == 0
    assert sdram_offset(0, 0, 1, 1) == 3
    assert sdram_offset(1, 0, 0, 0) == 0x800
    assert sdram_offset(0, 1, 0, 0) == 0x2000
    assert sdram_offset(3, 8191, 1023, 1) == (1 << 26) - 1

def test_sdram_dump_parsing(tmp_path):
    dump = tmp_path / "x.sdram"
    dump.write_text("1 2 3 1 ab\n0 0 0 0 01\n")
    assert read_sdram_dump(dump) == {sdram_offset(1, 2, 3, 1): 0xab, 0: 0x01}

def test_store_load_sdram_only_when_configured():
    words = encode_li_sdram_base(1) + [0xfff00113, (2 << 20) | (1 << 15) | (3 << 12) | (8 << 7) | 0x23,
                                       (12 << 20) | (1 << 15) | (2 << 12) | (3 << 7) | 3,
                                       (15 << 20) | (1 << 15) | (4 << 12) | (4 << 7) | 3]
    model = MachineS4(program(words), sdram=True)
    rows = [model.step() for _ in range(7)]
    assert rows[4]["mem_addr"] == BASE + 8 and rows[4]["mem_wmask"] == 0xff
    assert rows[5]["rd_data"] == (1 << 64) - 1 and rows[6]["rd_data"] == 0xff
    plain = MachineS4(program(words))
    rows = [plain.step() for _ in range(5)]
    assert rows[4]["trap"] == 1 and rows[4]["cause"] == 7 and plain.halted

def test_unwritten_sdram_read_is_an_error():
    words = encode_li_sdram_base(1) + [(0 << 20) | (1 << 15) | (3 << 12) | (2 << 7) | 3]
    model = MachineS4(program(words), sdram=True)
    for _ in range(3): model.step()
    with pytest.raises(UninitializedRead):
        model.step()

def test_fetch_from_sdram_faults():
    words = encode_li_sdram_base(1) + [(1 << 15) | 0x67]
    model = MachineS4(program(words), sdram=True)
    for _ in range(4): model.step()
    row = model.step()
    assert row["trap"] == 1 and row["cause"] == 1

def test_checker_rejects_wrong_sdram_read_data():
    words = encode_li_sdram_base(1) + [0xfff00113, (2 << 20) | (1 << 15) | (3 << 12) | 0x23,
                                       (1 << 15) | (3 << 12) | (3 << 7) | 3]
    checker = PipelineChecker(program(words), sdram=True)
    checker.data_request([f"{BASE:x}", "1", "ff", "ffffffffffffffff"])
    checker.data_response(["0", "0"])
    checker.data_request([f"{BASE:x}", "0", "ff", "0"])
    with pytest.raises(AssertionError):
        checker.data_response(["0", "fffffffffffffffe"])
