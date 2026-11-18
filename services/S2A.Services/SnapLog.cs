// 即时存档（缺省关，S2A_SNAP_MODE / S2A_SNAP_RESTORE 才开）：服务请求的压缩日志与恢复时重放。
//   存档模式（S2A_SNAP_MODE=1、非恢复）：每条服务请求（去掉无状态高频命令、写盘 / 提交类）记下整条消息与输入缓冲内容；
//     原生层同时记句柄创建 / 关闭的有序日志（thread.c hlog），每条请求建的句柄按请求序号打标。
//   恢复（S2A_SNAP_RESTORE）：B 正常起好服务层后，原生层恢复完内存与游戏自建的句柄，调 S2A_SnapReplay 按序重放；
//     每条请求前让原生层按 A 的值强制分配本条会建的句柄，请求后按日志穿插执行关闭——会话 cookie、句柄值、域对象号都与 A 一致。
//     消息与输入 / 输出缓冲放进窗口里的暂存区（服务按游戏地址读写，描述符地址只有 39 位），不碰已恢复的游戏内存。
using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using Ryujinx.Audio.Renderer.Server;

namespace S2A.Services
{
    // 开关单放一个小类：热路径（每条请求）只读这里的布尔值，开关关着时不触发 SnapLog 的静态初始化（日志缓冲、字典等一概不建）
    //   开关值不在这里读环境变量，读原生层的唯一定义处（runtime/src/snapshot.c s2a_snap_saving / s2a_snap_mode），三层同一个判定
    internal static class SnapSwitch
    {
        [DllImport("s2a_native")] private static extern int s2a_snap_saving();
        [DllImport("s2a_native")] private static extern int s2a_snap_mode();
        [DllImport("s2a_native")] private static extern int s2a_snap_logging();
        internal static readonly bool CanSave;   // 起局带了存档开关（恢复局也可以带：回到那一刻之后还能再存）
        internal static readonly bool Any;       // 存档或恢复
        // 正在记请求日志：普通局开局即记；恢复局重放时不记，重放完把快照里的日志接上当开头后再记（SnapLog.Replay 末尾置）。热路径每条请求读一次
        internal static volatile bool Save;

        // 没链原生层（服务层单测用托管假原生层，没有 s2a_native 库 / 入口）：存不了快照，开关按关
        static SnapSwitch()
        {
            try { CanSave = s2a_snap_saving() != 0; Any = s2a_snap_mode() != 0; Save = s2a_snap_logging() != 0; }
            catch (DllNotFoundException) { }
            catch (EntryPointNotFoundException) { }
        }
    }

    internal static unsafe class SnapLog
    {
        internal static bool On => SnapSwitch.Save;
        private static int _maxSeq = -1;

        private const uint EntReq = 1, EntConnect = 2;
        private static readonly object _lock = new();
        private static readonly MemoryStream _log = new();
        private static readonly BinaryWriter _w = new(_log);
        private static int _seq, _dropped, _kept;
        private static readonly Dictionary<string, int> _dropBy = new();

        [DllImport("s2a_native")] private static extern void s2a_snap_hctx(int seq);
        [DllImport("s2a_native")] private static extern int s2a_snap_replay_begin(int seq);
        [DllImport("s2a_native")] private static extern int s2a_snap_replay_end(int seq);
        [DllImport("s2a_native")] private static extern int s2a_snap_need_handle(uint h);

