package org.s2arm.android;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.TreeSet;
import java.util.stream.Collectors;
import java.util.stream.Stream;
import java.util.zip.ZipEntry;
import java.util.zip.ZipOutputStream;

/**
 * 资源替换类 mod 导入（GameMods）的宿主用例：期望值按 pack/jobs/mods.py 的规则手写，不跑被测实现推算。
 * 覆盖：起局 state 目录、四种发布结构、别的程序号不收、exefs 只报一句、逃逸 / 绝对路径 / 符号链接不收、
 * 数量 / 大小上限、不是 zip、找不到 romfs、同名整份替换、开关改名、删除、列出、半成品清理、zip64 中央目录。
 */
public final class GameModsTest {
    private static final String GID = "0100000000ABCDEF";
    private static int checks;
    private static Path tmp;

    private static void demand(boolean ok, String what) {
        checks++;
        if (!ok) throw new AssertionError(what);
    }

    private static Map<String, byte[]> entries(Object... kv) {
        Map<String, byte[]> m = new LinkedHashMap<>();
        for (int i = 0; i < kv.length; i += 2) m.put((String) kv[i], ((String) kv[i + 1]).getBytes(StandardCharsets.UTF_8));
        return m;
    }

    private static File zip(String name, Map<String, byte[]> files, String... symlinks) throws IOException {
        File f = tmp.resolve("in").resolve(name).toFile();
        Files.createDirectories(f.getParentFile().toPath());
        ByteArrayOutputStream bytes = new ByteArrayOutputStream();
        try (ZipOutputStream z = new ZipOutputStream(bytes)) {
            for (Map.Entry<String, byte[]> e : files.entrySet()) {
                z.putNextEntry(new ZipEntry(e.getKey()));
                z.write(e.getValue());
                z.closeEntry();
            }
        }
        byte[] b = bytes.toByteArray();
        for (String link : symlinks) markSymlink(b, link);
        try (FileOutputStream out = new FileOutputStream(f)) { out.write(b); }
        return f;
    }

    /** 把中央目录里这一条的外部属性写成 Unix 符号链接（0120777 << 16），模拟 Linux / Mac 打的带链接的 zip。 */
    private static void markSymlink(byte[] b, String name) {
        byte[] want = name.getBytes(StandardCharsets.UTF_8);
        for (int i = 0; i + 46 <= b.length; i++) {
            if (b[i] != 0x50 || b[i + 1] != 0x4b || b[i + 2] != 0x01 || b[i + 3] != 0x02) continue;
            int n = (b[i + 28] & 0xFF) | (b[i + 29] & 0xFF) << 8;
            if (n == want.length && Arrays.equals(Arrays.copyOfRange(b, i + 46, i + 46 + n), want)) {
                int attr = 0120777 << 16;
                for (int k = 0; k < 4; k++) b[i + 38 + k] = (byte) (attr >>> (8 * k));
                return;
            }
        }
        throw new AssertionError("fixture: no central entry " + name);
    }

    private static Path freshHome(String tag) throws IOException {
        Path home = tmp.resolve("homes").resolve(tag).resolve("mods");
        Files.createDirectories(home);
        return home;
    }

    private static GameMods.Result importZip(Path home, File zip) throws Exception {
        try (GameMods.Work work = new GameMods.Work(home.toFile())) {
            File root = new File(work.dir, "z");
            GameMods.unpackZip(zip, zip.getName(), root);
            return GameMods.importRoot(home.toFile(), root, zip.getName(), GameMods.baseName(zip.getName(), true), GID);
        }
    }

    private static Set<String> tree(Path dir) throws IOException {
        if (!Files.exists(dir)) return new TreeSet<>();
        try (Stream<Path> s = Files.walk(dir)) {
            return s.filter(p -> !p.equals(dir)).map(p -> dir.relativize(p).toString()).collect(Collectors.toCollection(TreeSet::new));
        }
    }

    private static Set<String> set(String... s) { return new TreeSet<>(Arrays.asList(s)); }

    private static GameMods.Failure failure(ThrowingRunnable r) throws Exception {
        try { r.run(); } catch (GameMods.Failure f) { return f; }
        throw new AssertionError("expected a GameMods.Failure");
    }

    private interface ThrowingRunnable { void run() throws Exception; }

    private static GameMods.Message msg(GameMods.Kind k, Object... a) { return new GameMods.Message(k, a); }

    public static void main(String[] args) throws Exception {
        tmp = Files.createTempDirectory("s2a-mods-test");
        try {
            run();
        } finally {
            GameMods.deleteTree(tmp);
        }
        System.out.println("PASS GameMods: " + checks + " checks");
    }

