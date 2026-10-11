INCLUDE sw/memory.ld
ENTRY(_start)
SECTIONS {
  . = ORIGIN(RAM);
  .text : { KEEP(*(.text.init)) *(.text .text.*) } > RAM
  .rodata : { *(.rodata .rodata.* .srodata .srodata.*) } > RAM
  .data : { *(.data .data.* .sdata .sdata.*) } > RAM
  .bss (NOLOAD) : { __bss_start = .; *(.sbss .sbss.* .bss .bss.*) *(COMMON) __bss_end = .; } > RAM
  .report ORIGIN(RAM) + 0x8000 (NOLOAD) : { KEEP(*(.report)) } > RAM
  ASSERT(__bss_end <= ORIGIN(RAM) + 0x8000, "Image overlaps the report block")
  . = ALIGN(16);
  __image_end = .;
  __stack_top = ORIGIN(RAM) + LENGTH(RAM);
  ASSERT(__image_end < __stack_top - 4096, "RAM overflow: reserve 4 KiB stack")
}