        // ---------- HIPC 描述符 ----------
        internal struct Desc { public int Kind; public int Off; public ulong Addr; public ulong Size; }   // Kind：0 X、1 A、2 B、3 W、4 C
        internal static List<Desc> ParseDescs(byte* msg, int size)
        {
            var d = new List<Desc>();
            uint w0 = *(uint*)msg, w1 = *(uint*)(msg + 4);
            int nx = (int)((w0 >> 16) & 0xF), na = (int)((w0 >> 20) & 0xF), nb = (int)((w0 >> 24) & 0xF), nw = (int)((w0 >> 28) & 0xF);
            int dw = (int)(w1 & 0x3FF), recv = (int)((w1 >> 10) & 0xF), off = 8;
            if ((w1 >> 31) != 0) { uint w2 = *(uint*)(msg + 8); off += 4 + (int)(w2 & 1) * 8 + 4 * (int)(((w2 >> 1) & 0xF) + ((w2 >> 5) & 0xF)); }
            for (int i = 0; i < nx; i++, off += 8)
            {
                uint a = *(uint*)(msg + off), b = *(uint*)(msg + off + 4);
                ulong addr = b | ((ulong)((a >> 12) & 0xF) << 32) | ((ulong)((a >> 6) & 0x7) << 36);
                d.Add(new Desc { Kind = 0, Off = off, Addr = addr, Size = a >> 16 });
            }
            for (int k = 1; k <= 3; k++)
            {
                int n = k == 1 ? na : k == 2 ? nb : nw;
                for (int i = 0; i < n; i++, off += 12)
                {
                    uint s0 = *(uint*)(msg + off), a0 = *(uint*)(msg + off + 4), f = *(uint*)(msg + off + 8);
                    ulong addr = a0 | ((ulong)((f >> 28) & 0xF) << 32) | ((ulong)((f >> 2) & 0x7) << 36);
                    d.Add(new Desc { Kind = k, Off = off, Addr = addr, Size = s0 | ((ulong)((f >> 24) & 0xF) << 32) });
                }
            }
            int c = recv > 2 ? recv - 2 : recv == 2 ? 1 : 0, coff = off + dw * 4;
            for (int i = 0; i < c && coff + 8 <= size; i++, coff += 8)
            {
                uint lo = *(uint*)(msg + coff), hi = *(uint*)(msg + coff + 4);
                d.Add(new Desc { Kind = 4, Off = coff, Addr = lo | ((ulong)(hi & 0xFFFF) << 32), Size = hi >> 16 });
            }
            return d;
        }
        // 参数本身是游戏内存指针的命令（不走描述符）：nn::ro 的 LoadNro（命令 0：pid、NRO 地址、长度、bss 地址、长度）与 LoadNrr（2 / 10：pid、NRR 地址、长度）。
        //   游戏装完会把放原文件的内存还掉，恢复时那块不可访问（一款大游戏：重放 LoadNro 在 ParseNro 读原文件崩）——记日志时把内容一起记下（种类 5），
        //   重放时放进暂存区、把参数里的地址改成暂存区地址（SetAddr 种类 5 = 改写消息里那个 u64）
        private static void AddRawPointers(List<Desc> ds, string n, long cmd, byte* msg, int size)
        {
            if (!n.Contains("IRoInterface")) return;
            uint c = (uint)cmd; if (c != 0 && c != 2 && c != 10) return;
            for (int o = 8; o + 16 + 24 <= size; o += 4)
            {
                if (*(uint*)(msg + o) != 0x49434653u) continue;   // CMIF 头 "SFCI"，参数在头后 16 字节
                int arg = o + 16; ulong addr = *(ulong*)(msg + arg + 8), len = *(ulong*)(msg + arg + 16);
                if (addr != 0 && len != 0 && len <= (1ul << 24)) ds.Add(new Desc { Kind = 5, Off = arg + 8, Addr = addr, Size = len });
                return;
            }
        }
        private static void SetAddr(byte* msg, Desc x, ulong a)
        {
            uint* p = (uint*)(msg + x.Off);
            if (x.Kind == 5) { *(ulong*)(msg + x.Off) = a; return; }
            switch (x.Kind)
            {
                case 0: p[0] = (p[0] & ~((0xFu << 12) | (0x7u << 6))) | (uint)(((a >> 32) & 0xF) << 12) | (uint)(((a >> 36) & 0x7) << 6); p[1] = (uint)a; break;
                case 4: p[0] = (uint)a; p[1] = (p[1] & 0xFFFF0000u) | (uint)((a >> 32) & 0xFFFF); break;
                default: p[1] = (uint)a; p[2] = (p[2] & ~((0xFu << 28) | (0x7u << 2))) | (uint)(((a >> 32) & 0xF) << 28) | (uint)(((a >> 36) & 0x7) << 2); break;
            }
        }