    private static void run() throws Exception {
        // 起局 state 目录：files/user/0/saves/<程序号>/ryujinx-android（BootSpecSource + GameSession.prepareState），mod 在它下面 mods/
        File files = tmp.resolve("files").toFile();
        Files.createDirectories(files.toPath());
        File modsDir = GameMods.modsDir(files, GID);
        demand(modsDir.equals(new File(files.getCanonicalFile(), "user/0/saves/" + GID + "/ryujinx-android/mods")), "mods dir: " + modsDir);
        demand(modsDir.getParentFile().isDirectory(), "state dir created like a launch");

        // 名字（mods.py _safe_name / 起名）
        demand(GameMods.safeName("a:b*c?").equals("a_b_c_"), "bad chars");
        demand(GameMods.safeName(" .x. ").equals("x"), "strip spaces and dots");
        demand(GameMods.safeName("..").equals("mod"), "empty after strip");
        demand(GameMods.safeName("y".repeat(81)).equals("y".repeat(80)), "80 chars");
        demand(GameMods.baseName("Cool.Pack.zip", true).equals("Cool.Pack"), "zip stem");
        demand(GameMods.baseName(".zip", true).equals("zip"), "dot-only stem");
        demand(GameMods.baseName("/storage/emulated/0/Mods/Some Mod/romfs", false).equals("Some Mod"), "picked romfs folder → parent name");
        demand(GameMods.baseName("romfs", false).equals("mod"), "romfs with no parent");
        demand(GameMods.baseName("/storage/emulated/0/Mods/Some Mod", false).equals("Some Mod"), "folder name");

        // Atmosphere 结构 + exefs 代码补丁只报一句
        Path home = freshHome("atmo");
        GameMods.Result r = importZip(home, zip("Cool Pack.zip", entries(
            "atmosphere/contents/" + GID + "/romfs/Data/a.bin", "abc",
            "atmosphere/contents/" + GID + "/exefs/fix.pchtxt", "@nsobid")));
        demand(r.imported.equals(List.of("Cool Pack")), "atmosphere imported " + r.imported);
        demand(r.notes.equals(List.of(msg(GameMods.Kind.EXEFS_SKIPPED))), "exefs note " + r.notes);
        demand(tree(home).equals(set("Cool Pack", "Cool Pack/romfs", "Cool Pack/romfs/Data", "Cool Pack/romfs/Data/a.bin")), "atmosphere layout " + tree(home));
        demand(new String(Files.readAllBytes(home.resolve("Cool Pack/romfs/Data/a.bin")), StandardCharsets.UTF_8).equals("abc"), "content");

        // Ryujinx 结构，多份 + 别的程序号不收（程序号大小写都认）
        home = freshHome("ryu");
        r = importZip(home, zip("multi.zip", entries(
            "0100000000abcdef/HD Textures/romfs/t.bin", "t",
            GID + "/Fix/romfs/f.bin", "f",
            "0100000000000099/Other/romfs/o.bin", "o")));
        demand(r.imported.equals(List.of("multi - Fix", "multi - HD Textures")), "ryujinx imported " + r.imported);
        demand(r.notes.equals(List.of(msg(GameMods.Kind.OTHER_GAME, "0100000000000099/Other", "0100000000000099"))), "other game note " + r.notes);
        demand(tree(home).equals(set("multi - Fix", "multi - Fix/romfs", "multi - Fix/romfs/f.bin",
            "multi - HD Textures", "multi - HD Textures/romfs", "multi - HD Textures/romfs/t.bin")), "ryujinx layout " + tree(home));

        // <名字>/romfs、只有 romfs/、romfs 里再套 romfs
        home = freshHome("plain");
        demand(importZip(home, zip("solo.zip", entries("MyMod/romfs/x", "1"))).imported.equals(List.of("solo")), "<name>/romfs single → archive name");
        demand(importZip(home, zip("bare.zip", entries("romfs/x", "1"))).imported.equals(List.of("bare")), "only romfs/");
        demand(importZip(home, zip("nest.zip", entries("A/romfs/romfs/x", "1"))).imported.equals(List.of("nest")), "nested romfs counted once");
        demand(Files.isRegularFile(home.resolve("nest/romfs/romfs/x")), "nested romfs kept inside the outer one");

        // 玩家选的就是 romfs 文件夹（文件夹导入：Work 里的临时目录也叫 romfs）
        home = freshHome("pickromfs");
        Path picked = tmp.resolve("pick/Some Mod/romfs");
        Files.createDirectories(picked.resolve("d"));
        Files.write(picked.resolve("d/y"), new byte[] {1});
        r = GameMods.importRoot(home.toFile(), picked.toFile(), "romfs",
            GameMods.baseName("/storage/emulated/0/Some Mod/romfs", false), GID);
        demand(r.imported.equals(List.of("Some Mod")) && Files.isRegularFile(home.resolve("Some Mod/romfs/d/y")), "picked romfs folder");

        // 逃逸 / 绝对路径 / 符号链接不收
        home = freshHome("evil");
        r = importZip(home, zip("evil.zip", entries(
            "ok/romfs/good.bin", "g",                              // 先有 z/：下面的逃逸条目若被放行就真写到外面
            "../../../../escape.txt", "x",                         // 解到 Work/z：上四级 = 整个 mods/ 之外
            "/ok/romfs/abs.txt", "x",
            "ok/romfs/..\\..\\..\\..\\..\\..\\esc2.txt", "x",
            "ok/romfs/link", "/etc/passwd"), "ok/romfs/link"));
        demand(r.imported.equals(List.of("evil")), "evil imported " + r.imported);
        demand(tree(home.resolve("evil")).equals(set("romfs", "romfs/good.bin")), "only the safe file lands: " + tree(home.resolve("evil")));
        try (Stream<Path> all = Files.walk(tmp)) {
            List<String> escaped = all.map(p -> p.getFileName().toString())
                .filter(n -> n.equals("escape.txt") || n.equals("abs.txt") || n.equals("esc2.txt")).collect(Collectors.toList());
            demand(escaped.isEmpty(), "escaping entries written: " + escaped);
        }
        // 文件夹里的符号链接：romfs 里的链接不搬；指向别处的目录链接不跟随
        home = freshHome("links");
        Path outside = tmp.resolve("outside");
        Files.createDirectories(outside.resolve("romfs"));
        Files.write(outside.resolve("romfs/secret"), new byte[] {9});
        Path folder = tmp.resolve("linkpick/z");
        Files.createDirectories(folder.resolve("M/romfs"));
        Files.write(folder.resolve("M/romfs/real"), new byte[] {1});
        Files.createSymbolicLink(folder.resolve("M/romfs/alias"), outside.resolve("romfs/secret"));
        Files.createSymbolicLink(folder.resolve("Linked"), outside);
        r = GameMods.importRoot(home.toFile(), folder.toFile(), "z", "linkpick", GID);
        demand(r.imported.equals(List.of("linkpick")), "only the real romfs, not the linked folder: " + r.imported);
        demand(tree(home).equals(set("linkpick", "linkpick/romfs", "linkpick/romfs/real")), "symlink not moved: " + tree(home));
        demand(Files.isRegularFile(outside.resolve("romfs/secret")), "link target untouched");

        // 上限（防压缩炸弹）：数量按条目、大小按真解出的字节
        Path work = tmp.resolve("limits");
        GameMods.Failure f = failure(() -> GameMods.unpackZip(zip("three.zip", entries("a", "1", "b", "2", "c", "3")), "three.zip", work.resolve("1").toFile(), 2, 1 << 20));
        demand(f.message.equals(msg(GameMods.Kind.TOO_MANY_FILES, 2, "three.zip")), "too many " + f.message);
        f = failure(() -> GameMods.unpackZip(zip("big.zip", entries("romfs/a", "0123456789A")), "big.zip", work.resolve("2").toFile(), 10, 10));
        demand(f.message.equals(msg(GameMods.Kind.TOO_LARGE, "big.zip")), "too large " + f.message);
        GameMods.unpackZip(zip("edge.zip", entries("romfs/a", "0123456789")), "edge.zip", work.resolve("3").toFile(), 1, 10);
        demand(Files.size(work.resolve("3/romfs/a")) == 10, "exactly at the limit passes");

        // 不是 zip、找不到 romfs（程序号写成大写）
        File text = tmp.resolve("in/readme.txt").toFile();
        Files.write(text.toPath(), "hello".getBytes(StandardCharsets.UTF_8));
        f = failure(() -> GameMods.unpackZip(text, "readme.txt", work.resolve("4").toFile()));
        demand(f.message.equals(msg(GameMods.Kind.NOT_ARCHIVE, "readme.txt")), "not a zip " + f.message);
        Path homeNo = freshHome("none");
        File noRomfs = zip("codeonly.zip", entries("exefs/main.ips", "PATCH"));
        f = failure(() -> {
            try (GameMods.Work w = new GameMods.Work(homeNo.toFile())) {
                File root = new File(w.dir, "z");
                GameMods.unpackZip(noRomfs, "codeonly.zip", root);
                GameMods.importRoot(homeNo.toFile(), root, "codeonly.zip", "codeonly", GID.toLowerCase());
            }
        });
        demand(f.message.equals(msg(GameMods.Kind.NO_ROMFS, "codeonly.zip", GID)), "no romfs " + f.message);
        demand(tree(homeNo).isEmpty(), "failed import leaves nothing behind: " + tree(homeNo));

        // 同名整份替换（关着的也换成新的、开着）+ 开关改名
        home = freshHome("toggle");
        importZip(home, zip("pack.zip", entries("romfs/a.bin", "aa")));
        GameMods.setEnabled(home.toFile(), "pack", false);
        demand(tree(home).equals(set(".off-pack", ".off-pack/romfs", ".off-pack/romfs/a.bin")), "off = .off- prefix: " + tree(home));
        List<GameMods.Mod> list = GameMods.listing(home.toFile());
        demand(list.size() == 1 && list.get(0).name.equals("pack") && !list.get(0).enabled && list.get(0).files == 1 && list.get(0).bytes == 2, "listing shows the off mod");
        importZip(home, zip("pack.zip", entries("romfs/b.bin", "bbb")));
        demand(tree(home).equals(set("pack", "pack/romfs", "pack/romfs/b.bin")), "same name replaced whole, on: " + tree(home));
        GameMods.setEnabled(home.toFile(), "pack", true);
        demand(tree(home).equals(set("pack", "pack/romfs", "pack/romfs/b.bin")), "enabling an enabled mod is a no-op");
        f = failure(() -> GameMods.setEnabled(freshHome("toggle").toFile(), "nope", false));
        demand(f.message.equals(msg(GameMods.Kind.MISSING, "nope")), "toggle missing " + f.message);
        Files.createDirectories(home.resolve("x"));
        Files.createDirectories(home.resolve(".off-x"));
        Path toggleHome = home;
        f = failure(() -> GameMods.setEnabled(toggleHome.toFile(), "x", false));
        demand(f.message.equals(msg(GameMods.Kind.NAME_TAKEN, "x")), "toggle conflict " + f.message);

        // 删除：整份删；没有 / 越界名字 → 没有这个 mod
        GameMods.remove(home.toFile(), "pack");
        demand(!Files.exists(home.resolve("pack")), "removed");
        f = failure(() -> GameMods.remove(toggleHome.toFile(), "pack"));
        demand(f.message.equals(msg(GameMods.Kind.MISSING, "pack")), "remove missing " + f.message);
        f = failure(() -> GameMods.remove(toggleHome.toFile(), "../toggle"));
        demand(f.message.equals(msg(GameMods.Kind.MISSING, "../toggle")) && Files.isDirectory(toggleHome), "remove refuses a path");

        // 列出：名字升序（叠加顺序）；「.」开头的半成品和文件不列
        home = freshHome("list");
        Files.createDirectories(home.resolve("b/romfs/s"));
        Files.write(home.resolve("b/romfs/1"), new byte[3]);
        Files.write(home.resolve("b/romfs/s/2"), new byte[4]);
        Files.createDirectories(home.resolve(".off-a/romfs"));
        Files.write(home.resolve(".off-a/romfs/1"), new byte[5]);
        Files.createDirectories(home.resolve(".importing-z/romfs"));
        Files.createDirectories(home.resolve(".work-1"));
        Files.write(home.resolve("readme"), new byte[1]);
        list = GameMods.listing(home.toFile());
        List<String> got = new ArrayList<>();
        for (GameMods.Mod m : list) got.add(m.name + ":" + m.enabled + ":" + m.files + ":" + m.bytes);
        demand(got.equals(List.of("a:false:1:5", "b:true:2:7")), "listing " + got);
        // 上次中途被杀的半成品：下一次导入开工时清掉
        try (GameMods.Work w = new GameMods.Work(home.toFile())) {
            demand(!Files.exists(home.resolve(".importing-z")) && !Files.exists(home.resolve(".work-1")), "stale leftovers cleared");
            demand(w.dir.isDirectory() && w.dir.getName().startsWith(".work-"), "work dir hidden from the service");
            File last = w.dir;
            w.close();
            demand(!last.exists(), "work dir removed on close");
        }

        // zip64（超过 65535 条，中央目录走 zip64 结尾记录）里的符号链接也认得出
        Map<String, byte[]> many = new LinkedHashMap<>();
        for (int i = 0; i < 70000; i++) many.put("romfs/f" + i, new byte[0]);
        many.put("romfs/link", "/etc".getBytes(StandardCharsets.UTF_8));
        demand(GameMods.zipSymlinks(zip("z64.zip", many, "romfs/link")).equals(Set.of("romfs/link")), "zip64 symlink found");
    }
}
