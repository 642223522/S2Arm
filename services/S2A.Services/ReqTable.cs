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

        private sealed class Ent { public byte[] Data; public Key Target; public readonly List<Key> Created = new(); }
        private sealed class Obj { public int Creator = -1; public Key Parent; public bool HasParent; public readonly HashSet<int> Seqs = new(); public readonly HashSet<Key> Children = new(); public bool Closed; }

        private readonly SortedDictionary<int, Ent> _ents = new();
        private readonly Dictionary<Key, Obj> _objs = new();
        public Func<int, bool> HasLiveHandles = _ => false;
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
            e.Created.Add(child);
            Obj o = O(child); o.Creator = seq; o.Parent = e.Target; o.HasParent = true; o.Closed = false;
            O(e.Target).Children.Add(child);
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
        }

        private void Collect(Key k)
        {
            if (!_objs.TryGetValue(k, out Obj o) || !o.Closed || o.Children.Count > 0) return;
            foreach (int s in o.Seqs) if (HasLiveHandles(s)) return;   // 发给它的请求建过还活着的句柄：这些请求得留着，对象也留着
            foreach (int s in new List<int>(o.Seqs)) Remove(s);
            _objs.Remove(k); Gone(k);
            if (o.HasParent && _objs.TryGetValue(o.Parent, out Obj p)) p.Children.Remove(k);
            if (o.Creator >= 0 && _ents.TryGetValue(o.Creator, out Ent c))
            {
                c.Created.Remove(k);
                if (c.Created.Count == 0 && !HasLiveHandles(o.Creator)) Remove(o.Creator);   // 建它的那条只建了它（或建的都收了）：一起删
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
            }
            var closed = new List<Key>(); foreach (var kv in _objs) if (kv.Value.Closed) closed.Add(kv.Key);
            w.Write(closed.Count); foreach (Key k in closed) { w.Write(k.Cookie); w.Write(k.Obj); }
        }

        public void Clear() { _ents.Clear(); _objs.Clear(); Bytes = 0; }
    }
}
