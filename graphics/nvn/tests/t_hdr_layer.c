// PR4 层状态机与层配置单测（评审稿 v3 §2.3 判定次序 / §4 PR4「新单测」行）：tick 滞回 / 排空纯逻辑（合成时钟进参）+ 排空计数喂入断言 + 层配置解析（S0/S1）+ 存储侧开机预挂与喂入。
//   纯 C，不需要 GPU / 游戏（同 t_nvn2 口径）：hdr_layer_tick_can / hdr_layer_tick_frame / hdr_layer_config 纯函数拿合成快照直调；
//   nvn2.c 存储侧（发布 / 读回 / 预挂 / 每帧喂入）经 nvn2_hdr_* 入口直调（t_nvn2 V4 段同款，存储在同一把锁后）。
//   三态流的 test-only / negctl 态的红由此而来：基线（无 PR4 实现）上 hdr_layer_config 与 nvn2_hdr_preattach 不存在——链接期报未定义符号。
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "nvn_hdr_policy.h"
static unsigned checks;
#define CHECK(c) do { checks++; if (!(c)) { fprintf(stderr, "t_hdr_layer:%d 失败：%s\n", __LINE__, #c); exit(1); } } while (0)

// 本测试给 nvn2.c 的接口（nvn2.c 里是弱定义，缺省 0）：装作 Switch 2 游戏，预挂段才走得进
int s2a_platform_ounce(void) { return 1; }
int dm_opmode(void) { const char *d = getenv("S2A_DOCKED"); return d && !strcmp(d, "1"); }   // 替身：同 t_nvn2.c（宿主不链进本单测）

