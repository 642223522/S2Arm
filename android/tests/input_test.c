#include "input.h"
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>

static atomic_int done;
static void *writer(void *unused) {
    (void)unused;
    for (int i = 1; i < 100000; i++) {
        int32_t values[4] = {i, -i, i * 2, -i * 2};
        s2a_android_input_set((uint32_t)i, values);
    }
    atomic_store(&done, 1); return NULL;
}
int main(void) {
    s2a_android_input_reset(); pthread_t thread;
    if (pthread_create(&thread, NULL, writer, NULL)) return 1;
    do {
        int32_t values[4]; uint32_t buttons = s2a_vpad_read(values);
        // 按键读数 = 当前按键 | 读之间按下又松开的锁存位（短按锁存）：当前那次写入的位必须都在，多出的只能来自锁存
        if ((buttons & (uint32_t)values[0]) != (uint32_t)values[0] || values[1] != -values[0]
            || values[2] != values[0] * 2 || values[3] != -values[2]) {
            fprintf(stderr, "Input reader observed a torn snapshot\n"); pthread_join(thread, NULL); return 1;
        }
    } while (!atomic_load(&done));
    pthread_join(thread, NULL);
    s2a_android_input_reset();
    int32_t values[4];
    if (s2a_vpad_read(values) || values[0] || values[1] || values[2] || values[3]) return 1;
    puts("Android input: concurrent coherent snapshots and focus-loss reset passed"); return 0;
}

