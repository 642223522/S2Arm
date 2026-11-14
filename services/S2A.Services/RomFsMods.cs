using LibHac;
using LibHac.Fs;
using LibHac.Fs.Fsa;
using LibHac.Tools.FsSystem.RomFs;
using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime;
using System.Text;
using Path = System.IO.Path;

namespace S2A.Services
{
    // 资源替换类 mod：玩家把 mod 放进 <本款文档根>/mods/<任意名>/romfs/**，起局时叠到本体 RomFS 上。
    //   多个 mod 按文件夹名升序（序号序）叠，后者覆盖前者；能替换原有文件（大小可以不同）、新增原包没有的文件和目录。
    //   本体 RomFS 已是「本体 + 更新」合并后的那份（出包时 pack/nx_unpack 合好），三种形态（单一 IMG、目录 + 预建索引、单文件镜像）和没有索引的现建一视同仁：
    //   这里只认 Application.Register 交给 fs 的那个 IStorage，经 LibHac 读出它的文件表，再按同一个 RomFsBuilder 建新布局
    //   （做法同 Ryujinx ModLoader.ApplyRomFsMods；它本身不复用：S2Arm 起局不走 Ryujinx 加载器、没人调 CollectMods，目录约定与叠加顺序也不同）。
    //   新镜像只留布局（文件区间 + 文件数据以外的字节），文件数据读时转给原 RomFS（按原偏移）或 mod 文件（LazyHostFile，同目录布局的按需打开）。
    //   没有 mod（mods/ 不在、空的、里面没有 romfs 文件）→ 原对象原样返回，不包一层、不读文件表。
    //   内存：叠加时要把原包几十万个路径过一遍 LibHac 的建表器，瞬时占用随文件数涨（合成 27 万文件、Mac M5 Pro：带 mod 起局峰值比不带多约 161 MB，见 docs/坑记录.md「资源替换类 mod」）；
    //   分段放掉中间数据、段间回收，返回前做一次压缩回收把瞬时占用还给系统。
    //   空目录：LibHac RomFsBuilder 只收文件，mod 里的空目录加不进去；原 RomFS 本来也由它按文件建（RomFsIndex.Write、RomFsFromDirectory），没有空目录可丢。
    //   不处理：mod 里 romfs/ 以外的东西（exefs/ 代码补丁、cheats/ 金手指等，各记一行黄）；符号链接（不跟随，记黄）；DLC（aoc）的 RomFS；多程序合集序号 ≥ 1 的子程序。
    //   游戏运行中 mod 文件被删 / 改：读到时回失败码、报红（不抛异常穿出服务边界）；改 mod 要先结束游戏。
    public static class RomFsMods
    {
        public const string DirName = "mods";
        internal static Action<string> Log = line => Console.Error.WriteLine(line);

        // 本款文档根下的 mods/：S2A_DOCS 有就用它（iOS 多款容器 = Documents/games/<游戏号>，runtime/src/launchctx.c；Mac 作业层 = 游戏库/temp/<游戏号>，pack/jobs/build.py）；
        //   没有时 iOS 单款包 = App 容器 Documents（同 graphics/metal/cs NxColdStart.Doc）；别的平台没有它 = 不启用（Mac 不碰用户文稿夹，见 runtime/include/s2a_docs.h）
        public static string ModsDir()
        {
            string docs = Environment.GetEnvironmentVariable("S2A_DOCS");
            if (string.IsNullOrEmpty(docs) && OperatingSystem.IsIOS()) docs = Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments);   // 平台例外：没给 S2A_DOCS 时只有 iOS 的 App 容器 Documents 可当 mod 目录的根；Mac 上同一个调用是用户文稿夹，不许碰，所以只能按平台分
            return string.IsNullOrEmpty(docs) ? null : Path.Combine(docs, DirName);
        }

        // 起局接线（Application.Register 交给 fs 之前；单一 IMG、单文件镜像、目录三处，各有经 Register 的用例：RomFsModsRegisterTest.cs）
        public static IStorage ApplyAtLaunch(IStorage baseStorage, int programIndex)
        {
            string dir = ModsDir();
            return dir == null ? baseStorage : Apply(baseStorage, dir, programIndex);
        }

        // 宿主路径 → 相对 romfs/ 的 RomFS 路径（/ 分隔）；只把本平台的分隔符换成 /，Unix 上文件名里的 \ 原样留着（下面按坏名字拒）
        private static string RelOf(string romfs, string path)
        {
            string rel = Path.GetRelativePath(romfs, path);
            return Path.DirectorySeparatorChar == '/' ? rel : rel.Replace(Path.DirectorySeparatorChar, '/');
        }

