#ifndef CORE_PORTME_H
#define CORE_PORTME_H
#include <stdint.h>
#include <stddef.h>
typedef int16_t ee_s16;
typedef uint16_t ee_u16;
typedef int32_t ee_s32;
typedef uint32_t ee_u32;
typedef uint8_t ee_u8;
typedef uintptr_t ee_ptr_int;
typedef size_t ee_size_t;
typedef double ee_f32;
#define HAS_FLOAT 0
#define HAS_TIME_H 0
#define USE_CLOCK 0
#define HAS_STDIO 0
#define HAS_PRINTF 0
#define CORETIMETYPE uint64_t
typedef uint64_t CORE_TICKS;
#define SEED_METHOD SEED_VOLATILE
#define MEM_METHOD MEM_STATIC
#define MULTITHREAD 1
#define MAIN_HAS_NOARGC 1
#define MAIN_HAS_NORETURN 0
#define COMPILER_VERSION "GCC " __VERSION__
#ifndef COMPILER_FLAGS
#define COMPILER_FLAGS "-march=rv32i -mabi=ilp32 -O2 -msmall-data-limit=0 -mno-relax -fno-delete-null-pointer-checks"
#endif
#define MEM_LOCATION "DTCM static; preloaded image"
#define align_mem(x) ((void *)(((uintptr_t)(x)+3u)&~(uintptr_t)3u))
extern ee_u32 default_num_contexts;
typedef struct { ee_u8 portable_id; } core_portable;
void portable_init(core_portable *, int *, char *[]);
void portable_fini(core_portable *);
int ee_printf(const char *, ...);
#endif