        // ---------- 过滤：无状态高频 / 由别处整块恢复的 / 写盘提交（重放会把旧内容写回盘） ----------
        internal static string TargetName(SessionTarget t, byte* msg, int size)
        {
            if (t is HleTarget h && h.Service.S2AIsDomain)
            {
                for (int i = 16; i + 12 <= Math.Min(size, 0x100); i += 4)
                    if (*(uint*)(msg + i) == 0x49434653) { int id = (int)*(uint*)(msg + i - 12); return h.Service.S2ADomainObjectFullName(id) ?? t.Name; }
            }
            return t.TraceName(msg, size);
        }
        // nvdrv 的 Ioctl（命令 1 / 11 / 12 / 13）：设备操作号在原始参数里（fd u32、ioctl 号 u32，紧跟 CMIF 头）。host1x 通道的 Submit（ioctl 类型 0x00、序号 0x01，低 16 位 0x0001；同类型的 Ctrl 设备只用 0x14–0x1b，不会撞）
        //   是「提交工作」（视频解码 / 图像处理），不是建状态：重放它要读游戏早已释放的命令缓冲（一款大游戏：重放 Submit 读已还的内存崩）。不进日志——
        //   丢掉后解码器参考帧可能缺，视频到下一个关键帧才干净（同 NVN 视频那条的取舍）；建映射等留状态的 ioctl 照常重放
        private static bool DropNvSubmit(string n, long cmd, byte* msg, int size)
        {
            uint c = (uint)cmd; if (!n.Contains("INvDrvServices") || !(c == 1 || c == 11 || c == 12 || c == 13)) return false;
            for (int o = 8; o + 16 + 8 <= size; o += 4)
            {
                if (*(uint*)(msg + o) != 0x49434653u) continue;   // CMIF 头 "SFCI"
                uint ioc = *(uint*)(msg + o + 16 + 4); return (ioc & 0xFFFF) == 0x0001;   // 11-17 前误写 0x4801（那是通道的 0x48 / 0x01 建状态命令，被错丢）
            }
            return false;
        }
        private static bool Drop(string n, long cmd)
        {
            uint c = (uint)cmd;
            if (n.Contains("IHidServer") && (c == 200 || c == 214)) return true;                     // 震动查询 / 震动发送
            if (n.Contains(".Fs.") && n.EndsWith("IStorage") && (c == 0 || c == 1 || c == 2 || c == 3)) return true;   // 文件系统的读 / 写 / 刷 / 改长（AM 的 IStorage 同名，cmd 0 是建读写器，不能丢）
            if (n.EndsWith("IFile") && (c == 0 || c == 1 || c == 2 || c == 3)) return true;
            if (n.EndsWith("IFileSystem") && (c <= 6 || c == 10 || c == 13)) return true;             // 建删改名 / 提交（写盘）
            if (n.Contains("AudioRenderer") && !n.Contains("Manager") && c == 4) return true;                                  // RequestUpdate：渲染器整块另存
            if (n.Contains("AudioOut") && !n.Contains("Manager") && (c == 3 || (c >= 5 && c <= 11))) return true;              // 缓冲队列：AudioOut 队列另存
            // 音频设备的纯查询（设备名列表 / 取音量 / 当前设备名 / 声道数，含 Auto 版）：不改服务状态，重放只为重建状态，不进日志（一款大游戏：
            //   重放 #10 取当前设备名时按 A 的接收表写回报内存区无效）。设音量（1 / 7）改状态、取系统事件（4 / 11 / 12）建句柄，照常重放
            if (n.Contains("AudioDevice") && (c == 0 || c == 2 || c == 3 || c == 5 || c == 6 || c == 8 || c == 10 || c == 13)) return true;
            // 每帧都发、不留状态的：不进日志，否则日志随游玩时长线性涨（实测一款大游戏 200 秒 2.2 万条、约 8 MB，一小时约 300 MB 常驻内存）
            if (n.EndsWith("ICommonStateGetter") && c == 50) return true;                                  // IsVrModeEnabled：纯查询
            if (n.EndsWith("DatabaseServiceImpl") && c == 0) return true;                                 // 头像库 IsUpdated：纯查询
            if (n.Contains("IHidServer") && (c == 201 || c == 206)) return true;                          // 发震动（单 / 多）：只输出
            if (n.Contains("HardwareOpusDecoder") && c != 1 && c != 3 && c <= 9) return true;            // Opus 解码：只解这一段，留下的只有解码器内部预测（下一段自愈）；建 / 设上下文（1 / 3）照常
            // 网络套接字的等待 / 读取（Select 5、Poll 6、Recv 8、RecvFrom 9、Read 25）：不改服务状态，网络连接也没法跨进程接上；进了日志，恢复时在全新的
            //   套接字上重放会一条条等到超时（一款 Switch 2 游戏：网络线程的 Poll 重放 310 条用了 642 秒）。建套接字 / 连接 / 接受（分配编号）照常记、照常重放
            if (n.EndsWith(".Bsd.IClient") && (c == 5 || c == 6 || c == 8 || c == 9 || c == 25)) return true;
            return false;
        }

