import random
import json
from pathlib import Path

MAP = json.loads((Path(__file__).resolve().parents[1] / 'config/address_map.json').read_text())
RAM_END = MAP['ram_base'] + MAP['ram_bytes']
HIGH_ALIAS = MAP['ram_base'] + (1 << 32)

def reg(rd, a, b, f3=0, f7=0, word=False):
    return (f7 << 25) | (b << 20) | (a << 15) | (f3 << 12) | (rd << 7) | (0x3b if word else 0x33)

def imm(rd, a, value, f3=0, word=False):
    return ((value & 4095) << 20) | (a << 15) | (f3 << 12) | (rd << 7) | (0x1b if word else 0x13)

def upper(rd, value, pc=False): return (value & 0xfffff000) | (rd << 7) | (0x17 if pc else 0x37)
def load(rd, a, offset, f3): return ((offset & 4095) << 20) | (a << 15) | (f3 << 12) | (rd << 7) | 3
def store(b, a, offset, f3):
    return (((offset >> 5) & 127) << 25) | (b << 20) | (a << 15) | (f3 << 12) | ((offset & 31) << 7) | 0x23
def branch(a, b, offset, f3):
    assert offset % 2 == 0 and -4096 <= offset <= 4094
    n = offset & 8191
    return ((n >> 12) << 31) | (((n >> 5) & 63) << 25) | (b << 20) | (a << 15) | (f3 << 12) | (((n >> 1) & 15) << 8) | (((n >> 11) & 1) << 7) | 0x63
def jal(rd, offset):
    assert offset % 2 == 0 and -(1 << 20) <= offset < (1 << 20)
    n = offset & 0x1fffff
    return ((n >> 20) << 31) | (((n >> 1) & 1023) << 21) | (((n >> 11) & 1) << 20) | (((n >> 12) & 255) << 12) | (rd << 7) | 0x6f
def jalr(rd, a, offset): return ((offset & 4095) << 20) | (a << 15) | (rd << 7) | 0x67
def m(rd, a, b, f3, word=False): return reg(rd, a, b, f3, 1, word)

M_OPS = [(f3, False) for f3 in range(8)] + [(f3, True) for f3 in (0, 4, 5, 6, 7)]
M_EDGES = [0, 1, (1 << 64) - 1, 2, 1 << 63, (1 << 63) - 1, 0xffffffff80000000, 0x7fffffff,
           0x0000000080000000, 0xa5a5a5a5ffffffff, 0x123456780000000d, 0xfffffffffffffff9]

def li(rd, value):
    words = [imm(rd, 0, 0)]
    for byte in (value & ((1 << 64)-1)).to_bytes(8, "big"):
        words += [imm(rd, rd, 8, 1), imm(rd, rd, byte)]
    return words

def cases():
    result = {}
    words = li(1, 0x800000007fffffff) + li(2, 0x7fffffff80000000)
    for f3, f7 in [(0,0),(0,32),(1,0),(2,0),(3,0),(4,0),(5,0),(5,32),(6,0),(7,0)]:
        words += [reg(3,1,2,f3,f7), reg(0,1,2,f3,f7), reg(4,2,1,f3,f7)]
    for f3 in (0,2,3,4,6,7):
        words += [imm(5,1,n,f3) for n in (-2048,-1,0,1,2047)]
    for amount in (0,1,31,32,63,64,65,127):
        words += [imm(2,0,amount)]
        for f3, f7 in ((1,0),(5,0),(5,32)):
            words += [reg(6,1,2,f3,f7), imm(7,1,(amount & 63) | (f7 << 5),f3)]
    words += [upper(8,0x80000000),upper(9,0x7ffff000),upper(10,0xfffff000,True),upper(11,0x80000000,True)]
    result["alu64"] = words

    words = []
    for value in (0,1,0x7fffffff,0x80000000,0xffffffff,0x1234567880000001,0xffffffff00000001):
        words += li(1,value)
        for n in (-2048,-1,0,1,2047): words += [imm(3,1,n,word=True)]
        for amount in (0,1,31,32,63,64,0x7ff):
            words += [imm(2,0,amount)]
            for f3,f7 in ((0,0),(0,32),(1,0),(5,0),(5,32)):
                words += [reg(4,1,2,f3,f7,True)]
            for f3,high in ((1,0),(5,0),(5,0x400)):
                words += [imm(5,1,(amount & 31) | high,f3,True)]
    result["word_ops"] = words

    words = [upper(20,0x4000,True),imm(1,0,-1),imm(2,0,1)]
    for f3 in (0,1,4,5,6,7):
        for a,b in ((1,1),(1,2),(2,1)):
            words += [branch(a,b,8,f3), store(2,20,0,3), imm(3,3,1)]
    words += [imm(6,0,8),imm(7,0,0),imm(7,7,3),imm(6,6,-1),branch(6,0,-8,1)]
    words += [jal(8,8), store(2,20,8,3), upper(9,0,True), imm(9,9,17),jalr(9,9,0),store(2,20,16,3),imm(10,0,99)]
    result["control"] = words

    words = [upper(20,0x4000,True)] + li(1,0x80ff7fff8001ff80)
    for f3 in range(4):
        size = 1 << f3
        for offset in range(0,16,size):
            words += [store(1,20,offset,f3),load(2,20,offset,f3),load(0,20,offset,f3)]
            if f3 < 3: words += [load(3,20,offset,f3+4)]
    words += [imm(20,20,16),load(4,20,-8,3),store(4,20,-16,3),0x0ff0000f,load(5,20,-16,3)]
    words += li(20,RAM_END)
    for f3 in range(4): words += [store(1,20,-(1<<f3),f3),load(6,20,-(1<<f3),f3)]
    result["memory_sizes"] = words

    result["array_loop"] = [upper(20,0x4000,True),imm(1,0,16),imm(2,0,1),imm(3,0,0),
        store(2,20,0,3),load(4,20,0,3),reg(3,3,4),imm(20,20,8),imm(2,2,1),imm(1,1,-1),branch(1,0,-24,1),
        store(3,20,0,3),load(5,20,0,3)]
    result["reset_store"] = [upper(20,0x4000,True),load(1,20,0,3),imm(1,1,1),store(1,20,0,3),load(2,20,0,3),0x0ff0000f]

    prefix = [imm(1,0,5),imm(2,0,7)]
    faults = {
        "ecall": [0x73], "ebreak":[0x100073],
        "jal_align":[jal(1,2)], "branch_align":[branch(0,0,2,0)],
        "jalr_align":[upper(4,0,True),jalr(4,4,2)],
        "fetch_bounds":li(4,RAM_END)+[jalr(0,4,0)],
        "fetch_high":li(4,HIGH_ALIAS)+[jalr(0,4,0)],
        "load_bounds":li(4,RAM_END)+[load(0,4,0,3)],
        "store_bounds":li(4,RAM_END)+[store(1,4,0,3)],
        "load_high":li(4,HIGH_ALIAS+0x4000)+[load(1,4,0,0)],
        "store_high":li(4,HIGH_ALIAS+0x4000)+[store(1,4,0,0)],
        "load_zero":[load(0,0,0,0)], "store_zero":[store(1,0,0,0)],
        "shift64_reserved":[imm(1,1,0x800,1)],
        "shiftw_reserved":[imm(1,1,32,1,True)],
        "m_word_reserved_1":[m(1,1,2,1,True)], "m_word_reserved_2":[m(1,1,2,2,True)],
        "m_word_reserved_3":[m(1,1,2,3,True)], "op_funct7_2_reserved":[reg(1,1,2,0,2)],
        "branch_reserved":[branch(1,2,8,2)], "load_reserved":[load(1,0,0,7)],
        "store_reserved":[store(1,0,0,4)],"jalr_reserved":[jalr(1,1,0)|0x1000],
        "csr":[0x300010f3], "mret":[0x30200073]
    }
    for f3 in (1,2,3):
        faults[f"load_align_{f3}"] = [upper(4,0x4000,True),load(1,4,1,f3)]
        faults[f"store_align_{f3}"] = [upper(4,0x4000,True),store(1,4,1,f3)]
    for name, code in faults.items(): result[f"fault_{name}"] = prefix + code
    result["promoted_divuw"] = prefix + [reg(1,1,2,5,1,True)]
    result["promoted_fence_i"] = prefix + [0x100f, (0xabc << 20) | (5 << 15) | (1 << 12) | (7 << 7) | 0x0f, imm(3,1,2)]
    result["branch_untaken_align"] = [imm(1,0,1),branch(0,1,2,0),imm(2,0,99)]
    result["fence_variants"] = prefix + [0x0000000f,0x0ff0000f,0x8330000f,0xfff0808f,0x0100000f]

    for seed in (11,29,97):
        rng = random.Random(seed)
        code = [upper(20,0x4000,True)]
        for rd in range(1,16): code += li(rd,rng.getrandbits(64))
        for _ in range(300):
            rd,a,b = (rng.randrange(16) for _ in range(3))
            category = rng.randrange(6)
            if category == 0:
                f3,f7 = rng.choice([(0,0),(0,32),(1,0),(2,0),(3,0),(4,0),(5,0),(5,32),(6,0),(7,0)])
                code += [reg(rd,a,b,f3,f7)]
            elif category == 1:
                f3 = rng.choice([0,2,3,4,6,7]); code += [imm(rd,a,rng.randint(-2048,2047),f3)]
            elif category == 2:
                f3,f7 = rng.choice([(0,0),(0,32),(1,0),(5,0),(5,32)]); code += [reg(rd,a,b,f3,f7,True)]
            elif category == 3:
                f3 = rng.randrange(4); offset = rng.randrange(64) * 8
                code += [store(b,20,offset,f3),load(rd,20,offset,f3)]
            elif category == 4:
                f3 = rng.choice([0,1,4,5,6,7]); code += [branch(a,b,8,f3),imm(rd,a,1)]
            else:
                word = bool(rng.randrange(2)); f3,high = rng.choice([(1,0),(5,0),(5,0x400)])
                code += [imm(rd,a,rng.randrange(32 if word else 64)|high,f3,word)]
        result[f"rv64_random_{seed}"] = code
    result.update(m_cases())
    result.update(pipe_cases())
    result.update(s4_cases())
    return result