        private static bool Hidden(string name) => name.StartsWith('.') || RomFsIndex.IsHostJunk(name);

        // 列一个目录的直接子项（不递归、不跟随符号链接）。用 Directory.EnumerateFileSystemEntries：tools/romfs_walk_lint.py 的 C# 规则认的就是这类写法，
        //   本文件在它的白名单里登记了理由（列的是玩家的 mod 文件夹，不是游戏 RomFS）；不换成守卫扫不到的写法（DirectoryInfo.Enumerate*）绕开登记。
        //   属性按链接本身取（lstat）：链接带 ReparsePoint，目标不在也不抛
        private readonly record struct Entry(string Name, string FullName, bool Dir, bool Link);

        private static List<Entry> ListDir(string dir)
        {
            List<Entry> list = new();
            foreach (string p in Directory.EnumerateFileSystemEntries(dir))
            {
                FileAttributes a = File.GetAttributes(p);
                list.Add(new(Path.GetFileName(p), p, (a & FileAttributes.Directory) != 0, (a & FileAttributes.ReparsePoint) != 0));
            }
            return list;
        }

        private readonly struct ModFile(string host, long length, string mod)
        {
            public readonly string Host = host, Mod = mod;
            public readonly long Length = length;
        }

        public static IStorage Apply(IStorage baseStorage, string modsDir, int programIndex = 0)
        {
            if (baseStorage == null || string.IsNullOrEmpty(modsDir)) return baseStorage;
            List<string> mods = new();

            try
            {
                if (!Directory.Exists(modsDir))
                {
                    Directory.CreateDirectory(modsDir);   // 玩家在「文件」App 里找得到放哪
                    Log($"S2A mod：建了空的 {modsDir}（mod 放 mods/<名字>/romfs/）");
                    return baseStorage;
                }

                foreach (Entry i in ListDir(modsDir))
                {
                    if (Hidden(i.Name)) continue;
                    if (i.Link) Log($"【黄】S2A mod：mods/{i.Name} 是符号链接，不跟随、不处理");
                    else if (i.Dir) mods.Add(i.FullName);
                    else Log($"【黄】S2A mod：mods/{i.Name} 是文件不是文件夹，不处理（zip 之类要先解压成 mods/<名字>/romfs/…）");
                }
            }
            catch (Exception e)
            {
                Red.Report("RomFS mod：mods/ 打不开，这局不叠 mod", $"{modsDir}：{e.GetType().Name}: {e.Message}");
                return baseStorage;
            }

            if (mods.Count == 0) return baseStorage;
            mods.Sort((a, b) => string.CompareOrdinal(Path.GetFileName(a), Path.GetFileName(b)));

            if (programIndex != 0)
            {
                Log($"【黄】S2A mod：多程序合集序号 {programIndex} 不叠 mod（只叠主程序，序号 0），mods/ 里的 {mods.Count} 个文件夹这局不用");
                return baseStorage;
            }

            long t0 = System.Diagnostics.Stopwatch.GetTimestamp();
            Dictionary<string, ModFile> files = new(StringComparer.Ordinal);   // RomFS 相对路径（/ 分隔、无前导 /）→ 最后一个给出它的 mod 文件
            List<string> order = new();   // 生效顺序（有 romfs 文件的 mod，序号序）
            int failed = 0;

            void Fail(string mod, string rel, string why)
            {
                failed++;
                Log($"【红】S2A mod：{mod}/romfs/{rel} 没叠上：{why}");
            }

            foreach (string mod in mods)
                if (Collect(mod, files, Fail)) order.Add(Path.GetFileName(mod));

            if (files.Count == 0)
            {
                if (failed > 0) Red.Report("RomFS mod：有文件没叠上（逐个见上面的红行）", $"{failed} 个；这局用原 RomFS");
                return baseStorage;
            }

            int replaced, baseCount = 0;
            List<string> added;
            RomFsFileSystem baseFs;   // 原 RomFS 的文件表（LibHac 读进内存的副本）：判替换 / 新增、喂建表器、查原偏移都按它，叠完放掉

            try
            {
                baseFs = new RomFsFileSystem(baseStorage);
                if (!Plan(baseFs.FileTable, files, Fail, out replaced, out added))
                {
                    Red.Report("RomFS mod：有文件没叠上（逐个见上面的红行）", $"{failed} 个；这局用原 RomFS");
                    return baseStorage;
                }
            }
            catch (Exception e)
            {
                Red.Report("RomFS mod：原 RomFS 的文件表读不出，这局不叠 mod", $"{e.GetType().Name}: {e.Message}");
                return baseStorage;
            }

            IStorage merged;

            try { merged = ModdedStorage.Build(baseStorage, baseFs, files, added, out baseCount); }
            catch (Exception e)
            {
                Red.Report("RomFS mod：建不出叠好 mod 的 RomFS，这局不叠 mod", $"{e.GetType().Name}: {e.Message}");
                return baseStorage;
            }

            int addedCount = added.Count;
            baseFs = null;
            added = null;
            files = null;
            // 瞬时占用（建表器的中间数据）还给系统：大对象堆也压缩一次（只在叠了 mod 的起局做这一次）
            GCSettings.LargeObjectHeapCompactionMode = GCLargeObjectHeapCompactionMode.CompactOnce;
            GC.Collect(2, GCCollectionMode.Aggressive, true, true);

            double ms = System.Diagnostics.Stopwatch.GetElapsedTime(t0).TotalMilliseconds;
            Log($"S2A mod：加载 {order.Count} 个 mod（顺序 {string.Join(" → ", order)}，后者覆盖前者），替换 {replaced} 个文件，新增 {addedCount} 个文件{(failed > 0 ? $"，{failed} 个失败" : "")}（原包 {baseCount} 个文件，叠加 {ms:F0} ms）：{modsDir}");
            if (failed > 0) Red.Report("RomFS mod：有文件没叠上（逐个见上面的红行）", $"{failed} 个");
            return merged;
        }

