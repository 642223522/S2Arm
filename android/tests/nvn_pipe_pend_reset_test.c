/* Standalone ordinary pending-table cancellation regression. No GPU/backend.
 * Only the production TU redirects pthread_cond_timedwait to the test seam.
 * The seam calls the real wait, then yields its table lock until the main thread
 * completes reset/reuse. No source edits or timing-based scheduling assumptions.
 */
#define _POSIX_C_SOURCE 200809L
#include "nvn_pipe_pend.h"
#include <pthread.h>
#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static pthread_mutex_t gate = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t gate_cv = PTHREAD_COND_INITIALIZER;
static int intercept, entered, awakened, resume_waiter, wait_calls;
static int checks, failures;
static const char *case_name;

static void deadline(int sig) {
    (void)sig;
    static const char message[] = "FAIL: standalone test exceeded 10 seconds\n";
    (void)write(STDERR_FILENO, message, sizeof message - 1);
    _exit(2);
}
static void require(int condition, const char *message) {
    if (!condition) {
        fprintf(stderr, "SETUP FAIL: %s\n", message);
        exit(2);
    }
}
static void check(int condition, const char *message) {
    checks++;
    if (!condition) {
        failures++;
        printf("FAIL %s: %s\n", case_name, message);
    }
}
static void lock(pthread_mutex_t *mu) { require(pthread_mutex_lock(mu) == 0, "mutex lock"); }
static void unlock(pthread_mutex_t *mu) { require(pthread_mutex_unlock(mu) == 0, "mutex unlock"); }
static void signal_gate(void) { require(pthread_cond_broadcast(&gate_cv) == 0, "gate broadcast"); }
static void wait_gate(int *flag) {
    lock(&gate);
    while (!*flag) require(pthread_cond_wait(&gate_cv, &gate) == 0, "gate wait");
    unlock(&gate);
}

int nvk_pp_reset_test_timedwait(pthread_cond_t *cv, pthread_mutex_t *mu,
                              const struct timespec *deadline_at) {
    if (!intercept) return pthread_cond_timedwait(cv, mu, deadline_at);
    /* A canceled waiter must not wait on a replacement task. Bound regressions. */
    if (++wait_calls > 1) return ETIMEDOUT;
    lock(&gate);
    entered = 1;
    signal_gate();
    unlock(&gate);
    int rc = pthread_cond_timedwait(cv, mu, deadline_at);
    /* Permit reset + reuse before production inspects the returned entry state.
     * Return with the caller's mutex locked, as required by timedwait. */
    unlock(mu);
    lock(&gate);
    awakened = 1;
    signal_gate();
    while (!resume_waiter) require(pthread_cond_wait(&gate_cv, &gate) == 0, "resume wait");
    unlock(&gate);
    lock(mu);
    return rc;
}

