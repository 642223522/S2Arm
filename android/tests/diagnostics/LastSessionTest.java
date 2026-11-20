// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
package org.s2arm.android;

import java.io.File;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Comparator;

/**
 * #528 item 15: the session marker behind the library's "last session ended abnormally" notice. Expectations are
 * written by hand from iOS runtime/src/sesdiag.c (fg / bg / none, a short read counts as fg) and the platform's
 * ApplicationExitInfo.REASON_* values; nothing here is computed by LastSession itself.
 */
public final class LastSessionTest {
    private static int checks, fails;

    private static void expect(String what, Object want, Object got) {
        checks++;
        if (!java.util.Objects.equals(want, got)) {
            fails++;
            System.out.println("【红】" + what + "\n  期望 " + want + "\n  真结果 " + got);
        }
    }

    private static Path marker(Path dir, String bytes) throws IOException {
        Path p = dir.resolve(LastSession.FILE);
        Files.write(p, bytes.getBytes(StandardCharsets.US_ASCII));
        return p;
    }

    private static String content(Path dir) throws IOException {
        return new String(Files.readAllBytes(dir.resolve(LastSession.FILE)), StandardCharsets.US_ASCII);
    }

    public static void main(String[] args) throws IOException {
        Path dir = Files.createTempDirectory("s2a-last-session-");
        try {
            File d = dir.toFile();
            // read: what the marker says about the last session
            expect("没有标记 = 上一局正常收尾", LastSession.NONE, LastSession.read(d));
            marker(dir, "fg\n"); expect("fg = 死在前台", LastSession.FOREGROUND, LastSession.read(d));
            marker(dir, "bg\n"); expect("bg = 在后台被关或回收", LastSession.BACKGROUND, LastSession.read(d));
            marker(dir, "bg"); expect("没有换行的 bg 照样是 bg", LastSession.BACKGROUND, LastSession.read(d));
            marker(dir, "b"); expect("只读到 1 字节：读不全按 fg", LastSession.FOREGROUND, LastSession.read(d));
            marker(dir, ""); expect("空文件：读不全按 fg", LastSession.FOREGROUND, LastSession.read(d));
            marker(dir, "xx\n"); expect("认不出的内容按 fg", LastSession.FOREGROUND, LastSession.read(d));
            marker(dir, "end\n"); expect("end（干净收尾、原生收尾没走完）按 fg", LastSession.FOREGROUND, LastSession.read(d));
            marker(dir, "end"); expect("没有换行的 end 也按 fg", LastSession.FOREGROUND, LastSession.read(d));
            Files.delete(dir.resolve(LastSession.FILE));
            Files.createDirectory(dir.resolve(LastSession.FILE));
            expect("标记在但读不了（是个目录）：按 fg", LastSession.FOREGROUND, LastSession.read(d));
            Files.delete(dir.resolve(LastSession.FILE));

            // mark: what the :game process writes
            LastSession.mark(d, LastSession.FOREGROUND); expect("写 fg", "fg\n", content(dir));
            marker(dir, "fg\n-and-a-much-longer-old-tail");
            LastSession.mark(d, LastSession.BACKGROUND); expect("改写成 bg 不留旧尾巴", "bg\n", content(dir));
            LastSession.mark(d, LastSession.FOREGROUND); expect("回前台再写 fg", "fg\n", content(dir));
            LastSession.mark(d, LastSession.ENDING);
            expect("干净收尾写 end：恰好是原生只删的那 4 个字节（lifecycle_android.c）", "end\n", content(dir));
            LastSession.mark(d, LastSession.BACKGROUND); expect("end 之后再写 bg 不留尾巴", "bg\n", content(dir));
            LastSession.mark(d, LastSession.NONE);
            expect("干净收尾删掉标记", false, Files.exists(dir.resolve(LastSession.FILE)));
            LastSession.mark(d, LastSession.NONE);
            expect("没有标记时再删不报错", false, Files.exists(dir.resolve(LastSession.FILE)));

            // markedAt: the time of the last write, 0 without a marker
            expect("没有标记的时间是 0", 0L, LastSession.markedAt(d));
            LastSession.mark(d, LastSession.FOREGROUND);
            long written = dir.resolve(LastSession.FILE).toFile().lastModified();
            expect("时间就是标记文件的修改时间", written, LastSession.markedAt(d));
            expect("写过的标记时间大于 0", true, LastSession.markedAt(d) > 0);
            LastSession.mark(d, LastSession.NONE);

            // pick: the exit record of the marked session
            String game = "org.s2arm.android:game", main = "org.s2arm.android";
            expect("没有记录", -1, LastSession.pick(game, 1000, new String[0], new long[0]));
            expect("只有库页进程的记录", -1,
                LastSession.pick(game, 1000, new String[]{main, main}, new long[]{2000, 3000}));
            expect("游戏进程的记录比标记早：是更早那一局的，不用", -1,
                LastSession.pick(game, 1000, new String[]{game, main}, new long[]{999, 2000}));
            expect("与标记同一毫秒的记录算这一局", 0,
                LastSession.pick(game, 1000, new String[]{game}, new long[]{1000}));
            expect("多条取最新的，不看排列顺序", 2,
                LastSession.pick(game, 1000, new String[]{game, main, game, game}, new long[]{1500, 9000, 3000, 2000}));
            expect("进程名为 null 的记录跳过", 1,
                LastSession.pick(game, 1000, new String[]{null, game}, new long[]{5000, 1200}));
            expect("两个数组不一样长：只看共有的部分", -1,
                LastSession.pick(game, 1000, new String[]{main, game}, new long[]{2000}));

            // kind: ApplicationExitInfo.REASON_* (SIGNALED 2, LOW_MEMORY 3, CRASH 4, CRASH_NATIVE 5, ANR 6,
            // EXCESSIVE_RESOURCE_USAGE 9); every other value says nothing.
            int[][] said = {{2, LastSession.SIGNALED}, {3, LastSession.LOW_MEMORY}, {4, LastSession.CRASH},
                {5, LastSession.NATIVE_CRASH}, {6, LastSession.NOT_RESPONDING}, {9, LastSession.EXCESSIVE_RESOURCES}};
            for (int[] pair : said) expect("原因 " + pair[0], pair[1], LastSession.kind(pair[0]));
            for (int code : new int[]{-1, 0, 1, 7, 8, 10, 11, 12, 13, 14, 15, 16, 17, 99})
                expect("原因 " + code + " 不写进提示", LastSession.NO_REASON, LastSession.kind(code));
            // Same numbering as the bundle's exit table (DiagnosticExits, checked against android-36):
            String[] names = {"signaled", "low_memory", "crash", "crash_native", "anr", "excessive_resource_usage"};
            for (int i = 0; i < said.length; i++)
                expect("原因 " + said[i][0] + " 的名字", names[i], DiagnosticExits.reason(said[i][0]));

            // cleanStop: HostApi stop reasons (0 exit requested, 1 low memory, 2 GPU device lost, 3 unrecoverable error)
            expect("游戏自己要求退出是干净收尾", true, LastSession.cleanStop(0));
            for (int reason : new int[]{1, 2, 3, 4, -1})
                expect("HostApi 停局原因 " + reason + " 不是干净收尾", false, LastSession.cleanStop(reason));
        } finally {
            try (var walk = Files.walk(dir)) {
                walk.sorted(Comparator.reverseOrder()).forEach(p -> p.toFile().delete());
            }
        }
        System.out.println("LastSession：" + checks + " 项检查，" + fails + " 项红");
        if (fails != 0) System.exit(1);
    }
}
