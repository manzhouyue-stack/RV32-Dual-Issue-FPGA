#include <stdint.h>
#include <assert.h>
static uint32_t values[12], addresses[12];
static unsigned pos, count;
static uint32_t fake_read(uint32_t address)
{
    assert(pos < count); assert(address == addresses[pos]); return values[pos++];
}
#define TIMER_READ32(a) fake_read(a)
#include "timer.h"
static void setup(unsigned n)
{
    count=n;pos=0;
    for(unsigned i=0;i<n;++i) addresses[i]=(i%3==1)?CYCLE_LO:CYCLE_HI;
}
int main(void)
{
    setup(3); values[0]=3;values[1]=0x12345678;values[2]=3;
    assert(cycle_read64()==UINT64_C(0x312345678));assert(pos==3);
    setup(6);values[0]=0;values[1]=0xffffffff;values[2]=1;
    values[3]=1;values[4]=5;values[5]=1;
    assert(cycle_read64()==UINT64_C(0x100000005));assert(pos==6);
    setup(9);values[0]=8;values[1]=0;values[2]=9;
    values[3]=9;values[4]=0;values[5]=10;
    values[6]=10;values[7]=0x55;values[8]=10;
    assert(cycle_read64()==UINT64_C(0xa00000055));assert(pos==9);
    assert((UINT64_C(5)-UINT64_C(0xfffffffffffffffe))==7);
    return 0;
}
