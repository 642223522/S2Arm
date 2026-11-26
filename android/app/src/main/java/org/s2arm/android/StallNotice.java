package org.s2arm.android;

/**
 * 停帧看门的屏上提示该显示哪一条（runtime/src/ap_host.c stall_watch → bridge.cpp s2a_ios_banner / show_message / clear_message
 * → NativeBridge.stallNotice）。不依赖 Android，宿主单测 StallNoticeTest 直接测；显示由 MainActivity 做。
 * 口径同 iOS：救场横幅（帧率补丁已关）按给的秒数定时收，帧又走了也不收（读得完）；「可能还在加载」那条一直在，
 * 直到看门说帧又走了才收——清除只收它，不收横幅。两条同时在时先显示横幅，横幅到时间后露出还在的那条。
 */
final class StallNotice {
    static final int NONE = 0, PATCH_OFF = 1, WAIT = 2;   // 与 bridge.cpp stall_notice 的种类同值（0 同时是「清除」事件）
    private boolean wait;
    private long bannerUntil;   // 单调毫秒；0 = 没有横幅

    /** 看门来的一件事：PATCH_OFF（seconds = 横幅显示秒数）/ WAIT / NONE（帧又走了，收掉 WAIT）。now：单调毫秒。 */
    void on(int kind, int seconds, long now) {
        if (kind == PATCH_OFF) bannerUntil = now + Math.max(1, seconds) * 1000L;
        else if (kind == WAIT) wait = true;
        else if (kind == NONE) wait = false;
    }

    /** 此刻显示哪一条：PATCH_OFF / WAIT / NONE。 */
    int visible(long now) { return now < bannerUntil ? PATCH_OFF : wait ? WAIT : NONE; }

    /** 过多久显示内容会自己变（横幅到时间）；-1 = 不会自己变。 */
    long changeIn(long now) { return now < bannerUntil ? bannerUntil - now : -1; }
}
