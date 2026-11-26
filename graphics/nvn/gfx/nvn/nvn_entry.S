    .arch_extension lse
// Common entry for unimplemented NVN functions: when the thunk comes in, x16 = this function's slot address (nvn_slot[i]).
// Calls nvn_unimpl_c(slot, x0, x1, x2) to report a failure and log the name, returns 0.
    .text
    .globl _nvn_unimpl_entry
    .p2align 2
// S2Arm：游戏 sp 不一定 16 字节对齐（Horizon 不查，苹果芯片对「以 sp 为基址的读写」查），先在下方对齐处开帧、原 sp 存进帧，出口还原（只动 x9 / x10）
_nvn_unimpl_entry:
    mov x9, sp
    and x10, x9, #~15
    sub x10, x10, #32
    mov sp, x10
    stp x29, x30, [sp]
    str x9, [sp, #16]
    mov x29, sp
    mov x3, x2
    mov x2, x1
    mov x1, x0
    mov x0, x16
    bl _nvn_unimpl_c
    ldr x9, [sp, #16]
    ldp x29, x30, [sp]
    mov sp, x9
    ret

// Timing wrapper entry (the slot table points here when DM_NVN_PROF=1): when the thunk comes in, x16 = this function's slot address.
// Save x0-x7 / q0-q7 (NVN functions pass no arguments on the stack, verified by the generator), take mach_absolute_time -> call the real implementation (nvn_real[i]) -> take it again,
// atomically add the difference to nvn_prof_ticks[i] (mach timebase units); return values x0/x1, q0-q3 are passed back unchanged.
// cntvct_el0 is not used: measured on this machine it is not in a fixed ratio to the system timebase (cntfrq reports 1 GHz, increment ratio over the same interval 98.9), so it cannot be converted to time.
    .globl _nvn_prof_entry
    .p2align 2
_nvn_prof_entry:
    mov x9, sp                       // S2Arm：sp 不对齐时同 nvn_unimpl_entry——对齐处开帧，原 sp 存 [240]
    and x9, x9, #~15
    sub x9, x9, #256
    mov x10, sp
    mov sp, x9
    str x10, [sp, #240]
    stp x29, x30, [sp]
    mov x29, sp
    stp x0, x1, [sp, #16]
    stp x1, x2, [sp, #224]           // S2Arm 诊断（g_nvn_qlog）：入参 x1 / x2 留给调用后的记录（[16,32) 调用后被返回值盖掉）
    stp x2, x3, [sp, #32]
    stp x4, x5, [sp, #48]
    stp x6, x7, [sp, #64]
    stp q0, q1, [sp, #96]
    stp q2, q3, [sp, #128]
    stp q4, q5, [sp, #160]
    stp q6, q7, [sp, #192]
    adrp x9, _nvn_slot@PAGE
    add x9, x9, _nvn_slot@PAGEOFF
    sub x16, x16, x9
    lsr x16, x16, #4                 // Slot index i
    str x16, [sp, #80]
    bl _mach_absolute_time
    str x0, [sp, #88]
    ldr x16, [sp, #80]
    adrp x9, _nvn_real@PAGE
    add x9, x9, _nvn_real@PAGEOFF
    ldr x17, [x9, x16, lsl #3]
    adrp x9, _nvn_slot@PAGE          // x16 back to the slot address: when the real implementation is the big-stack entry (nvn_big_entry) it finds the implementation through it
    add x9, x9, _nvn_slot@PAGEOFF
    add x16, x9, x16, lsl #4
    ldp x0, x1, [sp, #16]
    ldp x2, x3, [sp, #32]
    ldp x4, x5, [sp, #48]
    ldp x6, x7, [sp, #64]
    ldp q0, q1, [sp, #96]
    ldp q2, q3, [sp, #128]
    ldp q4, q5, [sp, #160]
    ldp q6, q7, [sp, #192]
    blr x17
    stp x0, x1, [sp, #16]
    stp q0, q1, [sp, #96]
    stp q2, q3, [sp, #128]
    bl _mach_absolute_time
    mov x9, x0
    ldr x10, [sp, #88]
    sub x9, x9, x10
    ldr x16, [sp, #80]
    adrp x10, _nvn_prof_ticks@PAGE
    add x10, x10, _nvn_prof_ticks@PAGEOFF
    add x10, x10, x16, lsl #3
    stadd x9, [x10]
    adrp x9, _g_nvn_qlog@PAGE        // S2Arm 诊断：S2A_NVN_QLOG 开着时记「槽号、游戏返回地址、返回值、入参 x1 / x2」（hle_nvn.c nvn_qlog_c 按名字筛）
    ldr w9, [x9, _g_nvn_qlog@PAGEOFF]
    cbz w9, 1f
    ldr x0, [sp, #80]
    ldr x1, [sp, #8]
    ldr x2, [sp, #16]
    ldp x3, x4, [sp, #224]
    bl _nvn_qlog_c
1:  ldp x0, x1, [sp, #16]
    ldp q0, q1, [sp, #96]
    ldp q2, q3, [sp, #128]
    ldp x29, x30, [sp]
    ldr x9, [sp, #240]
    mov sp, x9
    ret

// Big-stack entry: when the thunk comes in, x16 = this function's slot address. Load nvn_big_real[i] into x16 and hand over to dm_bigstack_enter (dm/host/hle_bigstack.c):
// on a guest thread stack it switches to this thread's big host stack before calling the implementation. The host's NVN implementations do Metal work when submitting, presenting and creating textures, and the Metal driver compiles internal programs (the fast-clear blit program, ...) on a deep stack,
// which The Legend of Zelda: Breath of the Wild's render thread stack cannot hold (SIGBUS in the AGX compiler, at an address in the guest stack region). NVN functions pass no arguments on the stack (verified by the generator); x0-x8 / d0-d7 are enough
    .globl _nvn_big_entry
    .p2align 2
_nvn_big_entry:
    adrp x17, _nvn_slot@PAGE
    add x17, x17, _nvn_slot@PAGEOFF
    sub x16, x16, x17
    lsr x16, x16, #4                 // Slot index i
    adrp x17, _nvn_big_real@PAGE
    add x17, x17, _nvn_big_real@PAGEOFF
    ldr x16, [x17, x16, lsl #3]
    b _dm_bigstack_enter

// S2Arm：带栈上参数的 NVN2 入口（HDR 显示元数据四个，hle_nvn.c nvn_stack_args）：进来时 x16 = 本函数槽地址，实现在 nvn_sa_real[i]。
//   不能换栈（栈上参数在调用方 sp 起），原先直接在游戏栈上跑实现；游戏 sp 不是 16 字节对齐时实现开头一压栈就 SIGBUS。
//   sp 对齐：直接尾跳实现。不对齐：对齐到下方开 48 字节帧，把调用方 sp 起 32 字节（最多三个 8 字节栈参）拷到新 sp 起，原 sp / lr 存 [32]，调完还原。
//   拷贝用 x9 作基址（不是 sp），读写都不触发 sp 对齐检查；只动 x9..x12、x17
    .globl _nvn_stackarg_entry
    .p2align 2
_nvn_stackarg_entry:
    adrp x17, _nvn_slot@PAGE
    add x17, x17, _nvn_slot@PAGEOFF
    sub x9, x16, x17
    lsr x9, x9, #4                   // 槽号 i
    adrp x17, _nvn_sa_real@PAGE
    add x17, x17, _nvn_sa_real@PAGEOFF
    ldr x17, [x17, x9, lsl #3]
    mov x9, sp
    tst x9, #15
    b.ne 1f
    br x17
1:  and x10, x9, #~15
    sub x10, x10, #48
    ldp x11, x12, [x9]
    stp x11, x12, [x10]
    ldp x11, x12, [x9, #16]
    stp x11, x12, [x10, #16]
    stp x9, x30, [x10, #32]
    mov sp, x10
    blr x17
    ldp x9, x30, [sp, #32]
    mov sp, x9
    ret
