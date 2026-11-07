/* Small streaming formatter for the integer CoreMark output formats.
 * No fixed-size output buffer; UART is used only outside timed iteration. */
#include <stdarg.h>
#include <stdint.h>
#include "mmio.h"
#include "platform.h"
unsigned cm_validated, cm_error;
static int starts(const char *s, const char *prefix)
{
    while (*prefix) if (*s++ != *prefix++) return 0;
    return 1;
}
static void put(char c)
{
    if (c == '\n' && !uart_send('\r')) platform_finish(11);
    if (!uart_send((unsigned char)c)) platform_finish(11);
}
int ee_printf(const char *fmt, ...)
{
    va_list ap;
    if (starts(fmt, "Correct operation validated.")) cm_validated = 1;
    if (starts(fmt, "ERROR") || starts(fmt, "[%u]ERROR") ||
        starts(fmt, "Errors detected") || starts(fmt, "Cannot validate")) cm_error = 1;
    va_start(ap, fmt);
    for (; *fmt; ++fmt) {
        if (*fmt != '%') { put(*fmt); continue; }
        ++fmt;
        unsigned width = 0;
        char pad = ' ';
        if (*fmt == '0') { pad = '0'; ++fmt; }
        while (*fmt >= '0' && *fmt <= '9') width = width * 10 + (*fmt++ - '0');
        int islong = *fmt == 'l';
        if (islong) ++fmt;
        if (*fmt == 's') { const char *s = va_arg(ap, const char *); while (*s) put(*s++); }
        else if (*fmt == '%') put('%');
        else if (*fmt == 'd' || *fmt == 'u' || *fmt == 'x') {
            uint32_t v;
            if (*fmt == 'd') v = islong ? (uint32_t)va_arg(ap, long) : (uint32_t)va_arg(ap, int);
            else v = islong ? (uint32_t)va_arg(ap, unsigned long) : va_arg(ap, unsigned int);
            char buf[32]; unsigned n = 0, base = *fmt == 'x' ? 16 : 10;
            if (*fmt == 'd' && (int32_t)v < 0) { put('-'); v = 0u - v; if (width) --width; }
            do { buf[n++] = "0123456789abcdef"[v % base]; v /= base; } while (v);
            while (width > n) { put(pad); --width; }
            while (n) put(buf[--n]);
        } else platform_finish(13);
    }
    va_end(ap);
    return 0;
}
