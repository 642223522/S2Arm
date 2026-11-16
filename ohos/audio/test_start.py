# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""Run the actual control function with injected OHAudio failures; CC is a host C compiler."""
import os
from pathlib import Path
import subprocess
import tempfile

s = (Path(__file__).with_name('ohaudio_sink.c')).read_text(encoding='utf8')
s = s[s.index('static int apply_control('):s.index('int s2a_ohaudio_open(')]
harness = r'''
#include <stdio.h>
#include <stdatomic.h>
#include <errno.h>
enum { AUDIOSTREAM_STATE_RUNNING=2,AUDIOSTREAM_STATE_INVALID=3,AUDIOSTREAM_STATE_RELEASED=4,
       AUDIOSTREAM_ERROR_ILLEGAL_STATE=7 };
typedef int OH_AudioStream_State;
struct s2a_ohaudio { void *renderer; int normal_latency; _Atomic int wants_running,focus_paused,stop_hint; };
static int test,starts,releases,opens,errors;
static int record_error(struct s2a_ohaudio *a,int e) { (void)a;errors++;return e; }
static int OH_AudioRenderer_GetCurrentState(void *r,int *s) { (void)r;*s=0;return 0; }
static int OH_AudioRenderer_Start(void *r) {
    (void)r;starts++;
    if(test==0)return 0;
    if(test==2)return 55;
    if(test==6||starts==2)return test==5||test==6?66:0;
    return AUDIOSTREAM_ERROR_ILLEGAL_STATE;
}
static int OH_AudioRenderer_Stop(void *r) { (void)r;return 0; }
static int OH_AudioRenderer_Pause(void *r) { (void)r;return 0; }
static int release_stream(struct s2a_ohaudio *a) { releases++;if(test==3)return -44;a->renderer=0;return 0; }
static int open_stream(struct s2a_ohaudio *a) { opens++;if(test==4)return -45;a->renderer=(void*)1;return 0; }
FUNCTION
int main(void) {
    const int expected_rc[]={0,0,-55,-44,-45,-66,-66,0};
    const int expected_starts[]={1,2,1,1,1,2,1,0};
    const int expected_releases[]={0,1,0,1,1,1,0,0};
    const int expected_opens[]={0,1,0,0,1,1,0,0};int bad=0;
    for(test=0;test<8;test++) {
        starts=releases=opens=errors=0;
        struct s2a_ohaudio a={.renderer=(void*)1,.normal_latency=test==6,.wants_running=test!=7};
        int rc=apply_control(&a);
        int ok=rc==expected_rc[test]&&starts==expected_starts[test]&&releases==expected_releases[test]&&opens==expected_opens[test];
        printf("case %d: %s rc=%d start=%d release=%d open=%d\n",test,ok?"PASS":"FAIL",rc,starts,releases,opens);bad+=!ok;
    }
    return bad?1:0;
}
'''.replace('FUNCTION', s)
with tempfile.TemporaryDirectory() as tmp:
    tmp = Path(tmp)
    src, exe = tmp / 'start.c', tmp / ('start.exe' if os.name == 'nt' else 'start')
    src.write_text(harness, encoding='utf8')
    subprocess.run([os.environ.get('CC', 'cc'), '-std=c11', str(src), '-o', str(exe)], check=True)
    raise SystemExit(subprocess.run([str(exe)]).returncode)