        private static void Collect2() => GC.Collect(2, GCCollectionMode.Forced, true, true);

        // 判 mod 文件是替换、新增还是建不出合法的树（建不出的逐个报红、从 files 里拿掉），新增的按路径序号序回出。回 false = 没有能叠的
        private static bool Plan(HierarchicalRomFileTable<RomFileInfo> table, Dictionary<string, ModFile> files, Action<string, string, string> Fail,
            out int replaced, out List<string> addedList)
        {
            replaced = 0;
            addedList = null;
            int addedCount;
            {
                // 只按路径查原 RomFS 的文件表，不把原包几十万个路径装进字典
                List<string> added = new(), drop = new();

                foreach ((string rel, ModFile m) in files)
                {
                    if (table.TryOpenFile("/" + rel, out RomFileInfo _)) { replaced++; continue; }
                    if (table.TryOpenDirectory("/" + rel, out FindPosition _)) { Fail(m.Mod, rel, "原包这里是目录"); drop.Add(rel); continue; }
                    string blocker = null;
                    for (int i = rel.IndexOf('/'); i > 0 && blocker == null; i = rel.IndexOf('/', i + 1))
                        if (table.TryOpenFile("/" + rel[..i], out RomFileInfo _)) blocker = rel[..i];
                    if (blocker != null) { Fail(m.Mod, rel, $"原包 {blocker} 是文件，不是目录"); drop.Add(rel); continue; }
                    added.Add(rel);
                }

                // 新增的之间也可能一个当文件、一个当目录（两个 mod 各给一半）：当文件的那个不叠
                HashSet<string> addedDirs = new(StringComparer.Ordinal);
                foreach (string rel in added)
                    for (int i = rel.IndexOf('/'); i > 0; i = rel.IndexOf('/', i + 1)) addedDirs.Add(rel[..i]);
                added.RemoveAll(rel =>
                {
                    if (!addedDirs.Contains(rel)) return false;
                    Fail(files[rel].Mod, rel, "别的 mod 文件把这里当目录");
                    drop.Add(rel);
                    return true;
                });
                foreach (string rel in drop) files.Remove(rel);
                added.Sort(StringComparer.Ordinal);
                addedCount = added.Count;

                // 只记黄、不改语义：新增路径按「NFC + 忽略大小写」对得上原包（多半是名字写法不一致没替换成）；换 / 加 NRO（代码模块）
                Dictionary<string, DirNames> kids = new(StringComparer.Ordinal);
                foreach (string rel in added)
                {
                    string near = Near(table, kids, rel);
                    if (near != null) Log($"【黄】S2A mod：{files[rel].Mod}/romfs/{rel} 按新增叠了：原包有写法不同的 {near}（大小写或 Unicode 写法不一样；要替换得照原包的名字）");
                }
                foreach ((string rel, ModFile m) in files)
                    if (rel.EndsWith(".nro", StringComparison.OrdinalIgnoreCase))
                        Log($"【黄】S2A mod：{m.Mod}/romfs/{rel} 是 NRO（代码模块），照叠但多半装不上：iOS 上 nn::ro 按 NRO 内容的 SHA-256 在出包时的 nro_modules.tsv 里认改写好的映像，内容变了认不出（runtime/src/loader.c s2a_nro_map 报红）；代码 mod 要出包时打");
                kids = null;
                addedList = added;
                return replaced + addedCount > 0;
            }
        }

