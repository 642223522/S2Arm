// HDR 上屏策略（评审稿 v3 §2.2 接缝 / §2.3 上屏模式矩阵与判定次序 / §4 PR3a）：屏幕能力快照（纯数据）+ choose_mode 纯函数 + 层 tick 状态机与 peak 步进（纯逻辑）+ nvn2.c 侧存储与入口的声明。
//   策略单源（调研缺口 A7）：直连出图层（nvn_mtl.m，PR3b/PR4 接入）、vi 门控（PR5）、通用路径（gal_present.m，PR7）共用；
//   nxnative 的 dm_hdr_layer_tick / vi_screen_peak / present_mode 三处散布式全局态收进本层包裹（评审稿 §2.7）——状态全走参数、不藏全局：合成快照 + 合成时钟即可全分支单测（t_nvn2 V4 段）。
//   模式枚举 v3 重定义（§2.3）：S1 = PQ 直通层（RGB10A2Unorm + kCGColorSpaceITUR_2100_PQ + wantsExtendedDynamicRangeContent，主路径）；
//   v2 的 S1 载体（16F + ExtendedLinear + CAEDRMetadata）整体移出枚举 → PR8+ 实验（16F 层水面黑块 / metadata 全屏旧帧矩形，调研实查否决默认开）；S4（SDR→HDR 逆映射）同为 PR8+，不占判定次序。
//   纯 C，不引平台头（只带标准 C 的 math.h）：宿主侧（host_adapt.m / front_mac.m / nvn_mtl.m）与单测都能包。
//   事件档读策略（发布 / tick / 同源答案入口），出图热路径只读已算好的结果——不逐帧进这里（热路径逐帧只喂排空计数，PR4）。
#pragma once
#include <math.h>

// 上屏模式（§2.3 矩阵）：S0 = SDR 直通（BGRA8Unorm + 显式 sRGB tag——创建与从 PQ 层切回两处都设，PR4/PR7 落地）；S1 = PQ 直通层（主路径）；
//   S3 = HDR→SDR（宿主 mode 1 映射兜底：S2ARM_HDR=on ∧ can 不行 / s1_ready 未过时强制，净空塌缩兜底）
enum { HDR_S0 = 0, HDR_S1, HDR_S3 };
// S2ARM_HDR 三态（§2.5）：off 缺省——字节级回现状（不变量：off ⇒ choose_mode 恒 HDR_S0 ∧ vi 恒 on=0，两处同时回退）；
//   auto 按快照自动；on 强制 HDR 管线（游戏 HDR 分支 + 宿主按屏选 S1/S3——can 不行 / s1_ready 未过走 S3）
enum { HDR_OFF = 0, HDR_AUTO, HDR_ON };

// 判定数值（评审稿 v3 定稿，照抄不发明）：can 滞回 500ms；排空两帧非 PQ 窗口；peak 十倍频 40 步（约 6%）量化 10 nit、
//   出带候选持稳 1s、地板 1.25×纸白、顶帽 10000 nit、无前端 1000
#define HDR_CAN_HYSTERESIS_MS 500ull
#define HDR_SDR_DRAIN_FRAMES 2
#define HDR_PEAK_STEPS_PER_DECADE 40
#define HDR_PEAK_QUANT_NITS 10
#define HDR_PEAK_HOLD_MS 1000ull
#define HDR_PEAK_FLOOR_TIMES 1.25
#define HDR_PEAK_CAP_NITS 10000
#define HDR_PEAK_NO_FRONTEND_NITS 1000

// 屏幕能力快照（§2.3 的判定输入，主线程查屏后发布；全 0 = 「无 HDR」缺省 = 现状行为）。
//   字段分两主（nvn2_hdr_snapshot_publish 只刷前者、层状态机独占后者——发布不回卷层状态，PR4 重探排空语义的前提）：
//   环境读数（host 查屏 / G1 烟囱填）：potential_edr / current_headroom / s1_ready / paper_white；
//   层状态机簿记（hdr_layer_tick_can / hdr_layer_tick_frame 增改）：can_settled / layer_pq / sdr_run + 滞回时间戳两枚
typedef struct {
    double potential_edr;    // 挂层屏 potentialEDR（倍数，1.0 = SDR 白锚；§1.3 实测：U2720QM 开态 4.555 / 内建 2.0 / 关态 1.0）：raw can = > 1.0（调用方口径）
    double current_headroom; // 运行时净空 currentEDR（peak=纸白×headroom 的原料；后台窗恒 1.2 的口径与前台判定是 PR4 的活）：≤ 0 = 无前端读数 → peak 答无前端值 1000
    int    can_settled;      // can 过 500ms 滞回后的持稳值（hdr_layer_tick_can 维护）：0 = 未持稳 / 未运行——按保守（SDR 语义）处理
    int    layer_pq;         // 层现持 PQ（S1 已挂）——「先持层再答」的输入：choose_mode 不见它 =1 不答 vi on=1
    int    sdr_run;          // 排空计数：不再 want 后连续非 PQ 窗口帧数（出图每帧喂），≥ 2 层才切回 SDR——保证无 HDR 帧落进 SDR 层
    int    s1_ready;         // G1 双面积烟囱大面积档就绪（§4 G1 第 4 条：大面积 currentEDR>1.0）：G1 未跑缺省 0——S1 的硬门槛（不虚假宣传）
    int    paper_white;      // 纸白（nit）：v3 定稿 100（PQ 相对模型 EDR=nits/100 的锚，§1.4 判读②）；vi_paper_white 改答 100 是 PR5 的活，本快照只供 peak 公式用；未发布按 100
    unsigned long long can_chg_ms;  // 滞回簿记：raw can 上次变化的时刻（合成时钟，ms）
    int    last_can_raw;     // 滞回簿记：上一次喂入的 raw can
} hdr_snapshot;

