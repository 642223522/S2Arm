package org.s2arm.android;

import java.io.BufferedInputStream;
import java.io.DataInputStream;
import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.io.RandomAccessFile;
import java.nio.channels.Channels;
import java.nio.charset.StandardCharsets;
import java.nio.file.FileVisitResult;
import java.nio.file.Files;
import java.nio.file.LinkOption;
import java.nio.file.Path;
import java.nio.file.SimpleFileVisitor;
import java.nio.file.attribute.BasicFileAttributes;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.Enumeration;
import java.util.HashSet;
import java.util.List;
import java.util.Locale;
import java.util.Set;
import java.util.regex.Pattern;
import java.util.stream.Stream;
import java.util.zip.ZipEntry;
import java.util.zip.ZipFile;

/**
 * 资源替换类 mod（LayeredFS）：口径照 pack/jobs/mods.py（Mac / iPhone 同一份），只搬文件，不解析、不执行 mod 里的任何东西。
 *   · 家：这款起局用的 state 目录（安卓的 S2A_DOCS）下 mods/&lt;名字&gt;/romfs/**；服务层 RomFsMods.ApplyAtLaunch 起局时按文件夹名升序叠，
 *     后叠的覆盖先叠的，「.」开头的跳过。
 *   · 导入：zip 或文件夹，按常见发布结构找出每个 romfs/（atmosphere/contents/&lt;程序号&gt;/romfs、&lt;程序号&gt;/&lt;名字&gt;/romfs、
 *     &lt;名字&gt;/romfs、只有 romfs/），一个 romfs 一份 mod；路径上标了别的程序号的不收；exefs 代码补丁不收、只报一句；
 *     符号链接、「..」逃逸、绝对路径不收；先解到 mods/.work-*，再经 .importing-&lt;名&gt; 改名落位，同名整份替换。
 *   · 关掉 = 改名为 .off-&lt;名字&gt;（服务层跳过「.」开头的）；删除 = 整份删。
 * 纯 Java（不碰 android.*）：宿主单测 android/tests/GameModsTest.java。
 */
final class GameMods {
    static final String DIR = "mods", OFF = ".off-", IMPORTING = ".importing-", WORK = ".work-";
    static final long MAX_BYTES = 16L << 30;   // 一次导入解开后的总大小上限（防压缩炸弹）
    static final int MAX_FILES = 200_000;
    private static final Pattern GID = Pattern.compile("[0-9A-Fa-f]{16}");
    private static final Pattern NAME_BAD = Pattern.compile("[\\x00-\\x1f/\\\\:*?\"<>|]");

    private GameMods() { }

    /** 玩家看到的话（文案在 strings.xml，参数照 mods.py 的原句）。 */
    enum Kind { NOT_ARCHIVE, TOO_MANY_FILES, TOO_LARGE, NO_ROMFS, MISSING, NAME_TAKEN, OTHER_GAME, EXEFS_SKIPPED, EMPTY_ROMFS }

    static final class Message {
        final Kind kind;
        final Object[] args;
        Message(Kind kind, Object... args) { this.kind = kind; this.args = args; }
        @Override public boolean equals(Object o) {
            return o instanceof Message && ((Message) o).kind == kind && Arrays.equals(((Message) o).args, args);
        }
        @Override public int hashCode() { return kind.hashCode() * 31 + Arrays.hashCode(args); }
        @Override public String toString() { return kind + Arrays.toString(args); }
    }

    static final class Failure extends Exception {
        final Message message;
        Failure(Kind kind, Object... args) { super(kind + Arrays.toString(args)); message = new Message(kind, args); }
    }

    static final class Result {
        final List<String> imported = new ArrayList<>();
        final List<Message> notes = new ArrayList<>();
    }

    static final class Mod {
        final String name;
        final boolean enabled;
        final int files;
        final long bytes;
        Mod(String name, boolean enabled, int files, long bytes) { this.name = name; this.enabled = enabled; this.files = files; this.bytes = bytes; }
    }