        // 新文件表的全部文件按相对路径序号序逐个交给 emit（原包的同路径换成 mod 的长度，再并进新增的）：不把原包几十万个路径攒成表。
        //   同 RomFsIndex.Write / RomFsFromDirectory 的加入顺序（建出的布局随加入顺序变，同序才与它们逐字节相同）：
        //   目录里的子项按「名字（目录再加 /）」序号序深度优先走，得到的正是整条路径的序号序
        private static void Walk(HierarchicalRomFileTable<RomFileInfo> table, Dictionary<string, ModFile> files, List<string> added, Action<string, long> emit)
        {
            // 新增路径按所在目录分好：目录 → 子项（名字、是不是目录）
            Dictionary<string, Dictionary<string, bool>> extra = new(StringComparer.Ordinal);
            foreach (string rel in added)
            {
                string parent = "";
                int from = 0;
                for (int i = rel.IndexOf('/'); ; i = rel.IndexOf('/', i + 1))
                {
                    bool dir = i >= 0;
                    string name = dir ? rel[from..i] : rel[from..];
                    if (!extra.TryGetValue(parent, out Dictionary<string, bool> d)) extra[parent] = d = new(StringComparer.Ordinal);
                    d[name] = dir;
                    if (!dir) break;
                    parent = rel[..i];
                    from = i + 1;
                }
            }

            Stack<(string Rel, bool Dir, bool InBase, long Length)> todo = new();
            todo.Push(("", true, true, 0));
            List<(string Key, string Name, bool Dir, bool InBase, long Length)> kids = new();

            while (todo.Count > 0)
            {
                (string rel, bool isDir, bool inBase, long length) = todo.Pop();
                if (!isDir) { emit(rel, files.TryGetValue(rel, out ModFile m) ? m.Length : length); continue; }

                kids.Clear();
                if (inBase)
                {
                    if (!table.TryOpenDirectory(rel.Length == 0 ? "/" : "/" + rel, out FindPosition start))
                        throw new InvalidDataException($"原 RomFS 文件表里打不开目录 /{rel}");
                    FindPosition p = start;
                    while (table.FindNextFile(ref p, out RomFileInfo info, out string n)) kids.Add((n, n, false, true, info.Length));
                    p = start;
                    while (table.FindNextDirectory(ref p, out string n)) kids.Add((n + "/", n, true, true, 0));
                }
                if (extra.TryGetValue(rel, out Dictionary<string, bool> ex))
                {
                    HashSet<string> have = new(StringComparer.Ordinal);
                    foreach (var k in kids) have.Add(k.Name);
                    foreach ((string n, bool d) in ex)
                        if (!have.Contains(n)) kids.Add((d ? n + "/" : n, n, d, false, files.TryGetValue(rel.Length == 0 ? n : rel + "/" + n, out ModFile m) ? m.Length : 0));
                }

                kids.Sort((a, b) => string.CompareOrdinal(a.Key, b.Key));
                for (int i = kids.Count - 1; i >= 0; i--)   // 倒着压栈，正着出
                    todo.Push((rel.Length == 0 ? kids[i].Name : rel + "/" + kids[i].Name, kids[i].Dir, kids[i].InBase, kids[i].Length));
            }
        }

