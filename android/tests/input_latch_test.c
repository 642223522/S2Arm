// 短按锁存：按下与松开落在两次 HID 读之间（adb input tap / 玩家快点）时，游戏仍读到一次按下。
#include "input.h"
#include <stdio.h>
#include <stdlib.h>

#define CHECK(c) do { if (!(c)) { fprintf(stderr, "input latch: %s:%d %s\n", __FILE__, __LINE__, #c); exit(1); } } while (0)
enum { A = 1u << 0, B = 1u << 1 };

int main(void) {
    const int32_t zero[4] = {0};
    int32_t s[4];
    // 读之间按下又松开：下一次读到 A，再下一次没有
    s2a_android_input_set(A, zero); s2a_android_input_set(0, zero);
    CHECK(s2a_vpad_read(s) == A);
    CHECK(s2a_vpad_read(s) == 0);
    // 按住：每次都读到；松开后不残留
    s2a_android_input_set(A, zero);
    CHECK(s2a_vpad_read(s) == A);
    CHECK(s2a_vpad_read(s) == A);
    s2a_android_input_set(0, zero);
    CHECK(s2a_vpad_read(s) == 0);
    // 失焦 / 换局：排队的短按一起清
    s2a_android_input_set(A, zero); s2a_android_input_set(0, zero); s2a_android_input_reset();
    CHECK(s2a_vpad_read(s) == 0);
    // 两键按着、先松 A：这次读到 A|B，下次只剩 B
    s2a_android_input_set(A | B, zero); s2a_android_input_set(B, zero);
    CHECK(s2a_vpad_read(s) == (A | B));
    CHECK(s2a_vpad_read(s) == B);
    s2a_android_input_reset();
    puts("android input latch ok");
    return 0;
}