    /** 这款的 mods/：起局交给原生层的同一个 state 目录（GameSession.stateDir）。 */
    static File modsDir(File privateRoot, String titleId) throws IOException {
        return new File(GameSession.stateDir(privateRoot, titleId), DIR);
    }

    /** 一次导入的临时目录 mods/.work-*（与落位处同一个文件系统，落位是改名）；关闭即删。 */
    static final class Work implements AutoCloseable {
        final File dir;
        Work(File home) throws IOException {
            Files.createDirectories(home.toPath());
            // 上一次导入中途被杀留下的半成品（「.」开头，服务层本来就不叠）：先清掉，不留几 GB 看不见的垃圾
            File[] old = home.listFiles((d, n) -> n.startsWith(WORK) || n.startsWith(IMPORTING));
            if (old != null) for (File f : old) deleteTree(f.toPath());
            dir = new File(home, WORK + System.nanoTime());
            Files.createDirectory(dir.toPath());
        }
        @Override public void close() throws IOException { deleteTree(dir.toPath()); }
    }

    static String safeName(String s) {
        String t = strip(NAME_BAD.matcher(s).replaceAll("_"), " .");
        if (t.isEmpty()) t = "mod";
        return t.codePointCount(0, t.length()) > 80 ? t.substring(0, t.offsetByCodePoints(0, 80)) : t;
    }

    private static String strip(String s, String chars) {
        int a = 0, b = s.length();
        while (a < b && chars.indexOf(s.charAt(a)) >= 0) a++;
        while (b > a && chars.indexOf(s.charAt(b - 1)) >= 0) b--;
        return s.substring(a, b);
    }

    /** mods.py 的起名：文件取去掉扩展名的名字；文件夹取它的名字，选的就是 romfs 时取上一级的名字。path 用「/」分隔。 */
    static String baseName(String path, boolean file) {
        List<String> parts = parts(path);
        String name = parts.isEmpty() ? "" : parts.get(parts.size() - 1);
        if (file) {
            int dot = name.lastIndexOf('.');
            if (dot > 0 && dot < name.length() - 1) name = name.substring(0, dot);
        } else if (name.toLowerCase(Locale.ROOT).equals("romfs")) {
            name = parts.size() > 1 ? parts.get(parts.size() - 2) : "";
        }
        return safeName(name);
    }

    private static List<String> parts(String path) {
        List<String> out = new ArrayList<>();
        for (String p : path.split("/")) if (!p.isEmpty() && !p.equals(".")) out.add(p);
        return out;
    }

    /** root 下的相对路径（「\」当「/」）；空、绝对路径、带「..」的 → null（不收）。 */
    static File inside(File root, String name) {
        name = name.replace('\\', '/');
        List<String> parts = parts(name);
        if (parts.isEmpty() || parts.contains("..") || name.startsWith("/")) return null;
        File f = root;
        for (String p : parts) f = new File(f, p);
        return f;
    }

    static void unpackZip(File zip, String shown, File out) throws IOException, Failure {
        unpackZip(zip, shown, out, MAX_FILES, MAX_BYTES);
    }

    /** zip → 解到 out。不是 zip / 文件太多 / 解开太大 → Failure；逃出目录的条目和符号链接跳过（mods.py _unpack）。 */
    static void unpackZip(File zip, String shown, File out, int maxFiles, long maxBytes) throws IOException, Failure {
        Set<String> links = zipSymlinks(zip);
        if (links == null) throw new Failure(Kind.NOT_ARCHIVE, shown);
        try (ZipFile z = new ZipFile(zip, StandardCharsets.UTF_8)) {
            if (z.size() > maxFiles) throw new Failure(Kind.TOO_MANY_FILES, maxFiles, shown);
            long total = 0;
            byte[] buf = new byte[1 << 16];
            for (Enumeration<? extends ZipEntry> en = z.entries(); en.hasMoreElements(); ) {
                ZipEntry e = en.nextElement();
                File dst = inside(out, e.getName());
                if (dst == null || links.contains(e.getName())) continue;
                if (e.isDirectory()) { Files.createDirectories(dst.toPath()); continue; }
                Files.createDirectories(dst.getParentFile().toPath());
                try (InputStream in = z.getInputStream(e); OutputStream w = new FileOutputStream(dst)) {
                    for (int n; (n = in.read(buf)) > 0; ) {   // 按真解出的字节数计：压缩包里写的大小可以是假的
                        total += n;
                        if (total > maxBytes) throw new Failure(Kind.TOO_LARGE, shown);
                        w.write(buf, 0, n);
                    }
                }
            }
        }
    }