// peak 步进状态（vi_screen_peak 收编为纯函数后由调用方持有——nvn2.c 存储侧持一份，单测自持；全 0 = 尚未答过）
typedef struct {
    int answered_nits;           // 当前已告知游戏的 peak（nit；0 = 还没答过——首答直接采纳，不等持稳）
    int hold_nits;               // 候选步的量化值（0 = 无候选；候选变化即重计）
    unsigned long long hold_ms;  // 候选步开始持稳的时刻（合成时钟）
} hdr_peak_state;

// 答案包（choose_mode 的一次判定输出）：mode 供出图层 / present 选路（PR3b/PR4），vi 三元组供 vi_hdr_status 照抄（PR5 接线）
typedef struct {
    int mode;      // HDR_S0 / HDR_S1 / HDR_S3
    int vi_on;     // vi_hdr_status 的 on（0 = off / 源非 HDR / auto 下 can 不行或层未持——游戏自降）
    int vi_fmt;    // 恒 1（fmt>1 是 SDK 错误 0x272——答 on=1 时；on=0 时 0 照现状）
    int vi_peak;   // peak（nit）：答 on=1 时按 hdr_vi_peak_nits 步进；on=0 时 0 照现状
} hdr_decision;

// peak 步进（vi_screen_peak 收编为纯函数；§4 PR5 公式 + §2.3 第 5 条「headroom 波动不切层、peak 步进吸收」）：
//   目标 = 纸白 × 当前 headroom（≤ 0 视为无前端 → 1000），夹到 [1.25×纸白, 10000]；格点十倍频 40 步锚在纸白（headroom 1.0 = 0 步）、值量化到 10 nit；
//   与当前答案差 ≤ 2 步（带内）答案不动、候选撤销——「带内保持」的读法：带内抖动被吸收，答案保持不变（1s 不参与）；
//   出带候选持稳 1s 才采纳（瞬时尖峰滤掉，防闪烁）；候选中途变化重计 1s。绝不答 0（地板兜底）。
//   快照指针为空按纸白 100 / 无前端处理；状态指针为空 = 无步进记忆，直接按目标答（正常调用方别这么用）。
static inline int hdr_vi_peak_nits(const hdr_snapshot *s, hdr_peak_state *st, unsigned long long now_ms) {
    double pw = (s && s->paper_white > 0) ? (double)s->paper_white : 100.0;   // 未发布按 PQ 锚 100
    double head = (s && s->current_headroom > 0) ? s->current_headroom : 0.0;
    double raw = head > 0 ? pw * head : (double)HDR_PEAK_NO_FRONTEND_NITS;    // 无前端：恒 1000（nxnative DM 缺省同值）
    double floor_nits = HDR_PEAK_FLOOR_TIMES * pw;
    if (raw < floor_nits) raw = floor_nits;
    if (raw > (double)HDR_PEAK_CAP_NITS) raw = (double)HDR_PEAK_CAP_NITS;
    int step = (int)lround(log10(raw / pw) * (double)HDR_PEAK_STEPS_PER_DECADE);   // 格点锚在纸白：headroom 1.0 = 0 步
    if (step < 0) step = 0;   // raw 已夹地板（≥ 1.25×纸白）：步号不会为负（headroom < 1 也夹到地板）
    int nits = (int)lround(pw * pow(10.0, (double)step / (double)HDR_PEAK_STEPS_PER_DECADE) / (double)HDR_PEAK_QUANT_NITS) * HDR_PEAK_QUANT_NITS;
    if (nits < (int)(ceil(floor_nits / (double)HDR_PEAK_QUANT_NITS)) * HDR_PEAK_QUANT_NITS)   // 量化后不破地板（125 → 130）
        nits = (int)(ceil(floor_nits / (double)HDR_PEAK_QUANT_NITS)) * HDR_PEAK_QUANT_NITS;
    if (nits > HDR_PEAK_CAP_NITS) nits = HDR_PEAK_CAP_NITS;
    if (!st) return nits;   // 无状态：直接按目标答，无步进记忆
    if (st->answered_nits <= 0) { st->answered_nits = nits; st->hold_nits = nits; st->hold_ms = now_ms; return nits; }   // 首答直接采纳
    int cur = (int)lround(log10((double)st->answered_nits / pw) * (double)HDR_PEAK_STEPS_PER_DECADE);   // 当前答案的步号（量化值反推有 ±1 步漂，带宽容 ±2 吸收）
    if (step >= cur - 2 && step <= cur + 2) { st->hold_nits = 0; return st->answered_nits; }   // 带内（±2 步）：保持不动、撤销候选
    if (st->hold_nits != nits) { st->hold_nits = nits; st->hold_ms = now_ms; return st->answered_nits; }   // 出带新候选（或候选变了）：重计 1s
    if (now_ms - st->hold_ms >= HDR_PEAK_HOLD_MS) { st->answered_nits = nits; st->hold_nits = nits; return nits; }   // 候选持稳 1s：采纳
    return st->answered_nits;
}

