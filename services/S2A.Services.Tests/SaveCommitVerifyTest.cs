using LibHac;
using LibHac.Common;
using LibHac.Fs;
using LibHac.Fs.Fsa;
using LibHac.FsSystem;
using System;
using System.Collections.Generic;
using System.IO;
using System.Text;
using Path = LibHac.Fs.Path;

namespace S2A.Services.Tests
{
    public static partial class Program
    {
        // 存档提交核对游戏写入（S2ASaveTransaction.SyncWrittenLocked / VerifyWrittenLocked）：游戏经事务写进去的字节，提交出来的新版本里必须一字不差；
        //   对不上不拒绝（游戏收到提交错误码多半当场中止）：按写入记录 / 已提交版本把新版本补对再提交，补不了也照常提交、记黄行。
        //   一款游戏（iPhone）写成功的 2 字节 "{}" 被提交成 2 个零字节，下次起局读它中止；之后又反过来：记录成 0000、盘上是 "{}"，提交被拒、游戏中止。
        //   期望值按规则写死，不跑实现推：
        //   ① 正常写 "{}" 关掉提交 → 成功，已提交 = "{}"
        //   ② 克隆出来的新版本每次都被换成两个零字节（模拟那次事故）→ 按记录补回：提交成功、已提交 = "{}"、不留 .s2a_new、报红 +0、不留护栏标记（提交成立了）；去掉故障再提交 → 成功、标记无
        //   ③ 写完又把文件截短到写入之前（SetSize 0）→ 提交成功，不误报（已提交是空文件）
        //   ④ 写完删掉 / 改名 → 提交成功：删掉的不在已提交里，改名的按新名字核对、内容是写的那份
        //   ⑤ 回滚后提交 → 成功、已提交仍是 OLD（回滚前的写入记录作废，不误报）
        //   ⑥ 游戏没动过的文件在克隆里变空 → 按已提交版本拷回：提交成功、已提交仍是 OLD、报红 +0
        //   ⑦ 游戏自己 SetSize(0) 清空已有文件 → 照常提交（按实际调用是有意的）
        //   ⑧ 只有第一次克隆被换成零字节（偶发）→ 内部重做一次就对了：提交成功、已提交 = "{}"、不报红（只记黄行）；克隆了 2 次
        //   （②⑥ 每次克隆都被换：重做一次仍不对才补）
        //   ⑩ 写盘之后、调用返回之前游戏把缓冲清零（真机那次）→ 写下去的和记录的是同一份：提交成功、已提交 = "{}"、报红 +0
        //   ⑨ 留上一份：提交 "{}"、再写 "[1]" 提交 → 已提交 "[1]"、上一份 "{}"；回到上一份 → 已提交 "{}"、上一份 "[1]"；再调一次 → 换回 "[1]"；
        //      回到上一份后护栏标记删掉；没有上一份的目录 → 回原因「没有上一份存档」
        //   护栏标记 .s2a_guard：不再写（提交不再被拦）；旧版本留下的在正常提交 / 回到上一份时清掉（⑨）
        [SoloTest("--save-commit-verify")]
        private static int SaveCommitVerify()
        {
            List<(string N, string E, string A)> rows = new();
            Red.Strict = false;
            int reds = 0;
            Red.Log = line => { reds++; Console.Error.WriteLine(line); };
            Ryujinx.HLE.S2AHooks.Red = _ => reds++;
            static string Txt(string p) => File.Exists(p) ? Convert.ToHexString(File.ReadAllBytes(p)) : "无";

            var real = new S2A.Apple.SaveCommit.AppleHostDirectoryTransaction();
            var hook = new CloneHookTransaction(real);
            Ryujinx.HLE.FileSystem.S2AHostFileSystem.Transaction = hook;
            string root = System.IO.Path.Combine(System.IO.Path.GetTempPath(), $"s2a_txn_verify_{Environment.ProcessId}");
            if (Directory.Exists(root)) Directory.Delete(root, true);
            Directory.CreateDirectory(root);

            // 一棵存档：已提交 0/x.bin = OLD，挂载后工作目录 1/ 是它的克隆
            (string Dir, Ryujinx.HLE.FileSystem.S2ASaveTransaction Tx) Open(string name)
            {
                string d = System.IO.Path.Combine(root, name);
                Directory.CreateDirectory(System.IO.Path.Combine(d, "0"));
                File.WriteAllText(System.IO.Path.Combine(d, "0", "x.bin"), "OLD");
                string why = Ryujinx.HLE.FileSystem.S2ASaveTransaction.Mount(d);
                if (why != null) throw new InvalidOperationException(why);
                using SharedRef<ISaveDataFileSystem> baseFs = new(new LocalSaveFs(System.IO.Path.Combine(d, "1")));
                var copy = SharedRef<ISaveDataFileSystem>.CreateCopy(in baseFs);
                return (d, new Ryujinx.HLE.FileSystem.S2ASaveTransaction(ref copy, d));
            }
            static Path P(string s) { var p = new Path(); p.InitializeWithNormalization(Encoding.UTF8.GetBytes(s + "\0")).ThrowIfFailure(); return p; }
            static void Write(Ryujinx.HLE.FileSystem.S2ASaveTransaction tx, string path, string text, long setSizeAfter = -1)
            {
                using Path p = P(path);
                using UniqueRef<IFile> f = new();
                tx.OpenFile(ref f.Ref, in p, OpenMode.ReadWrite | OpenMode.AllowAppend).ThrowIfFailure();
                byte[] data = Encoding.ASCII.GetBytes(text);
                f.Get.SetSize(data.Length).ThrowIfFailure();
                f.Get.Write(0, data, WriteOption.None).ThrowIfFailure();
                if (setSizeAfter >= 0) f.Get.SetSize(setSizeAfter).ThrowIfFailure();
            }

            {   // ①
                var (d, tx) = Open("normal");
                Write(tx, "/x.bin", "{}");
                bool ok = tx.Commit().IsSuccess();
                rows.Add(("① 正常写 {} 提交：结果 / 已提交", "True / 7B7D", $"{ok} / {Txt(System.IO.Path.Combine(d, "0", "x.bin"))}"));
                tx.Dispose();
            }
            {   // ②
                var (d, tx) = Open("zeroed");
                Write(tx, "/x.bin", "{}");
                hook.AfterClone = dst => File.WriteAllBytes(System.IO.Path.Combine(dst, "x.bin"), new byte[2]);
                int before = reds;
                bool ok1 = tx.Commit().IsSuccess();
                string guard = System.IO.Path.Combine(d, Ryujinx.HLE.FileSystem.S2ASaveTransaction.GuardFile);
                string mark = File.Exists(guard) && File.ReadAllText(guard).Contains("次提交") ? "有" : "无";
                string s1 = $"{ok1} / {Txt(System.IO.Path.Combine(d, "0", "x.bin"))} / {Directory.Exists(System.IO.Path.Combine(d, ".s2a_new"))} / +{reds - before} / 标记{mark}";
                hook.AfterClone = null;
                bool ok2 = tx.Commit().IsSuccess();
                string s2 = $"{ok2} / {Txt(System.IO.Path.Combine(d, "0", "x.bin"))} / 标记{(File.Exists(guard) ? "有" : "无")}";
                rows.Add(("② 克隆成零字节：结果 / 已提交 / .s2a_new 在 / 报红 / 护栏标记 ‖ 去掉故障再提交：结果 / 已提交 / 护栏标记", "True / 7B7D / False / +0 / 标记无 ‖ True / 7B7D / 标记无", $"{s1} ‖ {s2}"));
                tx.Dispose();
            }
            {   // ③
                var (d, tx) = Open("truncated");
                Write(tx, "/x.bin", "{}", setSizeAfter: 0);
                int before = reds;
                bool ok = tx.Commit().IsSuccess();
                rows.Add(("③ 写后截成 0：结果 / 已提交 / 报红", "True /  / +0", $"{ok} / {Txt(System.IO.Path.Combine(d, "0", "x.bin"))} / +{reds - before}"));
                tx.Dispose();
            }
            {   // ④
                var (d, tx) = Open("moved");
                Write(tx, "/y.bin", "AA");
                Write(tx, "/z.bin", "BB");
                using (Path y = P("/y.bin")) tx.DeleteFile(in y).ThrowIfFailure();
                using (Path z = P("/z.bin"), w = P("/w.bin")) tx.RenameFile(in z, in w).ThrowIfFailure();
                int before = reds;
                bool ok = tx.Commit().IsSuccess();
                rows.Add(("④ 写后删 y、z 改名 w：结果 / 已提交 y / 已提交 w / 报红", "True / 无 / 4242 / +0",
                    $"{ok} / {Txt(System.IO.Path.Combine(d, "0", "y.bin"))} / {Txt(System.IO.Path.Combine(d, "0", "w.bin"))} / +{reds - before}"));
                tx.Dispose();
            }
            {   // ⑤
                var (d, tx) = Open("rollback");
                Write(tx, "/x.bin", "{}");
                bool rb = tx.Rollback().IsSuccess();
                int before = reds;
                bool ok = tx.Commit().IsSuccess();   // 写入记录没随回滚清掉的话，这里会拿 {} 去比回滚后的 OLD、误判不提交
                rows.Add(("⑤ 回滚后提交：回滚 / 提交 / 已提交 / 报红", "True / True / 4F4C44 / +0", $"{rb} / {ok} / {Txt(System.IO.Path.Combine(d, "0", "x.bin"))} / +{reds - before}"));
                tx.Dispose();
            }

            {   // ⑥ 游戏没动 x.bin（只写了别的文件），克隆出来 x.bin 却成了空的
                var (d, tx) = Open("untouched");
                Write(tx, "/other.bin", "CC");
                hook.AfterClone = dst => File.WriteAllBytes(System.IO.Path.Combine(dst, "x.bin"), Array.Empty<byte>());
                int before = reds;
                bool ok = tx.Commit().IsSuccess();
                hook.AfterClone = null;
                rows.Add(("⑥ 没动过的文件克隆成空：结果 / 已提交 / 报红", "True / 4F4C44 / +0", $"{ok} / {Txt(System.IO.Path.Combine(d, "0", "x.bin"))} / +{reds - before}"));
                tx.Dispose();
            }
            {   // ⑦ 游戏自己把已有的 x.bin 截成 0（只调 SetSize(0)，没写）：按实际调用是有意清空，照常提交
                var (d, tx) = Open("cleared");
                using (Path p = P("/x.bin"))
                using (UniqueRef<IFile> f = new())
                {
                    tx.OpenFile(ref f.Ref, in p, OpenMode.ReadWrite).ThrowIfFailure();
                    f.Get.SetSize(0).ThrowIfFailure();
                }
                int before = reds;
                bool ok = tx.Commit().IsSuccess();
                rows.Add(("⑦ 游戏自己截成 0：结果 / 已提交 / 报红", "True /  / +0", $"{ok} / {Txt(System.IO.Path.Combine(d, "0", "x.bin"))} / +{reds - before}"));
                tx.Dispose();
            }

            {   // ⑧
                var (d, tx) = Open("once");
                Write(tx, "/x.bin", "{}");
                int clones = 0;
                hook.AfterClone = dst => { if (++clones == 1) File.WriteAllBytes(System.IO.Path.Combine(dst, "x.bin"), new byte[2]); };
                int before = reds;
                bool ok = tx.Commit().IsSuccess();
                hook.AfterClone = null;
                rows.Add(("⑧ 只有第一次克隆成零字节：结果 / 已提交 / 报红 / 克隆次数 / 护栏标记", "True / 7B7D / +0 / 2 / 无", $"{ok} / {Txt(System.IO.Path.Combine(d, "0", "x.bin"))} / +{reds - before} / {clones} / {(File.Exists(System.IO.Path.Combine(d, Ryujinx.HLE.FileSystem.S2ASaveTransaction.GuardFile)) ? "有" : "无")}"));
                tx.Dispose();
            }

            {   // ⑩ 游戏缓冲在写盘之后、调用返回之前被清零
                var (d, tx) = Open("racy");
                byte[] game = Encoding.ASCII.GetBytes("{}");
                LocalSaveFs.AfterInnerWrite = () => Array.Clear(game);
                using (Path p = P("/x.bin"))
                using (UniqueRef<IFile> f = new())
                {
                    tx.OpenFile(ref f.Ref, in p, OpenMode.ReadWrite | OpenMode.AllowAppend).ThrowIfFailure();
                    f.Get.SetSize(2).ThrowIfFailure();
                    f.Get.Write(0, game, WriteOption.None).ThrowIfFailure();
                }
                LocalSaveFs.AfterInnerWrite = null;
                int before = reds;
                bool ok = tx.Commit().IsSuccess();
                rows.Add(("⑩ 写盘后游戏缓冲被清零：结果 / 已提交 / 报红 / 护栏标记", "True / 7B7D / +0 / 无",
                    $"{ok} / {Txt(System.IO.Path.Combine(d, "0", "x.bin"))} / +{reds - before} / {(File.Exists(System.IO.Path.Combine(d, Ryujinx.HLE.FileSystem.S2ASaveTransaction.GuardFile)) ? "有" : "无")}"));
                tx.Dispose();
            }

            {   // ⑨
                var (d, tx) = Open("previous");
                Write(tx, "/x.bin", "{}");
                bool c1 = tx.Commit().IsSuccess();
                Write(tx, "/x.bin", "[1]");
                bool c2 = tx.Commit().IsSuccess();
                tx.Dispose();
                string cur = System.IO.Path.Combine(d, "0", "x.bin"), prev = System.IO.Path.Combine(d, Ryujinx.HLE.FileSystem.S2ASaveTransaction.PreviousDir, "x.bin");
                string s0 = $"{c1} / {c2} / {Txt(cur)} / {Txt(prev)}";
                string guard9 = System.IO.Path.Combine(d, Ryujinx.HLE.FileSystem.S2ASaveTransaction.GuardFile);
                File.WriteAllText(guard9, "x");   // 当作被拦过：回到上一份后标记应删掉
                string r1 = Ryujinx.HLE.FileSystem.S2ASaveTransaction.RestorePrevious(d) ?? "成功";
                string s1 = $"{r1} / {Txt(cur)} / {Txt(prev)} / 标记{(File.Exists(guard9) ? "有" : "无")}";
                string r2 = Ryujinx.HLE.FileSystem.S2ASaveTransaction.RestorePrevious(d) ?? "成功";
                string s2 = $"{r2} / {Txt(cur)}";
                string none = System.IO.Path.Combine(root, "noprev"); Directory.CreateDirectory(System.IO.Path.Combine(none, "0"));
                string r3 = Ryujinx.HLE.FileSystem.S2ASaveTransaction.RestorePrevious(none) ?? "成功";
                rows.Add(("⑨ 两次提交：结果 / 结果 / 已提交 / 上一份 ‖ 回到上一份：结果 / 已提交 / 上一份 ‖ 再回：结果 / 已提交 ‖ 没有上一份",
                    "True / True / 5B315D / 7B7D ‖ 成功 / 7B7D / 5B315D / 标记无 ‖ 成功 / 5B315D ‖ 没有上一份存档", $"{s0} ‖ {s1} ‖ {s2} ‖ {r3}"));
            }

            Ryujinx.HLE.FileSystem.S2AHostFileSystem.Transaction = null;
            try { Directory.Delete(root, true); } catch (Exception e) { Console.Error.WriteLine($"清理 {root}：{e.Message}"); }
            int failures = 0;
            foreach ((string n, string e, string a) in rows)
            {
                bool ok = e == a;
                if (!ok) failures++;
                Console.WriteLine($"{(ok ? "✓" : "✗")} {n}：{e} → {a}");
            }
            return failures == 0 ? 0 : 1;
        }