        // 请求开始（游戏线程上，处理前）：回本条序号，不记回 -1
        internal static int Begin(uint num, ulong cookie, SessionTarget t, byte* msg, int size, long cmd)
        {
            string n = TargetName(t, msg, size);
            if (n.Contains("AudioRenderer") && !n.Contains("Manager") && (uint)cmd == 4)
            {
                // 渲染器 RequestUpdate：每会话只留最后一条（恢复时先重放它把效果 / 混音的托管对象建出来，再整块拷回渲染器缓冲）
                byte[] e = Serialize(-1, num, cookie, cmd, n, msg, size);
                lock (_lock) { _lastUpdate[cookie] = e; _dropped++; }
                s2a_snap_hctx(-3); return -1;
            }
            if (Drop(n, cmd) || DropNvSubmit(n, cmd, msg, size)) { lock (_lock) { _dropped++; _dropBy[n + "#" + (uint)cmd] = _dropBy.GetValueOrDefault(n + "#" + (uint)cmd) + 1; } s2a_snap_hctx(-3); return -1; }
            lock (_lock)
            {
                int seq = _seq++; _kept++;
                _w.Write(Serialize(seq, num, cookie, cmd, n, msg, size));
                s2a_snap_hctx(seq);
                return seq;
            }
        }
        private static readonly Dictionary<ulong, byte[]> _lastUpdate = new();
        private static byte[] Serialize(int seq, uint num, ulong cookie, long cmd, string n, byte* msg, int size)
        {
            List<Desc> ds = ParseDescs(msg, size);
            AddRawPointers(ds, n, cmd, msg, size);
            var ms = new MemoryStream(); var w = new BinaryWriter(ms);
            w.Write(EntReq); w.Write(seq); w.Write(num); w.Write(cookie); w.Write(cmd); w.Write(n);
            w.Write(size); w.Write(new ReadOnlySpan<byte>(msg, size));
            w.Write(ds.Count);
            foreach (Desc x in ds)
            {
                bool input = x.Kind == 0 || x.Kind == 1 || x.Kind == 3 || x.Kind == 5;
                int len = input ? (int)Math.Min(x.Size, 1u << 24) : 0;
                w.Write(x.Kind); w.Write(x.Off); w.Write(x.Addr); w.Write(x.Size); w.Write(len);
                if (len > 0 && x.Addr != 0) w.Write(new ReadOnlySpan<byte>((void*)x.Addr, len)); else if (len > 0) w.Write(new byte[len]);
            }
            w.Flush(); return ms.ToArray();
        }
        internal static void End() => s2a_snap_hctx(-2);
        internal static int Connect()
        {
            lock (_lock) { int seq = _seq++; _kept++; _w.Write(EntConnect); _w.Write(seq); s2a_snap_hctx(seq); return seq; }
        }

        // 服务层实际用的 Ryujinx 数据根（Exports.cs 起服务层时定：配置里的状态目录 / S2A_RYU_DATA / 缺省），快照按它找玩家存档树
        internal static string DataRoot;
        [UnmanagedCallersOnly(EntryPoint = "S2A_SnapDataRoot")]
        private static int DataRootOut(byte* buf, int n)
        {
            if (DataRoot == null || n <= 0) return -1;
            byte[] b = System.Text.Encoding.UTF8.GetBytes(DataRoot);
            if (b.Length + 1 > n) return -1;
            new ReadOnlySpan<byte>(b).CopyTo(new Span<byte>(buf, n)); buf[b.Length] = 0; return b.Length;
        }