        // 列一个 mod：romfs/ 以外的条目记黄；romfs/ 下逐目录列（哪个子目录列不出只报那一个），符号链接不跟随（记黄）。回这个 mod 有没有给出文件
        private static bool Collect(string mod, Dictionary<string, ModFile> files, Action<string, string, string> fail)
        {
            string name = Path.GetFileName(mod), romfs = null;
            List<Entry> entries;

            try { entries = ListDir(mod); }
            catch (Exception e) { fail(name, "", $"{e.GetType().Name}: {e.Message}"); return false; }

            entries.Sort((a, b) => string.CompareOrdinal(a.Name, b.Name));

            foreach (Entry entry in entries)
            {
                string en = entry.Name;
                if (Hidden(en)) continue;
                bool dir = entry.Dir;

                if (entry.Link)
                {
                    Log($"【黄】S2A mod：{name}/{en} 是符号链接，不跟随、不处理");
                    continue;
                }

                if (dir && en.Equals("romfs", StringComparison.OrdinalIgnoreCase))
                {
                    romfs = entry.FullName;
                    continue;
                }

                string why = en.ToLowerInvariant() switch
                {
                    "exefs" => "代码补丁不在设备上打，要出包时打",
                    "cheats" => "金手指走金手指面板导入",
                    _ => "只认 romfs/",
                };
                Log($"【黄】S2A mod：{name}/{en}{(dir ? "/" : "")} 不处理（{why}）");
            }

            if (romfs == null) return false;
            List<string> found = new();
            Stack<string> dirs = new();
            dirs.Push(romfs);

            while (dirs.Count > 0)
            {
                string d = dirs.Pop();
                try
                {
                    foreach (Entry i in ListDir(d))
                    {
                        if (RomFsIndex.IsHostJunk(i.Name)) continue;
                        if (i.Link) Log($"【黄】S2A mod：{name}/romfs/{RelOf(romfs, i.FullName)} 是符号链接，不跟随、不叠");
                        else if (i.Dir) dirs.Push(i.FullName);
                        else found.Add(i.FullName);
                    }
                }
                catch (Exception e)
                {
                    fail(name, RelOf(romfs, d) + "/", $"列不出（{e.GetType().Name}: {e.Message}），这个目录下的文件不叠");
                }
            }

            found.Sort(StringComparer.Ordinal);
            bool any = false;

            foreach (string f in found)
            {
                string rel = RelOf(romfs, f);
                long length;

                // RomFS 路径的每一段都得是能进文件表的名字：宿主上合法、RomFS 里当分隔符或规范化掉的（\、.、..）逐个拒
                if (Array.Exists(rel.Split('/'), seg => seg.Length == 0 || seg == "." || seg == ".." || seg.Contains('\\')))
                {
                    fail(name, rel, "路径里有 RomFS 不认的名字（\\、.、..）");
                    continue;
                }

                // 起局就打开一次：读不了的现在报，不等游戏读到时才回失败（同 Application.RomFsFromDirectory 取长度）
                try { using FileStream s = File.OpenRead(f); length = s.Length; }
                catch (Exception e) { fail(name, rel, $"打不开（{e.GetType().Name}: {e.Message}）"); continue; }

                files[rel] = new ModFile(f, length, name);
                any = true;
            }

            return any;
        }

        // 原包一个目录的子项：名字 → 是不是目录；按写法折叠后的表第一次用到才建（每个目录只折叠一遍）
        private sealed class DirNames
        {
            public readonly Dictionary<string, bool> Exact = new(StringComparer.Ordinal);
            public Dictionary<string, string> Folded;   // Fold(名字) → 名字（折叠后相同的留先列到的）
        }

        // 新增路径逐段在原包里找：同名优先，没有就按「NFC + 忽略大小写」找；走过任一段写法不同的 → 回走到的原包路径，否则 null。
        //   每个新增文件的末段必然对不上同名：不能逐个把整个目录折叠比一遍（平铺 2 万文件的目录里新增 3000 个，Mac 上原先要 10.9 秒），按目录建一次折叠表查
        private static string Near(HierarchicalRomFileTable<RomFileInfo> table, Dictionary<string, DirNames> cache, string rel)
        {
            string cur = "";
            bool inexact = false;

            foreach (string seg in rel.Split('/'))
            {
                if (!cache.TryGetValue(cur, out DirNames kids))
                {
                    kids = new();
                    if (table.TryOpenDirectory(cur.Length == 0 ? "/" : "/" + cur, out FindPosition start))
                    {
                        FindPosition p = start;
                        while (table.FindNextFile(ref p, out RomFileInfo _, out string n)) kids.Exact.TryAdd(n, false);
                        p = start;
                        while (table.FindNextDirectory(ref p, out string n)) kids.Exact.TryAdd(n, true);
                    }
                    cache[cur] = kids;
                }

                string hit = seg;
                if (!kids.Exact.ContainsKey(seg))
                {
                    if (kids.Exact.Count == 0) break;
                    if (kids.Folded == null)
                    {
                        kids.Folded = new(kids.Exact.Count, StringComparer.Ordinal);
                        foreach (string n in kids.Exact.Keys) kids.Folded.TryAdd(Fold(n), n);
                    }
                    if (!kids.Folded.TryGetValue(Fold(seg), out hit)) break;
                    inexact = true;
                }

                cur = cur.Length == 0 ? hit : cur + "/" + hit;
                if (!kids.Exact[hit]) break;
            }

            return inexact ? cur : null;
        }

        /// <summary>单测读数：Fold 被调了几次（「写法相近」提示的开销按它核，不看墙钟）。</summary>
        internal static long S2ATestFoldCalls;

        private static string Fold(string s)
        {
            S2ATestFoldCalls++;
            return Nfc(s).ToUpperInvariant();
        }

