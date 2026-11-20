// Host-only cache ordering test. Files come exclusively from the production writer.
#include "nvn_vk_prog_warm.h"
#include "nvn_plat.h"
#include "direct/compile_request.h"
#include <stdio.h>
#include <string.h>
#include <time.h>

static const char *cache_dir;
static unsigned clock_calls, checks, failures;
static time_t epoch;
#define CHECK(test) do { ++checks; if (!(test)) { ++failures; fprintf(stderr, "FAIL:%d: %s\n", __LINE__, #test); } } while (0)

const char *nvn_plat_dir(int which) { return which == NVN_PLAT_DIR_CACHE ? cache_dir : NULL; }
int nvn_plat_flag(const char *name, int fallback) { (void)name; return fallback; }
void nvn_plat_log(int level, const char *category, const char *message) {
    (void)level; (void)category; (void)message;
}
int s2a_direct_provider_compile_context(struct s2a_direct_compile_context *out) {
    memset(out, 0, sizeof *out);
    out->session = 1; out->generation = 1; out->direct_abi = 7;
    out->profile_json = "recency-fixture"; out->profile_bytes = strlen(out->profile_json);
    out->translator_closure = "recency-fixture";
    return 0;
}

// Only the production TU calls this clock seam. Never modify cache bytes.
int nvk_recency_test_clock_gettime(clockid_t clock_id, struct timespec *value) {
    if (clock_id != CLOCK_REALTIME) return clock_gettime(clock_id, value);
    value->tv_sec = epoch + (time_t)clock_calls++;
    value->tv_nsec = 0;
    return 0;
}
static void note(unsigned char id, unsigned uses) {
    struct nvk_prog_rec rec = { .stage_mask = 1, .uses = uses };
    rec.identity[0] = id;
    nvk_prog_warm_note(&rec);
}
static void seed(void) {
    note(1, 1); note(2, 1); note(9, 9);
    nvk_prog_warm_save();
}
static void expect_plan(const unsigned char *ids, unsigned n) {
    struct nvk_prog_rec got;
    for (unsigned i = 0; i < n; ++i)
        CHECK(nvk_prog_warm_take(&got) == 1 && got.identity[0] == ids[i] &&
              got.uses == (ids[i] == 9 ? 9u : 1u));
    CHECK(nvk_prog_warm_take(&got) == 0);
}
static void expect_reload(const unsigned char *ids, unsigned n) {
    nvk_prog_warm_reset();
    CHECK(nvk_prog_warm_load() == (int)n);
    expect_plan(ids, n);
}
int main(int argc, char **argv) {
    const unsigned char old[] = {9, 2, 1}, next[] = {9, 3, 2, 1},
                        preload[] = {9, 4, 3, 2, 1};
    if (argc != 3) return 2;
    cache_dir = argv[2];
    epoch = 1700000000;
    if (!strcmp(argv[1], "seed-legacy")) {
        epoch = 1800000000;
        seed();
        CHECK(clock_calls == 3);
        expect_reload(old, sizeof old);
    } else if (!strcmp(argv[1], "fresh")) {
        seed();
        expect_reload(old, sizeof old);
        epoch -= 100;
        note(3, 1); nvk_prog_warm_save();
        expect_reload(next, sizeof next);
        CHECK(clock_calls == 0);
    } else if (!strcmp(argv[1], "legacy-after")) {
        expect_reload(old, sizeof old);
        note(3, 1); nvk_prog_warm_save();
        expect_reload(next, sizeof next);
        CHECK(clock_calls == 0);
    } else if (!strcmp(argv[1], "legacy-preload")) {
        note(3, 1); note(4, 1);
        CHECK(nvk_prog_warm_load() == 3);
        CHECK(nvk_prog_warm_contains((const unsigned char[32]){3}));
        CHECK(nvk_prog_warm_contains((const unsigned char[32]){4}));
        expect_plan(old, sizeof old);
        nvk_prog_warm_save();
        expect_reload(preload, sizeof preload);
        CHECK(clock_calls == 0);
    } else {
        return 2;
    }
    nvk_prog_warm_reset();
    printf("%s: %u checks, %u failures, %u realtime samples\n",
           argv[1], checks, failures, clock_calls);
    return failures != 0;
}
