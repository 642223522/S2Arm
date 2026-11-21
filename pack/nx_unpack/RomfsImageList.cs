// 按清单建标准 RomFS 镜像（不要密钥）：nx_unpack --romfs-image <清单> <输出镜像>
// 给 Switch 2 路径用（pack/ns2_dump.py 镜像形态 S2A_ROMFS_IMAGE=1）：文件来自导出目录里的散文件，或 NUP 容器里的一段（原样 / 单帧 zstd），
//   NUP 的资源不必先展开成几万个散文件。
// 清单每行 TAB 分隔 7 列：相对路径（/ 分隔）、字节数、来源文件、来源偏移、来源长度、编码（file 整个文件 | raw 原样一段 | zstd 单帧 zstd 一段）、SHA-256（十六进制，或 - 不核）。
// 布局与 RomfsExtraction.ExtractImage、services/romfs_index.sh --std 是同一个 LibHac RomFsBuilder（相对路径 Ordinal 排序加文件、跳过宿主垃圾名），
//   所以与「先展开成 romfs/ 再建镜像」逐字节相同。头与四张表从 RomFsBuilder 取；文件数据按文件分给各线程，各自顺序写进自己的位置（zstd 只能顺序解）；
//   每个文件核长度（对不上整份作废，先写暂存、成功才改名）；带 SHA-256 的再核哈希，对不上只打黄照常写（维护者 11-17）。
// 进度（#1612：Switch 2 大款这一步读写二十多 GB、几分钟到几十分钟，原先一行不打，玩家机上 4 小时只见心跳、分不清在跑还是卡住）：
//   每秒往出包进度协议 S2A_PROGRESS 追加一行「时刻<TAB>解包·资源镜像（MB）<TAB>已写<TAB>总数」（同 tools/progress.py，调用方没给就不写，作业层据此发界面进度），
//   每 15 秒往标准输出打一行（pack/ns2_dump.py 透传进出包日志）。
using System;
using System.Buffers.Binary;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using LibHac.Fs;
using LibHac.Fs.Fsa;
using LibHac.Tools.FsSystem.RomFs;
using Microsoft.Win32.SafeHandles;
using ZstdSharp;
using Path = System.IO.Path;

static class RomfsImageList {
    sealed record Src(string Rel, long Size, string From, long Off, long Len, string Codec, byte[] Sha);

    static long s_doneBytes; static int s_doneFiles;   // 各线程写完一块累加（Interlocked），进度计时器读

    sealed class Progress : IDisposable {
        readonly long totalMb; readonly int files; readonly string path = Environment.GetEnvironmentVariable("S2A_PROGRESS");
        readonly System.Diagnostics.Stopwatch clock = System.Diagnostics.Stopwatch.StartNew(); readonly System.Threading.Timer timer; long lastSay;
        public Progress(long totalBytes, int files) {
            totalMb = Math.Max(1, (totalBytes + (1 << 20) - 1) >> 20); this.files = files; s_doneBytes = 0; s_doneFiles = 0;
            Tick(); timer = new System.Threading.Timer(_ => Tick(), null, 1000, 1000);
        }
        void Tick(bool last = false) {
            long mb = Math.Min(totalMb, Interlocked.Read(ref s_doneBytes) >> 20); if (last) mb = totalMb;
            if (path != null) {
                try { File.AppendAllText(path, $"{DateTimeOffset.UtcNow.ToUnixTimeSeconds()}\t解包·资源镜像（MB）\t{mb}\t{totalMb}\n"); } catch (IOException) { } catch (UnauthorizedAccessException) { }
            }
            long s = clock.ElapsedMilliseconds / 1000;
            if (!last && s >= lastSay + 15) { lastSay = s; Console.WriteLine($"   资源镜像：已写 {mb:N0} / {totalMb:N0} MB（{Volatile.Read(ref s_doneFiles):N0} / {files:N0} 个文件），{s} 秒"); }
        }
        public void Dispose() { timer.Dispose(); Tick(last: true); }
    }