        [UnmanagedCallersOnly(EntryPoint = "S2A_SnapLogSave")]
        private static int Save(byte* path)
        {
            try
            {
                string p = Marshal.PtrToStringUTF8((IntPtr)path);
                lock (_lock)
                {
                    foreach (var kv in _lastUpdate) { byte[] e = (byte[])kv.Value.Clone(); BitConverter.TryWriteBytes(new Span<byte>(e, 4, 4), _seq++); _w.Write(e); _kept++; }
                    _w.Flush(); File.WriteAllBytes(p, _log.ToArray());
                }
                var sb = new StringBuilder();
                foreach (var kv in _dropBy) sb.Append(kv.Key).Append('×').Append(kv.Value).Append(' ');
                Console.Error.WriteLine($"[s2a] 即时存档：服务请求日志 记 {_kept} 条、{_log.Length / 1024} KB；丢掉 {_dropped} 条（{sb}）");
                return 0;
            }
            catch (Exception e) { Console.Error.WriteLine($"[s2a] 【红】即时存档：写服务请求日志失败 {e.Message}"); return -1; }
        }

        // 进程内重建开新一局：请求日志从头记（上一局的请求不能留在新一局的日志里）；要恢复时先不记，重放完接上快照日志后再记
        [UnmanagedCallersOnly(EntryPoint = "S2A_SnapSessionReset")]
        private static int SessionReset(int restoring)
        {
            lock (_lock) { _log.SetLength(0); _seq = 0; _kept = 0; _dropped = 0; _maxSeq = -1; _dropBy.Clear(); _lastUpdate.Clear(); }
            SnapSwitch.Save = SnapSwitch.CanSave && restoring == 0;
            return 0;
        }

        // ---------- 恢复：重放 ----------
        [UnmanagedCallersOnly(EntryPoint = "S2A_SnapReplay")]
        private static int Replay(byte* path, ulong scratch, ulong scratchSize)
        {
            int n = 0, bad = 0; string cur_ = "";   // 正在重放的那条（服务名#命令号），出错时说清是哪条
            try
            {
                Dispatcher d = Dispatcher.Instance;
                byte[] all = File.ReadAllBytes(Marshal.PtrToStringUTF8((IntPtr)path));
                var r = new BinaryReader(new MemoryStream(all));
                long t0 = System.Diagnostics.Stopwatch.GetTimestamp();
                while (r.BaseStream.Position < r.BaseStream.Length)
                {
                    uint kind = r.ReadUInt32(); int seq = r.ReadInt32(); if (seq > _maxSeq) _maxSeq = seq;
                    s2a_snap_replay_begin(seq);
                    if (kind == EntConnect) { d.SnapConnect(); s2a_snap_replay_end(seq); n++; continue; }
                    uint num = r.ReadUInt32(); ulong cookie = r.ReadUInt64(); long cmd = r.ReadInt64(); string name = r.ReadString();
                    int size = r.ReadInt32(); byte[] msgb = r.ReadBytes(size);
                    int nd = r.ReadInt32();
                    // 暂存区：消息放 4 KB 对齐的开头（同 A 的对齐，CMIF 填充一致），缓冲依次往后
                    cur_ = $"{name}#{(uint)cmd}";
                    ulong cur = scratch, msgAddr = cur; cur += ((ulong)size + 0xFFF) & ~0xFFFul;
                    new ReadOnlySpan<byte>(msgb).CopyTo(new Span<byte>((void*)msgAddr, size));
                    for (int i = 0; i < nd; i++)
                    {
                        Desc x = new() { Kind = r.ReadInt32(), Off = r.ReadInt32(), Addr = r.ReadUInt64(), Size = r.ReadUInt64() };
                        int len = r.ReadInt32(); byte[] data = len > 0 ? r.ReadBytes(len) : null;
                        if (x.Addr == 0) continue;
                        // 长度 0 但有地址的（接收表的空缓冲等）也改指暂存区：服务层照样按这个地址做内存追踪核对，留着 A 的原地址在 B 里可能无效（一款大游戏，iPhone 地址档）
                        if (x.Size == 0) { SetAddr((byte*)msgAddr, x, cur); continue; }
                        ulong need = (x.Size + 0xFFF) & ~0xFFFul;
                        if (cur + need > scratch + scratchSize) { Console.Error.WriteLine($"[s2a] 【红】即时存档恢复：重放第 {seq} 条 {name}#{(uint)cmd} 缓冲 {x.Size} 字节放不下暂存区"); bad++; continue; }
                        new Span<byte>((void*)cur, (int)Math.Min(x.Size, int.MaxValue)).Clear();
                        if (data != null) new ReadOnlySpan<byte>(data).CopyTo(new Span<byte>((void*)cur, data.Length));
                        SetAddr((byte*)msgAddr, x, cur); cur += need;
                    }
                    // 请求里拷贝 / 移交的游戏句柄：没放进表的先放（游戏建的句柄延后放，见 thread.c g_defer）
                    {
                        uint w1 = *(uint*)(msgAddr + 4);
                        if ((w1 >> 31) != 0)
                        {
                            uint w2 = *(uint*)(msgAddr + 8); int pid = (int)(w2 & 1), nh = (int)(((w2 >> 1) & 0xF) + ((w2 >> 5) & 0xF));
                            for (int i = 0; i < nh; i++) { uint h = *(uint*)(msgAddr + 12 + (ulong)pid * 8 + (ulong)i * 4); if (h != 0 && h < 0xFFFF8000u) s2a_snap_need_handle(h); }
                        }
                    }
                    uint rc = d.SnapRequest(num, cookie, (byte*)msgAddr, size);
                    if (rc != 0) { bad++; if (bad <= 20) Console.Error.WriteLine($"[s2a] 【黄】即时存档恢复：重放第 {seq} 条 {name}#{(uint)cmd} 回 0x{rc:X}"); }
                    if (s2a_snap_replay_end(seq) != 0) bad++;
                    n++;
                }
                double ms = (System.Diagnostics.Stopwatch.GetTimestamp() - t0) * 1000.0 / System.Diagnostics.Stopwatch.Frequency;
                Console.Error.WriteLine($"[s2a] 即时存档恢复：服务请求重放 {n} 条，{ms:F1} ms，异常 {bad} 条");
                if (bad == 0 && SnapSwitch.CanSave)
                {   // 恢复局接着记：快照里的日志整份当开头，序号接着编（同原生层的句柄日志接续，thread.c s2a_snap_hlog_continue）
                    lock (_lock) { _w.Write(all); _seq = _maxSeq + 1; _kept = n; }
                    SnapSwitch.Save = true;
                }
                return bad;
            }
            catch (Exception e) { Console.Error.WriteLine($"[s2a] 【红】即时存档恢复：重放第 {n} 条后出错（正在重放 {cur_}）{e}"); return -1; }
        }

