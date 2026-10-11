from model.rv64i import Fault, Machine, MAP, MASK, signed

CSR_NAMES = {0x300: "mstatus", 0x301: "misa", 0x304: "mie", 0x305: "mtvec", 0x340: "mscratch",
             0x341: "mepc", 0x342: "mcause", 0x343: "mtval", 0x344: "mip", 0xB00: "mcycle",
             0xB02: "minstret", 0xF11: "mvendorid", 0xF12: "marchid", 0xF13: "mimpid", 0xF14: "mhartid"}
MISA = (2 << 62) | (1 << 8) | (1 << 12)
DEVICES = {name: (MAP["devices"][name]["base"], MAP["devices"][name]["bytes"]) for name in MAP["devices"]}
ZICSR_NAMES = {"CSRRW", "CSRRS", "CSRRC", "CSRRWI", "CSRRSI", "CSRRCI", "MRET", "WFI"}

REGISTERS = {"uart": {0x00, 0x08, 0x10, 0x18, 0x20}, "timer": {0x00, 0x08, 0x10},
             "counters": set(range(0x00, 0x78, 8)), "cache": {0x00, 0x08}, "intc": {0x00, 0x08, 0x10}}
ACCEL_BASE, ACCEL_BYTES = MAP["reserved"]["accelerator"]["base"], MAP["reserved"]["accelerator"]["bytes"]

def mmio_register_exists(address):
    beat = address & ~7
    for name, (base, size) in DEVICES.items():
        if base <= beat < base + size: return beat - base in REGISTERS[name]
    return False

def in_accelerator(address):
    return ACCEL_BASE <= address < ACCEL_BASE + ACCEL_BYTES

def is_mmio(address):
    base, size = MAP["reserved"]["peripherals"]["base"], MAP["reserved"]["peripherals"]["bytes"]
    return base <= address < base + size