static int key_equal(const void *a, const void *b) {
    return memcmp(a, b, sizeof(unsigned)) == 0;
}
static nvk_pp *table_new(void) {
    nvk_pp *table = calloc(1, sizeof *table);
    require(table != NULL, "allocate table");
    nvk_pp_init(table, sizeof(unsigned));
    require(table->ready, "initialize table");
    return table;
}
static void table_free(nvk_pp *table) {
    for (int i = 0; i < NVK_PP_MAX; i++)
        require(pthread_cond_destroy(&table->ent[i].cv) == 0, "destroy table condition");
    require(pthread_mutex_destroy(&table->mu) == 0, "destroy table mutex");
    free(table);
}
static int enter(nvk_pp *table, unsigned key) {
    int handle = -1;
    require(nvk_pp_enter(table, &key, key_equal, &handle) == NVK_PP_ENTER_BUILDER,
            "enter fixed key as builder");
    require(handle >= 0 && handle < NVK_PP_MAX, "valid handle");
    return handle;
}
struct waiter {
    nvk_pp *table;
    unsigned key;
    int result, code;
    void *object;
    char why[32];
};
static void *wait_main(void *argument) {
    struct waiter *w = argument;
    w->object = w;
    w->code = 99;
    strcpy(w->why, "sentinel");
    w->result = nvk_pp_wait(w->table, &w->key, key_equal, 2000,
                            &w->object, &w->code, w->why, sizeof w->why);
    return NULL;
}
static void test_reset(int reuse) {
    case_name = reuse == 2 ? "reset then reuse compiling" :
                reuse == 1 ? "reset then reuse ready" : "reset while waiting";
    nvk_pp *table = table_new();
    int original_handle = enter(table, 11);
    struct waiter w = { .table = table, .key = 11 };
    intercept = 1;
    entered = awakened = resume_waiter = wait_calls = 0;
    pthread_t thread;
    require(pthread_create(&thread, NULL, wait_main, &w) == 0, "create waiter");
    wait_gate(&entered);
    /* Reset acquiring table->mu proves the real wait released that mutex. */
    nvk_pp_reset(table);
    wait_gate(&awakened);
    int new_payload = 71;
    if (reuse) {
        int new_handle = enter(table, 22);
        check(new_handle == original_handle, "different fixed key reuses same slot");
        if (reuse == 1) nvk_pp_publish(table, new_handle, &new_payload, 0, NULL);
    }
    lock(&gate);
    resume_waiter = 1;
    signal_gate();
    unlock(&gate);
    require(pthread_join(thread, NULL) == 0, "join waiter");
    intercept = 0;
    printf("RESULT %s: status=%d expected=%d new_result=%d\n", case_name,
           w.result, NVK_PP_WAIT_ABSENT, w.object == &new_payload);
    check(wait_calls == 1, "canceled waiter does not wait on replacement task");
    check(w.result == NVK_PP_WAIT_ABSENT, "canceled waiter returns ABSENT");
    check(w.object == NULL && w.code == 0 && !w.why[0], "canceled outputs empty");
    table_free(table);
}
static void test_controls(void) {
    nvk_pp *table = table_new();
    unsigned key = 33;
    int handle = enter(table, key), code;
    void *object;
    char why[32];
    case_name = "compiling zero-budget poll";
    check(nvk_pp_wait(table, &key, key_equal, 0, &object, &code, why, sizeof why)
          == NVK_PP_WAIT_TIMEOUT, "existing compiling item remains TIMEOUT");
    case_name = "real compiling timed wait";
    int result = nvk_pp_wait(table, &key, key_equal, 5, &object, &code, why, sizeof why);
    printf("RESULT %s: status=%d expected=%d\n", case_name, result, NVK_PP_WAIT_TIMEOUT);
    check(result == NVK_PP_WAIT_TIMEOUT, "real wait still times out");
    check(!object && !code && !why[0], "timeout outputs empty");
    case_name = "ready control";
    int payload = 42;
    nvk_pp_publish(table, handle, &payload, 0, NULL);
    check(nvk_pp_wait(table, &key, key_equal, 5, &object, &code, why, sizeof why)
          == NVK_PP_WAIT_READY, "ready preserved");
    check(object == &payload, "ready object preserved");
    nvk_pp_reset(table);
    case_name = "absent zero-budget poll";
    check(nvk_pp_wait(table, &key, key_equal, 0, &object, &code, why, sizeof why)
          == NVK_PP_WAIT_ABSENT, "missing item remains ABSENT");
    handle = enter(table, key);
    case_name = "failed control";
    nvk_pp_publish(table, handle, NULL, 7, "ordinary task failure");
    check(nvk_pp_wait(table, &key, key_equal, 5, &object, &code, why, sizeof why)
          == NVK_PP_WAIT_FAILED, "failure preserved");
    check(!object && code == 7 && !strcmp(why, "ordinary task failure"), "failure details preserved");
    table_free(table);
}
int main(void) {
    struct sigaction action;
    memset(&action, 0, sizeof action);
    action.sa_handler = deadline;
    require(sigemptyset(&action.sa_mask) == 0, "signal mask");
    require(sigaction(SIGALRM, &action, NULL) == 0, "alarm handler");
    alarm(10);
    test_reset(0);
    test_reset(1);
    test_reset(2);
    test_controls();
    alarm(0);
    require(pthread_cond_destroy(&gate_cv) == 0, "destroy gate condition");
    require(pthread_mutex_destroy(&gate) == 0, "destroy gate mutex");
    printf("TOTAL checks=%d failures=%d\n", checks, failures);
    return failures ? 1 : 0;
}