// 层 tick——can 滞回 + 进层（事件档：250ms tick / 换屏通知 / 开机预挂，PR4 接线；纯逻辑，合成时钟进参）：
//   raw can（potential_edr > 1.0 的调用方口径）持稳 HDR_CAN_HYSTERESIS_MS 才写 can_settled（flap 永不持稳——拖窗沿两屏边缘不来回切层）；
//   持稳 ∧ s1_ready ∧ 三态非 off ∧ 层未持 PQ → 进层（即时——排空只在退出时等，进入不等：开机预挂赶首查询前，§2.3 第 4 条）
static inline void hdr_layer_tick_can(hdr_snapshot *s, int sw, int raw_can, unsigned long long now_ms) {
    if (raw_can != s->last_can_raw) { s->last_can_raw = raw_can; s->can_chg_ms = now_ms; }   // 变化只记时刻（合成时钟）
    else if (now_ms - s->can_chg_ms >= HDR_CAN_HYSTERESIS_MS) s->can_settled = raw_can;      // 持稳 500ms 才算
    if (sw != HDR_OFF && s->can_settled && s->s1_ready && !s->layer_pq) { s->layer_pq = 1; s->sdr_run = 0; }   // 持稳 ∧ s1_ready → 进层
}

// 层 tick——排空喂入（每帧，nvn_mtl.m present 档喂计数，PR4 接线；纯逻辑）：层在 PQ 态且不再 want（三态 off / can 未持稳 / s1_ready 掉）时，
//   连续 HDR_SDR_DRAIN_FRAMES 帧非 PQ 窗口才切回 SDR——无 HDR 帧落进 SDR 层；want 期间（层不因源切回，§2.3 第 2 条）与 PQ 窗口帧都清零重等
static inline void hdr_layer_tick_frame(hdr_snapshot *s, int sw, int frame_is_pq) {
    if (!s->layer_pq) { s->sdr_run = 0; return; }
    if (sw != HDR_OFF && s->can_settled && s->s1_ready) { s->sdr_run = 0; return; }   // 还要 PQ：非 PQ 帧也不排空
    if (frame_is_pq) { s->sdr_run = 0; return; }   // 排空途中又有 PQ 窗口（游戏未降）：清零重等
    if (++s->sdr_run >= HDR_SDR_DRAIN_FRAMES) { s->layer_pq = 0; s->sdr_run = 0; }   // 连续两帧非 PQ：排空切回 SDR
}