class MachineS4(Machine):
    def __init__(self, program, reset_pc=None, sdram=False, sdram_fetch=False):
        self.external = None
        self.mmio_read = None
        self.accel_port = None
        super().__init__(program, reset_pc, sdram, sdram_fetch)

    def reset(self):
        super().reset()
        self.mie_bit = self.mpie_bit = 0
        self.csr = {0x304: 0, 0x305: 0, 0x340: 0, 0x341: 0, 0x342: 0, 0x343: 0, 0xB02: 0}
        self.minstret_written = False

    def _csr_read(self, address):
        if address == 0x300: return (3 << 11) | (self.mpie_bit << 7) | (self.mie_bit << 3)
        if address == 0x301: return MISA
        if address in (0xF11, 0xF12, 0xF13, 0xF14): return 0
        if address in (0xB00, 0x344):
            if self.external is None: raise AssertionError("mcycle/mip read needs an external value")
            return self.external() & MASK
        return self.csr[address]

    def _csr_write(self, address, value):
        value &= MASK
        if address == 0x300: self.mie_bit, self.mpie_bit = (value >> 3) & 1, (value >> 7) & 1
        elif address == 0x304: self.csr[0x304] = value & 0x888
        elif address in (0x305, 0x341): self.csr[address] = value & ~3 & MASK
        elif address in (0x340, 0x342, 0x343): self.csr[address] = value
        elif address == 0xB02: self.csr[0xB02] = value; self.minstret_written = True

    def _system(self, instruction, row):
        f3, rd, rs1 = (instruction >> 12) & 7, (instruction >> 7) & 31, (instruction >> 15) & 31
        if instruction == 0x30200073:
            self.last_name = "MRET"
            row["next_pc"] = self.csr[0x341]
            self.mie_bit, self.mpie_bit = self.mpie_bit, 1
            return
        if instruction == 0x10500073:
            self.last_name = "WFI"
            return
        if f3 in (0, 4): raise Fault(2)
        address = instruction >> 20
        immediate = f3 >= 4
        operand = rs1 if immediate else self.regs[rs1]
        kind = f3 & 3
        self.last_name = ("CSRRW", "CSRRS", "CSRRC")[kind - 1] + ("I" if immediate else "")
        write_intent = kind == 1 or rs1 != 0
        if address not in CSR_NAMES or (address >> 10 == 3 and write_intent): raise Fault(2)
        old = self._csr_read(address)
        if write_intent:
            new = operand if kind == 1 else (old | operand if kind == 2 else old & ~operand)
            self._csr_write(address, new)
        self.coverage[f"CSR_{CSR_NAMES[address]}"] += 1
        row.update(rd=rd, rd_data=old & MASK if rd else 0)
        if rd: self.regs[rd] = old & MASK

    def _target(self, instruction):
        opcode = instruction & 127
        if opcode == 0x6f:
            displacement = signed(((instruction >> 31) << 20) | (instruction & 0xff000) |
                                  (((instruction >> 20) & 1) << 11) | (((instruction >> 21) & 1023) << 1), 21)
            return (self.pc + displacement) & MASK
        if opcode == 0x67:
            return (self.regs[(instruction >> 15) & 31] + signed(instruction >> 20, 12)) & ~1 & MASK
        displacement = signed(((instruction >> 31) << 12) | (((instruction >> 7) & 1) << 11) |
                              (((instruction >> 25) & 63) << 5) | (((instruction >> 8) & 15) << 1), 13)
        return (self.pc + displacement) & MASK

    def _address(self, instruction):
        base = self.regs[(instruction >> 15) & 31]
        if instruction & 127 == 0x23: imm = signed(((instruction >> 25) << 5) | ((instruction >> 7) & 31), 12)
        else: imm = signed(instruction >> 20, 12)
        return (base + imm) & MASK

    def _tval(self, cause, instruction, row):
        if cause == 0: return self.pc if self.pc % 4 else self._target(instruction)
        if cause == 1 or cause == 3: return self.pc
        if cause == 2: return instruction
        if cause in (4, 6): return self._address(instruction)
        if cause in (5, 7): return row["mem_addr"]
        return 0

    def _mmio(self, instruction, row):
        opcode, f3 = instruction & 127, (instruction >> 12) & 7
        if opcode not in (3, 0x23): return False
        store = opcode == 0x23
        if (store and f3 > 3) or (not store and f3 == 7): return False
        address = self._address(instruction)
        size = 1 << (f3 & 3)
        accel = self.accel_port is not None and in_accelerator(address)
        if not (is_mmio(address) or accel) or address % size: return False
        mask = ((1 << size) - 1) << (address % 8)
        row["mem_addr"] = address
        row["mem_wmask" if store else "mem_rmask"] = mask
        self.last_name = ({0: "SB", 1: "SH", 2: "SW", 3: "SD"} if store else
                          {0: "LB", 1: "LH", 2: "LW", 3: "LD", 4: "LBU", 5: "LHU", 6: "LWU"})[f3]
        if store:
            value = self.regs[(instruction >> 20) & 31] & ((1 << (8 * size)) - 1)
            row["mem_wdata"] = value << (8 * (address % 8))
        if accel:
            value = self.regs[(instruction >> 20) & 31] & ((1 << (8 * size)) - 1) if store else 0
            if self.accel_port(address, size, store, value): raise Fault(7 if store else 5)
        elif not mmio_register_exists(address): raise Fault(7 if store else 5)
        self.coverage["MMIO_store" if store else "MMIO_load"] += 1
        if store: return True
        if self.mmio_read is None: raise AssertionError("MMIO load needs a device value")
        raw = self.mmio_read(address, size)
        if raw is None:
            raw = 0
        row["mem_rdata"] = (raw << (8 * (address % 8))) & MASK
        value = signed(raw, size * 8) if f3 < 4 else raw
        rd = (instruction >> 7) & 31
        row.update(rd=rd, rd_data=value & MASK if rd else 0)
        if rd: self.regs[rd] = value & MASK
        return True

    def _execute(self, instruction, row):
        if instruction & 127 == 0x73 and instruction not in (0x73, 0x100073):
            return self._system(instruction, row)
        if self._mmio(instruction, row): return
        return super()._execute(instruction, row)

    def _enter(self, row, cause, tval, interrupt=False):
        handled = self.csr[0x305] != 0
        row.update(trap=1, cause=cause, rd=0, rd_data=0, intr=int(interrupt))
        if not handled:
            row["next_pc"] = self.pc
            self.halted = True
            return
        self.csr[0x341] = self.pc & ~3
        self.csr[0x342] = ((1 << 63) if interrupt else 0) | cause
        self.csr[0x343] = tval & MASK
        self.mpie_bit, self.mie_bit = self.mie_bit, 0
        row["next_pc"] = self.csr[0x305]

    def step(self):
        if self.halted: raise ValueError("Stepped halted model")
        row = dict(order=self.order, pc=self.pc, insn=0, next_pc=(self.pc + 4) & MASK,
                   rd=0, rd_data=0, mem_addr=0, mem_rmask=0, mem_wmask=0, mem_rdata=0,
                   mem_wdata=0, trap=0, cause=0, intr=0)
        self.last_name = "ILLEGAL"
        self.minstret_written = False
        instruction = 0
        snapshot = list(self.regs)
        try:
            if self.pc % 4: raise Fault(0)
            instruction = row["insn"] = self._fetch()
            self._execute(instruction, row)
        except Fault as fault:
            self.regs = snapshot
            for key in ("rd", "rd_data", "mem_rdata"): row[key] = 0
            tval = self._tval(fault.cause, instruction, row)
            self._enter(row, fault.cause, tval)
            self.coverage[f"cause_{fault.cause}"] += 1
            self.coverage[self.last_name] += 1
            self.coverage["trap_handled" if not self.halted else "trap_terminal"] += 1
            self.pc = row["next_pc"]
            self.order += 1
            return row
        self.coverage[self.last_name] += 1
        if not self.minstret_written: self.csr[0xB02] = (self.csr[0xB02] + 1) & MASK
        self.pc = row["next_pc"]
        self.order += 1
        return row

    def interrupts_enabled(self, cause):
        return self.mie_bit == 1 and (self.csr[0x304] >> cause) & 1 == 1

    def take_interrupt(self, cause):
        if self.halted: raise ValueError("Interrupt after halt")
        row = dict(order=self.order, pc=self.pc, insn=0, next_pc=self.pc, rd=0, rd_data=0, mem_addr=0,
                   mem_rmask=0, mem_wmask=0, mem_rdata=0, mem_wdata=0, trap=1, cause=cause, intr=1)
        self._enter(row, cause, 0, interrupt=True)
        self.coverage[f"interrupt_{cause}"] += 1
        self.pc = row["next_pc"]
        self.order += 1
        return row