    internal static (int Files, long Bytes) Write(string listPath, string destination, int parallelism = 0) {
        if (Directory.Exists(destination) || File.Exists(destination)) throw new IOException("RomFS 镜像输出已存在（不覆盖）");
        var all = new List<Src>(); int line = 0;
        foreach (string raw in File.ReadLines(listPath, Encoding.UTF8)) {
            line++; if (raw.Length == 0) continue;
            string[] f = raw.Split('\t');
            InvalidDataException Bad(string why) => new($"RomFS 镜像清单第 {line} 行{why}：{raw}");
            if (f.Length != 7) throw Bad("不是 7 列");
            if (f[0].Length == 0 || f[0].StartsWith('/') || f[0].Contains('\\') || f[0].Split('/').Any(p => p is "" or "." or "..")) throw Bad("相对路径不合法");
            if (!long.TryParse(f[1], out long size) || size < 0 || !long.TryParse(f[3], out long off) || off < 0 || !long.TryParse(f[4], out long len) || len < 0) throw Bad("数字列不对");
            if (f[5] is not ("file" or "raw" or "zstd")) throw Bad("编码不认识");
            if (f[5] == "raw" && len != size) throw Bad("原样一段的长度与字节数不等");
            byte[] sha = f[6] == "-" ? null : Convert.FromHexString(f[6]);
            if (sha != null && sha.Length != 32) throw Bad("SHA-256 不是 32 字节");
            all.Add(new Src(f[0], size, f[2], off, len, f[5], sha));
        }
        var files = all.Where(s => !RomfsExtraction.IsHostJunk(s.Rel)).OrderBy(s => s.Rel, StringComparer.Ordinal).ToList();
        var dup = files.GroupBy(s => s.Rel, StringComparer.OrdinalIgnoreCase).FirstOrDefault(g => g.Count() > 1);
        if (dup != null) throw new InvalidDataException($"RomFS 资源里有只差大小写（或重复）的路径：{string.Join(" / ", dup.Select(s => s.Rel))}");

        var builder = new RomFsBuilder(); var at = new long[files.Count]; long cur = 0;
        for (int i = 0; i < files.Count; i++) {
            builder.AddFile("/" + files[i].Rel, new SizeOnly(files[i].Size));
            at[i] = 0x200 + cur; cur = (cur + files[i].Size + 15) & ~15L;   // 同 RomFsBuilder.AddFile：每个文件后补齐到 16 字节
        }
        using IStorage image = builder.Build();
        image.GetSize(out long total).ThrowIfFailure();
        byte[] head = new byte[0x200]; image.Read(0, head).ThrowIfFailure();
        long tables = BinaryPrimitives.ReadInt64LittleEndian(head.AsSpan(8));   // 目录哈希表偏移 = 数据区末尾
        if (tables != 0x200 + cur) throw new InvalidOperationException($"RomFS 布局推算不符：数据区末尾 {0x200 + cur}，头里 {tables}");
        byte[] meta = new byte[total - tables]; image.Read(tables, meta).ThrowIfFailure();

        string parent = Path.GetDirectoryName(Path.GetFullPath(destination));
        Directory.CreateDirectory(parent);
        string stage = Path.Combine(parent, ".romfs-image-" + Guid.NewGuid().ToString("N"));
        try {
            using (var handle = File.OpenHandle(stage, FileMode.CreateNew, FileAccess.Write, FileShare.None, FileOptions.None, total)) {
                RandomAccess.Write(handle, head, 0);
                RandomAccess.Write(handle, meta, tables);
                var order = Enumerable.Range(0, files.Count).OrderByDescending(i => files[i].Size).ToArray();   // 大文件先开，尾部不剩一个大文件单线程拖着
                using (new Progress(files.Sum(s => s.Size), files.Count))
                    Parallel.ForEach(order, new ParallelOptions { MaxDegreeOfParallelism = parallelism <= 0 ? Environment.ProcessorCount : parallelism },
                        i => { Copy(files[i], handle, at[i]); Interlocked.Increment(ref s_doneFiles); });
            }
            File.Move(stage, destination);
        } finally {
            if (File.Exists(stage)) File.Delete(stage);
        }
        return (files.Count, files.Sum(s => s.Size));
    }

