package org.s2arm.android;

import java.io.File;
import java.io.IOException;
import java.math.BigDecimal;
import java.math.RoundingMode;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.text.NumberFormat;
import java.time.Instant;
import java.time.ZoneId;
import java.time.temporal.ChronoUnit;
import java.util.Locale;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * 一款在这台设备上的游玩时间（库页卡片下那一行）。不依赖 Android，宿主单测 PlaytimeTest 直接测。
 * 文件：运行时 runtime/src/playtime.c 写进本款 state 目录（安卓的 S2A_DOCS）的 playtime.json，一行
 * {"schema":1,"seconds":N,"lastPlayed":<Unix 秒>}；这里只读。
 * 规则三端同一份（launchers/macos/adapter/Sources/S2ArmAppleAdapter/Playtime.swift summary）：
 *   时长：不满 1 小时按分钟（向下取整，至少 1 分钟）；满 1 小时按 0.1 小时向下取，去掉 .0，10 小时起取整（向下）
 *   哪天：按本机时区比日历日：同一天「今天」、差 1 天「昨天」、再早「N 天前」；时刻在未来（改过时钟）按「今天」
 */
final class Playtime {
    static final String FILE = "playtime.json";

    /** 文案模板（{0} 占位），原文同 launchers/shared/experience.v1.json 的 library.playtime.*。 */
    static final class Text {
        final String minutes, hours, today, yesterday, daysAgo;
        Text(String minutes, String hours, String today, String yesterday, String daysAgo) {
            this.minutes = minutes; this.hours = hours; this.today = today; this.yesterday = yesterday; this.daysAgo = daysAgo;
        }
    }

    final long seconds;
    /** 最近一次玩（Unix 秒） */
    final long lastPlayed;

    Playtime(long seconds, long lastPlayed) { this.seconds = seconds; this.lastPlayed = lastPlayed; }

    /** 读 state 目录里的 playtime.json：没有 / 读不出 / 0 秒都按没玩过（null，界面不显示）。 */
    static Playtime read(File stateDir) {
        String s;
        try { s = new String(Files.readAllBytes(new File(stateDir, FILE).toPath()), StandardCharsets.UTF_8); }
        catch (IOException | RuntimeException e) { return null; }
        long seconds = field(s, "seconds");
        return seconds > 0 ? new Playtime(seconds, field(s, "lastPlayed")) : null;
    }

    // 字段缺 / 坏按 0（同 playtime.c 的 field）
    private static long field(String s, String key) {
        Matcher m = Pattern.compile("\"" + key + "\"\\s*:\\s*(\\d{1,18})").matcher(s);
        return m.find() ? Long.parseLong(m.group(1)) : 0;
    }

    /** 「玩了 1.5 小时 · 昨天」。now：Unix 秒；zone 定日历日；locale 定小数点写法。 */
    String summary(long now, ZoneId zone, Locale locale, Text t) {
        long minutes = seconds / 60;
        String duration;
        if (minutes < 60) {
            duration = t.minutes.replace("{0}", String.valueOf(Math.max(1, minutes)));
        } else {
            long tenths = minutes * 10 / 60;   // 向下取到 0.1 小时
            NumberFormat f = NumberFormat.getNumberInstance(locale);
            f.setGroupingUsed(false); f.setMinimumFractionDigits(0); f.setMaximumFractionDigits(tenths < 100 ? 1 : 0);
            f.setRoundingMode(RoundingMode.DOWN);
            // 十进制定点数直接给格式化（0.1 小时的个数 / 整小时数），不经 double 换算
            duration = t.hours.replace("{0}", f.format(tenths < 100 ? BigDecimal.valueOf(tenths, 1) : BigDecimal.valueOf(minutes / 60)));
        }
        long days = ChronoUnit.DAYS.between(Instant.ofEpochSecond(lastPlayed).atZone(zone).toLocalDate(),
                                            Instant.ofEpochSecond(now).atZone(zone).toLocalDate());
        String when = days <= 0 ? t.today : days == 1 ? t.yesterday : t.daysAgo.replace("{0}", String.valueOf(days));
        return duration + " · " + when;
    }
}
