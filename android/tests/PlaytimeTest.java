package org.s2arm.android;

import java.io.File;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.ZoneId;
import java.util.Locale;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * 库页游玩时间一行（Playtime.summary / read）的宿主回归。期望值照抄苹果侧 launchers/macos/Tests/S2ArmAppleAdapterTests/PlaytimeTests.swift
 * （按规则手算：分钟向下取整至少 1；满 1 小时按 0.1 小时向下取、10 小时起取整；按本机时区比日历日），文案读真 strings.xml（参数 = res 目录）。
 * 另加两条安卓侧的：2.3 小时（138 分 = 23 个 0.1 小时）、库页按只算路径的 GameSession.statePath 找到起局用的同一个 state 目录。
 */
public final class PlaytimeTest {
    private static final ZoneId CN = ZoneId.of("Asia/Shanghai");
    private static final long NOW = 1_794_790_800L;   // 2026-11-16 09:00 北京时间
    private static int checks;

    private static void eq(String got, String want, String what) {
        checks++;
        if (!got.equals(want)) throw new AssertionError(what + ": got \"" + got + "\" want \"" + want + "\"");
    }

    private static void demand(boolean ok, String what) { checks++; if (!ok) throw new AssertionError(what); }

    private static Playtime.Text text(Path res, String dir) throws Exception {
        String xml = new String(Files.readAllBytes(res.resolve(dir).resolve("strings.xml")), StandardCharsets.UTF_8);
        String[] keys = {"minutes", "hours", "today", "yesterday", "days_ago"}, v = new String[keys.length];
        for (int i = 0; i < keys.length; i++) {
            Matcher m = Pattern.compile("<string name=\"library_playtime_" + keys[i] + "\">([^<]*)</string>").matcher(xml);
            if (!m.find()) throw new AssertionError(dir + "/strings.xml has no library_playtime_" + keys[i]);
            v[i] = m.group(1);
        }
        return new Playtime.Text(v[0], v[1], v[2], v[3], v[4]);
    }

    private static String line(Playtime.Text t, Locale locale, long seconds, long lastAgo) {
        return new Playtime(seconds, NOW - lastAgo).summary(NOW, CN, locale, t);
    }

    public static void main(String[] args) throws Exception {
        Path res = Path.of(args[0]);
        Playtime.Text zh = text(res, "values-zh"), en = text(res, "values");
        Locale zhl = Locale.SIMPLIFIED_CHINESE;

        // testDuration
        eq(line(zh, zhl, 59, 0), "玩了 1 分钟 · 今天", "不满 1 分钟按 1 分钟");
        eq(line(zh, zhl, 45 * 60 + 59, 0), "玩了 45 分钟 · 今天", "分钟向下取整");
        eq(line(zh, zhl, 60 * 60, 0), "玩了 1 小时 · 今天", "1.0 去掉 .0");
        eq(line(zh, zhl, 90 * 60, 0), "玩了 1.5 小时 · 今天", "1.5 小时");
        eq(line(zh, zhl, 599 * 60 + 59, 0), "玩了 9.9 小时 · 今天", "9 小时 59 分：5990/60 = 99 个 0.1 小时");
        eq(line(zh, zhl, 600 * 60, 0), "玩了 10 小时 · 今天", "10 小时起取整");
        eq(line(zh, zhl, 12 * 3600 + 59 * 60, 0), "玩了 12 小时 · 今天", "12 小时 59 分向下取整");
        eq(line(zh, zhl, 138 * 60, 0), "玩了 2.3 小时 · 今天", "138 分 = 23 个 0.1 小时");

        // testDay
        eq(line(zh, zhl, 600, 8 * 3600 + 50 * 60), "玩了 10 分钟 · 今天", "当天 00:10");
        eq(line(zh, zhl, 600, 9 * 3600 + 30 * 60), "玩了 10 分钟 · 昨天", "前一天 23:30（跨天）");
        eq(line(zh, zhl, 600, 3 * 86400), "玩了 10 分钟 · 3 天前", "3 天前");
        eq(line(zh, zhl, 600, -7200), "玩了 10 分钟 · 今天", "改过时钟、时刻在未来");

        // testOtherLanguages（安卓资源只有中英两份）
        eq(line(en, Locale.ENGLISH, 90 * 60, 86400), "Played 1.5 h · yesterday", "英文");

        // testCatalog 对应：文件没有 / 0 秒按没玩过；有就原样读出
        Path dir = Files.createTempDirectory("s2a-playtime");
        File state = dir.toFile();
        demand(Playtime.read(state) == null, "no file = never played");
        Files.write(dir.resolve(Playtime.FILE), "{\"schema\":1,\"seconds\":0,\"lastPlayed\":1}\n".getBytes(StandardCharsets.UTF_8));
        demand(Playtime.read(state) == null, "0 seconds = never played");
        Files.write(dir.resolve(Playtime.FILE), "{\"schema\":1,\"seconds\":125,\"lastPlayed\":1794790800}\n".getBytes(StandardCharsets.UTF_8));
        Playtime p = Playtime.read(state);
        demand(p != null && p.seconds == 125 && p.lastPlayed == 1_794_790_800L, "seconds / lastPlayed read back");

        // 库页读的路径 = 起局交给原生层的 state 目录（GameSession.stateDir 会建目录；statePath 只算不建）
        File root = dir.resolve("files").toFile();
        File only = GameSession.statePath(root, "0100633007D48000");
        demand(!only.exists(), "statePath must not create the directory");
        File made = GameSession.stateDir(root, "0100633007D48000");
        demand(made.getCanonicalFile().equals(only.getCanonicalFile()), "statePath " + only + " != stateDir " + made);

        System.out.println("PlaytimeTest: ok (" + checks + " checks)");
    }
}