    static void Copy(Src s, SafeFileHandle dst, long at) {
        if (s.Size == 0 && s.Codec != "file" && s.Len == 0) { Check(s, 0, s.Sha == null ? null : SHA256.HashData(ReadOnlySpan<byte>.Empty)); return; }
        using var hash = s.Sha == null ? null : IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        byte[] buf = new byte[4 << 20]; long n = 0;
        void Put(int got) {
            if (n + got > s.Size) throw new InvalidDataException($"RomFS 文件 {s.Rel} 比清单里的 {s.Size} 字节长（来源 {s.From}）");
            hash?.AppendData(buf, 0, got); RandomAccess.Write(dst, buf.AsSpan(0, got), at + n); n += got; Interlocked.Add(ref s_doneBytes, got);
        }
        using (Stream src = Open(s)) {
            for (int got; (got = src.Read(buf, 0, buf.Length)) > 0;) Put(got);
        }
        Check(s, n, hash?.GetHashAndReset());
    }

    static Stream Open(Src s) {
        var fs = new FileStream(s.From, FileMode.Open, FileAccess.Read, FileShare.Read, 1 << 16);
        try {
            if (s.Codec == "file") return fs;
            if (s.Off + s.Len > fs.Length) throw new InvalidDataException($"RomFS 文件 {s.Rel} 的来源一段越出 {s.From} 末尾");
            fs.Position = s.Off;
            Stream part = new Slice(fs, s.Len);
            return s.Codec == "raw" ? part : new DecompressionStream(part, 1 << 20, checkEndOfStream: true, leaveOpen: false);
        } catch { fs.Dispose(); throw; }
    }

    static void Check(Src s, long n, byte[] got) {
        if (n != s.Size) throw new InvalidDataException($"RomFS 文件 {s.Rel} 读出 {n} 字节，清单里是 {s.Size}（来源 {s.From}）");
        // SHA-256 对不上不再整份作废（维护者 11-17：「校验不过就整个拒绝」一律撤掉，D-RE44）：打黄 + 【校验跳过】机读行，照常写进镜像；长度不符仍报（布局按长度排定，物理上放不进）
        if (s.Sha != null && !got.AsSpan().SequenceEqual(s.Sha)) {
            Console.WriteLine($"🟡 RomFS 文件 {s.Rel} 的 SHA-256 和清单对不上（来源 {Path.GetFileName(s.From)}，疑改版 / 整合版或损坏），照常写进镜像");
            P.SkipLine("资源镜像 RomFS", "", $"文件 {s.Rel}");
        }
    }

    // 只给 RomFsBuilder 定长度、排布局；数据由 Copy 直接写，不经它读
    sealed class SizeOnly : IFile {
        readonly long size;
        public SizeOnly(long size) { this.size = size; }
        protected override LibHac.Result DoRead(out long bytesRead, long offset, Span<byte> destination, in ReadOption option) => throw new NotSupportedException();
        protected override LibHac.Result DoGetSize(out long size) { size = this.size; return LibHac.Result.Success; }
        protected override LibHac.Result DoWrite(long offset, ReadOnlySpan<byte> source, in WriteOption option) => ResultFs.WriteUnpermitted.Value;
        protected override LibHac.Result DoFlush() => LibHac.Result.Success;
        protected override LibHac.Result DoSetSize(long size) => ResultFs.WriteUnpermitted.Value;
        protected override LibHac.Result DoOperateRange(Span<byte> outBuffer, OperationId operationId, long offset, long size, ReadOnlySpan<byte> inBuffer)
            => ResultFs.NotImplemented.Value;
    }

    // 来源文件里的一段（从当前位置起 len 字节），读完即止；关闭时连底层文件一起关
    sealed class Slice : Stream {
        readonly Stream inner; long left;
        public Slice(Stream inner, long len) { this.inner = inner; left = len; }
        public override int Read(byte[] buffer, int offset, int count) {
            if (left <= 0) return 0;
            int got = inner.Read(buffer, offset, (int)Math.Min(count, left));
            if (got <= 0) throw new EndOfStreamException("来源文件提前结束");
            left -= got; return got;
        }
        protected override void Dispose(bool disposing) { if (disposing) inner.Dispose(); base.Dispose(disposing); }
        public override bool CanRead => true; public override bool CanSeek => false; public override bool CanWrite => false;
        public override long Length => throw new NotSupportedException();
        public override long Position { get => throw new NotSupportedException(); set => throw new NotSupportedException(); }
        public override void Flush() { }
        public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
        public override void SetLength(long value) => throw new NotSupportedException();
        public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();
    }
}
