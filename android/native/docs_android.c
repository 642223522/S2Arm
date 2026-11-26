#include "docs_android.h"
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/stat.h>

int s2a_android_docs_bind(const char *state_dir) {
    if (!state_dir || state_dir[0] != '/') return EINVAL;
    if (setenv("S2A_DOCS", state_dir, 1)) return errno;
    return 0;
}

int s2a_android_stall_off_apply(const char *docs) {
    if (!docs || !docs[0]) return 0;
    char path[1200]; struct stat st;
    if (snprintf(path, sizeof path, "%s/cpatch_stall_off", docs) >= (int)sizeof path || stat(path, &st) || !S_ISREG(st.st_mode)) return 0;
    if (getenv("S2A_FPS60")) return 2;
    return setenv("S2A_FPS60", "0", 1) ? -errno : 1;
}
