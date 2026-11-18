// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// OHOS app-process shims for the NativeAOT runtime (linked only into our library).
#define _GNU_SOURCE
#include <errno.h>
#include <pthread.h>
#include <stdarg.h>
#include <sys/syscall.h>

// OHOS musl has no thread cancellation; NativeAOT only uses this to disable it around waits.
int pthread_setcancelstate(int state, int *old) { (void)state; if (old) *old = 0; return 0; }

#ifndef S2A_NO_MEMPOLICY_SHIM
// The app seccomp filter kills the process (SIGSYS) on get_mempolicy, which the GC's NUMA probe
// issues unconditionally. Report ENOSYS instead so the GC takes its documented non-NUMA path.
long __real_syscall(long n, ...);
long __wrap_syscall(long n, ...) {
    va_list ap; va_start(ap, n);
    long a = va_arg(ap, long), b = va_arg(ap, long), c = va_arg(ap, long), d = va_arg(ap, long), e = va_arg(ap, long), f = va_arg(ap, long);
    va_end(ap);
    if (n == __NR_get_mempolicy || n == __NR_set_mempolicy || n == __NR_mbind) { errno = ENOSYS; return -1; }
    return __real_syscall(n, a, b, c, d, e, f);
}
#endif

// Hardware faults the runtime handles itself (a null dereference in managed code becomes a
// NullReferenceException). OHOS musl's sigchain runs "special" handlers before the handler set
// with sigaction, and the crash collector (DFX) is one of them: it records a cppcrash and the
// framework then kills the app, although the runtime would have recovered. A special handler
// registered in front hands faults whose PC lies in this library's code (where NativeAOT puts
// managed code) to the runtime's own handler and stops the chain; every other fault still goes
// to DFX. sigchain is not in the NDK stubs, so it is looked up at run time.
#ifndef S2A_NO_FAULT_FORWARD
#include <dlfcn.h>
#include <link.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <ucontext.h>

struct s2a_signal_chain_action {   // layout of <sigchain.h> struct signal_chain_action
    bool (*sca_sigaction)(int, siginfo_t *, void *);
    sigset_t sca_mask;
    int sca_flags;
};

static uintptr_t code_lo, code_hi;

static int find_code(struct dl_phdr_info *info, size_t size, void *base) {
    (void)size;
    if (info->dlpi_addr != (uintptr_t)base) return 0;
    for (int i = 0; i < info->dlpi_phnum; i++) {
        const ElfW(Phdr) *ph = &info->dlpi_phdr[i];
        if (ph->p_type != PT_LOAD || !(ph->p_flags & PF_X)) continue;
        uintptr_t lo = info->dlpi_addr + ph->p_vaddr, hi = lo + ph->p_memsz;
        if (!code_lo || lo < code_lo) code_lo = lo;
        if (hi > code_hi) code_hi = hi;
    }
    return 1;
}

static bool forward_fault(int sig, siginfo_t *info, void *uc) {
    uintptr_t pc = (uintptr_t)((ucontext_t *)uc)->uc_mcontext.pc;
    if (pc < code_lo || pc >= code_hi) return false;
    struct sigaction cur;   // sigchain answers with the handler the runtime installed
    if (sigaction(sig, NULL, &cur) != 0 || !(cur.sa_flags & SA_SIGINFO) || !cur.sa_sigaction) return false;
    cur.sa_sigaction(sig, info, uc);
    return true;
}

__attribute__((constructor)) static void install_fault_forward(void) {
    Dl_info self;
    if (!dladdr((void *)install_fault_forward, &self)) return;
    dl_iterate_phdr(find_code, self.dli_fbase);
    void (*add)(int, struct s2a_signal_chain_action *) =
        (void (*)(int, struct s2a_signal_chain_action *))dlsym(RTLD_DEFAULT, "add_special_signal_handler");
    if (!add || !code_hi) return;
    struct s2a_signal_chain_action a = {.sca_sigaction = forward_fault, .sca_flags = 0};
    sigemptyset(&a.sca_mask);
    add(SIGSEGV, &a);
    add(SIGBUS, &a);
}
#endif