// 判定次序（§2.3，纯函数；合成快照 + 合成时钟全分支单测，t_nvn2 V4 段）：
//   1. off → 恒 S0 ∧ vi 恒 on=0（不变量，无视快照与层状态——出图 S0 直通 + 游戏回 SDR 分支，两处同时回退）；
//   2. 源非 HDR（8 位窗 / color_space=0 / 未知枚举一律按非 HDR——Q1 口径，调用方传 src_hdr=0）→ SDR 语义：vi 不答 on=1，层不因源切回（层在 PQ 态仍 S1，逐帧 mode 2 上屏——PR3b）；
//   3. can 未持稳（500ms 滞回后）或 s1_ready 未过（G1 大面积烟囱硬门槛——不虚假宣传）：auto → vi on=0 游戏自降（SDR 屏上游戏自画比宿主映射少饱和 / 更准，§2.3 注意②），层没排完前按层现态答 S1（present 逐帧按实际格式选转换）；on → S3 强制（vi 仍答 on=1 / fmt=1 / peak，宿主 mode 1 映射上屏）；
//   4. can=true ∧ s1_ready → mode=S1：「先持层再答」——layer_pq 入参 =1 才放行 vi on=1 / fmt=1 / peak（Bananza 首查询即定窗口，等 headroom 爬坡会永久困在 SDR——§1.4 判读②）；层未持只答 mode，下一发布周期补答；
//   headroom 波动不在这里切层（peak 步进吸收，答案变层不动）；净空塌缩 120 帧滞回（v3 保留的唯一帧级滞回）是 PR4/PR5 的层 / 门控活，不在本函数。
//   快照指针为空 = 没发布过，按全 0「无 HDR」处理；peak 状态指针为空 = 无步进记忆。
static inline hdr_decision hdr_choose_mode(int sw, int src_hdr, const hdr_snapshot *s, hdr_peak_state *pk, unsigned long long now_ms) {
    static const hdr_snapshot none;   // 全 0 = 无 HDR（没发布过 / 单测 / 安卓）
    hdr_decision d = { HDR_S0, 0, 0, 0 };
    if (!s) s = &none;
    if (sw == HDR_OFF) return d;   // §2.3 第 1 条（不变量）
    if (!src_hdr) { d.mode = s->layer_pq ? HDR_S1 : HDR_S0; return d; }   // 第 2 条：源非 HDR → SDR 语义；层不因源切回
    if (!s->can_settled || !s->s1_ready) {   // 第 3 条（can=false，500ms 滞回后）+ S1 硬门槛（s1_ready=0）
        if (sw == HDR_ON) { d.mode = HDR_S3; d.vi_on = 1; d.vi_fmt = 1; d.vi_peak = hdr_vi_peak_nits(s, pk, now_ms); }   // on：S3 强制（vi 仍答 on=1，宿主 mode 1 映射上屏）
        else if (s->layer_pq) d.mode = HDR_S1;   // auto：vi on=0 游戏自降；层没排完前按层现态答 S1
        return d;
    }
    d.mode = HDR_S1;   // 第 4 条：can=true ∧ s1_ready → 层持 PQ（hdr_layer_tick_can 进层，开机预挂赶首查询前）
    if (s->layer_pq) { d.vi_on = 1; d.vi_fmt = 1; d.vi_peak = hdr_vi_peak_nits(s, pk, now_ms); }   // 「先持层再答」：layer_pq 入参不 =1 不放行
    return d;
}

// nvn2.c 侧的存储与入口（实现都在 nvn2.c：同 PR1 探针 nvn2_vi_hdr_probe 的口径，声明不进 nvn2.h，统一收在本头）。
//   快照与层状态机 / peak 状态都存 nvn2.c（PR1 g_hdr 探针存储同款先例，同一把锁）：nvn2.c 仍纯 C、不引平台头、不对宿主符号有链接依赖（宿主侧调进来，方向同 nvn2_sev_attach_register）；
//   nxnative dm_hdr_layer_tick / vi_screen_peak 的散布式全局态由此收进本文件单点（评审稿 §2.7）。
//   缺省全 0 = 「无 HDR」：不发布（单测 / 安卓 / 无头局）——现状行为分毫不差
void nvn2_hdr_snapshot_publish(const hdr_snapshot *s);   // 平台侧（host_adapt.m 挂层块 / front_mac.m screen_edr_note）发布环境读数；只刷 potential_edr / current_headroom / s1_ready / paper_white，层簿记不回卷；空指针忽略
void nvn2_hdr_snapshot_probe(hdr_snapshot *out);         // 读回整份（含层簿记；出图 / 门控 / 单测只读）；空指针忽略
int  nvn2_hdr_switch(void);                              // S2ARM_HDR 三态解析：不设 / off / 看不懂 = off 缺省（缺省关，字节级回现状；看不懂打一次红行）
void nvn2_hdr_tick(int sw, int raw_can, unsigned long long now_ms);      // 层 tick——can 滞回 + 进层，对存储快照（事件档：250ms timer / 换屏通知，PR4 接线）
void nvn2_hdr_tick_frame(int sw, int frame_is_pq);                       // 层 tick——排空喂入，对存储快照（每帧，PR4 接线）
hdr_decision nvn2_hdr_answer(int src_hdr, unsigned long long now_ms);    // 同源答案入口：三态开关 + 已发布快照 + 存储的 peak 状态进 choose_mode——vi 门控 / 出图都从这读，不各自判
