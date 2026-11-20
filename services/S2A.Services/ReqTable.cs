using System;
using System.Collections.Generic;

namespace S2A.Services
{
    // 即时存档请求日志的条目表（维护者 11-19：大小跟「此刻活着的服务对象」走，跟游戏玩了多久无关）。
    //   请求日志只为恢复时重建服务的状态：一个对象（会话 / 域对象）关掉、而且没有还活着的子对象时，发给它的请求、建它的那条、关它的那条一起删——
    //   文件开关、取服务又关、套接字开关这类按构造就收住，不靠逐个列表。删一条请求前问原生层它建的句柄还有没有活着的（活着的要靠重放这条建，不能删），
    //   删了让原生层把它建 / 关句柄的两条日志一起删（runtime/src/thread.c s2a_snap_seq_live / s2a_snap_hlog_forget）。
    //   条目按序号存、存档时按序号写出（每条带一份元数据，恢复局读回来接着按同一口径收）
    internal sealed class ReqTable
    {
        internal readonly record struct Key(ulong Cookie, int Obj);

        // Uses：这条消息里递的句柄（原生层建它的那条日志编号，删这条时解钉）；Deps：建那些句柄的请求（它们被这条钉住）；Creator：这条建过对象
        private sealed class Ent { public byte[] Data; public Key Target; public readonly List<Key> Created = new(); public readonly List<uint> Uses = new(); public readonly List<int> Deps = new(); public bool Creator; }
        private sealed class Obj { public int Creator = -1; public Key Parent; public bool HasParent; public readonly HashSet<int> Seqs = new(); public readonly HashSet<Key> Children = new(); public bool Closed; }

        private readonly SortedDictionary<int, Ent> _ents = new();
        private readonly Dictionary<Key, Obj> _objs = new();
        public Func<int, bool> HasLiveHandles = _ => false;
        public Action<uint> Unuse = _ => { };
        private readonly Dictionary<int, int> _pins = new();   // 序号 → 被几条留着的请求递过它建的句柄（钉住的不删）
        private bool Blocked(int seq) => HasLiveHandles(seq) || _pins.ContainsKey(seq);
        public Action<int> Forget = _ => { };
        public Action<Key> Gone = _ => { };
        public bool Collecting = true;        // 单测负对照用：关掉就不收（日志随请求次数涨）   // 一个对象从表里收掉了（按键覆盖的那几张表跟着删它的条目）
        public long Bytes { get; private set; }
        public int Count => _ents.Count;

        private Obj O(Key k) { if (!_objs.TryGetValue(k, out Obj o)) _objs[k] = o = new Obj(); return o; }

        public void Add(int seq, byte[] data, Key target)
        {
            if (_ents.TryGetValue(seq, out Ent old)) { Bytes -= old.Data.Length; old.Data = data; Bytes += data.Length; return; }
            _ents[seq] = new Ent { Data = data, Target = target }; Bytes += data.Length; O(target).Seqs.Add(seq);
        }

        // 同一条请求后面补的记录（交出的域对象号等）接在它的字节后面
        public void Append(int seq, byte[] more)
        {
            if (!_ents.TryGetValue(seq, out Ent e)) return;
            byte[] d = new byte[e.Data.Length + more.Length]; e.Data.CopyTo(d, 0); more.CopyTo(d, e.Data.Length);
            Bytes += more.Length; e.Data = d;
        }

        // 第 seq 条请求建出了对象 child（新会话 / 域对象）
        public void Created(int seq, Key child)
        {
            if (!_ents.TryGetValue(seq, out Ent e)) return;
            e.Created.Add(child); e.Creator = true;
            Obj o = O(child); o.Creator = seq; o.Parent = e.Target; o.HasParent = true; o.Closed = false;
            O(e.Target).Children.Add(child);
        }

        // 第 seq 条递了句柄（建它的日志编号 uid，建它的请求 creator，-1 = 不是请求建的）：creator 被钉住，第 seq 条删掉时放开
        public void Use(int seq, uint uid, int creator)
        {
            if (!_ents.TryGetValue(seq, out Ent e)) return;
            if (uid != 0) e.Uses.Add(uid);
            if (creator >= 0 && creator != seq) { e.Deps.Add(creator); _pins[creator] = _pins.GetValueOrDefault(creator) + 1; }
        }

