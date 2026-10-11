# RV64IM system on the DE10-Lite

An original SystemVerilog RISC-V processor and system, built for the Terasic
DE10-Lite (Intel MAX 10 10M50DAF484C7G):

- a **five-stage pipeline** (IF/ID/EX/MEM/WB, forwarding, load-use and M-unit
  stalls, branch flushing) implementing **RV64IM_Zicsr_Zifencei in machine
  mode** (traps, MRET, timer/software/external interrupts), plus the original
  **multicycle RV64IM core** kept as a reference configuration;
- an **iterative multiply/divide unit** for all 13 M instructions (65 cycles,
  33 for the W forms);
- MMIO **UART** (simulation only on the board), **machine timer**, **performance
  counters**, **cache control** and an **interrupt controller**;
- an **SDR SDRAM controller** for the board's 64 MiB IS42S16320 chip;
- **2 KiB direct-mapped I- and D-caches** over SDRAM (32-byte line bursts,
  write-through, FENCE.I);
- a **4x4 INT8 matrix multiply-accumulate accelerator** (D = A*B + C, INT32
  results, completion interrupt);
- an **integrated demonstration** (`sw/s8_demo.c`) that runs a tiled 16x16
  matrix product and 64 4x4 cases on the CPU and on the accelerator, with
  caches on and off, checks every result and shows cycles on the HEX displays.

## Address map

| Region | Base | Size |
| --- | --- | --- |
| On-chip RAM (reset PC) | 0x8000_0000 | 64 KiB |
| SDRAM (cacheable) | 0x9000_0000 | 64 MiB |
| UART | 0x1000_0000 | 256 B |
| Timer (MSIP, MTIMECMP, MTIME) | 0x1000_1000 | 256 B |
| Performance counters | 0x1000_2000 | 256 B |
| Cache control | 0x1000_3000 | 256 B |
| Interrupt controller | 0x1000_4000 | 256 B |
| Matrix accelerator | 0x1001_0000 | 64 KiB |

The map is defined in `config/address_map.json`; `scripts/gen_map.py`
generates `rtl/soc/platform_pkg.sv` and `sw/platform.h` from it.

## Tools

| Tool | Version | Used for |
| --- | --- | --- |
| Quartus Prime Lite | 24.1std.0, MAX 10 device support, USB-Blaster driver | FPGA build and programming (Windows) |
| Vivado XSIM | 2025.2 with UVM 1.2 | RTL and UVM simulation (Windows) |
| WSL Ubuntu | 24.04 | firmware, Python, Spike |
| riscv64-unknown-elf-gcc | 13.2.0 | firmware |
| Python | 3.12 venv at `/home/jonat/.venvs/riscv-soc` with `requirements-lock.txt` | models, checkers, tests |
| Spike | commit in `spike-commit.txt` | reference simulator |

The scripts default to `C:\intelFPGA_lite\24.1std\quartus`,
`C:\AMDDesignTools\2025.2\Vivado`, WSL distro `Ubuntu` and the venv above. Pass
`-Quartus`, `-Vivado`, `-Distro` or `-LinuxPython` to override them.

## Running it on the DE10-Lite

Run these from PowerShell in the project folder.

1. **Build the firmware images.** This compiles every program in `sw/` with GCC in WSL and writes them to `build/`.

   ```powershell
   wsl -d Ubuntu --cd /mnt/c/projects/riscv-soc --exec /home/jonat/.venvs/riscv-soc/bin/python scripts/programs.py
   ```

2. **Build the FPGA image.** This is a full Quartus compile, about 10 minutes, and writes `build/quartus_board_s8_p1/output_files/de10_lite_s8_p1.sof`. Add `-Power` for a Quartus power estimate.

   ```powershell
   .\scripts\build_board.ps1 -Stage s8 -Demo s8
   ```

3. **Program the board.** Connect the DE10-Lite over USB and put all switches down first. Programming is over JTAG and is lost at power-off. The script prints "Configuration succeeded".

   ```powershell
   .\scripts\program_board.ps1 -Stage s8
   ```