        // NFC：服务层是 InvariantGlobalization，string.Normalize 什么都不做（实测 "café" 原样返回）；苹果上直接调 CoreFoundation（同 SystemLocale.cs），
        //   iOS「文件」App / APFS 存的名字可能是 NFD。全 ASCII 不调；别的平台或调不到就按原样比（只影响一行黄的提示）
        private static string Nfc(string s)
        {
            bool ascii = true;
            foreach (char c in s) if (c > 0x7F) { ascii = false; break; }
            if (ascii || !(OperatingSystem.IsIOS() || OperatingSystem.IsMacOS())) return s;   // 平台例外：下面直接调 CoreFoundation 做 NFC（服务层 string.Normalize 不干活），这个库只有苹果平台有；别的平台按原样比

            try
            {
                IntPtr m = CFStringCreateMutable(IntPtr.Zero, 0);
                if (m == IntPtr.Zero) return s;
                try
                {
                    unsafe
                    {
                        fixed (char* p = s) CFStringAppendCharacters(m, p, s.Length);
                        CFStringNormalize(m, 2);   // kCFStringNormalizationFormC
                        long n = CFStringGetLength(m);
                        char[] buf = new char[n];
                        fixed (char* q = buf) CFStringGetCharacters(m, new CFRange { Location = 0, Length = n }, q);
                        return new string(buf);
                    }
                }
                finally { CFRelease(m); }
            }
            catch (Exception e) when (e is DllNotFoundException or EntryPointNotFoundException) { return s; }
        }

        private struct CFRange { public long Location, Length; }
        private const string CF = "/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation";
        [System.Runtime.InteropServices.DllImport(CF)] private static extern IntPtr CFStringCreateMutable(IntPtr alloc, long maxLength);
        [System.Runtime.InteropServices.DllImport(CF)] private static extern unsafe void CFStringAppendCharacters(IntPtr str, char* chars, long numChars);
        [System.Runtime.InteropServices.DllImport(CF)] private static extern void CFStringNormalize(IntPtr str, long form);
        [System.Runtime.InteropServices.DllImport(CF)] private static extern long CFStringGetLength(IntPtr str);
        [System.Runtime.InteropServices.DllImport(CF)] private static extern unsafe void CFStringGetCharacters(IntPtr str, CFRange range, char* buffer);
        [System.Runtime.InteropServices.DllImport(CF)] private static extern void CFRelease(IntPtr cf);

        // 叠好 mod 的镜像：有序区间表（文件 → 原镜像偏移或 mod 文件；文件数据以外的非零字节段 → 内存），区间之间是全零填充。
        //   布局由 LibHac RomFsBuilder 建（只给长度的文件），同 RomFsIndex.Write 的做法；读法同 RomFsIndex.IndexedStorage，按偏移读、无读位置状态
        private sealed class ModdedStorage : IStorage
        {
            private readonly IStorage _base;
            private readonly long _size;
            private readonly long[] _start, _len;
            private readonly int[] _ref;            // ≥ 0：文件区间号；< 0：~段号
            private readonly long[] _src;           // 文件区间号 → 原镜像里的偏移；< 0：第 ~值 个 mod 文件
            private readonly LazyHostFile[] _host;  // mod 文件（按需打开）
            private readonly string[] _hostPath;
            private readonly byte[][] _seg;

            private ModdedStorage(IStorage baseStorage, long size, long[] start, long[] len, int[] refs, long[] src, LazyHostFile[] host, string[] hostPath, byte[][] seg)
            {
                (_base, _size, _start, _len, _ref, _src, _host, _hostPath, _seg) = (baseStorage, size, start, len, refs, src, host, hostPath, seg);
            }

