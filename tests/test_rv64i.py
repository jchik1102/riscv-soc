import pytest
from model.reference import Machine, MASK, MAP, BusChecker
from scripts.rv64_programs import reg, imm, upper, load, store, branch, jal, jalr
from scripts.spike_compare import parse_commit

BASE = MAP['ram_base']

def one(instruction, a=0, b=0):
    m = Machine(instruction.to_bytes(4, 'little'))
    m.regs[1], m.regs[2] = a, b
    return m, m.step()

@pytest.mark.parametrize('f3,f7,a,b,expected', [
    (0,0,MASK,1,0), (0,32,0,1,MASK), (0,32,0x8000000000000000,1,0x7fffffffffffffff),
    (1,0,1,63,0x8000000000000000), (1,0,3,64,3), (1,0,3,65,6),
    (5,0,0x8000000000000000,63,1), (5,32,0x8000000000000000,63,MASK),
    (5,32,0x8000000000000000,1,0xc000000000000000),
    (2,0,MASK,0,1), (3,0,MASK,0,0), (2,0,0,MASK,0), (3,0,0,MASK,1),
    (4,0,0xa5,0x3c,0x99), (6,0,0xa5,0x3c,0xbd), (7,0,0xa5,0x3c,0x24)])
def test_register_math(f3,f7,a,b,expected):
    m, r = one(reg(3,1,2,f3,f7),a,b)
    assert r['trap'] == 0 and r['rd_data'] == expected and m.regs[3] == expected

@pytest.mark.parametrize('f3,n,a,expected', [
    (2,-1,0,0),(3,-1,0,1),(3,-1,MASK,0),(2,-2048,MASK,0),
    (4,-1,0xa5,0xffffffffffffff5a),(6,-2048,0x12,0xfffffffffffff812),
    (7,-2048,0x123456789abcdef0,0x123456789abcd800),
    (1,32,1,0x100000000),(5,32,0x8000000000000000,0x80000000),
    (5,0x43f,0x8000000000000000,MASK)])
def test_immediate_math(f3,n,a,expected):
    _, r = one(imm(3,1,n,f3),a)
    assert r['trap'] == 0 and r['rd_data'] == expected

@pytest.mark.parametrize('f3,f7,a,b,expected', [
    (0,0,0x7fffffff,1,0xffffffff80000000),
    (0,32,0x80000000,1,0x7fffffff), (0,0,0xffffffff,1,0),
    (1,0,1,31,0xffffffff80000000),(1,0,0xabcdef0080000001,32,0xffffffff80000001),
    (5,0,0xffffffff,1,0x7fffffff),(5,0,0x80000000,0,0xffffffff80000000),
    (5,32,0x1234567880000000,31,MASK),(5,32,0xffffffff00000002,1,1)])
def test_word_math(f3,f7,a,b,expected):
    _, r = one(reg(3,1,2,f3,f7,True),a,b)
    assert r['trap'] == 0 and r['rd_data'] == expected

@pytest.mark.parametrize('f3,n,a,expected', [
    (0,1,0x7fffffff,0xffffffff80000000),(0,0,0xffffffff, MASK),
    (1,31,1,0xffffffff80000000),(5,0,0x80000000,0xffffffff80000000),
    (5,1,0xffffffff,0x7fffffff),(5,0x41f,0x80000000,MASK)])
def test_word_immediates(f3,n,a,expected):
    _, r = one(imm(3,1,n,f3,True),a)
    assert r['trap'] == 0 and r['rd_data'] == expected

def test_upper_and_indirect_jump_alias():
    assert one(upper(3,0x80000000))[1]['rd_data'] == 0xffffffff80000000
    assert one(upper(3,0x80000000,True))[1]['rd_data'] == 0
    m, r = one(jalr(1,1,0),BASE+17)
    assert r['next_pc'] == BASE+16 and m.regs[1] == BASE+4
    assert one(jal(3,-8))[1]['next_pc'] == BASE-8

@pytest.mark.parametrize('f3,a,b,taken', [
    (0,1,1,True),(0,1,2,False),(1,1,1,False),(1,1,2,True),
    (4,MASK,0,True),(4,0,MASK,False),(5,MASK,0,False),(5,0,MASK,True),
    (6,MASK,0,False),(6,0,MASK,True),(7,MASK,0,True),(7,0,MASK,False)])
def test_branch_sign_and_negative_displacement(f3,a,b,taken):
    _, r = one(branch(1,2,-4,f3),a,b)
    assert r['next_pc'] == BASE+(-4 if taken else 4) and r['rd'] == 0

@pytest.mark.parametrize('f3,size,expected', [
    (0,1,0xffffffffffffff80),(1,2,0xffffffffffff8080),
    (2,4,0xffffffff80808080),(3,8,0x8080808080808080),
    (4,1,0x80),(5,2,0x8080),(6,4,0x80808080)])
