# Design decisions

> **How to read this.** Each entry states what the RTL does, with file
> references, and then answers the design questions. The answers were
> **inferred from the code, tests and logs**, not taken from the author's
> notes, so they explain why the design works as it does, not a recorded
> history of the decision. Where the repository holds no evidence (for
> example, whether an alternative was measured first), the answer says so.

## 1. Branches resolve in EX; fetch follows a BHT/BTB prediction

**What the RTL does.** Branch conditions are evaluated in EX on the forwarded
operands (`rtl/core/core_pipeline.sv:208-216`, operands from `:162`). Fetch
looks up `pc_f` in `branch_predictor` (`:337`) in the same cycle: a 32-entry
direct-mapped BTB with 8-bit partial tags, a table of 256 two-bit counters and
an 8-entry return-address stack. A BTB hit predicts the stored target for JAL
and for a JALR that is not a return (its last target), the top of the
return-address stack for a return, and the stored target for a branch when its
counter says taken (`:503-504`); otherwise fetch continues at pc+4 (`:342`).
The predicted next PC travels with the instruction. ID compares it with pc+4
and pc+imm, and for a JALR computes the rs1 value that would make it right,
predicted PC − imm (`:311-313`); EX redirects only when the prediction was
wrong (`:314-323`). A redirect loads the real next PC (`:407`) and flushes IF
and ID (`flush_front`, `:352`), discarding the two younger instructions, and
is counted by `event_redirect` (`:372`). MRET and FENCE.I always redirect. The
predictor is trained from EX on branches, JAL and JALR (`:347`). The stack
follows the hints in table 2.1 of the RISC-V unprivileged spec, with x1 and x5
as link registers: a JAL or JALR that writes one is a call and pushes pc+4, a
JALR that reads one is a return and pops, and a JALR that reads one link
register and writes the other does both (`:334-335`). The stack changes when
the instruction leaves EX, so it follows program order and never a wrong path.
All predictor state clears on reset. `+define+NO_JALR_PRED` keeps the BTB and
counters for branches and JAL but redirects on every JALR, the previous front
end.

**Why EX rather than ID?** In EX the comparator sits behind the existing
forwarding muxes (`fa`/`fb`), so a branch can use a result produced by the
instruction directly ahead of it with no extra hazard logic. Resolving in ID
would need a second forwarding path into ID and a stall whenever a branch
depends on an instruction still in EX.

**Why a predictor, and what did it change?** Before prediction every taken
branch or jump cost two fetched instructions. CoreMark on the core
(`make coremark`, 10 iterations, memory answering one cycle after each
request) went from 0.894 to 0.980 CoreMark/MHz, and its misprediction rate
(perf counters for control transfers and mispredictions, offsets 0x78 and
0x80) fell from 60.25% to 10.54%. On the S3 FIR benchmark the rate fell from
54.76% to 4.34% and cycles by 6.4%
([summary](results/coremark/summary.txt)). The gain is smaller than the
redirect reduction because the bus allows one outstanding fetch and one data
request, so memory waits dominate (IPC 0.353 with prediction). CoreMark's own
CRCs check that every run computed correctly.

**Why predict JALR, and why from the BTB as well as a stack?** Without JALR
prediction, all 36,749 of CoreMark's JALRs mispredicted, and they were 37% of
the remaining 98,904 mispredictions. Half of them (18,343) are returns, which
the stack predicts. The others include every call: with `-mcmodel=medany` GCC emits
every call as `auipc ra` + `jalr ra`, so there is no JAL to predict, and the
target of a given call site never changes, so the BTB's last target predicts
it. With the stack for returns and the BTB for the rest, JALR mispredictions
fell to 5,407 (3,337 of them returns), and total mispredictions to 68,690. Cycles fell only 0.9% from the no-JALR front end,
about 3.1 cycles per avoided redirect, for the memory-wait reason above.

**Why is a misprediction always safe?** EX checks every instruction's next PC
against the prediction, not just control transfers. A partial-tag alias that
predicts a jump at a non-branch, a stale target, or a stack entry lost to
overflow (it wraps, dropping the oldest return address) or not yet pushed
because the call is still in ID or EX, is caught the same way as a wrong
direction, so the predictor can only cost cycles. The full regression, the 23
pipeline mutants, the UVM runs and a directed stack test (`pipe_ras`:
recursion deeper than 8, x5 links, a callee that returns to ra+4, coroutine
swaps, odd return offsets) pass with it.