        // ---------- 音频渲染器：整块存 / 拷回 + 块内指针平移 ----------
        // 音频渲染器工作缓冲（整块拷 + 平移块内指针）按 Ryujinx 这几个结构的大小排布：布局指纹 = 各结构名 + 大小 + 托管标量个数。
        //   同 C 侧 snapfmt.h 的布局指纹：存档记进清单，恢复前比，不同即拒绝。局限：字段换序但大小不变时这一版看不出（NativeAOT 下字段偏移反射不可靠）
        [UnmanagedCallersOnly(EntryPoint = "S2A_SnapAudioFp")]
        private static ulong AudioFp()
        {
            ulong h = 1469598103934665603ul;
            void Mix(string name, int size) { foreach (char c in name) h = (h ^ c) * 0x100000001b3ul; h = (h ^ (ulong)size) * 0x100000001b3ul; }
            Mix("VoiceState", System.Runtime.CompilerServices.Unsafe.SizeOf<Ryujinx.Audio.Renderer.Common.VoiceState>());
            Mix("VoiceInfo", System.Runtime.CompilerServices.Unsafe.SizeOf<Ryujinx.Audio.Renderer.Server.Voice.VoiceInfo>());
            Mix("VoiceChannelResource", System.Runtime.CompilerServices.Unsafe.SizeOf<Ryujinx.Audio.Renderer.Server.Voice.VoiceChannelResource>());
            Mix("MixInfo", System.Runtime.CompilerServices.Unsafe.SizeOf<Ryujinx.Audio.Renderer.Server.Mix.MixInfo>());
            Mix("MemoryPoolInfo", System.Runtime.CompilerServices.Unsafe.SizeOf<Ryujinx.Audio.Renderer.Server.MemoryPool.MemoryPoolInfo>());
            Mix("BiquadFilterState", System.Runtime.CompilerServices.Unsafe.SizeOf<Ryujinx.Audio.Renderer.Dsp.State.BiquadFilterState>());
            Mix("SplitterState", System.Runtime.CompilerServices.Unsafe.SizeOf<Ryujinx.Audio.Renderer.Server.Splitter.SplitterState>());
            Mix("scalars", AudioRenderSystem.S2ASnapScalarCount);
            return h;
        }