            public static ModdedStorage Build(IStorage baseStorage, RomFsFileSystem baseFs, Dictionary<string, ModFile> files, List<string> added, out int baseCount)
            {
                HierarchicalRomFileTable<RomFileInfo> table = baseFs.FileTable;
                IStorage layout = Layout(table, files, added, out int count);
                baseCount = count - added.Count;
                layout.GetSize(out long total).ThrowIfFailure();
                Collect2();   // 建表器自己的中间数据不可达了：查偏移前还回去，峰值不叠在一起

                // 文件区间：走一遍建出的文件表，每个有数据的文件记新偏移、长度、来源（原镜像偏移或第几个 mod 文件）
                long[] rOff = new long[count], rLen = new long[count], rSrc = new long[count];
                List<string> hostPath = new();
                List<long> hostLen = new();
                int nr = Ranges(layout, table, baseFs.Header.DataOffset, files, count, rOff, rLen, rSrc, hostPath, hostLen);
                Collect2();
                int[] perm = new int[nr];
                for (int i = 0; i < nr; i++) perm[i] = i;
                Array.Sort(rOff, perm, 0, nr);
                long[] sLen = new long[nr], sSrc = new long[nr];
                for (int i = 0; i < nr; i++) (sLen[i], sSrc[i]) = (rLen[perm[i]], rSrc[perm[i]]);
                rLen = rSrc = null;
                perm = null;

                // 文件数据以外的区间：从布局里读出（文件只给长度、读出全零，这些区间不含文件数据），全零的不存
                List<(long Off, byte[] Data)> segs = new();
                long pos = 0;
                const int Chunk = 1 << 20;
                byte[] buf = new byte[Chunk];   // 文件之间的对齐填充有几十万段、几乎全是零：先读进同一块缓冲，非零才拷出来存
                void Gap(long from, long to)
                {
                    for (long o = from; o < to; o += Chunk)
                    {
                        Span<byte> b = buf.AsSpan(0, (int)Math.Min(Chunk, to - o));
                        layout.Read(o, b).ThrowIfFailure();
                        if (b.IndexOfAnyExcept((byte)0) >= 0) segs.Add((o, b.ToArray()));
                    }
                }
                for (int i = 0; i < nr; i++)
                {
                    if (rOff[i] < pos) throw new InvalidDataException("建出的镜像文件区间重叠");
                    Gap(pos, rOff[i]);
                    pos = rOff[i] + sLen[i];
                }
                Gap(pos, total);
                layout = null;

                int n = nr + segs.Count;
                long[] start = new long[n], length = new long[n];
                int[] refs = new int[n];
                for (int i = 0, a = 0, b = 0; i < n; i++)
                {
                    if (b >= segs.Count || (a < nr && rOff[a] < segs[b].Off))
                    {
                        (start[i], length[i], refs[i]) = (rOff[a], sLen[a], a);
                        a++;
                    }
                    else
                    {
                        (start[i], length[i], refs[i]) = (segs[b].Off, segs[b].Data.Length, ~b);
                        b++;
                    }
                }

                LazyHostFile[] host = new LazyHostFile[hostPath.Count];
                for (int i = 0; i < host.Length; i++) host[i] = new LazyHostFile(hostPath[i], hostLen[i]);
                byte[][] seg = new byte[segs.Count][];
                for (int i = 0; i < segs.Count; i++) seg[i] = segs[i].Data;
                return new ModdedStorage(baseStorage, total, start, length, refs, sSrc, host, hostPath.ToArray(), seg);
            }

            // 以下两个单独成方法、不内联：建表器与建出的文件表副本只活在各自那一帧
            [System.Runtime.CompilerServices.MethodImpl(System.Runtime.CompilerServices.MethodImplOptions.NoInlining)]
            private static IStorage Layout(HierarchicalRomFileTable<RomFileInfo> table, Dictionary<string, ModFile> files, List<string> added, out int count)
            {
                RomFsBuilder builder = new();
                int n = 0;
                Walk(table, files, added, (rel, len) => { builder.AddFile("/" + rel, new SizeOnlyFile(len)); n++; });
                count = n;
                return builder.Build();
            }

            [System.Runtime.CompilerServices.MethodImpl(System.Runtime.CompilerServices.MethodImplOptions.NoInlining)]
            private static int Ranges(IStorage layout, HierarchicalRomFileTable<RomFileInfo> baseTable, long baseData, Dictionary<string, ModFile> files, int count,
                long[] rOff, long[] rLen, long[] rSrc, List<string> hostPath, List<long> hostLen)
            {
                RomFsFileSystem fs = new(layout);
                HierarchicalRomFileTable<RomFileInfo> table = fs.FileTable;
                long dataOffset = fs.Header.DataOffset;
                Dictionary<string, int> hostOf = new(StringComparer.Ordinal);
                int nr = 0, seen = 0;
                Stack<string> todo = new();
                todo.Push("");

                while (todo.Count > 0)
                {
                    string dir = todo.Pop();
                    if (!table.TryOpenDirectory(dir.Length == 0 ? "/" : "/" + dir, out FindPosition start))
                        throw new InvalidDataException($"建出的文件表里打不开目录 /{dir}");
                    FindPosition p = start;
                    while (table.FindNextFile(ref p, out RomFileInfo info, out string name))
                    {
                        string rel = dir.Length == 0 ? name : dir + "/" + name;
                        long want, src;
                        seen++;
                        if (files.TryGetValue(rel, out ModFile m))
                        {
                            if (!hostOf.TryGetValue(rel, out int h)) { hostOf[rel] = h = hostPath.Count; hostPath.Add(m.Host); hostLen.Add(m.Length); }
                            (want, src) = (m.Length, ~(long)h);
                        }
                        else if (baseTable.TryOpenFile("/" + rel, out RomFileInfo b)) (want, src) = (b.Length, baseData + b.Offset);
                        else throw new InvalidDataException($"建出的文件表里多了 /{rel}（原包和 mod 里都没有）");
                        if (info.Length != want) throw new InvalidDataException($"建出的文件表里 /{rel} 长度 {info.Length}，应为 {want}");
                        if (info.Length > 0) (rOff[nr], rLen[nr], rSrc[nr], nr) = (dataOffset + info.Offset, info.Length, src, nr + 1);   // 零长度文件没有数据可读，不进区间表
                    }
                    p = start;
                    while (table.FindNextDirectory(ref p, out string name)) todo.Push(dir.Length == 0 ? name : dir + "/" + name);
                }

                if (seen != count) throw new InvalidDataException($"建出的文件表有 {seen} 个文件，应为 {count}");
                return nr;
            }