def m_cases():
    result = {}
    setup = []
    for index, value in enumerate(M_EDGES, 1): setup += li(index, value)
    for name, ops in (("m_mul_edges", [o for o in M_OPS if o[0] < 4]),
                      ("m_div_edges", [o for o in M_OPS if o[0] >= 4 and not o[1]]),
                      ("m_divw_edges", [o for o in M_OPS if o[0] >= 4 and o[1]])):
        words, rd = list(setup), 13
        for f3, word in ops:
            for a in range(1, len(M_EDGES) + 1):
                for b in range(1, len(M_EDGES) + 1):
                    words.append(m(0 if (a * 7 + b) % 29 == 0 else rd, a, b, f3, word))
                    rd = 13 if rd == 31 else rd + 1
        result[name] = words

    words = [upper(20,0x4000,True), imm(1,0,1), imm(2,0,10),
             m(1,1,2,0), imm(2,2,-1), branch(2,0,-8,1),
             store(1,20,0,3), load(3,20,0,3), m(4,3,3,0), m(5,4,4,3),
             imm(6,0,1071), imm(7,0,462),
             branch(7,0,20,0), m(8,6,7,7), imm(6,7,0), imm(7,8,0), jal(0,-16)]
    words += li(9,987654321) + [imm(10,0,10), imm(11,0,0),
             m(12,9,10,7), reg(11,11,12), m(9,9,10,5), branch(9,0,-12,1),
             store(11,20,8,3), m(16,11,10,6), branch(16,0,8,0), imm(17,0,1),
             imm(13,0,-7), imm(14,0,2), m(13,13,14,4), imm(14,0,-7), imm(15,0,2), m(14,14,15,6),
             m(15,14,15,0), m(0,1,0,4), m(18,1,0,4), m(19,1,0,6),
             m(21,13,13,1), m(22,13,1,2), m(23,13,1,3)]
    words += li(24,0xffffffff00000007) + li(25,0x0000000200000002) + [
             m(26,24,25,5,True), m(27,24,25,7,True), m(28,24,25,4,True), m(29,24,25,6,True),
             m(30,24,25,0,True), m(31,25,24,0,True), load(9,20,8,3), m(9,9,9,0)]
    result["m_mixed"] = words

    result["m_reset"] = li(1,0x8000000000000001) + li(2,0xfffffffffffffffd) + [
        m(3,1,2,4), m(4,1,2,1), m(1,1,2,6), imm(5,1,0)]
    result["m_reset_w"] = li(1,0x12345678fffffff9) + li(2,0x9abcdef000000003) + [
        m(3,1,2,0,True), m(4,1,2,6,True), m(2,1,2,5,True), imm(5,2,0)]

    for seed in (13,31,101):
        rng = random.Random(seed)
        code = [upper(20,0x4000,True)]
        for rd in range(1,16):
            code += li(rd, rng.choice(M_EDGES) if rng.randrange(3) == 0 else rng.getrandbits(rng.randint(1,64)))
        for _ in range(240):
            rd,a,b = (rng.randrange(16) for _ in range(3))
            category = rng.randrange(6)
            if category < 3:
                f3, word = rng.choice(M_OPS); code += [m(rd,a,b,f3,word)]
            elif category == 3:
                f3 = rng.randrange(4); offset = rng.randrange(64) * 8
                code += [store(b,20,offset,f3), load(rd,20,offset,f3)]
            elif category == 4:
                f3 = rng.choice([0,1,4,5,6,7]); code += [branch(a,b,8,f3), m(rd,a,b,rng.randrange(8))]
            else:
                f3,f7 = rng.choice([(0,0),(0,32),(5,32),(3,0)]); code += [reg(rd,a,b,f3,f7, bool(rng.randrange(2)) and f3 != 3)]
        result[f"m_random_{seed}"] = code
    return result