def test_load_extension_all_lanes(f3,size,expected):
    for lane in range(0,8,size):
        m = Machine(load(3,1,-8+lane,f3).to_bytes(4,'little'))
        m.regs[1] = BASE+0x108
        m.mem[0x100:0x108] = bytes([0x80])*8
        r = m.step()
        assert r['rd_data'] == expected and r['mem_addr'] == BASE+0x100+lane
        assert r['mem_rmask'] == ((1<<size)-1)<<lane

@pytest.mark.parametrize('f3,size', [(0,1),(1,2),(2,4),(3,8)])
def test_store_bytes_and_reset_persistence(f3,size):
    for lane in range(0,8,size):
        m, r = one(store(2,1,lane,f3),BASE+0x100,0x8877665544332211)
        assert m.mem[0x100:0x108] == bytes(lane) + bytes.fromhex('1122334455667788')[:size] + bytes(8-lane-size)
        m.reset()
        assert m.mem[0x100+lane] == 0x11 and m.regs == [0]*32

@pytest.mark.parametrize('instruction,a,cause', [
    (jal(1,2),0,0),(jalr(1,1,2),BASE,0),(branch(0,0,2,0),0,0),
    (load(0,1,1,1),BASE,4),(load(3,1,2,2),BASE,4),(load(3,1,4,3),BASE,4),
    (store(2,1,1,1),BASE,6),(store(2,1,2,2),BASE,6),(store(2,1,4,3),BASE,6),
    (load(0,1,0,0),BASE+MAP['ram_bytes'],5),(store(2,1,0,0),BASE+MAP['ram_bytes'],7),
    (load(3,1,0,3),0x180000000,5),(store(2,1,0,3),0x180000000,7),
    (0x73,0,11),(0x100073,0,3),(0x30200073,0,2),(0x200f,0,2),(0x700f,0,2),
    (imm(3,1,32,1,True),0,2),(reg(3,1,2,2,0,True),0,2),
    (reg(3,1,2,1,1,True),0,2),(reg(3,1,2,3,1,True),0,2),(reg(3,1,2,0,2),0,2),
    (imm(3,1,0x800,5),0,2),(load(3,1,0,7),0,2)])
def test_faults_are_precise(instruction,a,cause):
    m, r = one(instruction,a,123)
    assert r['trap'] == 1 and r['cause'] == cause and r['next_pc'] == BASE
    assert r['rd'] == 0 and m.regs[1:4] == [a,123,0]

def test_not_taken_misaligned_target_and_fence():
    assert one(branch(1,2,2,0),1,2)[1]['trap'] == 0
    assert one(0xfff0808f)[1]['trap'] == 0
    for word in (0x100f, (0xabc << 20) | (5 << 15) | (1 << 12) | (7 << 7) | 0x0f):
        m, r = one(word, 1, 2)
        assert r['trap'] == 0 and r['rd'] == 0 and r['next_pc'] == BASE + 4 and m.regs[1:3] == [1, 2]
        assert m.last_name == "FENCE.I"

def test_sdram_fetch_only_in_the_s6_configuration():
    sdram_base = MAP['memories']['sdram']['base']
    code = b"".join(w.to_bytes(4, "little") for w in [imm(5,0,7), 0x100073])
    for fetch in (False, True):
        m = Machine(bytes(8), reset_pc=sdram_base, sdram=True, sdram_fetch=fetch)
        m.sdram[0:8] = code
        r = m.step()
        assert (r['trap'], r['cause']) == ((0, 0) if fetch else (1, 1))
        if fetch: assert m.regs[5] == 7 and m.step()['cause'] == 3

def test_spike_store_is_not_register_write():
    assert parse_commit('core   0: 3 0x80000000 (0x0020b023) mem 0x80004000 0x00000001') == (
        BASE,0x0020b023,0,0,[(0x80004000,1)])
    assert parse_commit('core   0: 3 0x80000000 (0x0000b183) x3  0x00000001 mem 0x80004000')[2:] == (3,1,[(0x80004000,None)])

def test_bus_duplicate_store_and_reset_before_ack():
    instruction = store(2,1,0,3)
    m = Machine(instruction.to_bytes(4,'little'))
    m.regs[1:3] = [BASE+0x100,123]
    bus = BusChecker(m)
    bus.accept([f'{BASE:x}','0','f','0'])
    bus.respond(['0',f'{instruction:x}'])
    bus.accept([f'{BASE+0x100:x}','1','ff','7b'])
    with pytest.raises(AssertionError): bus.accept([f'{BASE+0x100:x}','1','ff','7b'])
    m.reset(); bus.reset()
    assert m.mem[0x100] == 123
    with pytest.raises(AssertionError): bus.respond(['0','0'])