            public override Result Read(long offset, Span<byte> destination)
            {
                if (offset < 0 || offset > _size || destination.Length > _size - offset) return ResultFs.OutOfRange.Value;   // 先比 offset 再减，不做会溢出的加法

                int i = Array.BinarySearch(_start, offset);
                i = i >= 0 ? i : Math.Max(0, ~i - 1);

                while (!destination.IsEmpty)
                {
                    if (i >= _start.Length || offset < _start[i])
                    {
                        long next = i < _start.Length ? _start[i] : _size;
                        int z = (int)Math.Min(destination.Length, next - offset);
                        destination[..z].Clear();
                        destination = destination[z..];
                        offset += z;
                        continue;
                    }

                    long end = _start[i] + _len[i];
                    if (offset >= end) { i++; continue; }

                    int count = (int)Math.Min(destination.Length, end - offset);
                    long inner = offset - _start[i];
                    int r = _ref[i];

                    if (r < 0)
                    {
                        _seg[~r].AsSpan((int)inner, count).CopyTo(destination);
                    }
                    else if (_src[r] >= 0)
                    {
                        Result res = _base.Read(_src[r] + inner, destination[..count]);
                        if (res.IsFailure()) return res;
                    }
                    else
                    {
                        int h = (int)~_src[r];
                        Result res;

                        // 游戏运行中玩家在「文件」App 里删 / 改了 mod：没打开过（或句柄被淘汰后重开）的文件打开时抛 IO 异常，HleTarget 不接这类异常、会穿出服务边界终止整局。
                        //   这里接住、报红、回失败码（同长度对不上那条）；LazyHostFile 是上游的，不动它
                        try { res = _host[h].Read(out long got, inner, destination[..count], ReadOption.None); if (res.IsSuccess() && got != count) res = ResultFs.HostFileDataCorrupted.Value; }
                        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
                        {
                            Red.Report("RomFS mod：游戏运行中 mod 文件被删 / 改，本次读回失败（改 mod 要先结束游戏）", $"{_hostPath[h]}：{e.GetType().Name}: {e.Message}");
                            return ResultFs.HostFileDataCorrupted.Value;
                        }

                        // 区间按 mod 文件起局时的长度划定：读不满 = 文件在起局之后被换过，回失败，不补零当完整（同 IndexedStorage）
                        if (res.IsFailure()) return res;
                    }

                    destination = destination[count..];
                    offset += count;
                    i++;
                }

                return Result.Success;
            }

            public override void Dispose()
            {
                _base.Dispose();
                base.Dispose();
            }

            public override Result GetSize(out long size)
            {
                size = _size;
                return Result.Success;
            }

            public override Result Write(long offset, ReadOnlySpan<byte> source) => ResultFs.WriteUnpermitted.Value;
            public override Result Flush() => Result.Success;
            public override Result SetSize(long size) => ResultFs.WriteUnpermitted.Value;

            public override Result OperateRange(Span<byte> outBuffer, OperationId operationId, long offset, long size, ReadOnlySpan<byte> inBuffer)
                => ResultFs.NotImplemented.Value;
        }

        // 只给长度的文件（建布局用，读出全零），同 RomFsIndex 里那份（那份是上游文件的 private 类）
        private sealed class SizeOnlyFile(long size) : IFile
        {
            protected override Result DoRead(out long bytesRead, long offset, Span<byte> destination, in ReadOption option)
            {
                int n = (int)Math.Max(0, Math.Min(destination.Length, size - offset));
                destination[..n].Clear();
                bytesRead = n;
                return Result.Success;
            }

            protected override Result DoGetSize(out long s)
            {
                s = size;
                return Result.Success;
            }

            protected override Result DoWrite(long offset, ReadOnlySpan<byte> source, in WriteOption option) => ResultFs.WriteUnpermitted.Value;
            protected override Result DoFlush() => Result.Success;
            protected override Result DoSetSize(long s) => ResultFs.WriteUnpermitted.Value;
            protected override Result DoOperateRange(Span<byte> outBuffer, OperationId operationId, long offset, long s, ReadOnlySpan<byte> inBuffer)
                => ResultFs.NotImplemented.Value;
        }
    }
}