    /**
     * zip 中央目录里标成符号链接的条目名（外部属性高 16 位是 Unix 文件类型 0120000）；没有结尾记录 = 不是 zip → null。
     * java.util.zip 不给外部属性，这里只读中央目录（含 zip64）。
     */
    static Set<String> zipSymlinks(File zip) throws IOException {
        try (RandomAccessFile f = new RandomAccessFile(zip, "r")) {
            long len = f.length();
            int tail = (int) Math.min(len, 22 + 65535);
            if (tail < 22) return null;
            byte[] b = new byte[tail];
            f.seek(len - tail);
            f.readFully(b);
            int at = -1;
            for (int i = tail - 22; i >= 0; i--) if (le32(b, i) == 0x06054b50L) { at = i; break; }
            if (at < 0) return null;
            long count = le16(b, at + 10), size = le32(b, at + 12), start = (len - tail + at) - size;   // 前面带东西（自解压）的也认
            if ((count == 0xFFFF || le32(b, at + 16) == 0xFFFFFFFFL || size == 0xFFFFFFFFL)
                    && at >= 20 && le32(b, at - 20) == 0x07064b50L) {
                byte[] r = new byte[56];
                f.seek(le64(b, at - 20 + 8));
                f.readFully(r);
                if (le32(r, 0) != 0x06064b50L) throw new IOException("zip64 end record is damaged");
                count = le64(r, 32);
                start = le64(r, 48);
            }
            Set<String> links = new HashSet<>();
            f.seek(start);
            DataInputStream in = new DataInputStream(new BufferedInputStream(Channels.newInputStream(f.getChannel()), 1 << 16));
            byte[] h = new byte[46];
            for (long i = 0; i < count; i++) {
                in.readFully(h);
                if (le32(h, 0) != 0x02014b50L) throw new IOException("zip central directory is damaged");
                byte[] name = new byte[le16(h, 28)];
                in.readFully(name);
                skip(in, le16(h, 30) + le16(h, 32));
                if (((le32(h, 38) >>> 16) & 0170000) == 0120000) links.add(new String(name, StandardCharsets.UTF_8));
            }
            return links;
        }
    }

    private static void skip(DataInputStream in, int n) throws IOException {
        while (n > 0) {
            int s = in.skipBytes(n);
            if (s <= 0) { in.readByte(); s = 1; }
            n -= s;
        }
    }

    private static int le16(byte[] b, int i) { return (b[i] & 0xFF) | (b[i + 1] & 0xFF) << 8; }
    private static long le32(byte[] b, int i) { return le16(b, i) | (long) le16(b, i + 2) << 16; }
    private static long le64(byte[] b, int i) { return le32(b, i) | le32(b, i + 4) << 32; }

    static final class Found {
        final String label;
        final Path dir;
        Found(String label, Path dir) { this.label = label; this.dir = dir; }
    }

