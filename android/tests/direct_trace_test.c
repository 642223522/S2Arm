// SPDX-License-Identifier: Apache-2.0
#define _POSIX_C_SOURCE 200809L
#include "../native/gfx_plat/direct_diag.h"
#include <stdint.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <dirent.h>
#include <unistd.h>
static void pause_ms(long ms) { struct timespec t = {ms / 1000, (ms % 1000) * 1000000}; nanosleep(&t, NULL); }
// Published segments (".jsonl"; the writer renames from a temporary name) in the output folder.
static int published(const char *dir) {
    DIR *d = opendir(dir); int n = 0;
    if (!d) return -1;
    for (struct dirent *e; (e = readdir(d));) { size_t l = strlen(e->d_name); if (l > 6 && !strcmp(e->d_name + l - 6, ".jsonl")) n++; }
    closedir(d);
    return n;
}
// The writer copies the record buffer at the start of each flush, so the segment being flushed when the last record
//   was added may not hold it; the second one published after that point does. Wait for that instead of a fixed
//   sleep (a loaded host can leave the writer thread unscheduled for longer than any fixed pause).
//   Stops early when the writer has given up (collection disabled); on timeout the test side reports what is missing.
static void wait_published_after(const char *dir, int before) {
    for (int waited = 0; waited < 10000 && s2a_direct_diag_enabled(); waited += 10) { if (published(dir) >= before + 2) return; pause_ms(10); }
}
int main(int argc, char **argv) {
    if (argc != 3) return 2;
    if (!strcmp(argv[2], "collision")) {
        char path[2048];
        snprintf(path, sizeof path, "%s/direct-trace-%ld-123-000000.jsonl", argv[1], (long)getpid());
        int fd = open(path, O_WRONLY | O_CREAT | O_EXCL, 0600);
        if (fd < 0 || write(fd, "existing", 8) != 8 || close(fd)) return 6;
    }
    if (s2a_direct_diag_start(argv[1], 123)) return 3;
    if (!strcmp(argv[2], "off")) { if (s2a_direct_diag_enabled()) return 4; pause_ms(350); return 0; }
    if (!s2a_direct_diag_enabled()) return 5;
    if (!strcmp(argv[2], "collision")) {
        for (int waited = 0; waited < 10000 && s2a_direct_diag_enabled(); waited += 10) pause_ms(10);   // the writer gives up on the taken name
        if (s2a_direct_diag_enabled()) return 7;
        puts("READY"); fflush(stdout); for (;;) pause_ms(1000);
    }
    uint8_t id[32]; memset(id, 0xab, sizeof id);
    s2a_direct_diag_frame();
    uint64_t token = s2a_direct_diag_compile_begin(id, 7, 1, 0);
    wait_published_after(argv[1], published(argv[1]));   // begin and end land in different published segments
    s2a_direct_diag_compile_end(token, 1);
    s2a_direct_diag_frame();
    if (!strcmp(argv[2], "overflow")) for (int i = 0; i < 5000; ++i) s2a_direct_diag_frame();
    if (!strcmp(argv[2], "inflight")) (void)s2a_direct_diag_compile_begin(id, 32, 1, 0);
    wait_published_after(argv[1], published(argv[1]));
    puts("READY"); fflush(stdout);
    for (;;) pause_ms(1000);
}
