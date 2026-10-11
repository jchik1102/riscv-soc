import copy
import csv
import json
from collections import Counter
from pathlib import Path
from model.rv64m import M_NAMES, m_name, m_result

ROOT = Path(__file__).resolve().parents[1]
MAP = json.loads((ROOT / "config/address_map.json").read_text())
MASK = (1 << 64) - 1
ZIFENCEI_NAMES = {"FENCE.I"}
BASE_NAMES = set("LUI AUIPC JAL JALR BEQ BNE BLT BGE BLTU BGEU LB LH LW LD LBU LHU LWU SB SH SW SD ADDI SLTI SLTIU XORI ORI ANDI SLLI SRLI SRAI ADD SUB SLL SLT SLTU XOR SRL SRA OR AND ADDIW SLLIW SRLIW SRAIW ADDW SUBW SLLW SRLW SRAW FENCE ECALL EBREAK".split())

def signed(value, bits=64):
    value &= (1 << bits) - 1
    return value - (1 << bits) if value & (1 << (bits - 1)) else value

class Fault(Exception):
    def __init__(self, cause): self.cause = cause

class UninitializedRead(AssertionError):
    pass

class SparseMemory:
    PAGE = 4096
    def __init__(self, size):
        self.size = size
        self.pages = {}

    def _bytes(self, index):
        if not isinstance(index, slice) or index.step not in (None, 1): raise TypeError("contiguous slices only")
        return range(index.start, index.stop)

    def __getitem__(self, index):
        result = bytearray()
        for offset in self._bytes(index):
            page = self.pages.get(offset // self.PAGE)
            if page is None or not page[1][offset % self.PAGE]:
                raise UninitializedRead(f"read of unwritten SDRAM offset {offset:#x}")
            result.append(page[0][offset % self.PAGE])
        return bytes(result)

    def __setitem__(self, index, values):
        for offset, value in zip(self._bytes(index), values):
            data, written = self.pages.setdefault(offset // self.PAGE, (bytearray(self.PAGE), bytearray(self.PAGE)))
            data[offset % self.PAGE] = value
            written[offset % self.PAGE] = 1

    def items(self):
        for page in sorted(self.pages):
            data, written = self.pages[page]
            for i in range(self.PAGE):
                if written[i]: yield page * self.PAGE + i, data[i]

    def __eq__(self, other):
        return isinstance(other, SparseMemory) and dict(self.items()) == dict(other.items())

class Machine:
    def __init__(self, program, reset_pc=None, sdram=False, sdram_fetch=False):
        if len(program) > MAP["ram_bytes"]: raise ValueError("Program exceeds implemented RAM")
        if sdram_fetch and not sdram: raise ValueError("SDRAM fetch needs the SDRAM region")
        self.mem = bytearray(MAP["ram_bytes"])
        self.sdram = SparseMemory(MAP["memories"]["sdram"]["bytes"]) if sdram else None
        self.sdram_fetch = sdram_fetch
        self.mem[:len(program)] = program
        self.reset_pc = MAP["reset_pc"] if reset_pc is None else reset_pc
        self.coverage = Counter()
        self.reset()

    def reset(self):
        self.regs = [0] * 32
        self.pc = self.reset_pc
        self.order = 0
        self.halted = False
        self.last_name = ""

    def _offset(self, address, size, cause):
        offset = address - MAP["ram_base"]
        if not 0 <= offset <= len(self.mem) - size: raise Fault(cause)
        return offset

    def _fetch(self):
        if self.sdram_fetch:
            offset = self.pc - MAP["memories"]["sdram"]["base"]
            if 0 <= offset <= self.sdram.size - 4:
                return int.from_bytes(self.sdram[offset:offset+4], "little")
        offset = self._offset(self.pc, 4, 1)
        return int.from_bytes(self.mem[offset:offset+4], "little")

    def _data_region(self, address, size, cause):
        if self.sdram is not None:
            offset = address - MAP["memories"]["sdram"]["base"]
            if 0 <= offset <= self.sdram.size - size: return self.sdram, offset
        return self.mem, self._offset(address, size, cause)

    def _execute(self, instruction, row):
        opcode = instruction & 127
        rd, rs1, rs2 = (instruction >> 7) & 31, (instruction >> 15) & 31, (instruction >> 20) & 31
        f3, f7 = (instruction >> 12) & 7, instruction >> 25
        a, b = self.regs[rs1], self.regs[rs2]
        imm = signed(instruction >> 20, 12)
        value = 0
        if opcode in (0x37, 0x17):
            self.last_name = "LUI" if opcode == 0x37 else "AUIPC"
            value = signed(instruction & 0xfffff000, 32) + (self.pc if opcode == 0x17 else 0)
        elif opcode in (0x33, 0x3b) and f7 == 1:
            word = opcode == 0x3b
            if word and f3 in (1, 2, 3): raise Fault(2)
            self.last_name = m_name(f3, word)
            value = m_result(f3, word, a, b)
            if f3 >= 4:
                width = 32 if word else 64
                divisor, dividend = b & ((1 << width) - 1), a & ((1 << width) - 1)
                if divisor == 0: self.coverage["M_divide_by_zero"] += 1
                elif f3 in (4, 6) and dividend == 1 << (width - 1) and divisor == (1 << width) - 1:
                    self.coverage["M_signed_overflow"] += 1
        elif opcode in (0x13, 0x1b, 0x33, 0x3b):
            word = opcode in (0x1b, 0x3b)
            immediate = opcode in (0x13, 0x1b)
            width = 32 if word else 64
            operand = (imm & MASK) if immediate else b
            if immediate:
                name = {0:"ADD", 2:"SLT", 3:"SLTU", 4:"XOR", 6:"OR", 7:"AND"}.get(f3)
                if f3 in (1, 5):
                    high = instruction >> (25 if word else 26)
                    arithmetic_high = 0x20 if word else 0x10
                    if f3 == 1 and high == 0: name = "SLL"
                    elif f3 == 5 and high in (0, arithmetic_high): name = "SRA" if high else "SRL"
                    else: raise Fault(2)
                if word and f3 not in (0, 1, 5): raise Fault(2)
            else:
                name = {(0,0):"ADD", (0x20,0):"SUB", (0,1):"SLL", (0,2):"SLT", (0,3):"SLTU",
                        (0,4):"XOR", (0,5):"SRL", (0x20,5):"SRA", (0,6):"OR", (0,7):"AND"}.get((f7, f3))
                if word and f3 not in (0, 1, 5): raise Fault(2)
            if name is None: raise Fault(2)
            self.last_name = name + ("I" if immediate else "") + ("W" if word else "")
            if self.last_name == "SLTUI": self.last_name = "SLTIU"
            shift = operand % width
            left = a & ((1 << width) - 1)
            if name == "ADD": value = left + operand
            elif name == "SUB": value = left - operand
            elif name == "SLL": value = left << shift
            elif name == "SRL": value = left >> shift
            elif name == "SRA": value = signed(left, width) >> shift
            elif name == "SLT": value = int(signed(a) < signed(operand))
            elif name == "SLTU": value = int(a < operand)
            elif name == "XOR": value = a ^ operand
            elif name == "OR": value = a | operand
            elif name == "AND": value = a & operand
            if word: value = signed(value, 32)
        elif opcode in (0x6f, 0x67):
            if opcode == 0x67 and f3 != 0: raise Fault(2)
            self.last_name = "JAL" if opcode == 0x6f else "JALR"
            displacement = signed(((instruction >> 31) << 20) | (instruction & 0xff000) |
                                  (((instruction >> 20) & 1) << 11) | (((instruction >> 21) & 1023) << 1), 21)
            target = ((self.pc + displacement) if opcode == 0x6f else ((a + imm) & ~1)) & MASK
            if target % 4: raise Fault(0)
            row["next_pc"] = target
            value = self.pc + 4
        elif opcode == 0x63:
            predicates = {0:("BEQ",a == b), 1:("BNE",a != b), 4:("BLT",signed(a) < signed(b)),
                          5:("BGE",signed(a) >= signed(b)), 6:("BLTU",a < b), 7:("BGEU",a >= b)}
            if f3 not in predicates: raise Fault(2)
            self.last_name, taken = predicates[f3]
            self.coverage[f"{self.last_name}_{'taken' if taken else 'not_taken'}"] += 1
            displacement = signed(((instruction >> 31) << 12) | (((instruction >> 7) & 1) << 11) |
                                  (((instruction >> 25) & 63) << 5) | (((instruction >> 8) & 15) << 1), 13)
            if taken:
                target = (self.pc + displacement) & MASK
                if target % 4: raise Fault(0)
                row["next_pc"] = target
            return
        elif opcode in (3, 0x23):
            store = opcode == 0x23
            names = {0:"SB",1:"SH",2:"SW",3:"SD"} if store else {0:"LB",1:"LH",2:"LW",3:"LD",4:"LBU",5:"LHU",6:"LWU"}
            if f3 not in names: raise Fault(2)
            self.last_name = names[f3]
            if store: imm = signed(((instruction >> 25) << 5) | ((instruction >> 7) & 31), 12)
            address = (a + imm) & MASK
            size = 1 << (f3 & 3)
            if address % size: raise Fault(6 if store else 4)
            mask = ((1 << size) - 1) << (address % 8)
            row["mem_addr"] = address
            row["mem_wmask" if store else "mem_rmask"] = mask
            if store:
                value = b & ((1 << (size * 8)) - 1)
                row["mem_wdata"] = value << (8 * (address % 8))
            memory, offset = self._data_region(address, size, 7 if store else 5)
            if store:
                memory[offset:offset+size] = value.to_bytes(size, "little")
                return
            raw = int.from_bytes(memory[offset:offset+size], "little")
            row["mem_rdata"] = raw << (8 * (address % 8))
            value = signed(raw, size * 8) if f3 < 4 else raw
        elif opcode == 0x0f and f3 in (0, 1):
            self.last_name = "FENCE" if f3 == 0 else "FENCE.I"
            return
        elif instruction in (0x73, 0x100073):
            self.last_name = "ECALL" if instruction == 0x73 else "EBREAK"
            raise Fault(11 if instruction == 0x73 else 3)
        else: raise Fault(2)
        row.update(rd=rd, rd_data=(value & MASK) if rd else 0)
        if rd: self.regs[rd] = value & MASK

    def step(self):
        if self.halted: raise ValueError("Stepped halted model")
        row = dict(order=self.order, pc=self.pc, insn=0, next_pc=(self.pc + 4) & MASK,
                   rd=0, rd_data=0, mem_addr=0, mem_rmask=0, mem_wmask=0, mem_rdata=0,
                   mem_wdata=0, trap=0, cause=0)
        self.last_name = "ILLEGAL"
        try:
            if self.pc % 4: raise Fault(0)
            row["insn"] = self._fetch()
            self._execute(row["insn"], row)
        except Fault as fault:
            row.update(trap=1, cause=fault.cause, next_pc=self.pc, rd=0, rd_data=0)
            self.halted = True
        self.coverage[self.last_name] += 1
        if row["trap"]: self.coverage[f"cause_{row['cause']}"] += 1
        self.pc = row["next_pc"]
        self.order += 1
        return row

def read_hex(path):
    result = bytearray()
    for line in Path(path).read_text().splitlines():
        for token in line.split("//", 1)[0].split():
            if token.startswith("@"):
                address = int(token[1:], 16)
                result.extend(bytes(max(0, address - len(result))))
                if address != len(result): raise ValueError("Only ascending hex addresses supported")
            else: result.append(int(token, 16))
    return result

class BusChecker:
    def __init__(self, model):
        self.model = model
        self.reset()
        self.requests = 0

    def reset(self):
        self.phase = "fetch"
        self.response = None
        self.preview = None

    def accept(self, fields):
        if self.phase not in ("fetch", "data") or self.response is not None:
            raise AssertionError("Unexpected or duplicate bus request")
        if self.preview is None: self.preview = copy.deepcopy(self.model).step()
        row = self.preview
        if self.phase == "fetch":
            if self.model.pc % 4: raise AssertionError("Misaligned fetch was issued")
            address, write, mask, data = self.model.pc & ~7, 0, 15 << (self.model.pc % 8), 0
        else:
            address, write = row["mem_addr"] & ~7, int(bool(row["mem_wmask"]))
            mask, data = row["mem_wmask"] or row["mem_rmask"], row["mem_wdata"]
        actual = tuple(int(x, 16) for x in fields)
        if actual != (address, write, mask, data):
            raise AssertionError(f"Bus request expected {(address,write,mask,data)}, actual {actual}")
        error = not MAP["ram_base"] <= address <= MAP["ram_base"] + len(self.model.mem) - 8
        rdata = 0
        if not error:
            for lane in range(8):
                if mask & (1 << lane):
                    index = address - MAP["ram_base"] + lane
                    if write: self.model.mem[index] = (data >> (8 * lane)) & 255
                    else: rdata |= self.model.mem[index] << (8 * lane)
        self.response = (int(error), rdata)
        self.requests += 1

    def respond(self, fields):
        actual = tuple(int(x, 16) for x in fields)
        if self.response is None or actual != self.response:
            raise AssertionError(f"Bus response expected {self.response}, actual {actual}")
        error = self.response[0]
        self.response = None
        self.phase = "data" if self.phase == "fetch" and not error and (self.preview["mem_rmask"] or self.preview["mem_wmask"]) else "retire"

    def retirement(self):
        if self.phase != "retire" or self.response is not None:
            raise AssertionError("Retirement before required bus completion")
        self.reset()

def compare(program, trace_path, require_bus=False):
    model = Machine(program)
    bus = BusChecker(model)
    count = 0
    fields = None
    saw_bus = False
    with Path(trace_path).open() as stream:
        for line in stream:
            if line.strip() == "RESET":
                model.reset(); bus.reset()
                continue
            values = next(csv.reader([line]))
            if fields is None:
                fields = values
                continue
            if values[0] == "Q":
                saw_bus = True; bus.accept(values[1:]); continue
            if values[0] == "R":
                bus.respond(values[1:]); continue
            if len(values) != len(fields): raise AssertionError("Malformed trace row")
            if saw_bus or require_bus: bus.retirement()
            decimal = {"order", "rd", "trap", "cause"}
            actual = {k: int(v, 10 if k in decimal else 16) for k, v in zip(fields, values)}
            expected = model.step()
            if actual != expected:
                differences = {k: (expected.get(k), actual.get(k)) for k in expected if expected.get(k) != actual.get(k)}
                raise AssertionError(f"Trace row {count}: expected/actual {differences}")
            count += 1
    if not model.halted: raise AssertionError("Trace ended before terminal diagnostic")
    if require_bus:
        if not saw_bus: raise AssertionError("Missing accepted bus transactions")
        if read_hex(str(trace_path) + ".mem") != model.mem:
            raise AssertionError("Final RAM contents differ from independent model")
    return count, model