    /** → 每个 romfs 目录与它的标签（mods.py _find）。romfs 大小写都认；套在别的 romfs 里的不算；路径上有别的程序号 = 不是这款。 */
    static List<Found> find(File rootFile, String gid, List<Message> notes) throws IOException {
        Path root = rootFile.toPath();
        List<Found> found = new ArrayList<>();
        if (low(root.getFileName().toString()).equals("romfs")) {   // 玩家直接选的就是 romfs 文件夹
            found.add(new Found("", root));
            return found;
        }
        List<Path> dirs = new ArrayList<>();
        try (Stream<Path> all = Files.walk(root)) {   // 不跟随符号链接
            all.filter(p -> !p.equals(root) && Files.isDirectory(p, LinkOption.NOFOLLOW_LINKS)).forEach(dirs::add);
        }
        dirs.sort((a, c) -> compareParts(root.relativize(a), root.relativize(c)));
        boolean exefs = false;
        for (Path d : dirs) {
            String name = low(d.getFileName().toString());
            if (name.equals("exefs") && hasPatch(d)) exefs = true;
            Path rel = root.relativize(d);
            if (!name.equals("romfs")) continue;
            List<String> above = new ArrayList<>();
            for (int i = 0; i < rel.getNameCount() - 1; i++) above.add(rel.getName(i).toString());
            boolean nested = false;
            for (String p : above) if (low(p).equals("romfs")) nested = true;
            if (nested) continue;
            List<String> ids = new ArrayList<>();
            for (String p : above) if (GID.matcher(p).matches()) ids.add(p.toUpperCase(Locale.ROOT));
            if (!ids.isEmpty() && !ids.contains(gid.toUpperCase(Locale.ROOT))) {
                notes.add(new Message(Kind.OTHER_GAME, above.isEmpty() ? "romfs" : String.join("/", above), ids.get(ids.size() - 1)));
                continue;
            }
            List<String> label = new ArrayList<>();
            for (String p : above)
                if (!GID.matcher(p).matches() && !Arrays.asList("atmosphere", "contents", "mods").contains(low(p))) label.add(p);
            found.add(new Found(String.join("/", label.subList(Math.max(0, label.size() - 2), label.size())), d));
        }
        if (exefs) notes.add(new Message(Kind.EXEFS_SKIPPED));
        return found;
    }

    private static String low(String s) { return s.toLowerCase(Locale.ROOT); }

    private static int compareParts(Path a, Path b) {
        for (int i = 0; i < Math.min(a.getNameCount(), b.getNameCount()); i++) {
            int c = a.getName(i).toString().compareTo(b.getName(i).toString());
            if (c != 0) return c;
        }
        return Integer.compare(a.getNameCount(), b.getNameCount());
    }

    private static boolean hasPatch(Path d) throws IOException {
        try (Stream<Path> files = Files.list(d)) {
            return files.anyMatch(f -> {
                String n = low(f.getFileName().toString());
                return Files.isRegularFile(f) && (n.endsWith(".pchtxt") || n.endsWith(".ips")) && n.lastIndexOf('.') > 0;
            });
        }
    }

    /**
     * 解开 / 拷来的 root（在 Work 里，会被搬走）里每个找到的 romfs 存成 home/&lt;名字&gt;/romfs（同名整份替换，开着关着的都换成新的、开着）。
     * 一个都没找到 = Failure（说清要什么结构）。shown 是玩家选的那个东西的名字，base 是 baseName 起的名字。
     */
    static Result importRoot(File home, File root, String shown, String base, String gid) throws IOException, Failure {
        Result r = new Result();
        List<Found> found = find(root, gid, r.notes);
        if (found.isEmpty()) throw new Failure(Kind.NO_ROMFS, shown, gid.toUpperCase(Locale.ROOT));
        for (Found it : found) {
            String name = safeName(found.size() == 1 || it.label.isEmpty() ? base : base + " - " + it.label.replace("/", " - "));
            removeLinks(it.dir);
            if (count(it.dir)[0] == 0) {
                r.notes.add(new Message(Kind.EMPTY_ROMFS, name));
                continue;
            }
            Path tmp = home.toPath().resolve(IMPORTING + name);
            deleteTree(tmp);
            Files.createDirectories(tmp);
            Files.move(it.dir, tmp.resolve("romfs"));
            deleteTree(home.toPath().resolve(name));
            deleteTree(home.toPath().resolve(OFF + name));
            Files.move(tmp, home.toPath().resolve(name));
            r.imported.add(name);
        }
        return r;
    }

