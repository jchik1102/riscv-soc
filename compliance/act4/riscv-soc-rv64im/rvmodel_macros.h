// rvmodel_macros.h
// DUT-specific ACT4 macros for the riscv-soc pipeline core.
// Adapted from config/spike/spike-RVI20U64 in riscv-arch-test.
// SPDX-License-Identifier: BSD-3-Clause

#ifndef _RVMODEL_MACROS_H
#define _RVMODEL_MACROS_H

// tohost/fromhost let Spike (the cross-check) end the test through HTIF.
#define RVMODEL_DATA_SECTION \
        .pushsection .tohost,"aw",@progbits;                \
        .balign 8; .global tohost; tohost: .dword 0;         \
        .balign 8; .global fromhost; fromhost: .dword 0;     \
        .popsection

##### TERMINATION #####
// The result is written to tohost (1 = pass, 3 = fail, as Spike's HTIF
// expects). Then mtvec is cleared and ECALL is executed: with mtvec == 0 the
// pipeline treats the trap as unhandled and halts (core_pipeline.sv:281,295),
// which ends the simulation. The runner reads tohost from the final memory
// dump. Spike stops on the tohost write before reaching the ECALL.
#define RVMODEL_HALT_PASS  \
  li x1, 1                ;\
  la t0, tohost           ;\
  sw x1, 0(t0)            ;\
  sw x0, 4(t0)            ;\
  csrw mtvec, x0          ;\
  ecall                   ;\
  write_tohost_pass:      ;\
    j write_tohost_pass   ;\

#define RVMODEL_HALT_FAIL \
  li x1, 3                ;\
  la t0, tohost           ;\
  sw x1, 0(t0)            ;\
  sw x0, 4(t0)            ;\
  csrw mtvec, x0          ;\
  ecall                   ;\
  write_tohost_fail:      ;\
    j write_tohost_fail   ;\

##### IO #####
// The UART is not 16550-compatible and is not needed for pass/fail, so the
// console macros are left empty.
#define RVMODEL_IO_INIT(_R1, _R2, _R3)
#define RVMODEL_IO_WRITE_STR(_R1, _R2, _R3, _STR_PTR)

##### Access Fault #####
// Address 0 is outside every decoded region, so accesses there fault.
#define RVMODEL_ACCESS_FAULT_ADDRESS 0x00000000

##### Machine Timer (rtl/peripherals/timer.sv at TIMER_BASE 0x1000_1000) #####
#define RVMODEL_MSIP_ADDRESS     0x10001000
#define RVMODEL_MTIMECMP_ADDRESS 0x10001008
#define RVMODEL_MTIME_ADDRESS    0x10001010
#define RVMODEL_INTERRUPT_LATENCY 10
#define RVMODEL_TIMER_INT_SOON_DELAY 1000
#define RVMODEL_MAX_CYCLES_PER_TIMER_TICK 100

##### Machine Interrupts #####
// External interrupts come from irq_ctrl and cannot be raised by software,
// so the external-interrupt macros are left empty (privileged tests are off).
#define RVMODEL_SET_MEXT_INT(_R1, _R2)
#define RVMODEL_CLR_MEXT_INT(_R1, _R2)
#define RVMODEL_SET_MSW_INT(_R1, _R2) \
  li _R1, 1; \
  li _R2, RVMODEL_MSIP_ADDRESS; \
  sw _R1, 0(_R2);
#define RVMODEL_CLR_MSW_INT(_R1, _R2) \
  li _R2, RVMODEL_MSIP_ADDRESS; \
  sw zero, 0(_R2);

##### Supervisor Interrupts (no S-mode) #####
#define RVMODEL_SET_SEXT_INT(_R1, _R2)
#define RVMODEL_CLR_SEXT_INT(_R1, _R2)
#define RVMODEL_SET_SSW_INT(_R1, _R2)
#define RVMODEL_CLR_SSW_INT(_R1, _R2)

#endif // _RVMODEL_MACROS_H