def pipe_cases():
    result = {}
    nop = imm(0, 0, 0)
    base = [upper(20, 0x4000, True)]
    words = base + [imm(1,0,5), reg(2,1,1), reg(3,2,1), reg(4,1,3), reg(5,4,2,0,32),
             imm(0,1,7), reg(6,0,1), reg(7,1,0),
             imm(8,0,77), store(8,20,0,3), load(9,20,0,3), store(9,20,8,3),
             load(10,20,8,3), imm(11,10,1),
             load(12,20,0,3), nop, reg(13,12,12),
             load(14,20,0,3), nop, nop, reg(15,14,14),
             load(16,20,0,3), branch(16,8,8,0), imm(17,0,1),
             imm(18,0,3), branch(18,5,8,1), imm(17,17,2),
             upper(19,0,True), imm(19,19,16), jalr(21,19,0), imm(17,17,4), imm(17,17,8),
             load(22,20,0,3), store(22,20,16,2), load(23,20,16,6), branch(23,22,8,0), imm(17,17,16)]
    words += [branch(0,0,16,0), store(8,20,24,3), m(24,8,8,0), store(8,20,32,3),
              jal(0,12), store(8,20,40,3), store(8,20,48,3),
              load(25,20,24,3), load(26,20,40,3)]
    words += [m(27,1,2,0), m(28,27,27,0), store(28,20,56,3), branch(28,0,8,1), imm(17,17,32),
              m(29,28,1,4), load(30,20,56,3), m(31,30,30,1), m(24,1,2,0), m(24,24,3,7),
              load(25,20,0,3), m(26,1,3,0), reg(26,26,25)]
    result["pipe_forward"] = words
    result["pipe_redirect"] = [imm(1,0,9), nop, imm(1,1,-1), branch(1,0,-4,1),
        jal(0,4), jal(0,8), imm(2,0,1), jal(0,8), imm(2,2,2), imm(3,0,3),
        upper(4,0,True), imm(4,4,20), jalr(0,4,0), imm(3,3,64), imm(3,3,128), nop,
        imm(5,0,4), imm(5,5,-1), imm(6,6,1), branch(5,0,-8,1), imm(7,6,0)]
    for name, access in (("pipe_kill_load", load(5,4,0,3)), ("pipe_kill_store", store(1,4,0,3))):
        result[name] = base + [imm(1,0,-7), imm(2,0,3)] + li(4, RAM_END) + [access, m(6,1,2,4), store(1,20,0,3), m(7,1,2,0)]
    result["pipe_trap_shadow"] = base + [imm(1,0,1), store(1,20,0,3), 0x73, store(1,20,8,3), m(2,1,1,0), jal(0,-8)]
    result["pipe_misaligned_shadow"] = base + [imm(1,0,1), load(2,20,1,3), store(1,20,8,3), m(3,1,1,4)]
    for seed in (3, 17, 59):
        rng = random.Random(seed)
        code = base[:]
        for rd in range(1, 7): code += li(rd, rng.choice(M_EDGES) if rng.randrange(2) else rng.getrandbits(64))
        for _ in range(400):
            rd, a, b = (rng.randrange(7) for _ in range(3))
            category = rng.randrange(8)
            if category == 0:
                f3, f7 = rng.choice([(0,0),(0,32),(1,0),(2,0),(3,0),(4,0),(5,0),(5,32),(6,0),(7,0)])
                code += [reg(rd,a,b,f3,f7)]
            elif category == 1: code += [imm(rd,a,rng.randint(-2048,2047),rng.choice([0,2,3,4,6,7]))]
            elif category == 2:
                f3, word = rng.choice(M_OPS); code += [m(rd,a,b,f3,word)]
            elif category == 3:
                f3 = rng.randrange(4); offset = rng.randrange(8) * 8
                code += [store(b,20,offset,f3), load(rd,20,offset,rng.choice([f3, f3+4] if f3 < 3 else [3]))]
            elif category == 4:
                f3 = rng.randrange(7); offset = rng.randrange(8) * 8
                code += [load(rd,20,offset,f3), reg(a,rd,b)]
            elif category == 5:
                skip = rng.randrange(1, 4)
                code += [branch(a,b,4*(skip+1),rng.choice([0,1,4,5,6,7]))]
                code += [rng.choice([store(b,20,8*rng.randrange(8),3), m(rd,a,b,rng.randrange(8)), imm(rd,a,1)]) for _ in range(skip)]
            elif category == 6:
                skip = rng.randrange(1, 3)
                code += [jal(rng.choice([0,rd]), 4*(skip+1))] + [store(a,20,8*rng.randrange(8),3)] * skip
            else:
                f3, word = rng.choice(M_OPS); code += [m(rd,a,b,f3,word), reg(b,rd,a), store(rd,20,8*rng.randrange(8),3)]
        result[f"pipe_random_{seed}"] = code
    result["pipe_ras"] = pipe_ras()
    return result

def pipe_ras():
    # Calls and returns for the return-address stack, each in a loop so the
    # BTB learns the returns: leaf calls; recursion 12 deep (past the 8-entry
    # stack) with ld ra just before ret; x5 as the link register; a callee that
    # returns 4 bytes past the call (the stack's prediction is wrong and EX
    # must redirect); coroutine swaps (JALR that pops and pushes); a push-only
    # jalr ra, 0(ra); and a return with an odd offset. x17 and x12 add up
    # markers that a wrong path or a skipped call would change; the expected
    # values are checked in check_all.py.
    prog, labels = [], {}
    def at(name): prog.append(name)
    def to(name, make): prog.append((name, make))
    loop = lambda name, reg: to(name, lambda off: branch(reg, 0, off, 1))
    prog += [upper(20, 0x4000, True), imm(2, 20, 1024), imm(17, 0, 0), imm(12, 0, 0)]
    prog += [imm(11, 0, 12)]; at("loop1")
    to("leaf", lambda off: jal(1, off)); prog += [imm(17, 17, 1), imm(11, 11, -1)]; loop("loop1", 11)
    prog += [imm(13, 0, 2)]; at("outer")
    prog += [imm(10, 0, 12)]; to("rec", lambda off: jal(1, off)); prog += [imm(17, 17, 2), imm(13, 13, -1)]; loop("outer", 13)
    prog += [imm(11, 0, 6)]; at("loop3")
    to("leaf5", lambda off: jal(5, off)); prog += [imm(17, 17, 4), imm(11, 11, -1)]; loop("loop3", 11)
    prog += [imm(11, 0, 6)]; at("loop4")
    to("skip", lambda off: jal(1, off)); prog += [imm(17, 17, 1000), imm(17, 17, 8), imm(11, 11, -1)]; loop("loop4", 11)
    prog += [imm(11, 0, 6)]; at("loop5")
    to("co", lambda off: jal(5, off)); prog += [imm(17, 17, 16), jalr(5, 1, 0), imm(11, 11, -1)]; loop("loop5", 11)
    prog += [imm(11, 0, 6)]; at("loop6")
    prog += [upper(1, 0, True)]; to("pushf", lambda off: imm(1, 1, off + 4)); prog += [jalr(1, 1, 0), imm(17, 17, 32), imm(11, 11, -1)]; loop("loop6", 11)
    prog += [imm(11, 0, 6)]; at("loop7")
    to("oddf", lambda off: jal(1, off)); prog += [imm(17, 17, 64), imm(11, 11, -1)]; loop("loop7", 11)
    prog += [store(17, 20, 0, 3), store(12, 20, 8, 3), 0]
    at("leaf"); prog += [imm(12, 12, 3), jalr(0, 1, 0)]
    at("rec"); to("base", lambda off: branch(10, 0, off, 0))
    prog += [imm(2, 2, -16), store(1, 2, 0, 3), imm(10, 10, -1)]; to("rec", lambda off: jal(1, off))
    prog += [imm(12, 12, 1), imm(2, 2, 16), load(1, 2, -16, 3), jalr(0, 1, 0)]
    at("base"); prog += [jalr(0, 1, 0)]
    at("leaf5"); prog += [imm(12, 12, 5), jalr(0, 5, 0)]
    at("skip"); prog += [imm(1, 1, 4), jalr(0, 1, 0)]
    at("co"); prog += [imm(12, 12, 1), jalr(1, 5, 0), imm(12, 12, 2), jalr(0, 5, 0)]
    at("pushf"); prog += [imm(12, 12, 7), jalr(0, 1, 0)]
    at("oddf"); prog += [imm(12, 12, 9), jalr(0, 1, 1)]
    pc = 0
    for item in prog:
        if isinstance(item, str): labels[item] = pc
        else: pc += 4
    words, pc = [], 0
    for item in prog:
        if isinstance(item, str): continue
        words.append(item[1](labels[item[0]] - pc) if isinstance(item, tuple) else item)
        pc += 4
    return words