**Why are the comparisons in ID, and why is the JALR check an equality?** The
first version compared the 64-bit real next PC with the prediction in EX. That
put a 64-bit compare after the forwarded branch compare, and the S8 build
missed 50 MHz by 0.053 ns (slow 85 °C) on the path into the redirect perf
counter ([worst paths](results/quartus/bpred-first-version/worst_setup_paths.txt)).
Comparing the prediction with pc+4 and pc+imm in ID, where neither depends on
forwarded operands, leaves EX with a one-bit select on the branch outcome. A
JALR's target needs a forwarded register and an adder, so ID subtracts the
immediate from the prediction instead, and EX only checks that the forwarded
rs1 equals that value: no adder after the forwarding muxes. Equality is
enough because a taken prediction always has bits 1:0 clear, so rs1 + imm
equals the prediction exactly when the real target, (rs1 + imm) with bit 0
cleared, does. The first version, which also predicted JALR, measured 0.978 CoreMark/MHz
([summary](results/coremark/first-version/summary.txt)); this one measures
0.980 and closes timing.

**What did it cost on the FPGA?** The S8 build, with the predictor, the stack
and the two new counters, closes at 50 MHz with +0.487 ns of setup slack (it
had +1.546 ns without prediction, and +0.377 ns with the BHT/BTB before JALR
prediction) and uses 25,898 logic elements, up from 21,517 without prediction
([fit](results/quartus/de10_lite_s8_p1.fit.summary),
[timing](results/quartus/de10_lite_s8_p1.sta.summary)). The BTB, counters and
stack are flip-flops because the lookup has to be combinational in the fetch
cycle, and the MAX 10's M9K blocks only have registered reads.

## 2. Iterative multiply/divide unit instead of hard multipliers

**What the RTL does.** All 13 M instructions go through `muldiv_unit`, built on
`mul_iter` and `div_iter`. The multiplier is shift-and-add, one bit per cycle,
64 iterations (32 for the W forms) with a sign correction term
(`rtl/core/mul_iter.sv:22-23`, `:51`). The divider is a restoring
shift-subtract on magnitudes, one quotient bit per cycle, with signs fixed at
the end (`rtl/core/div_iter.sv`). The pipeline stalls while the unit is busy
(`event_arith_wait`).

**Why not the MAX 10's 9-bit hard multipliers?** A 64x64 multiply built from
9-bit elements needs dozens of them plus a wide adder tree that would be hard
to close at 50 MHz in one cycle, and a divide can't use them at all. One
iterative datapath serves both operations in small area. The 16 multiplier
elements the S8 build does use belong to the 4x4 accelerator's parallel MACs
([fit summary](results/quartus/de10_lite_s8_p1.fit.summary)).

**Why radix-2, with no early-out?** It is the simplest correct structure:
each step is one add or subtract and one shift, and the latency is fixed (65
cycles, 33 for the W forms), which keeps the pipeline stall logic and the
Python cycle model simple. Radix-4 or an early-out would roughly halve the
latency at the cost of more logic and data-dependent timing.

**Divide-by-zero and `MIN / -1`.** Divide-by-zero returns an all-ones quotient
(`div_iter.sv:35`) and the dividend as remainder, as the ISA specifies.
`MIN / -1` needs no special case: the magnitude of `MIN` is 2^63, the
quotient magnitude is 2^63, and negating it gives `MIN` back with remainder 0,
which is the specified result. Both are checked by the M-unit bench vectors
(`scripts/muldiv_vectors.py`) and by the 12 M-unit mutants, which include a
negated divide-by-zero quotient (`results/checkers/muldiv_mutants.json`).

## 3. Forwarding priority and the load-use stall

**What the RTL does.** EX operands take the MEM-stage result first, then the
WB-stage result, then the register file (`core_pipeline.sv:131-136`). MEM
forwarding is disabled for loads (`mem_fwd`, `:124`), so a dependent
instruction behind a load stalls one cycle (`event_load_use`, `:297`). ID also
reads through a WB bypass (`:118-120`), so the register file needs no
write-before-read timing.

**Why MEM before WB?** When both stages hold the same `rd`, MEM holds the
younger write, which is the value program order says the reader should see.
Giving WB priority would forward a stale value.

**Why no load forwarding from MEM?** Load data arrives from the bus response
during MEM. Forwarding it into EX in the same cycle would chain the bus
response, the load alignment and sign-extension (`load_store`) and the ALU
into one path. Stalling one cycle keeps that path out of the critical timing
at the cost of one cycle per back-to-back load use, which the
`event_load_use` counter measures.

