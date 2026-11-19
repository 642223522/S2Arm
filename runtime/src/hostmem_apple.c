// 宿主还能给多少内存（应用池按宿主余量扩用，runtime/src/svc_mem.c pool_fits）：苹果平台实现。
//   iPhone：os_proc_available_memory，离系统给本 App 的内存上限还剩多少（超了会被系统杀）；
//   Mac：空闲 + 不活跃 + 可清除 + 预读页（系统随时能收回给本进程的部分）。读不到回 0（按宿主给不了处理）
#include <stdint.h>
#include <TargetConditionals.h>
#if TARGET_OS_IPHONE
#include <os/proc.h>
uint64_t s2a_host_mem_avail(void) { return os_proc_available_memory(); }
#else
#include <mach/mach.h>
uint64_t s2a_host_mem_avail(void) {
    vm_statistics64_data_t vs; mach_msg_type_number_t c = HOST_VM_INFO64_COUNT; vm_size_t pg = 0;
    if (host_statistics64(mach_host_self(), HOST_VM_INFO64, (host_info64_t)&vs, &c) != KERN_SUCCESS || host_page_size(mach_host_self(), &pg) != KERN_SUCCESS) return 0;
    return ((uint64_t)vs.free_count + vs.inactive_count + vs.purgeable_count + vs.speculative_count) * pg;
}
#endif
