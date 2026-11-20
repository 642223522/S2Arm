using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Threading;

namespace Ryujinx.HLE.HOS.Services.Nv.NvDrvServices.NvMap
{
    class NvMapIdDictionary
    {
        private readonly ConcurrentDictionary<int, NvMapHandle> _nvmapHandles;
        private int _id;

        public ICollection<NvMapHandle> Values => _nvmapHandles.Values;

        public NvMapIdDictionary()
        {
            _nvmapHandles = new ConcurrentDictionary<int, NvMapHandle>();
        }

        public int Add(NvMapHandle handle)
        {
            int id = Interlocked.Add(ref _id, 4);

            if (id != 0 && _nvmapHandles.TryAdd(id, handle))
            {
                return id;
            }

            throw new InvalidOperationException("NvMap ID overflow.");
        }

        public NvMapHandle Get(int id)
        {
            if (_nvmapHandles.TryGetValue(id, out NvMapHandle handle))
            {
                return handle;
            }

            return null;
        }

        public NvMapHandle Delete(int id)
        {
            if (_nvmapHandles.TryRemove(id, out NvMapHandle handle))
            {
                return handle;
            }

            return null;
        }

        public ICollection<NvMapHandle> Clear()
        {
            ICollection<NvMapHandle> values = _nvmapHandles.Values;

            _nvmapHandles.Clear();

            // S2Arm: Clear is the session reset (NvMapDeviceFile.S2AReset) of an in-process restart. Numbering restarts too, as in a new
            // process: an instant snapshot replays the logged nvmap Create calls and later requests name the handles by the numbers they had
            // when logged (left running on, the replayed handles got other numbers and the video channel's maps all failed: video frozen)
            Interlocked.Exchange(ref _id, 0);

            return values;
        }
    }
}