The demo starts by itself and finishes in about 30 ms. **KEY0 reruns it.**
Switches are written SW9 ... SW0, and up = 1. SW1 SW0 select the view:

| Do | HEX shows | Meaning |
| --- | --- | --- |
| Look at the LEDs | LEDR0 on, LEDR1 off, LEDR4/6/7 on, LEDR9 blinks | Booted and passed its own checks; LEDR4 = SDRAM ready, LEDR6 = caches built, LEDR7 = accelerator built |
| SW1 SW0 = 0 0 | `0a4eff` | Checksum of all results; matches the Python model's value |
| SW1 SW0 = 1 1 | `440000` | 4x4 accelerator, 0x40 = 64 test cases, 0 mismatches |
| SW1 SW0 = 0 1 | `3000xx` | Phase 3 = done; xx = 1 ms timer interrupts taken |
| SW1 SW0 = 1 0 | `038cfa` (232,698) | Cycles for the 16x16 product on the CPU, caches on |
| ... and SW5 up | `004e9a` (20,122) | Same product on the accelerator, polled (11.6x) |
| SW5 down, SW6 up | `00764d` (30,285) | Accelerator with the completion interrupt (7.7x) |
| SW6 down, SW7 up | `04b3ae` (308,142) | CPU with both caches off |
| SW7 down, SW8 up | `03c91f` (248,095) | The 64 small cases on the CPU (SW5/SW6 up again for the accelerator) |
| SW4 SW3 SW2 | other counters | Cycles, retired instructions, memory waits, M-unit cycles, D-cache accesses/misses, uncached loads, SDRAM stores |

Cycle counts can shift slightly between runs because of the timer interrupts;
the checksum does not change.

### Earlier stage demos

Build and program them the same way with `build_board.ps1 -Stage sN -Demo <demo>`
and then `program_board.ps1 -Stage sN`:

| Build | Shows |
| --- | --- |
| `-Stage s3 -Demo fir` | FIR benchmark: LEDR0 pass, checksum `c6e755`, 109,067 cycles (SW 01/10) |
| `-Stage s4 -Demo s4` | Timer interrupts: HEX counts 50 ticks of 0.1 s up to `000032`, then LEDR0 |
| `-Stage s5 -Demo s5` | Test of all 64 MiB of SDRAM: checksum `c9e2a8`; KEY0 counts runs kept in SDRAM; SW9 up at KEY0 runs the hardware tester |
| `-Stage s6 -Demo s6` | Caches: checksum `e52428`; SW1 SW0 = 1 1 with SW4 up and SW3 SW2 = cache mode shows cycles (both off 159,154, both on 30,414) |
| `-Stage s7 -Demo s7` | Accelerator: checksum `dcb4f6`, SW 11 shows `440000` |

## Simulation and verification

```powershell
.\scripts\regress.ps1                                     # everything except UVM and board builds; ends REGRESSION_PASS
.\scripts\regress_uvm.ps1                                 # UVM regression and Python/Spike re-checks; ends UVM_REGRESSION_PASS
.\scripts\synthesize.ps1 -Stage s8 -Pipeline 1 -AccelN 4  # exact-device Quartus synthesis check
```

`regress.ps1` builds the firmware itself. Run XSIM jobs one at a time; parallel
XSIM runs in the same folder interfere.

Verification never takes expected values from the RTL. A Python ISA/system
model (`model/`) fetches and decodes each program on its own, Spike runs the same
bytes, and separate models check the SDRAM, caches and accelerator. Every
checker was shown to work by injecting bugs into the RTL (mutants) and into the
traces.

## Results

**Board (observed on the DE10-Lite at 50 MHz):**

| Stage | Result |
| --- | --- |
| S3 FIR | Pass, 109,067 cycles; the multicycle core needs 154,346 (1.42x slower) |
| S4 interrupts | Pass, 50 timer ticks of 0.1 s |
| S5 SDRAM | All 64 MiB tested by the CPU; hardware tester 0 errors |
| S6 caches | Kernel in SDRAM: caches off 159,154 cycles, I only 47,434, D only 137,969, both 30,414 (5.2x) |
| S7 accelerator | 64 cases, 0 mismatches; per 4x4 case CPU 3,820 cycles, accelerator 303 polled (12.6x) |
| S8 demo | Pass, 64 cases with 0 mismatches; 16x16 product 232,698 cycles on the CPU vs 20,122 on the accelerator (11.6x); every value within 0.05% of simulation |

