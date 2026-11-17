package org.s2arm.android;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * 停帧看门屏上提示（StallNotice）的宿主回归，期望按口径手写（同 iOS：救场横幅定时收、帧又走了不收；「可能还在加载」等清除才收、清除不收横幅；
 * 横幅压在等待那条上面）。另核文案：stall_wait 两种语言逐字等于 runtime/include/s2a_ui_text.h 的 S2A_UI_STALL_WAIT(_EN)，stall_patch_off 带秒数占位。
 * 参数：res 目录、s2a_ui_text.h。
 */
public final class StallNoticeTest {
    private static int checks;
    private static void eq(long got, long want, String what) { checks++; if (got != want) throw new AssertionError(what + ": got " + got + " want " + want); }
    private static void demand(boolean ok, String what) { checks++; if (!ok) throw new AssertionError(what); }

    private static String xml(Path res, String dir, String name) throws Exception {
        String s = new String(Files.readAllBytes(res.resolve(dir).resolve("strings.xml")), StandardCharsets.UTF_8);
        Matcher m = Pattern.compile("<string name=\"" + name + "\">([^<]*)</string>").matcher(s);
        if (!m.find()) throw new AssertionError(dir + " has no " + name);
        return m.group(1).replace("\\n", "\n").replace("\\'", "'");
    }
    private static String macro(String header, String name) {
        Matcher m = Pattern.compile("#define " + name + "\\s+\"((?:[^\"\\\\]|\\\\.)*)\"").matcher(header);
        if (!m.find()) throw new AssertionError("s2a_ui_text.h has no " + name);
        return m.group(1).replace("\\n", "\n");
    }

    public static void main(String[] args) throws Exception {
        StallNotice n = new StallNotice();
        eq(n.visible(0), StallNotice.NONE, "nothing at start");
        n.on(StallNotice.PATCH_OFF, 8, 1000);
        eq(n.visible(1000), StallNotice.PATCH_OFF, "banner shows");
        eq(n.changeIn(1000), 8000, "banner changes in 8 s");
        n.on(StallNotice.NONE, 0, 2000);
        eq(n.visible(2000), StallNotice.PATCH_OFF, "frames moving again does not take the banner away");
        eq(n.visible(8999), StallNotice.PATCH_OFF, "banner still up just before 8 s");
        eq(n.visible(9000), StallNotice.NONE, "banner gone at 8 s");
        eq(n.changeIn(9000), -1, "nothing pending");

        StallNotice w = new StallNotice();
        w.on(StallNotice.WAIT, 0, 0);
        eq(w.visible(100_000), StallNotice.WAIT, "wait notice stays until cleared");
        eq(w.changeIn(100_000), -1, "wait notice has no timer");
        w.on(StallNotice.PATCH_OFF, 8, 100_000);
        eq(w.visible(100_000), StallNotice.PATCH_OFF, "banner on top of the wait notice");
        eq(w.visible(108_000), StallNotice.WAIT, "wait notice shows again after the banner");
        w.on(StallNotice.NONE, 0, 109_000);
        eq(w.visible(109_000), StallNotice.NONE, "clear takes the wait notice away");
        w.on(StallNotice.PATCH_OFF, 0, 200_000);
        eq(w.visible(200_999), StallNotice.PATCH_OFF, "banner shown at least 1 s even if 0 s asked");

        Path res = Path.of(args[0]);
        String header = new String(Files.readAllBytes(Path.of(args[1])), StandardCharsets.UTF_8);
        demand(xml(res, "values-zh", "stall_wait").equals(macro(header, "S2A_UI_STALL_WAIT")), "zh stall_wait = S2A_UI_STALL_WAIT");
        demand(xml(res, "values", "stall_wait").equals(macro(header, "S2A_UI_STALL_WAIT_EN")), "en stall_wait = S2A_UI_STALL_WAIT_EN");
        demand(String.format(xml(res, "values-zh", "stall_patch_off"), 30).startsWith("画面约 30 秒"), "zh patch-off text carries the seconds");
        demand(String.format(xml(res, "values", "stall_patch_off"), 30).contains("about 30 seconds"), "en patch-off text carries the seconds");
        System.out.println("StallNoticeTest: ok (" + checks + " checks)");
    }
}
