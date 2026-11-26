# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""Execute the shell's worker creation block against pthread failure injection.

Requires Python 3 and a host C++ compiler (CXX). No OHOS SDK or game inputs.
This tests attribute/error handling, not the device's actual stack mapping.
"""
import os
from pathlib import Path
import subprocess
import tempfile

source = (Path(__file__).resolve().parents[1] / 'entry/src/main/cpp/bridge_ohos.cpp').read_text(encoding='utf8')
start = source.index('\n', source.index('if(g_started.exchange(true))'))
end = source.index('    if(rc)', start)
block = source[start:end]
harness = r'''
#include <cstddef>
#include <cstdio>
using pthread_t = int;
struct pthread_attr_t { size_t stack; };
static int fail, created, destroyed, bad;
static size_t stack;
static void *worker(void *) { return nullptr; }
static int pthread_attr_init(pthread_attr_t *a) { a->stack=128*1024; return fail==1?11:0; }
static int pthread_attr_setstacksize(pthread_attr_t *a,size_t n) { if(fail==2)return 22; a->stack=n; return 0; }
static int pthread_attr_destroy(pthread_attr_t *) { destroyed++; return 0; }
static int pthread_create(pthread_t *,const pthread_attr_t *a,void *(*)(void *),void *) {
    created++; stack=a?a->stack:128*1024; return fail==3?33:0;
}
static int launch() { BLOCK return rc; }
int main() {
    for(fail=0;fail<4;fail++) {
        created=destroyed=0;stack=0; int rc=launch();
        bool ok=rc==fail*11 && created==(fail==0||fail==3) && destroyed==(fail!=1);
        if(created)ok=ok&&stack==8*1024*1024;
        std::printf("case %d: %s (rc=%d create=%d destroy=%d stack=%zu)\n",fail,ok?"PASS":"FAIL",rc,created,destroyed,stack);
        bad+=!ok;
    }
    return bad?1:0;
}
'''.replace('BLOCK', block)
with tempfile.TemporaryDirectory() as tmp:
    tmp = Path(tmp)
    cpp, exe = tmp / 'worker.cpp', tmp / ('worker.exe' if os.name == 'nt' else 'worker')
    cpp.write_text(harness, encoding='utf8')
    subprocess.run([os.environ.get('CXX', 'c++'), '-std=c++17', str(cpp), '-o', str(exe)], check=True)
    raise SystemExit(subprocess.run([str(exe)]).returncode)
