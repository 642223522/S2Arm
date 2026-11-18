// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// perform(window, op, ...): 仅标准裁剪/尺寸重置操作走切栈回调；其余恢复原始 ABI 后尾调用。
.text
.p2align 2
.global s2a_guest_window_dispatch
.hidden s2a_guest_window_dispatch
.type s2a_guest_window_dispatch,%function
s2a_guest_window_dispatch:
    .cfi_startproc
    hint #34
    cmp w1,#3
    b.eq 1f
    cmp w1,#5
    b.eq 1f
    cmp w1,#8
    b.eq 1f
    cmp w1,#15
    b.eq 1f
    sub sp,sp,#208
    .cfi_def_cfa_offset 208
    stp x0,x1,[sp]
    stp x2,x3,[sp,#16]
    stp x4,x5,[sp,#32]
    stp x6,x7,[sp,#48]
    stp x8,x30,[sp,#64]
    .cfi_offset 30,-136
    stp q0,q1,[sp,#80]
    stp q2,q3,[sp,#112]
    stp q4,q5,[sp,#144]
    stp q6,q7,[sp,#176]
    bl s2a_guest_window_original
    mov x16,x0
    ldp q0,q1,[sp,#80]
    ldp q2,q3,[sp,#112]
    ldp q4,q5,[sp,#144]
    ldp q6,q7,[sp,#176]
    ldp x0,x1,[sp]
    ldp x2,x3,[sp,#16]
    ldp x4,x5,[sp,#32]
    ldp x6,x7,[sp,#48]
    ldp x8,x30,[sp,#64]
    add sp,sp,#208
    .cfi_def_cfa_offset 0
    .cfi_restore 30
    br x16
1:
    adrp x16,s2a_guest_window_crop_entry_wrapped
    add x16,x16,:lo12:s2a_guest_window_crop_entry_wrapped
    ldar x16,[x16]
    br x16
    .cfi_endproc
.size s2a_guest_window_dispatch,.-s2a_guest_window_dispatch
.section .note.GNU-stack,"",%progbits
