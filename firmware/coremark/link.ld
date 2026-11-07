OUTPUT_ARCH(riscv)
ENTRY(_start)
MEMORY
{
    BOOT (rx)  : ORIGIN = 0x00000000, LENGTH = 4K
    ITCM (rx)  : ORIGIN = 0x00001000, LENGTH = 28K
    DTCM (rw)  : ORIGIN = 0x00010000, LENGTH = 32K
}
SECTIONS
{
    .boot : { KEEP(*(.boot)) } > BOOT
    .text : { KEEP(*(.text.start)) *(.text .text.*) } > ITCM
    .rodata : { *(.srodata .srodata.* .rodata .rodata.*) . = ALIGN(4); } > ITCM
    .data :
    {
        . = ALIGN(4);
        __data_start = .;
        *(.sdata .sdata.* .data .data.*)
        . = ALIGN(4);
        __data_end = .;
    } > DTCM AT> ITCM
    __data_load_start = LOADADDR(.data);
    .bss (NOLOAD) :
    {
        . = ALIGN(4);
        __bss_start = .;
        *(.sbss .sbss.* .bss .bss.*) *(COMMON)
        . = ALIGN(4);
        __bss_end = .;
    } > DTCM
    __global_pointer$ = ORIGIN(DTCM) + 0x800;
    __stack_top = ORIGIN(DTCM) + LENGTH(DTCM);
    __stack_bottom = __stack_top - 4096;
    ASSERT(__bss_end <= __stack_bottom, "DTCM data/BSS overlaps 4 KiB stack")
    ASSERT(__data_load_start + SIZEOF(.data) <= ORIGIN(ITCM) + LENGTH(ITCM), "ITCM overflow")
    /DISCARD/ : { *(.comment .eh_frame .eh_frame.* .note .note.*) }
}
