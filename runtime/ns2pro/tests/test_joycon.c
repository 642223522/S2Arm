// Joy-Con 2 单只（runtime/ns2pro/NS2JoyCon.c）：型号识别、SL / SR、横握视角、六轴、震动包。期望按协议文档与映射表手算，未在实机验证。
#include "NS2Transport.h"
#include <stdio.h>
#include <string.h>
static int bad;
#define CK(c, ...) do { if (c) printf("✓ " __VA_ARGS__); else { printf("✗ " __VA_ARGS__); bad++; } printf("\n"); } while (0)
enum { A, B, X, Y, LS, RS, L, R, ZL, ZR, PLUS, MINUS, LEFT, UP, RIGHT, DOWN, HOME, CAPTURE };
#define BIT(n) (1ull << (n))
int main(void) {
    const uint8_t pro[9] = {0x53, 0x05, 1, 0, 3, 0x7e, 0x05, 0x69, 0x20}, jl[9] = {0x53, 0x05, 1, 0, 3, 0x7e, 0x05, 0x67, 0x20}, jr[9] = {0x53, 0x05, 1, 0, 3, 0x7e, 0x05, 0x66, 0x20};
    const uint8_t other[9] = {0x4c, 0x00, 1, 0, 3, 0x7e, 0x05, 0x69, 0x20};
    CK(ns2_kind_from_manufacturer(pro, 9) == NS2_KIND_PRO && ns2_kind_from_manufacturer(jl, 9) == NS2_KIND_JOYCON_L && ns2_kind_from_manufacturer(jr, 9) == NS2_KIND_JOYCON_R,
       "① 广播产品号：0x2069 Pro、0x2067 左只、0x2066 右只");
    CK(ns2_kind_from_manufacturer(other, 9) == NS2_KIND_NONE && ns2_kind_from_manufacturer(pro, 8) == NS2_KIND_NONE && ns2_kind_from_manufacturer(NULL, 9) == NS2_KIND_NONE,
       "② 公司号不对 / 不够 9 字节 / 空：不认");
    uint8_t rep[64] = {0}; rep[4] = 0x20; rep[6] = 0x10;   // 按键字段第 0 字节 0x20 = 右只 SL，第 2 字节 0x10 = 左只 SR
    CK(ns2_decode_side_buttons(rep, sizeof rep) == (NS2_SIDE_SL_R | NS2_SIDE_SR_L) && ns2_decode_side_buttons(rep, 6) == 0, "③ SL / SR：右只 SL + 左只 SR；太短返回 0");
    ns2_state l = {BIT(UP) | BIT(MINUS) | BIT(CAPTURE) | BIT(L) | BIT(ZL), 100, 200, 7, 8};
    ns2_joycon_sideways(NS2_KIND_JOYCON_L, NS2_SIDE_SL_L, &l);
    CK(l.buttons == (BIT(Y) | BIT(PLUS) | BIT(HOME) | BIT(L)) && l.lx == -200 && l.ly == 100 && l.rx == 0 && l.ry == 0,
       "④ 左只横握：上 → Y、Minus → Plus、Capture → Home、SL → L，原 L / ZL 不出；摇杆 (100,200) → (−200,100)，右摇杆 0（实 %llx %d,%d,%d,%d）", (unsigned long long)l.buttons, l.lx, l.ly, l.rx, l.ry);
    ns2_state r = {BIT(X) | BIT(RS) | BIT(HOME) | BIT(R) | BIT(ZR), 5, 6, 300, -400};
    ns2_joycon_sideways(NS2_KIND_JOYCON_R, NS2_SIDE_SR_R, &r);
    CK(r.buttons == (BIT(A) | BIT(LS) | BIT(HOME) | BIT(R)) && r.lx == -400 && r.ly == -300 && r.rx == 0 && r.ry == 0,
       "⑤ 右只横握：X → A、右摇杆按下 → 左摇杆按下、Home 照旧、SR → R，原 R / ZR 不出；摇杆 (300,−400) → (−400,−300)（实 %llx %d,%d）", (unsigned long long)r.buttons, r.lx, r.ly);
    ns2_state r2 = {BIT(A) | BIT(B) | BIT(Y), 0, 0, 0, 0}; ns2_joycon_sideways(NS2_KIND_JOYCON_R, 0, &r2);
    ns2_state l2 = {BIT(RIGHT) | BIT(DOWN) | BIT(LEFT), 0, 0, 0, 0}; ns2_joycon_sideways(NS2_KIND_JOYCON_L, 0, &l2);
    CK(r2.buttons == (BIT(B) | BIT(Y) | BIT(X)) && l2.buttons == (BIT(X) | BIT(A) | BIT(B)), "⑥ 其余面键：右只 A → B、B → Y、Y → X；左只 右 → X、下 → A、左 → B");
    ns2_state p = {BIT(ZL) | BIT(A), 1, 2, 3, 4}; ns2_joycon_sideways(NS2_KIND_PRO, NS2_SIDE_SL_L, &p);
    CK(p.buttons == (BIT(ZL) | BIT(A)) && p.lx == 1 && p.ry == 4, "⑦ Pro：原样不动");
    ns2_motion ml = {.acceleration_x = 1, .acceleration_z = 2, .gyro_x = 3, .gyro_z = 4}, mr = ml, mp = ml;
    ns2_joycon_sideways_motion(NS2_KIND_JOYCON_L, &ml); ns2_joycon_sideways_motion(NS2_KIND_JOYCON_R, &mr); ns2_joycon_sideways_motion(NS2_KIND_PRO, &mp);
    CK(ml.acceleration_x == 2 && ml.acceleration_z == -1 && ml.gyro_x == 4 && ml.gyro_z == -3 && mr.acceleration_x == -2 && mr.acceleration_z == 1 && mr.gyro_x == -4 && mr.gyro_z == 3 && mp.acceleration_x == 1,
       "⑧ 六轴：左只 (x,z) → (z,−x)、右只 → (−z,x)，Pro 不动");
    ns2_vibration v[2] = {{0.2f, 160, 0.1f, 320}, {0.5f, 160, 0.4f, 320}};
    uint8_t jrp[42], ref[42], prop[42], prop2[42]; ns2_vibration one[2] = {v[1], {0}};
    ns2_encode_rumble_for(NS2_KIND_JOYCON_R, v, 3, 1, jrp); ns2_encode_rumble(one, 3, 1, ref);
    int tail0 = 1; for (int i = 17; i < 42; i++) tail0 &= jrp[i] == 0;
    ns2_encode_rumble_for(NS2_KIND_PRO, v, 3, 1, prop); ns2_encode_rumble(v, 3, 1, prop2);
    CK(!memcmp(jrp, ref, 17) && tail0 && (jrp[1] & 0xf0) == 0x50 && !memcmp(prop, prop2, 42), "⑨ 震动：右只只放一块（取右侧值）、第二块起全 0；Pro 与原编码逐字节相同");
    printf("%s test_joycon：%d 项不符\n", bad ? "✗" : "✓", bad);
    return bad ? 1 : 0;
}