**FPGA build (S8, Quartus Prime Lite 24.1):** 21,517 logic elements (43%),
629,696 memory bits (38%), 16 9-bit multipliers, 1 PLL. Timing met at 50 MHz in
every corner (worst setup slack +1.546 ns, worst hold slack +0.131 ns; slow-corner
Fmax 54.19 MHz). The power estimate is 415 mW (vectorless estimate, not measured).

**Verification (final regression):**

| Check | Result |
| --- | --- |
| Python model and checker tests | 240 passed |
| Multicycle CPU | 131 traces, 38,447 retired instructions checked |
| Pipeline CPU (with random interrupts and resets) | 244 traces, 90,807 retired instructions checked |
| Multicycle vs pipeline | 79 programs, 29,267 identical retirements |
| Spike comparison | 93 of 95 programs agree; the other 2 differ by design (WFI, SDRAM fetch fault) |
| UVM 1.2 | 105 runs, 0 errors, 100% of defined coverage bins |
| RTL mutants | 97 of 97 detected (M unit 12, pipeline 23, SDRAM 23, cache 17, accelerator 22) |
| Trace fault injection | 24 of 24 detected |
| SoC runs | S4 to S8 firmware and random whole-system programs, about 1 million retirements checked in S8 |

## Problems found while building it

1. **SDRAM read one word late (S5).** The first two board images read every
   SDRAM word one word late, although simulation passed. The SDRAM model drove
   data one clock after the datasheet's edge, and the controller had been tuned
   to the model. A gate-level simulation ruled out synthesis; re-reading the
   datasheet's CAS-latency definition found the cause. The model and controller
   were fixed.
2. **Interrupt lowered during writeback (S4).** Random interrupt tests showed that
   if an interrupt source dropped in the same cycle the interrupted instruction
   reached writeback, the front end could still deliver that instruction. Trap
   entry now flushes the front end.
3. **Cache address alias (S6).** An address just outside the cached SDRAM region
   could hit in the cache because the tag stored only the offset inside the
   region. The cache unit bench caught it after 20,000 random requests.
4. **Registers removed by Quartus (S7).** Quartus decided some accelerator
   control bits were never read, because they were read only inside a function
   through module scope, and removed them. XSIM simulated them correctly. The
   synthesis log showed it, and the read path was rewritten as plain logic.
5. **Tool and file problems.** XSIM's optimized elaboration returned zero load
   data when the pipeline had two `load_store` instances (found by the UVM
   bench). Scripted edits on Windows converted files to CRLF line endings and
   broke the WSL tools, so `.gitattributes` keeps every file byte-exact.

## Limitations

- No UART link on the board (no USB-serial adapter); the UART is verified in simulation.
- Machine mode only: no compressed or floating-point instructions, S/U modes,
  MMU, PMP, A extension or debug.
- 50 MHz only; 100 MHz was not attempted.
- SDRAM board trace delays are assumed in timing analysis; the board runs are the
  physical evidence.
- Verification is extensive but finite: no formal proof or compliance claim.

## Layout

| Path | Contents |
| --- | --- |
| `rtl/` | Cores, M unit, CSRs, bus, memories, SDRAM, caches, peripherals, accelerator |
| `fpga/de10_lite/` | Board top level, pins, timing constraints, PLL, Quartus Tcl |
| `sw/` | Startup code, linker scripts, firmware |
| `tb/` | Unit, CPU/SoC/board and UVM testbenches |
| `model/`, `tests/` | Python reference models and their pytest tests |
| `scripts/` | Firmware build, simulation, checking, regression, synthesis, board build and programming |
| `config/` | Address map and regression run lists |
| `sim/cpu_sim/` | XSIM smoke test used by the tool qualification |

Generated output goes to `build/`, which Git ignores.