    /** → 这款的 mod（文件夹名升序 = 叠加顺序；关着的也列出）。 */
    static List<Mod> listing(File home) throws IOException {
        List<Mod> out = new ArrayList<>();
        File[] all = home.listFiles();
        if (all == null) return out;
        for (File d : all) {
            String n = d.getName();
            if (!Files.isDirectory(d.toPath(), LinkOption.NOFOLLOW_LINKS)) continue;
            boolean on = !n.startsWith(".");
            if (!on && !(n.startsWith(OFF) && n.length() > OFF.length())) continue;
            long[] c = count(d.toPath().resolve("romfs"));
            out.add(new Mod(on ? n : n.substring(OFF.length()), on, (int) c[0], c[1]));
        }
        Collections.sort(out, (a, b) -> a.name.equals(b.name) ? Boolean.compare(b.enabled, a.enabled) : a.name.compareTo(b.name));
        return out;
    }

    /** 开 / 关：改名 &lt;名字&gt; ↔ .off-&lt;名字&gt;。 */
    static void setEnabled(File home, String name, boolean on) throws IOException, Failure {
        Path off = own(home, name, OFF + name), live = own(home, name, name);
        Path from = on ? off : live, to = on ? live : off;
        if (!Files.isDirectory(from, LinkOption.NOFOLLOW_LINKS)) {
            if (Files.isDirectory(to, LinkOption.NOFOLLOW_LINKS)) return;   // 本来就是这个状态
            throw new Failure(Kind.MISSING, name);
        }
        if (Files.exists(to, LinkOption.NOFOLLOW_LINKS)) throw new Failure(Kind.NAME_TAKEN, name);
        Files.move(from, to);
    }

    /** 删除：整份删（开着关着都算）。 */
    static void remove(File home, String name) throws IOException, Failure {
        Path off = own(home, name, OFF + name), live = own(home, name, name);
        boolean any = false;
        for (Path p : new Path[] {live, off})
            if (Files.isDirectory(p, LinkOption.NOFOLLOW_LINKS)) { deleteTree(p); any = true; }
        if (!any) throw new Failure(Kind.MISSING, name);
    }

    private static Path own(File home, String name, String child) throws Failure {
        if (name.isEmpty() || name.startsWith(".") || name.contains("/") || name.contains("\\")) throw new Failure(Kind.MISSING, name);
        return home.toPath().resolve(child);
    }

    /** {普通文件数, 字节数}，不跟随符号链接。 */
    private static long[] count(Path dir) throws IOException {
        long[] c = {0, 0};
        if (!Files.isDirectory(dir, LinkOption.NOFOLLOW_LINKS)) return c;
        try (Stream<Path> all = Files.walk(dir)) {
            all.forEach(p -> {
                try {
                    BasicFileAttributes a = Files.readAttributes(p, BasicFileAttributes.class, LinkOption.NOFOLLOW_LINKS);
                    if (a.isRegularFile()) { c[0]++; c[1] += a.size(); }
                } catch (IOException e) { throw new java.io.UncheckedIOException(e); }
            });
        } catch (java.io.UncheckedIOException e) { throw e.getCause(); }
        return c;
    }

    private static void removeLinks(Path dir) throws IOException {
        List<Path> links = new ArrayList<>();
        try (Stream<Path> all = Files.walk(dir)) { all.filter(Files::isSymbolicLink).forEach(links::add); }
        for (Path p : links) Files.delete(p);
    }

    /** 整棵删，不跟随符号链接（链接本身删掉）。 */
    static void deleteTree(Path p) throws IOException {
        if (!Files.exists(p, LinkOption.NOFOLLOW_LINKS)) return;
        Files.walkFileTree(p, new SimpleFileVisitor<Path>() {
            @Override public FileVisitResult visitFile(Path f, BasicFileAttributes a) throws IOException { Files.delete(f); return FileVisitResult.CONTINUE; }
            @Override public FileVisitResult postVisitDirectory(Path d, IOException e) throws IOException {
                if (e != null) throw e;
                Files.delete(d);
                return FileVisitResult.CONTINUE;
            }
        });
    }

    /** 列表里的大小（库页一行字）。 */
    static String size(long bytes) {
        if (bytes >= 1L << 30) return String.format(Locale.ROOT, "%.1f GB", bytes / (double) (1L << 30));
        if (bytes >= 1L << 20) return String.format(Locale.ROOT, "%.1f MB", bytes / (double) (1L << 20));
        return String.format(Locale.ROOT, "%d KB", (bytes + 1023) >> 10);
    }
}