        // 宿主目录原语外包一层：克隆成功后调 AfterClone（参数 = 克隆出来的目录）
        private sealed class CloneHookTransaction(Ryujinx.HLE.FileSystem.IHostDirectoryTransaction inner) : Ryujinx.HLE.FileSystem.IHostDirectoryTransaction
        {
            public Action<string> AfterClone;
            public bool Supported(string directory) => inner.Supported(directory);
            public int CloneTree(string source, string destination)
            {
                int e = inner.CloneTree(source, destination);
                if (e == 0) AfterClone?.Invoke(destination);
                return e;
            }
            public int Exchange(string a, string b) => inner.Exchange(a, b);
            public int WriteToken(string directory, ReadOnlySpan<byte> value) => inner.WriteToken(directory, value);
            public int ReadToken(string directory, Span<byte> value, out int length) => inner.ReadToken(directory, value, out length);
            public int SyncDirectory(string directory) => inner.SyncDirectory(directory);
            public int OpenRead(string path, out Microsoft.Win32.SafeHandles.SafeFileHandle handle) => inner.OpenRead(path, out handle);
        }

        // 底层文件外包一层：写完调 LocalSaveFs.AfterInnerWrite
        private sealed class HookFile : IFile
        {
            private UniqueRef<IFile> _f;
            public HookFile(ref UniqueRef<IFile> f) => _f = new UniqueRef<IFile>(ref f);
            protected override Result DoRead(out long bytesRead, long offset, Span<byte> destination, in ReadOption option) => _f.Get.Read(out bytesRead, offset, destination, in option);
            protected override Result DoWrite(long offset, ReadOnlySpan<byte> source, in WriteOption option) { Result r = _f.Get.Write(offset, source, in option); LocalSaveFs.AfterInnerWrite?.Invoke(); return r; }
            protected override Result DoFlush() => _f.Get.Flush();
            protected override Result DoSetSize(long size) => _f.Get.SetSize(size);
            protected override Result DoGetSize(out long size) => _f.Get.GetSize(out size);
            protected override Result DoOperateRange(Span<byte> outBuffer, OperationId operationId, long offset, long size, ReadOnlySpan<byte> inBuffer) => _f.Get.OperateRange(outBuffer, operationId, offset, size, inBuffer);
            public override void Dispose() { _f.Destroy(); base.Dispose(); }
        }