**Why `rd != 0` and `!trap`?** `x0` is hardwired to zero, so a write to it
must never be forwarded. An instruction that trapped never architecturally
writes its `rd`, so forwarding its result would leak a value that doesn't
exist.

## 4. Write-through, direct-mapped 2 KiB caches with 32-byte lines

**What the RTL does.** The I- and D-caches are instances of one `cache` module
(`rtl/memory/cache.sv`, `LINE_BYTES = 32`, `:25`). The D-cache is
write-through (`WRITES(1)`, `rtl/soc/cpu_soc.sv:111`). Both refill through
`burst_arbiter` into the SDRAM controller (`cpu_soc.sv:118`).

**Why write-through?** With one core and no other bus master writing SDRAM,
write-through needs no dirty bits, no write-back buffer and no eviction path.
SDRAM always holds current data, so software can turn the D-cache off through
the cache control registers at any time without a flush. Disabling it clears
every valid bit (`rtl/memory/cache.sv:172`), so re-enabling starts cold and
can't return stale lines. The cost is SDRAM
traffic on every store.

**Why direct-mapped, 2 KiB?** Direct-mapped is the smallest correct cache: one
tag compare and no replacement state. The size is set by
`CACHES_ICACHE_BYTES`/`CACHES_DCACHE_BYTES` in `config/address_map.json`. The
repository doesn't record why 2 KiB was chosen. The S8 build uses 38% of the
device's memory bits, most of it the 64 KiB on-chip RAM.

**I-cache coherence with stores to code.** It isn't automatic. Software must
execute FENCE.I. In EX, FENCE.I waits until older instructions have drained
(`fence_wait`, `core_pipeline.sv:270`), invalidates the I-cache
(`icache_inv`, `:271`) and drops the fetch buffer (`:327`), so instructions
fetched after it see the new code. This is what Zifencei requires.

## 5. Data port wins arbitration for the shared on-chip RAM

**What the RTL does.** Fetch and data share the single-ported `onchip_ram`
through `bus_arbiter`. Fetch (`m1`) is granted only when the data port (`m0`)
has no request (`rtl/soc/bus_arbiter.sv:24`). A lock keeps the owner for a
multi-beat transaction (`:40-42`).

**Why data first?** A data access comes from the instruction in MEM, the
oldest instruction in flight. Serving it first lets that instruction retire
and frees the pipeline. Stalling it to fetch younger instructions that can't
make progress anyway would only add cycles.

**Can fetch starve?** No. Each MEM instruction issues at most one data
request. While it waits, nothing new enters MEM, so the data port goes idle
and fetch is granted. Forward progress is checked by the trace runs with
random bus delays (`MaxDelay` up to 9) and by the UVM random tests.

**Why one RAM port?** The on-chip RAM is also the target of the boot loader
port, and a second CPU port would need dual-port M9K configuration and
duplicated address decode. The repository doesn't record whether dual-port
was tried. With the caches in S6 and later, code in SDRAM is fetched through
the I-cache, which removes most of the contention.

## 6. A FIR filter peripheral, checked against MATLAB

**What the RTL does.** `rtl/peripherals/fir_filter.sv` is a 16-tap FIR filter
on the SoC bus at `0x1002_0000` (`config/address_map.json`, region `dsp`),
built into the SoC when `cpu_soc`'s `FIR_LANES` is not 0. Software writes the
16 Q15 coefficients, then each sample to `DATA`; the write starts
16/LANES cycles of multiply-accumulate, LANES taps per cycle, into a 37-bit
accumulator, and the result is rounded half up and saturated exactly as
`sw/fir.c` does. A read of `DATA` returns the output. `bus_decoder` gives the
region its own target, like the matrix accelerator's.

**Why hold the bus instead of a status bit?** Reads and writes that need the
filter idle (`DATA`, the coefficients, `CTRL`) are held off with `req_ready`
low until it finishes, so the driver is "store the sample, load the output",
seven instructions per sample, with no polling loop. `STATUS`, `CYCLES` and
`SAMPLES` stay readable while it computes. A coefficient written while the
filter is busy waits, so the output in flight uses the old coefficients; the
unit bench checks this.

