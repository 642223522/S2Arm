// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
#import "LauncherPadBridge.h"
#include "../../../../../macos/ns2_relay.h"
#include <errno.h>
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>
// Reuse the existing Joy-Con orientation implementation, including its rumble
// dependency, rather than maintaining another interpretation of the raw bits.
#include "../../../../../runtime/ns2pro/NS2Rumble.c"
#include "../../../../../runtime/ns2pro/NS2JoyCon.c"

struct s2a_launcher_pad_client {
    int fd;
    size_t used;
    unsigned char bytes[sizeof(ns2_relay_packet)];
};

int s2a_launcher_pad_decode(const void *bytes, size_t length, s2a_launcher_pad_sample *out) {
    if (!out) return -1;
    memset(out, 0, sizeof *out);
    if (!bytes || length != sizeof(ns2_relay_packet)) return -1;
    ns2_relay_packet p;
    memcpy(&p, bytes, sizeof p);
    if (p.magic != NS2_RELAY_MAGIC || p.version != NS2_RELAY_VERSION || p.type != NS2_RELAY_INPUT) return -1;
    if (p.player != 0) return 0; // The launcher's navigation belongs to player 1.
    out->epoch = p.epoch;
    if (!p.ready) return 1;
    ns2_joycon_raw_to_sideways((ns2_kind)p.kind, &p.state);
    out->ready = 1;
    out->buttons = p.state.buttons;
    out->x = p.state.lx / 32768.0f;
    out->y = p.state.ly / 32768.0f;
    out->right_y = p.state.ry / 32768.0f;
    return 1;
}

s2a_launcher_pad_client *s2a_launcher_pad_open(const char *path) {
    struct sockaddr_un addr = {.sun_family = AF_UNIX};
    if (!path || strlen(path) >= sizeof addr.sun_path) return NULL;
    strlcpy(addr.sun_path, path, sizeof addr.sun_path);
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return NULL;
    if (fcntl(fd, F_SETFL, O_NONBLOCK) < 0 || (connect(fd, (struct sockaddr *)&addr, sizeof addr) < 0 && errno != EINPROGRESS)) { close(fd); return NULL; }
    s2a_launcher_pad_client *c = calloc(1, sizeof *c);
    if (!c) { close(fd); return NULL; }
    c->fd = fd;
    return c;
}

int s2a_launcher_pad_poll(s2a_launcher_pad_client *c, s2a_launcher_pad_sample *sample) {
    if (!c || !sample) return -1;
    int found = 0;
    for (unsigned count = 0; count < 32; count++) {
        ssize_t n = read(c->fd, c->bytes + c->used, sizeof c->bytes - c->used);
        if (n < 0 && errno == EINTR) continue;
        if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) return found;
        if (n <= 0) return -1;
        c->used += (size_t)n;
        if (c->used == sizeof c->bytes) {
            s2a_launcher_pad_sample next;
            int result = s2a_launcher_pad_decode(c->bytes, c->used, &next);
            c->used = 0;
            if (result < 0) return -1;
            if (result > 0) { *sample = next; found = 1; }
        }
    }
    return found;
}
void s2a_launcher_pad_close(s2a_launcher_pad_client *c) {
    if (c) { shutdown(c->fd, SHUT_RDWR); close(c->fd); free(c); }
}