        // 工作目录上的真文件：LibHac 的本地文件系统（生产里存档文件也经它读写），附加数据只给默认值
        private sealed class LocalSaveFs : ISaveDataFileSystem
        {
            private readonly LocalFileSystem _fs = new(useUnixTimeStamps: true);
            public static Action AfterInnerWrite;   // ⑩：底层文件写完之后调（模拟游戏别的线程在这次调用期间改缓冲）
            public LocalSaveFs(string root) => _fs.Initialize(root, LocalFileSystem.PathMode.DefaultCaseSensitivity, ensurePathExists: true).ThrowIfFailure();
            protected override Result DoCreateFile(ref readonly Path path, long size, CreateFileOptions option) => _fs.CreateFile(in path, size, option);
            protected override Result DoDeleteFile(ref readonly Path path) => _fs.DeleteFile(in path);
            protected override Result DoCreateDirectory(ref readonly Path path) => _fs.CreateDirectory(in path);
            protected override Result DoDeleteDirectory(ref readonly Path path) => _fs.DeleteDirectory(in path);
            protected override Result DoDeleteDirectoryRecursively(ref readonly Path path) => _fs.DeleteDirectoryRecursively(in path);
            protected override Result DoCleanDirectoryRecursively(ref readonly Path path) => _fs.CleanDirectoryRecursively(in path);
            protected override Result DoRenameFile(ref readonly Path a, ref readonly Path b) => _fs.RenameFile(in a, in b);
            protected override Result DoRenameDirectory(ref readonly Path a, ref readonly Path b) => _fs.RenameDirectory(in a, in b);
            protected override Result DoGetEntryType(out DirectoryEntryType entryType, ref readonly Path path) => _fs.GetEntryType(out entryType, in path);
            protected override Result DoOpenFile(ref UniqueRef<IFile> outFile, ref readonly Path path, OpenMode mode)
            {
                // 文件不在先建（同游戏「建文件再写」）
                if (_fs.GetEntryType(out _, in path).IsFailure()) { Result c = _fs.CreateFile(in path, 0, CreateFileOptions.None); if (c.IsFailure()) return c; }
                using UniqueRef<IFile> inner = new();
                Result r = _fs.OpenFile(ref inner.Ref, in path, mode);
                if (r.IsFailure()) return r;
                outFile.Reset(new HookFile(ref inner.Ref));
                return Result.Success;
            }
            protected override Result DoOpenDirectory(ref UniqueRef<IDirectory> outDirectory, ref readonly Path path, OpenDirectoryMode mode) => _fs.OpenDirectory(ref outDirectory, in path, mode);
            protected override Result DoCommit() => Result.Success;
            public override Result CommitExtraData(bool updateTimeStamp) => Result.Success;
            public override bool IsSaveDataFileSystemCacheEnabled() => false;
            public override Result ReadExtraData(out SaveDataExtraData extraData) { extraData = default; return Result.Success; }
            public override void RegisterExtraDataAccessorObserver(ISaveDataExtraDataAccessorObserver observer, SaveDataSpaceId spaceId, ulong saveDataId) { }
            public override Result RollbackOnlyModified() => Result.Success;
            public override Result WriteExtraData(in SaveDataExtraData extraData) => Result.Success;
            public override void Dispose() { _fs.Dispose(); base.Dispose(); }
        }
    }
}
