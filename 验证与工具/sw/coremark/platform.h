#ifndef CM_PLATFORM_H
#define CM_PLATFORM_H
#include <stdint.h>
void platform_init(void);
void platform_finish(uint32_t result) __attribute__((noreturn));
void print_hex64(uint64_t value);
#endif