        [UnmanagedCallersOnly(EntryPoint = "S2A_SnapAudioSave")]
        private static int AudioSave(byte* path)
        {
            try
            {
                var m = Ryujinx.Horizon.Audio.AudioManagers.S2ALast?.AudioRendererManager;
                using var w = new BinaryWriter(File.Create(Marshal.PtrToStringUTF8((IntPtr)path)));
                if (m == null) { w.Write(0); return 0; }
                int n = 0;
                lock (m.S2ASessionLock)   // 工作线程停在两次处理之间
                {
                    System.Threading.Thread.Sleep(20);   // 内联 DSP 在会话锁外执行：等手上这一拍做完
                    foreach (var r in m.S2ASessions) if (r != null && r.S2ASnapBuffer.Ptr != IntPtr.Zero) n++;
                    w.Write(n);
                    foreach (var r in m.S2ASessions)
                    {
                        if (r == null || r.S2ASnapBuffer.Ptr == IntPtr.Zero) continue;
                        lock (r.S2ALock)
                        {
                            var (ptr, size) = r.S2ASnapBuffer;
                            w.Write(r.S2ASessionId); w.Write((ulong)ptr); w.Write(size); w.Write(new ReadOnlySpan<byte>((void*)ptr, size));
                            ulong[] sc = r.S2ASnapScalars(); w.Write(sc.Length); foreach (ulong v in sc) w.Write(v);
                        }
                    }
                }
                Console.Error.WriteLine($"[s2a] 即时存档：音频渲染器 {n} 个会话已存");
                return 0;
            }
            catch (Exception e) { Console.Error.WriteLine($"[s2a] 【红】即时存档：存音频渲染器失败 {e}"); return -1; }
        }

        [UnmanagedCallersOnly(EntryPoint = "S2A_SnapAudioRestore")]
        private static int AudioRestore(byte* path)
        {
            try
            {
                var m = Ryujinx.Horizon.Audio.AudioManagers.S2ALast?.AudioRendererManager;
                using var r = new BinaryReader(File.OpenRead(Marshal.PtrToStringUTF8((IntPtr)path)));
                int n = r.ReadInt32(), ok = 0, bad = 0; long moved = 0;
                lock (m.S2ASessionLock)
                {
                    for (int k = 0; k < n; k++)
                    {
                        int id = r.ReadInt32(); ulong old = r.ReadUInt64(); int size = r.ReadInt32(); byte[] data = r.ReadBytes(size);
                        int ns = r.ReadInt32(); ulong[] sc = new ulong[ns]; for (int i = 0; i < ns; i++) sc[i] = r.ReadUInt64();
                        AudioRenderSystem sys = null;
                        foreach (var x in m.S2ASessions) if (x != null && x.S2ASessionId == id) sys = x;
                        if (sys == null || sys.S2ASnapBuffer.Size != size) { Console.Error.WriteLine($"[s2a] 【红】即时存档恢复：音频渲染器会话 {id} 在 B 里{(sys == null ? "没有" : $"大小不同（{sys.S2ASnapBuffer.Size} ≠ {size}）")}"); bad++; continue; }
                        lock (sys.S2ALock)
                        {
                            ulong nw = (ulong)sys.S2ASnapBuffer.Ptr; byte* p = (byte*)nw;
                            new ReadOnlySpan<byte>(data).CopyTo(new Span<byte>(p, size));
                            // 块内绝对指针（混音效果顺序表、分路器目的地链、内存池地址信息）：落在 A 的块范围里的 8 字节对齐值按基址差平移
                            for (int o = 0; o + 8 <= size; o += 8) { ulong v = *(ulong*)(p + o); if (v >= old && v < old + (ulong)size) { *(ulong*)(p + o) = v - old + nw; moved++; } }
                            sys.S2ARestoreScalars(sc);
                            sys.S2AForceEffectReinit();
                        }
                        ok++;
                    }
                }
                Console.Error.WriteLine($"[s2a] 即时存档恢复：音频渲染器 {ok}/{n} 个会话拷回，块内指针平移 {moved} 处{(bad > 0 ? $"，失败 {bad}" : "")}");
                return bad;
            }
            catch (Exception e) { Console.Error.WriteLine($"[s2a] 【红】即时存档恢复：音频渲染器拷回失败 {e}"); return -1; }
        }
    }
}