int main(void) {
    // ---------- 层配置解析（评审稿 §2.3 S0/S1 行 + 注意事项①；PR4 新增的纯函数）----------
    //   S0 = 8 位 SDR（BGRA8Unorm）+ 显式 sRGB tag、无 EDR；S1 = 10 位 PQ（RGB10A2Unorm）+ BT.2100 PQ 标签 + wantsExtendedDynamicRangeContent；
    //   CAEDRMetadata 两态都不挂（默认关——PR8+ 经 S2A_HDR_META 实验）。层持不持 PQ（layer_pq）是唯一输入：off / can 不行 / 排空完成都落 S0 配置。
    {   hdr_layer_cfg s0 = hdr_layer_config(0);
        CHECK(s0.pf == HDR_LPF_SDR8 && s0.color == HDR_LCS_SRGB && s0.wants_edr == 0 && s0.metadata == 0);   // S0：显式 sRGB tag（创建与从 PQ 切回两处同一份配置——注意事项①）
        hdr_layer_cfg s1 = hdr_layer_config(1);
        CHECK(s1.pf == HDR_LPF_PQ10 && s1.color == HDR_LCS_PQ && s1.wants_edr == 1 && s1.metadata == 0);   // S1：RGB10A2 + ITUR_2100_PQ + wantsEDR；metadata 默认不挂
    }

    // ---------- tick 滞回（合成时钟；评审稿 §4 PR4 ②「can 变化持稳 500ms 才算」）----------
    //   拖窗沿两屏边缘的 flap：raw can 每 100ms 翻一次，永不持稳、永不进层
    {   hdr_snapshot s = { .s1_ready = 1 };
        hdr_layer_tick_can(&s, HDR_AUTO, 1, 0);
        hdr_layer_tick_can(&s, HDR_AUTO, 0, 100);
        hdr_layer_tick_can(&s, HDR_AUTO, 1, 200);
        hdr_layer_tick_can(&s, HDR_AUTO, 0, 300);
        hdr_layer_tick_can(&s, HDR_AUTO, 1, 400);
        hdr_layer_tick_can(&s, HDR_AUTO, 0, 500);
        CHECK(s.can_settled == 0 && s.layer_pq == 0);   // flap 永不持稳（进层更不会——层不因噪声切）
        // 持稳：can=1 从 1000 拿到 1501 → 过 500ms → can_settled=1 ∧ s1_ready=1 ∧ 非 off → 即时进层（进入不等排空，§2.3 第 4 条）
        hdr_layer_tick_can(&s, HDR_AUTO, 1, 1000);
        CHECK(s.can_settled == 0 && s.layer_pq == 0);   // 499ms 都不算
        hdr_layer_tick_can(&s, HDR_AUTO, 1, 1499);
        CHECK(s.can_settled == 0 && s.layer_pq == 0);
        hdr_layer_tick_can(&s, HDR_AUTO, 1, 1500);
        CHECK(s.can_settled == 1 && s.layer_pq == 1 && s.sdr_run == 0);   // 持稳即进层，sdr_run 清零
        // off 不变量：off 下 can 持稳也不进层（vi 恒 on=0 ∧ 出图恒 S0，两处同时回退）
        hdr_snapshot so = { .s1_ready = 1 };
        hdr_layer_tick_can(&so, HDR_OFF, 1, 0);
        hdr_layer_tick_can(&so, HDR_OFF, 1, 500);
        CHECK(so.can_settled == 1 && so.layer_pq == 0);   // can 记账照走、层不动
        // s1_ready=0（G1 大面积烟囱硬门槛——不虚假宣传）：持稳也不进层
        hdr_snapshot sg = { .s1_ready = 0 };
        hdr_layer_tick_can(&sg, HDR_AUTO, 1, 0);
        hdr_layer_tick_can(&sg, HDR_AUTO, 1, 500);
        CHECK(sg.can_settled == 1 && sg.layer_pq == 0);
    }

    // ---------- 排空喂入（合成喂入序列；评审稿 §4 PR4 ②「连出两帧非 PQ 窗口才切回——无 HDR 帧落进 SDR 层」）----------
    {   hdr_snapshot s = { .s1_ready = 1, .potential_edr = 2.0 };
        hdr_layer_tick_can(&s, HDR_AUTO, 1, 0);
        hdr_layer_tick_can(&s, HDR_AUTO, 1, 500);   // 进层（上面验过：持稳 500ms 即进）
        CHECK(s.layer_pq == 1);
        // 还要 PQ（can 持稳 ∧ s1_ready）：非 PQ 窗口帧也不排空（层不因源切回，§2.3 第 2 条）
        hdr_layer_tick_frame(&s, HDR_AUTO, 0);
        hdr_layer_tick_frame(&s, HDR_AUTO, 0);
        CHECK(s.layer_pq == 1 && s.sdr_run == 0);
        // can 掉了（掉屏 / HDR 关）：500ms 持稳后 want=false——排空途中又见 PQ 窗口（游戏没降）清零重等
        hdr_layer_tick_can(&s, HDR_AUTO, 0, 600);
        hdr_layer_tick_can(&s, HDR_AUTO, 0, 1100);
        CHECK(s.can_settled == 0 && s.layer_pq == 1);   // 滞回期间层不动
        hdr_layer_tick_frame(&s, HDR_AUTO, 1);          // PQ 窗口帧：清零
        CHECK(s.layer_pq == 1 && s.sdr_run == 0);
        hdr_layer_tick_frame(&s, HDR_AUTO, 0);          // 非 PQ 第 1 帧：计数 1，层还在
        CHECK(s.layer_pq == 1 && s.sdr_run == 1);
        hdr_layer_tick_frame(&s, HDR_AUTO, 1);          // 中途又出 PQ 窗口：清零重等（无 HDR 帧落进 SDR 层的铁律）
        CHECK(s.layer_pq == 1 && s.sdr_run == 0);
        hdr_layer_tick_frame(&s, HDR_AUTO, 0);
        hdr_layer_tick_frame(&s, HDR_AUTO, 0);          // 连续两帧非 PQ：排空切回 SDR
        CHECK(s.layer_pq == 0 && s.sdr_run == 0);
        hdr_layer_tick_frame(&s, HDR_AUTO, 0);          // 层已 SDR：喂入空转
        CHECK(s.layer_pq == 0 && s.sdr_run == 0);
        // off 喂入：不再 want，两帧非 PQ 排空（off 不变量的层侧——不留 PQ）
        hdr_layer_tick_can(&s, HDR_AUTO, 1, 1200);
        hdr_layer_tick_can(&s, HDR_AUTO, 1, 1700);
        CHECK(s.layer_pq == 1);
        hdr_layer_tick_frame(&s, HDR_OFF, 0);
        CHECK(s.layer_pq == 1 && s.sdr_run == 1);
        hdr_layer_tick_frame(&s, HDR_OFF, 0);
        CHECK(s.layer_pq == 0 && s.sdr_run == 0);
    }

    // ---------- 存储侧（nvn2.c 入口；发布 / 读回 / 开机预挂 / 每帧喂入——t_nvn2 V4 段同款直调口径）----------
    {   hdr_snapshot rb;
        setenv("S2A_HDR", "auto", 1);
        CHECK(nvn2_hdr_switch() == HDR_AUTO);                       // PR4 起开关名 S2A_ 前缀（维护者 PR #1640 意见，覆盖 v3 文档口径）；off 缺省语义不变
        hdr_snapshot pub = { .potential_edr = 2.0, .current_headroom = 2.0, .s1_ready = 1, .paper_white = 100 };
        nvn2_hdr_snapshot_publish(&pub);
        rb = (hdr_snapshot){0};
        nvn2_hdr_snapshot_probe(&rb);
        CHECK(rb.s1_ready == 1 && rb.layer_pq == 0);                // 发布只刷环境读数；层簿记仍 0
        // 开机预挂（PR4 ③）：识别 Switch 2 游戏即进层——不滞回（开机无翻屏史），赶在首查询前（Bananza 首查询即定窗口）
        nvn2_hdr_preattach(1, 5000);
        nvn2_hdr_snapshot_probe(&rb);
        CHECK(rb.layer_pq == 1 && rb.can_settled == 1 && rb.sdr_run == 0);   // 即时进层：can_settled / 滞回簿记一并记好，后续 tick 无缝衔接
        // 预挂后再发布（重探）：层簿记不回卷（排空语义的前提）
        pub.current_headroom = 2.5;
        nvn2_hdr_snapshot_publish(&pub);
        nvn2_hdr_snapshot_probe(&rb);
        CHECK(rb.layer_pq == 1 && rb.current_headroom == 2.5);
        // 无 HDR 屏（raw can=0）预挂：不动（层恒 S0——不虚假宣传）。已在层内时：环境读数清零不回卷层簿记（发布语义），
        //   要经 tick 持稳 can=0（500ms 滞回）+ 两帧非 PQ 排空才回 SDR——先排空再验 SDR 屏预挂不进层
        nvn2_hdr_preattach(0, 6000);
        nvn2_hdr_snapshot_probe(&rb);
        CHECK(rb.layer_pq == 1);                                    // 已在层内不受影响
        hdr_snapshot sd = {0};
        nvn2_hdr_snapshot_publish(&sd);
        nvn2_hdr_snapshot_probe(&rb);
        CHECK(rb.layer_pq == 1);                                    // 发布不回卷层簿记（排空语义的前提）
        nvn2_hdr_tick(HDR_AUTO, 0, 6100);
        nvn2_hdr_tick(HDR_AUTO, 0, 6600);                           // can=0 持稳 500ms → can_settled=0（want 掉）
        nvn2_hdr_tick_frame(HDR_AUTO, 0);
        nvn2_hdr_tick_frame(HDR_AUTO, 0);                           // 连续两帧非 PQ → 排空切回
        nvn2_hdr_snapshot_probe(&rb);
        CHECK(rb.layer_pq == 0 && rb.sdr_run == 0);
        nvn2_hdr_preattach(0, 7000);
        nvn2_hdr_snapshot_probe(&rb);
        CHECK(rb.layer_pq == 0);                                    // SDR 屏预挂不进层
        // 预挂后的排空喂入：off 下两帧非 PQ 切回（同纯函数段）
        hdr_snapshot pub2 = { .potential_edr = 2.0, .current_headroom = 2.0, .s1_ready = 1, .paper_white = 100 };
        nvn2_hdr_snapshot_publish(&pub2);
        nvn2_hdr_preattach(1, 8000);
        nvn2_hdr_snapshot_probe(&rb);
        CHECK(rb.layer_pq == 1);
        nvn2_hdr_tick_frame(HDR_OFF, 0);
        nvn2_hdr_tick_frame(HDR_OFF, 0);
        nvn2_hdr_snapshot_probe(&rb);
        CHECK(rb.layer_pq == 0 && rb.sdr_run == 0);
        // off 预挂：不动（off ⇒ 层恒 S0）
        setenv("S2A_HDR", "off", 1);
        nvn2_hdr_preattach(1, 9000);
        nvn2_hdr_snapshot_probe(&rb);
        CHECK(rb.layer_pq == 0);
        unsetenv("S2A_HDR");
        memset(&pub, 0, sizeof pub);
        nvn2_hdr_snapshot_publish(&pub);   // 段末清回缺省（t_nvn2 V4 段收尾同款）
    }

    printf("t_hdr_layer：全部通过（%u 项）\n", checks);
    return 0;
}
