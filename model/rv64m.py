MASK64 = (1 << 64) - 1
MASK32 = (1 << 32) - 1

NAMES = ("MUL", "MULH", "MULHSU", "MULHU", "DIV", "DIVU", "REM", "REMU")
WORD_NAMES = {0: "MULW", 4: "DIVW", 5: "DIVUW", 6: "REMW", 7: "REMUW"}
M_NAMES = frozenset(NAMES) | frozenset(WORD_NAMES.values())

def as_signed(value, bits):
    value &= (1 << bits) - 1
    return value - (1 << bits) if value >> (bits - 1) else value

def sign_extend32(value):
    return as_signed(value, 32) & MASK64

def truncating_divide(n, d):
    q = abs(n) // abs(d)
    if (n < 0) != (d < 0):
        q = -q
    r = n - q * d
    return q, r

def divide(n, d, bits, quotient):
    if d == 0:
        return ((1 << bits) - 1) if quotient else n & ((1 << bits) - 1)
    q, r = truncating_divide(n, d)
    return (q if quotient else r) & ((1 << bits) - 1)

def m_result(funct3, word, a, b):
    a &= MASK64
    b &= MASK64
    if word:
        if funct3 not in WORD_NAMES:
            raise ValueError("Reserved OP-32 M encoding")
        if funct3 == 0:
            return sign_extend32(as_signed(a, 32) * as_signed(b, 32))
        signed_op = funct3 in (4, 6)
        n = as_signed(a, 32) if signed_op else a & MASK32
        d = as_signed(b, 32) if signed_op else b & MASK32
        return sign_extend32(divide(n, d, 32, funct3 in (4, 5)))
    if funct3 == 0:
        return (a * b) & MASK64
    if funct3 in (1, 2, 3):
        left = as_signed(a, 64) if funct3 in (1, 2) else a
        right = as_signed(b, 64) if funct3 == 1 else b
        return ((left * right) >> 64) & MASK64
    signed_op = funct3 in (4, 6)
    n = as_signed(a, 64) if signed_op else a
    d = as_signed(b, 64) if signed_op else b
    return divide(n, d, 64, funct3 in (4, 5))

def m_name(funct3, word):
    return WORD_NAMES[funct3] if word else NAMES[funct3]