**Why LANES = 4 in the SoC?** It is the most parallel setting that closes
50 MHz on both parts. One lane takes 16 cycles per output; four take 4, using
8 of the MAX 10's 9-bit multipliers and 5 Artix-7 DSPs, with +0.877 ns
(Quartus, slow 85 °C) and +0.631 ns (Vivado) of setup slack. Sixteen lanes
(one output per cycle) failed timing in both: the 16 products and their sum
in one cycle need pipelining, which would add latency to every read
(`results/fir/synth/summary.txt`). With four lanes the filter's 4 cycles are
already shorter than the 7-instruction loop around them.

**Why MATLAB as the reference?** The filter is fixed-point, and the question
is whether its rounding and saturation match a reference written by someone
thinking in fixed point rather than in RTL. `matlab/fir_model.m` uses
Fixed-Point Designer's `fi` objects (Q15 inputs, full-precision Q30 products
and sum, `Nearest` rounding, `Saturate`), checks itself against a plain
integer computation, and must agree with the Python reference the firmware
uses. The case files it writes are committed under `tests/fir/` so the
regression runs without MATLAB; `make fir` regenerates them and fails if they
change.

**Why an ADC model?** The filter's real input would come from an ADC, and a
DSP block is usually judged by spectra, not by single values. `tb/unit/adc_rnm.sv`
models a 12-bit sampling ADC with real-valued input (offset, gain error and
Gaussian noise as parameters). XSim has no user-defined nettypes, so the
analog node is a `real` variable port, one driver per node. The bench feeds
tones through it into the filter at 1 MHz, and `matlab/adc_fir_check.m`
checks the filter output bit for bit against `fir_model` on the same codes,
the ADC's SNR against the 12-bit ideal, and the filter's gain at each tone
against the gain computed from its coefficients.


## 7. DDR3 through Xilinx's MIG, as a second memory back end

**What was built.** `rtl/memory/ddr3_bridge.sv` connects the SoC's SDRAM-region
bus (the bus the caches refill on, `soc_pkg::bus2_req_t`) to the native user
interface of a Xilinx MIG 7-series DDR3 controller. The MIG is generated by
`fpga/arty_a7/gen_mig.tcl` from Digilent's settings for the Arty A7-100T's
MT41K128M16 (`fpga/arty_a7/mig_ddr3.prj`), and `fpga/arty_a7/arty_ddr3_top.sv`
is a board top that puts the pipeline SoC with its caches in front of it. The
bridge takes and answers exactly what `sdram_ctrl` does, so the SoC, the
caches and the firmware are unchanged; the SoC's 64 MiB SDRAM region maps to
the first 64 MiB of the 256 MiB part.

**Why the native interface and not MIG's AXI port?** Digilent's settings use
AXI. The SoC's bus has one request in flight and at most four beats, and the
MIG's native interface is a command port, a write-data port and a read-data
port, so the bridge is a small state machine. Through AXI it would need five
channels and an AXI interconnect inside the MIG, for no gain at one
outstanding request.

**Why two clocks?** The DDR3 runs at 325 MHz with a 4:1 PHY, so the MIG's
user logic runs at 81.25 MHz. The SoC closes timing at 50 MHz on the MAX 10
and the Artix-7, not at 81.25 MHz, so the SoC keeps its own 50 MHz clock and
the bridge crosses between the two with two asynchronous FIFOs
(`rtl/memory/async_fifo.sv`, the same design as the network engine's
`stream_cdc_fifo`, which has a formal proof, cocotb tests with two clocks and
an equivalence-checked VHDL version). The crossings are bounded in the build
script, not cut: data paths under 12.308 ns (the user clock's period) and the
Gray pointers' bit-to-bit skew under the same.

**What a beat costs.** One MIG command is one BL8 burst, 16 bytes on the
16-bit part. A single 64-bit read or write uses half of one burst (a write
masks the other half's bytes); a 4-beat line refill is two reads. The bridge
answers the SoC's beats from the 128-bit read data, low half first.

**Why one MMCM.** The MIG needs a 200 MHz reference for its IDELAYs and a
clock for its own PLL, and the SoC needs 50 MHz. Digilent's settings take the
system clock from a pin through the MIG's own input buffer, which would leave
the board's only oscillator unusable for anything else. The MIG here takes
both clocks from fabric ("No Buffer"), and one MMCM in the board top makes
50, 100 and 200 MHz from the 100 MHz oscillator.

**Reset.** The async FIFOs need both sides reset together. The bridge's SoC
side follows the MIG's user-clock reset, synchronized into the SoC clock, and
the CPU is held until the boot image is loaded; the bridge holds requests off
until the MIG reports calibration done.
