/* CoreMark image for tb/core/coremark_tb.sv: everything in the 64 KiB at the
 * reset PC, the same region as the on-chip RAM. */
INCLUDE sw/memory.ld
ENTRY(_start)
SECTIONS {
  . = ORIGIN(RAM);
  .text : { KEEP(*(.text.init)) *(.text .text.*) } > RAM
  .rodata : { *(.rodata .rodata.* .srodata .srodata.*) } > RAM
  .data : { *(.data .data.* .sdata .sdata.*) } > RAM
  .bss (NOLOAD) : { __bss_start = .; *(.sbss .sbss.* .bss .bss.*) *(COMMON) . = ALIGN(8); __bss_end = .; } > RAM
  . = ALIGN(16);
  __image_end = .;
  __stack_top = ORIGIN(RAM) + LENGTH(RAM);
  ASSERT(__image_end < __stack_top - 8192, "RAM overflow: reserve 8 KiB stack")
}