        public void Close(Key k) { O(k).Closed = true; if (Collecting) Collect(k); }

        // 会话句柄关了：这个会话和它的全部域对象都算关
        public void CloseSession(ulong cookie)
        {
            var keys = new List<Key>(); foreach (Key k in _objs.Keys) if (k.Cookie == cookie) keys.Add(k);
            foreach (Key k in keys) if (_objs.TryGetValue(k, out Obj o)) o.Closed = true;
            if (Collecting) foreach (Key k in keys) Collect(k);
        }

        private void Remove(int seq)
        {
            if (!_ents.Remove(seq, out Ent e)) return;
            Bytes -= e.Data.Length; if (_objs.TryGetValue(e.Target, out Obj t)) t.Seqs.Remove(seq);
            Forget(seq);
            foreach (uint u in e.Uses) Unuse(u);
            foreach (int d in e.Deps)
            {   // 放开它钉住的：钉数归零后，那条（和它的对象）按原规则能收就收
                int n = _pins.GetValueOrDefault(d) - 1; if (n > 0) { _pins[d] = n; continue; }
                _pins.Remove(d);
                if (!Collecting || !_ents.TryGetValue(d, out Ent de)) continue;
                if (de.Creator && de.Created.Count == 0 && !HasLiveHandles(d)) { Remove(d); continue; }   // 建的对象早收了、只因被钉才留着的
                Collect(de.Target);
            }
        }

        private void Collect(Key k)
        {
            if (!_objs.TryGetValue(k, out Obj o) || !o.Closed || o.Children.Count > 0) return;
            foreach (int s in o.Seqs) if (Blocked(s)) return;   // 发给它的请求建过还活着的句柄：这些请求得留着，对象也留着
            foreach (int s in new List<int>(o.Seqs)) Remove(s);
            _objs.Remove(k); Gone(k);
            if (o.HasParent && _objs.TryGetValue(o.Parent, out Obj p)) p.Children.Remove(k);
            if (o.Creator >= 0 && _ents.TryGetValue(o.Creator, out Ent c))
            {
                c.Created.Remove(k);
                if (c.Created.Count == 0 && !Blocked(o.Creator)) Remove(o.Creator);   // 建它的那条只建了它（或建的都收了）：一起删
            }
            if (o.HasParent) Collect(o.Parent);   // 父对象先关了、在等子对象收完的：现在能收了
        }

        public IEnumerable<KeyValuePair<int, byte[]>> InOrder() { foreach (var kv in _ents) yield return new(kv.Key, kv.Value.Data); }

        // 元数据（恢复局读回来接着收）：每条 序号、目标、建出的对象；每个对象 是否已关（已关但还收不掉的）
        public void WriteMeta(System.IO.BinaryWriter w)
        {
            w.Write(_ents.Count);
            foreach (var kv in _ents)
            {
                w.Write(kv.Key); w.Write(kv.Value.Target.Cookie); w.Write(kv.Value.Target.Obj); w.Write(kv.Value.Created.Count);
                foreach (Key c in kv.Value.Created) { w.Write(c.Cookie); w.Write(c.Obj); }
                w.Write(kv.Value.Uses.Count); foreach (uint u in kv.Value.Uses) w.Write(u);
                w.Write(kv.Value.Deps.Count); foreach (int d in kv.Value.Deps) w.Write(d);
            }
            var closed = new List<Key>(); foreach (var kv in _objs) if (kv.Value.Closed) closed.Add(kv.Key);
            w.Write(closed.Count); foreach (Key k in closed) { w.Write(k.Cookie); w.Write(k.Obj); }
        }

        public void Clear() { _ents.Clear(); _objs.Clear(); _pins.Clear(); Bytes = 0; }
        // 恢复局接回元数据里的句柄依赖（原生层的钉数随句柄日志一起恢复，这里只接条目表这边）
        public void Restore(int seq, List<uint> uses, List<int> deps)
        {
            if (!_ents.TryGetValue(seq, out Ent e)) return;
            e.Uses.AddRange(uses); foreach (int d in deps) { e.Deps.Add(d); _pins[d] = _pins.GetValueOrDefault(d) + 1; }
        }
    }
}