def csr(rd, rs1, address, f3): return (address << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | 0x73
MSTATUS, MIE, MTVEC, MSCRATCH, MEPC, MCAUSE, MTVAL, MIP = 0x300, 0x304, 0x305, 0x340, 0x341, 0x342, 0x343, 0x344
MISA, MINSTRET, MHARTID, MVENDORID = 0x301, 0xB02, 0xF14, 0xF11
MRET, WFI = 0x30200073, 0x10500073

def _address_of(words, index, reg):
    at = len(words)
    words += [upper(reg, 0, True), imm(reg, reg, 0)]
    return lambda target: words.__setitem__(at + 1, imm(reg, reg, 4 * (target - at)))

def s4_cases():
    result = {}
    w = [upper(20, 0x4000, True), csr(0, 5, MSCRATCH, 5), csr(1, 0, MSCRATCH, 2)]
    w += li(2, 0xa5a5a5a55a5a5a5a) + [csr(3, 2, MSCRATCH, 1), csr(4, 2, MSCRATCH, 3), csr(5, 31, MSCRATCH, 6),
         csr(6, 3, MSCRATCH, 7), csr(0, 0, MSCRATCH, 2), csr(7, 0, MISA, 2), csr(8, 0, MHARTID, 2),
         csr(9, 0, MVENDORID, 2), csr(10, 0, MINSTRET, 2), imm(0, 0, 0), imm(0, 0, 0), csr(11, 0, MINSTRET, 2),
         csr(0, 0, MINSTRET, 1), csr(12, 0, MINSTRET, 2), csr(13, 0, MINSTRET, 2)]
    w += li(14, 0x123454) + [csr(0, 14, MTVEC, 1), csr(15, 0, MTVEC, 2)] + li(14, 0x123457) + [csr(0, 14, MEPC, 1), csr(16, 0, MEPC, 2)]
    w += li(14, 0xfff) + [csr(0, 14, MIE, 1), csr(17, 0, MIE, 2), csr(0, 0, MIE, 1),
         csr(0, 14, MCAUSE, 1), csr(18, 0, MCAUSE, 2), csr(0, 2, MTVAL, 1), csr(19, 0, MTVAL, 2),
         csr(0, 0, MTVEC, 1), csr(0, 8, MSTATUS, 6), csr(21, 0, MSTATUS, 2), csr(0, 8, MSTATUS, 7)]
    patch = _address_of(w, 0, 22)
    w += [csr(0, 22, MEPC, 1)] + li(23, 0x80) + [csr(0, 23, MSTATUS, 2), MRET, imm(24, 0, 99)]
    patch(len(w))
    w += [csr(25, 0, MSTATUS, 2), csr(0, 31, MSTATUS, 7), store(25, 20, 0, 3)]
    result["s4_csr"] = w
    result["s4_wfi"] = [imm(1, 0, 1), WFI, imm(1, 1, 1), WFI]

    w = [upper(20, 0x4000, True), imm(21, 20, 0), imm(22, 0, 0)]
    set_handler = _address_of(w, 0, 5)
    w += [csr(0, 5, MTVEC, 1), imm(1, 0, 1)]
    w += [0x00000073, imm(10, 10, 1), 0x00100073, imm(10, 10, 1), 0x00000000, imm(10, 10, 1),
          load(1, 20, 1, 3), imm(10, 10, 1), store(1, 20, 3, 3), imm(10, 10, 1), load(1, 20, 2, 2), imm(10, 10, 1)]
    w += li(4, HIGH_ALIAS) + [load(1, 4, 0, 3), imm(10, 10, 1), store(1, 4, 0, 3), imm(10, 10, 1)]
    w += [upper(4, 0, True), imm(4, 4, 10), jalr(0, 4, 0), imm(10, 10, 1), branch(0, 0, 6, 0), imm(10, 10, 1),
          csr(0, 1, MHARTID, 1), imm(10, 10, 1), csr(1, 0, 0x7c0, 2), imm(10, 10, 1), csr(0, 0, MISA, 1), imm(10, 10, 1)]
    resume = _address_of(w, 0, 23)
    w += li(4, RAM_END) + [jalr(0, 4, 0)]
    resume(len(w))
    w += [imm(10, 10, 1), csr(9, 0, MINSTRET, 2), csr(0, 0, MTVEC, 1), 0x00100073]
    set_handler(len(w))
    w += [csr(5, 0, MCAUSE, 2), csr(6, 0, MEPC, 2), csr(7, 0, MTVAL, 2), store(5, 21, 0, 3), store(6, 21, 8, 3),
          store(7, 21, 16, 3), imm(21, 21, 24), imm(22, 22, 1), imm(28, 0, 1), branch(5, 28, 16, 0),
          imm(6, 6, 4), csr(0, 6, MEPC, 1), MRET, csr(0, 23, MEPC, 1), MRET]
    result["s4_traps"] = w

    w = [upper(20, 0x4000, True), imm(24, 20, 0x100)]
    set_handler = _address_of(w, 0, 5)
    w += [csr(0, 5, MTVEC, 1)] + li(6, 0x888) + [csr(0, 6, MIE, 1), csr(0, 8, MSTATUS, 6), imm(1, 0, 40), imm(5, 0, 0)]
    loop = len(w)
    w += [m(2, 1, 1, 0), m(3, 2, 1, 4), store(2, 20, 0, 3), load(4, 20, 0, 3), reg(5, 5, 4), reg(5, 5, 3),
          m(6, 5, 1, 7, True), imm(1, 1, -1)]
    w += [branch(1, 0, 4 * (loop - len(w)), 1)]
    w += [store(5, 20, 8, 3), csr(0, 8, MSTATUS, 7), csr(0, 0, MTVEC, 1), 0x00100073]
    set_handler(len(w))
    w += [csr(25, 0, MCAUSE, 2), imm(26, 0, 1), imm(26, 26, 63, 1), reg(26, 25, 26, 0, 0), reg(26, 25, 0, 0, 0)]
    w[-2:] = [imm(26, 25, 1, 1), imm(26, 26, 1, 5)]
    w += [imm(26, 26, 3, 1), reg(26, 26, 24), load(27, 26, 0, 3), imm(27, 27, 1), store(27, 26, 0, 3), MRET]
    result["s4_interrupt"] = w
    return result

SDRAM_BASE = MAP['memories']['sdram']['base']
SDRAM_END = SDRAM_BASE + MAP['memories']['sdram']['bytes']

def s5_cases():
    result = {}
    w = [upper(21, 0x4000, True)] + li(20, SDRAM_BASE) + li(1, 0x0123456789abcdef)
    w += [store(1, 20, 0, 3), load(2, 20, 0, 3), reg(3, 2, 1, 4, 0), store(3, 21, 0, 3)]
    for lane in range(8):
        w += [imm(4, 0, 0x81 + 0x11 * lane - 256 * ((0x81 + 0x11 * lane) > 127)), store(4, 20, 8 + lane, 0)]
    w += [load(5, 20, 8, 3)] + [load(6 + f3, 20, 8 + 4 * (f3 & 1), f3) for f3 in (0, 1, 2, 4, 5, 6)]
    w += [store(1, 20, 16, 1), store(2, 20, 18, 1), store(5, 20, 20, 2), load(12, 20, 16, 3), load(13, 20, 20, 6)]
    for offset in (0x7f8, 0x800, 0x1000, 0x1800, 0x1ff8, 0x2000):
        w += li(14, SDRAM_BASE + offset) + li(15, (offset << 32) | 0xa5a50000 | offset)
        w += [store(15, 14, 0, 3), load(16, 14, 0, 3), branch(16, 15, 8, 0), imm(17, 17, 1)]
    w += li(14, SDRAM_END - 8) + [store(1, 14, 0, 3), load(18, 14, 0, 3), m(19, 18, 1, 0), store(19, 21, 8, 3)]
    w += [imm(22, 0, 16), upper(23, 0, True), imm(24, 20, 0x100), imm(25, 0, 0)]
    loop = len(w)
    w += [load(26, 23, 0, 3), m(26, 26, 22, 0), store(26, 24, 0, 3), load(27, 24, 0, 3), reg(25, 25, 27),
          imm(23, 23, 8), imm(24, 24, 2047), imm(24, 24, 9), imm(22, 22, -1)]
    w += [branch(22, 0, 4 * (loop - len(w)), 1), store(25, 21, 16, 3)]
    w += li(28, SDRAM_END) + [load(29, 28, 0, 3)]
    result["s5_sdram"] = w
    for seed in (5, 23):
        rng = random.Random(seed)
        windows = [0x7e0, 0x1fe0, MAP['memories']['sdram']['bytes'] - 64, rng.randrange(1 << 20, 1 << 25) & ~63]
        code = [upper(24, 0x4000, True)]
        for i, offset in enumerate(windows):
            code += li(20 + i, SDRAM_BASE + offset)
        for rd in range(1, 8): code += li(rd, rng.getrandbits(64))
        for i in range(4):
            code += [store(1 + (k % 7), 20 + i, 8 * k, 3) for k in range(8)]
        for _ in range(300):
            rd, a, b = (rng.randrange(1, 8) for _ in range(3))
            window = 20 + rng.randrange(4)
            category = rng.randrange(7)
            if category == 0:
                f3 = rng.randrange(4); offset = rng.randrange(64 >> f3) << f3
                code += [store(b, window, offset, f3)]
            elif category == 1:
                f3 = rng.randrange(7); size = 1 << (f3 & 3); offset = rng.randrange(64 // size) * size
                code += [load(rd, window, offset, f3)]
            elif category == 2:
                f3 = rng.randrange(7); size = 1 << (f3 & 3); offset = rng.randrange(64 // size) * size
                code += [load(rd, window, offset, f3), reg(a, rd, b), store(a, 24, 8 * rng.randrange(8), 3)]
            elif category == 3:
                f3, word = rng.choice(M_OPS); code += [load(rd, window, 8 * rng.randrange(8), 3), m(a, rd, b, f3, word)]
            elif category == 4:
                code += [load(rd, 24, 8 * rng.randrange(8), 3), store(rd, window, 8 * rng.randrange(8), 3)]
            elif category == 5:
                skip = rng.randrange(1, 3)
                code += [load(rd, window, 8 * rng.randrange(8), 3), branch(rd, b, 4 * (skip + 1), rng.choice([0, 1, 4, 5, 6, 7]))]
                code += [store(a, window, 8 * rng.randrange(8), 3) for _ in range(skip)]
            else:
                f3, f7 = rng.choice([(0,0),(0,32),(4,0),(6,0),(7,0)]); code += [reg(rd, a, b, f3, f7)]
        for i in range(4):
            for k in range(8): code += [load(2, 20 + i, 8 * k, 3), reg(1, 1, 2, 4, 0)]
        code += [store(1, 24, 0, 3)]
        result[f"s5_random_{seed}"] = code
    w = li(20, SDRAM_BASE) + [imm(1, 0, 0x13), store(1, 20, 0, 2), store(0, 20, 4, 2), jalr(0, 20, 0)]
    result["s5_fetch_fault"] = w
    return result

FENCE_I = 0x0000100f
NOP = 0x00000013
BODY_WORD = 0x400

def _pc_relative(words, reg):
    at = len(words)
    words += [upper(reg, 0, True), imm(reg, reg, 0)]
    def patch(target):
        offset = 4 * (target - at)
        high = (offset + 0x800) >> 12
        words[at] = upper(reg, (high << 12) & 0xfffff000, True)
        words[at + 1] = imm(reg, reg, offset - (high << 12))
    return patch

def _place_bodies(prologue, bodies):
    assert len(prologue) <= BODY_WORD, "prologue overlaps the body area"
    image = prologue
    image += [0] * (BODY_WORD - len(prologue))
    starts = []
    for body in bodies:
        body = body + [NOP] * (len(body) % 2)
        starts.append(len(image))
        image += body
    return image, starts

def _copy(words, dest, source_reg, count_dwords):
    words += li(6, dest) + [imm(7, 0, count_dwords)]
    loop = len(words)
    words += [load(5, source_reg, 0, 3), store(5, 6, 0, 3), imm(source_reg, source_reg, 8), imm(6, 6, 8), imm(7, 7, -1)]
    words += [branch(7, 0, 4 * (loop - len(words)), 1)]

def s6_cases():
    result = {}
    a_base, b_base, c_base = SDRAM_BASE + 0x100, SDRAM_BASE + 0x1100, SDRAM_BASE + 0x1fe0
    body_a = [imm(10, 10, 1), imm(11, 0, 5),
              imm(12, 12, 3), reg(13, 12, 10, 4), imm(13, 13, 1, 1), reg(14, 14, 13), imm(15, 15, 1),
              reg(16, 14, 15, 0, 32), reg(17, 17, 16, 6), reg(18, 17, 12, 7), imm(11, 11, -1)]
    body_a += [branch(11, 0, -36, 1), jalr(0, 1, 0)]
    body_b = [imm(19, 19, 2), m(31, 19, 19, 0), store(31, 25, 0, 3), load(26, 25, 0, 3), reg(27, 27, 26), jalr(0, 1, 0)]
    body_c = [imm(28, 0, 1)] + [imm(28, 28, k) for k in range(2, 12)] + [store(28, 30, 24, 3), 0x00100073]
    w = [upper(30, 0x4000, True)] + li(25, SDRAM_BASE + 0x3000)
    patches = [_pc_relative(w, 21)]
    _copy(w, a_base, 21, (len(body_a) + 1) // 2)
    patches.append(_pc_relative(w, 21))
    _copy(w, b_base, 21, (len(body_b) + 1) // 2)
    patches.append(_pc_relative(w, 21))
    _copy(w, c_base, 21, (len(body_c) + 1) // 2)
    w += [FENCE_I] + li(23, a_base) + li(24, b_base) + [imm(9, 0, 3)]
    loop = len(w)
    w += [jalr(1, 23, 0), jalr(1, 24, 0), imm(9, 9, -1)]
    w += [branch(9, 0, 4 * (loop - len(w)), 1)]
    w += li(5, imm(10, 10, 7)) + [store(5, 23, 0, 2), FENCE_I, jalr(1, 23, 0)]
    w += [load(6, 23, 0, 3), load(7, 24, 8, 3), store(10, 30, 0, 3), store(27, 30, 8, 3), store(6, 30, 16, 3)]
    w += li(8, c_base) + [jalr(0, 8, 0)]
    image, starts = _place_bodies(w, [body_a, body_b, body_c])
    for patch, start in zip(patches, starts): patch(start)
    result["s6_icache"] = image

    base = SDRAM_BASE + 0x40000
    w = [upper(30, 0x4000, True)] + li(20, base) + li(21, base + 4096) + li(22, base + 2048) + li(23, base + 0x10000)
    for rd, value in ((1, 0x0123456789abcdef), (2, 0xfedcba9876543210), (3, 0x8000000000000001), (4, 0x00ff00ff00ff00ff)):
        w += li(rd, value)
    for window in (20, 21, 22, 23):
        w += [store(1 + k % 4, window, 8 * k, 3) for k in range(8)]
    w += [load(5, 20, 0, 3), load(6, 20, 8, 3), load(7, 20, 16, 2), load(8, 20, 22, 5), load(9, 20, 31, 0),
          load(10, 20, 32, 3), load(11, 20, 28, 6), load(12, 20, 24, 4)]
    w += [store(1, 20, 3, 0), store(2, 20, 10, 1), store(3, 20, 20, 2), store(4, 20, 24, 3),
          load(13, 20, 0, 3), load(14, 20, 8, 3), load(15, 20, 16, 3), load(16, 20, 24, 3)]
    w += [load(17, 21, 0, 3), load(18, 20, 0, 3), load(19, 22, 8, 3), load(24, 23, 16, 3), load(26, 20, 16, 3)]
    w += [store(4, 21, 0, 3), load(27, 21, 0, 3), load(28, 21, 0, 3)]
    w += [imm(9, 0, 2), imm(29, 0, 0)]
    outer = len(w)
    w += [imm(31, 20, 0), imm(8, 0, 8)]
    inner = len(w)
    w += [load(7, 31, 0, 3), reg(29, 29, 7), imm(31, 31, 8), imm(8, 8, -1)]
    w += [branch(8, 0, 4 * (inner - len(w)), 1), imm(9, 9, -1)]
    w += [branch(9, 0, 4 * (outer - len(w)), 1)]
    for rd in (5, 6, 7, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 24, 26, 27, 28):
        w += [reg(29, 29, rd, 4)]
    w += [store(29, 30, 0, 3)]
    result["s6_dcache"] = w

    w = li(20, SDRAM_END - 8) + [imm(1, 0, 0x13), store(0, 20, 0, 2), store(1, 20, 4, 2), FENCE_I, jalr(0, 20, 4)]
    result["s6_fetch_end"] = w

    for seed in (7, 19):
        rng = random.Random(seed)
        start = rng.randrange(1 << 16, 1 << 24) & ~63
        windows = [start, start + 2048, start + 4096, start + 0x10000]
        body = []
        for i in range(4):
            body += [store(1 + (k % 7), 20 + i, 8 * k, 3) for k in range(8)]
        for _ in range(450):
            rd, a, b = (rng.randrange(1, 8) for _ in range(3))
            window = 20 + rng.randrange(4)
            category = rng.randrange(8)
            if category == 0:
                f3 = rng.randrange(4); offset = rng.randrange(64 >> f3) << f3
                body += [store(b, window, offset, f3)]
            elif category in (1, 2):
                f3 = rng.randrange(7); size = 1 << (f3 & 3); offset = rng.randrange(64 // size) * size
                body += [load(rd, window, offset, f3)]
            elif category == 3:
                f3, word = rng.choice(M_OPS); body += [load(rd, window, 8 * rng.randrange(8), 3), m(a, rd, b, f3, word)]
            elif category == 4:
                body += [load(rd, 24, 8 * rng.randrange(8), 3), store(rd, window, 8 * rng.randrange(8), 3)]
            elif category == 5:
                skip = rng.randrange(1, 4)
                body += [load(rd, window, 8 * rng.randrange(8), 3), branch(rd, b, 4 * (skip + 1), rng.choice([0, 1, 4, 5, 6, 7]))]
                body += [rng.choice([store(a, window, 8 * rng.randrange(8), 3), imm(a, b, rng.randint(-2048, 2047))]) for _ in range(skip)]
            elif category == 6:
                body += [load(rd, window, 8 * rng.randrange(8), 3), reg(a, rd, b), store(a, 24, 8 * rng.randrange(8), 3)]
            else:
                f3, f7 = rng.choice([(0, 0), (0, 32), (4, 0), (6, 0), (7, 0), (1, 0), (5, 32)]); body += [reg(rd, a, b, f3, f7)]
        for i in range(4):
            for k in range(8): body += [load(2, 20 + i, 8 * k, 3), reg(1, 1, 2, 4, 0)]
        body += [store(1, 24, 0, 3), 0x00100073]
        dest = SDRAM_BASE + 0x8000
        w = [upper(24, 0x4000, True)]
        for i, offset in enumerate(windows): w += li(20 + i, SDRAM_BASE + offset)
        patch = _pc_relative(w, 21)
        _copy(w, dest, 21, (len(body) + 1) // 2)
        for rd in range(1, 8): w += li(rd, rng.getrandbits(64))
        w += li(21, SDRAM_BASE + windows[1]) + [FENCE_I] + li(8, dest) + [jalr(0, 8, 0)]
        image, starts = _place_bodies(w, [body])
        patch(starts[0])
        result[f"s6_random_{seed}"] = image
    return result

def s6_soc_cases():
    result = {}
    counters, control = MAP['devices']['counters']['base'], MAP['devices']['cache']['base']
    base = SDRAM_BASE + 0x50000
    code = SDRAM_BASE + 0x6000
    body = [imm(10, 10, 1), imm(11, 0, 4), imm(10, 10, 2), imm(11, 11, -1), branch(11, 0, -8, 1), jalr(0, 1, 0)]
    w = [upper(30, 0x4000, True)] + li(20, base) + li(29, counters) + li(28, control)
    patch = _pc_relative(w, 21)
    _copy(w, code, 21, (len(body) + 1) // 2)
    w += [load(5, 28, 8, 3), load(6, 28, 0, 3)]
    w += [FENCE_I] + li(23, code) + [jalr(1, 23, 0), jalr(1, 23, 0)]
    w += li(1, 0x1111222233334444) + [store(1, 20, 0, 3), store(1, 20, 8, 3), load(7, 20, 0, 3), load(8, 20, 8, 3), load(9, 20, 0, 6)]
    w += [load(12, 29, 0x58, 3), load(13, 29, 0x60, 3)]
    w += [imm(14, 0, 1), store(14, 28, 0, 3)]
    w += [load(15, 20, 0, 3), store(1, 20, 16, 3), load(16, 20, 16, 3)]
    w += [imm(14, 0, 2), store(14, 28, 0, 3)]
    w += [load(17, 20, 0, 3), jalr(1, 23, 0), load(18, 20, 16, 3)]
    w += [imm(14, 0, 3), store(14, 28, 0, 3), jalr(1, 23, 0), jalr(1, 23, 0)]
    w += [store(0, 29, 0, 3)]
    w += [load(19 + i, 29, 0x40 + 8 * i, 3) for i in range(7)]
    w += [store(19 + i, 30, 8 * i, 3) for i in range(7)]
    w += [store(5, 30, 56, 3), store(6, 30, 64, 3), store(10, 30, 72, 3)]
    image, starts = _place_bodies(w, [body])
    patch(starts[0])
    result["s6_control"] = image
    return result

ACCEL = MAP['reserved']['accelerator']['base']
AREG = MAP['accel_regs']
INTC = MAP['devices']['intc']['base']

def _matmul_sw(w, a_base, b_base, c_base, d_base, n):
    w += li(10, a_base) + li(11, b_base) + li(12, c_base) + li(13, d_base) + [imm(20, 0, n), imm(14, 0, 0)]
    loop_i = len(w)
    w += [imm(15, 0, 0)]
    loop_j = len(w)
    w += [imm(21, 14, 2 if n == 4 else 1, 1), reg(21, 21, 15), imm(21, 21, 2, 1)]
    w += [reg(22, 12, 21), load(17, 22, 0, 2), imm(16, 0, 0)]
    loop_k = len(w)
    w += [imm(23, 14, 2, 1), reg(23, 23, 16), reg(23, 23, 10), load(18, 23, 0, 0)]
    w += [imm(24, 16, 2, 1), reg(24, 24, 15), reg(24, 24, 11), load(19, 24, 0, 0)]
    w += [m(25, 18, 19, 0), reg(17, 17, 25), imm(16, 16, 1)]
    w += [branch(16, 20, 4 * (loop_k - len(w)), 4)]
    w += [reg(17, 17, 0, 0, 0, True), reg(22, 13, 21), store(17, 22, 0, 2), imm(15, 15, 1)]
    w += [branch(15, 20, 4 * (loop_j - len(w)), 4)]
    w += [imm(14, 14, 1)]
    w += [branch(14, 20, 4 * (loop_i - len(w)), 4)]

def _store_matrices(w, rng, a_base, b_base, c_base, n, a=None, b=None, c=None):
    a = a or [[rng.randint(-128, 127) for _ in range(n)] for _ in range(n)]
    b = b or [[rng.randint(-128, 127) for _ in range(n)] for _ in range(n)]
    c = c or [[rng.randint(-(1 << 31), (1 << 31) - 1) for _ in range(n)] for _ in range(n)]
    for base, rows in ((a_base, a), (b_base, b)):
        w += li(5, base)
        for i, row in enumerate(rows):
            w += li(6, sum((x & 0xff) << (8 * k) for k, x in enumerate(row))) + [store(6, 5, 4 * i, 2)]
    w += li(5, c_base)
    for i in range(n * n):
        w += li(6, c[i // n][i % n] & 0xffffffff) + [store(6, 5, 4 * i, 2)]
    return a, b, c

S7_SW_SETS = ((4, None, None, None),
              (4, [[-128] * 4] * 4, [[-128, 127, -128, 127]] * 4, [[(1 << 31) - 1, -(1 << 31)] * 2] * 4),
              (2, None, None, None))

def s7_matmul_layout(index):
    base = SDRAM_BASE + 0x10000 + 0x400 * index
    return base, base + 0x40, base + 0x80, base + 0x100

def s7_matmul_operands():
    rng = random.Random(77)
    out = []
    for n, a, b, c in S7_SW_SETS:
        a = a or [[rng.randint(-128, 127) for _ in range(n)] for _ in range(n)]
        b = b or [[rng.randint(-128, 127) for _ in range(n)] for _ in range(n)]
        c = c or [[rng.randint(-(1 << 31), (1 << 31) - 1) for _ in range(n)] for _ in range(n)]
        out.append((n, a, b, c))
    return out

def s7_cases():
    w = [upper(30, 0x4000, True)]
    for index, (n, a, b, c) in enumerate(s7_matmul_operands()):
        a_base, b_base, c_base, d_base = s7_matmul_layout(index)
        _store_matrices(w, None, a_base, b_base, c_base, n, a, b, c)
        _matmul_sw(w, a_base, b_base, c_base, d_base, n)
    return {"s7_matmul_sw": w}

def s7_soc_cases():
    result = {}
    rng = random.Random(1707)
    w = [upper(30, 0x4000, True)] + li(29, MAP['ram_base'] + 0x5000) + li(28, ACCEL)
    set_handler = _pc_relative(w, 5)
    w += [csr(0, 5, MTVEC, 1)]
    w += [load(1, 28, AREG['info'], 3), load(2, 28, AREG['cycles'], 3), load(3, 28, AREG['ctrl'], 3), load(4, 28, AREG['status'], 3)]
    w += [store(1, 30, 0, 3), store(2, 30, 8, 3), store(3, 30, 16, 3), store(4, 30, 24, 3)]
    a = [[-128, 127, -1, 0], [1, 2, 3, 4], [-5, 6, -7, 8], [127, 127, -128, -128]]
    b = [[1, 0, 0, 0], [0, -1, 0, 0], [0, 0, 1, 0], [-128, 64, 32, 127]]
    for i, row in enumerate(a):
        w += li(6, sum((x & 0xff) << (8 * k) for k, x in enumerate(row))) + [store(6, 28, AREG['a'] + 4 * i, 2)]
    for i in range(0, 4, 2):
        value = sum((x & 0xff) << (8 * k) for k, x in enumerate(b[i])) | (sum((x & 0xff) << (8 * k) for k, x in enumerate(b[i + 1])) << 32)
        w += li(6, value) + [store(6, 28, AREG['b'] + 4 * i, 3)]
    for i in range(16):
        value = [(1 << 31) - 1, -(1 << 31), -1, 0][i % 4] if i < 8 else rng.randint(-(1 << 31), (1 << 31) - 1)
        w += li(6, value & 0xffffffff) + [store(6, 28, AREG['c'] + 4 * i, 2)]
    w += [load(7, 28, AREG['a'], 3), load(8, 28, AREG['b'] + 8, 6), load(9, 28, AREG['c'] + 4, 2)]
    w += [store(7, 30, 32, 3), store(8, 30, 40, 3), store(9, 30, 48, 3)]

    def run(ctrl, slot, busy_probe):
        nonlocal w
        w += [imm(6, 0, ctrl), store(6, 28, AREG['ctrl'], 3)]
        if busy_probe:
            w += [store(6, 28, AREG['a'], 2)]
            w += [store(6, 28, AREG['ctrl'], 3)]
            w += [load(10, 28, AREG['d'], 2), load(11, 28, AREG['status'], 3), load(12, 28, AREG['cycles'], 3)]
        poll = len(w)
        w += [load(13, 28, AREG['status'], 3), imm(14, 13, 2, 7)]
        w += [branch(14, 0, 4 * (poll - len(w)), 0)]
        w += [store(13, 30, slot, 3), load(12, 28, AREG['cycles'], 3), store(12, 30, slot + 8, 3)]
        for k in range(8):
            w += [load(15, 28, AREG['d'] + 8 * k, 3), store(15, 30, slot + 16 + 8 * k, 3)]
        w += [load(15, 28, AREG['d'] + 4, 2), store(15, 30, slot + 80, 3)]
        w += [imm(6, 0, 6), store(6, 28, AREG['status'], 2)]
        w += [load(16, 28, AREG['status'], 3), store(16, 30, slot + 88, 3)]

    run(1, 0x100, True)
    run(5, 0x200, False)
    run(5, 0x300, True)
    w += [store(6, 28, AREG['a'] + 1, 0),
          load(6, 28, AREG['d'] + 2, 1),
          store(6, 28, AREG['d'], 2),
          store(6, 28, AREG['a'] + 16, 2),
          load(6, 28, 0x500, 3),
          load(6, 28, 0x20, 2)]
    w += [store(6, 28, AREG['info'], 3), load(17, 28, AREG['info'], 3), store(17, 30, 0x400, 3)]
    w += [imm(6, 0, 7), store(6, 28, AREG['ctrl'] + 4, 2), load(18, 28, AREG['ctrl'], 3), store(18, 30, 0x408, 3)]
    w += [csr(0, 0, MTVEC, 1), 0x00100073]
    set_handler(len(w))
    w += [csr(5, 0, MCAUSE, 2), csr(6, 0, MTVAL, 2), store(5, 29, 0, 3), store(6, 29, 8, 3), imm(29, 29, 16),
          csr(7, 0, MEPC, 2), imm(7, 7, 4), csr(0, 7, MEPC, 1), MRET]
    result["s7_accel"] = w

    w = [upper(30, 0x4000, True)] + li(29, MAP['ram_base'] + 0x5000) + li(28, ACCEL) + li(27, INTC) + li(25, SDRAM_BASE + 0x20000)
    set_handler = _pc_relative(w, 5)
    w += [csr(0, 5, MTVEC, 1), imm(26, 0, 0)]
    for i in range(4):
        w += li(6, 1 << (8 * i)) + [store(6, 28, AREG['a'] + 4 * i, 2)]
    for i in range(4):
        w += li(6, rng.getrandbits(32)) + [store(6, 28, AREG['b'] + 4 * i, 2)]
    w += li(6, 0x800) + [csr(0, 6, MIE, 1), csr(0, 8, MSTATUS, 6)]

    def wait_count(target):
        nonlocal w
        w += [imm(9, 0, target)]
        loop = len(w)
        w += [m(1, 26, 9, 0), imm(1, 1, 3), store(1, 25, 0, 3), load(2, 25, 0, 3), reg(3, 3, 2),
              m(4, 2, 9, 5), imm(25, 25, 8)]
        w += [branch(26, 9, 4 * (loop - len(w)), 1)]

    def poll_done():
        nonlocal w
        poll = len(w)
        w += [load(13, 28, AREG['status'], 3), imm(14, 13, 2, 7)]
        w += [branch(14, 0, 4 * (poll - len(w)), 0)]

    def read_d(slot):
        nonlocal w
        for k in range(8): w += [load(15, 28, AREG['d'] + 8 * k, 3), store(15, 30, slot + 8 * k, 3)]

    w += [imm(6, 0, 3), store(6, 28, AREG['ctrl'], 3)]
    wait_count(1)
    read_d(0x000)
    w += [imm(6, 0, 1 << MAP['interrupts']['uart']), store(6, 27, 8, 3)]
    w += [imm(6, 0, 3), store(6, 28, AREG['ctrl'], 3)]
    poll_done()
    w += [load(10, 27, 0, 3), load(11, 27, 16, 3), store(10, 30, 0x100, 3), store(11, 30, 0x108, 3), store(26, 30, 0x110, 3)]
    w += [imm(6, 0, 3), store(6, 27, 8, 3)]
    wait_count(2)
    w += [imm(6, 0, 1), store(6, 28, AREG['ctrl'], 3)]
    poll_done()
    w += [store(26, 30, 0x118, 3), imm(6, 0, 2), store(6, 28, AREG['ctrl'], 3)]
    wait_count(3)
    read_d(0x200)
    w += [imm(6, 0, 7), store(6, 28, AREG['ctrl'], 3)]
    wait_count(4)
    w += [csr(0, 8, MSTATUS, 7), store(26, 30, 0x120, 3), store(3, 30, 0x128, 3)]
    w += [csr(0, 0, MTVEC, 1), 0x00100073]
    set_handler(len(w))
    w += [csr(5, 0, MCAUSE, 2), store(5, 29, 0, 3)]
    w += [load(7, 27, 16, 3), store(7, 29, 8, 3), load(7, 27, 0, 3), store(7, 29, 16, 3), imm(29, 29, 24)]
    w += [imm(7, 0, 2), store(7, 28, AREG['status'], 3), imm(26, 26, 1)]
    w += [branch(5, 0, 8, 5), MRET]
    w += [csr(7, 0, MEPC, 2), imm(7, 7, 4), csr(0, 7, MEPC, 1), MRET]
    result["s7_irq"] = w
    return result

TIMER_BASE = MAP['devices']['timer']['base']
CACHE_BASE = MAP['devices']['cache']['base']
S8_RANDOM_SEEDS = (3, 11, 29, 47, 83)

def s8_soc_cases():
    result = {}
    for seed in S8_RANDOM_SEEDS:
        rng = random.Random(8000 + seed)
        period = rng.randrange(600, 1600)
        start = rng.randrange(1 << 16, 1 << 24) & ~63
        windows = [start, start + 2048, start + 4096, start + 0x10000]
        body = []
        for i in range(4):
            body += [store(1 + (k % 7), 20 + i, 8 * k, 3) for k in range(8)]
        weights = [8, 10, 4, 3, 3, 5, 6, 3, 5, 1, 1, 1, 1, 1, 1, 1]
        for _ in range(900):
            rd, a, b = (rng.randrange(1, 8) for _ in range(3))
            window = 20 + rng.randrange(4)
            category = rng.choices(range(16), weights)[0]
            if category == 0:
                f3 = rng.randrange(4); offset = rng.randrange(64 >> f3) << f3
                body += [store(b, window, offset, f3)]
            elif category == 1:
                f3 = rng.randrange(7); size = 1 << (f3 & 3); offset = rng.randrange(64 // size) * size
                body += [load(rd, window, offset, f3)]
            elif category == 2:
                f3, word = rng.choice(M_OPS); body += [load(rd, window, 8 * rng.randrange(8), 3), m(a, rd, b, f3, word)]
            elif category == 3:
                body += [load(rd, 30, 8 * rng.randrange(8, 64), 3), store(rd, window, 8 * rng.randrange(8), 3),
                         store(a, 30, 8 * rng.randrange(8, 64), 3)]
            elif category == 4:
                skip = rng.randrange(1, 4)
                body += [load(rd, window, 8 * rng.randrange(8), 3), branch(rd, b, 4 * (skip + 1), rng.choice([0, 1, 4, 5, 6, 7]))]
                body += [rng.choice([store(a, window, 8 * rng.randrange(8), 3), imm(a, b, rng.randint(-2048, 2047))]) for _ in range(skip)]
            elif category == 5:
                f3, f7 = rng.choice([(0, 0), (0, 32), (4, 0), (6, 0), (7, 0), (1, 0), (5, 32)]); body += [reg(rd, a, b, f3, f7)]
            elif category == 6:
                region, words = rng.choice([(AREG['a'], 4), (AREG['b'], 4), (AREG['c'], 16), (AREG['c'], 16)])
                if rng.randrange(2): body += [store(b, 28, region + 4 * rng.randrange(words), 2)]
                else: body += [store(b, 28, region + 8 * rng.randrange(words // 2), 3)]
            elif category == 7:
                value = rng.choice([1, 1, 3, 5, 7, 7, 2, 0])
                body += [imm(8, 0, value), store(8, 28, AREG['ctrl'], 3)]
            elif category == 8:
                address = rng.choice([AREG['status'], AREG['cycles'], AREG['info'], AREG['ctrl'],
                                      AREG['d'] + 8 * rng.randrange(8), AREG['d'] + 4 * rng.randrange(16),
                                      AREG['a'] + 4 * rng.randrange(4), AREG['c'] + 8 * rng.randrange(8)])
                f3 = 3 if address % 8 == 0 and rng.randrange(2) else rng.choice([2, 6])
                body += [load(rd, 28, address, f3), store(rd, window, 8 * rng.randrange(8), 3)]
            elif category == 9:
                body += [imm(8, 0, rng.choice([0, 1, 2, 3, 3, 3])), store(8, 25, 0, 3)]
            elif category == 10:
                body += [FENCE_I]
            elif category == 11:
                body += [rng.choice([store(b, 28, AREG['a'] + rng.randrange(16), 0), load(rd, 28, AREG['d'] + 2, 1),
                                     store(b, 28, AREG['d'] + 8 * rng.randrange(8), 3), load(rd, 28, 0x500, 3)])]
            elif category == 12:
                body += [imm(8, 0, rng.choice([0, 1, 2, 3, 3])), store(8, 27, 8, 3)]
            elif category == 13:
                body += [load(rd, 27, rng.choice([0, 8, 16]), 3)]
            elif category == 14:
                body += [imm(8, 0, rng.choice([2, 4, 6])), store(8, 28, AREG['status'], 3)]
            else:
                body += [load(rd, 26, 16, 3), store(rd, window, 8 * rng.randrange(8), 3)]
        body += [csr(0, 8, MSTATUS, 7), imm(8, 0, 3), store(8, 27, 8, 3), store(8, 25, 0, 3)]
        for i in range(4):
            for k in range(8): body += [load(2, 20 + i, 8 * k, 3), reg(1, 1, 2, 4, 0)]
        body += [store(1, 30, 0, 3), store(15, 30, 8, 3), store(16, 30, 16, 3), store(17, 30, 24, 3)]
        body += [csr(0, 0, MTVEC, 1), 0x00100073]
        dest = SDRAM_BASE + 0x8000
        w = [upper(30, 0x4000, True)]
        for i, offset in enumerate(windows): w += li(20 + i, SDRAM_BASE + offset)
        w += li(25, CACHE_BASE) + li(26, TIMER_BASE) + li(27, INTC) + li(28, ACCEL)
        w += [imm(15, 0, 0), imm(16, 0, 0), imm(17, 0, 0)]
        set_handler = _pc_relative(w, 5)
        w += [csr(0, 5, MTVEC, 1)]
        for offset in [AREG['a'], AREG['a'] + 8, AREG['b'], AREG['b'] + 8] + [AREG['c'] + 8 * k for k in range(8)]:
            w += li(9, rng.getrandbits(64)) + [store(9, 28, offset, 3)]
        w += [imm(9, 0, 1), store(9, 28, AREG['ctrl'], 3)]
        poll = len(w)
        w += [load(9, 28, AREG['status'], 3), imm(9, 9, 2, 7), branch(9, 0, 4 * (poll - len(w) - 2), 0)]
        patch = _pc_relative(w, 21)
        _copy(w, dest, 21, (len(body) + 1) // 2)
        for rd in range(1, 8): w += li(rd, rng.getrandbits(64))
        w += li(21, SDRAM_BASE + windows[1])
        w += [load(9, 26, 16, 3), imm(9, 9, period), store(9, 26, 8, 3)]
        w += li(9, 0x880) + [csr(0, 9, MIE, 1), csr(0, 8, MSTATUS, 6)]
        w += [FENCE_I] + li(8, dest) + [jalr(0, 8, 0)]
        set_handler(len(w))
        w += [csr(31, 0, MCAUSE, 2), branch(31, 0, 24, 4)]
        w += [imm(15, 15, 1), csr(31, 0, MEPC, 2), imm(31, 31, 4), csr(0, 31, MEPC, 1), MRET]
        w += [imm(31, 31, 0xff, 7), imm(19, 0, 7), branch(31, 19, 24, 1)]
        w += [imm(17, 17, 1), load(19, 26, 16, 3), imm(19, 19, period), store(19, 26, 8, 3), MRET]
        w += [imm(16, 16, 1), load(18, 27, 16, 3), imm(18, 18, 2, 7), branch(18, 0, 12, 0),
              imm(19, 0, 2), store(19, 28, AREG['status'], 3), MRET]
        image, starts = _place_bodies(w, [body])
        patch(starts[0])
        assert len(image) < 0x1000, "S8 random image reaches the RAM data area"
        result[f"s8_random_{seed}"] = image
    return result
