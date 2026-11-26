"""Switch 1 (NVN1) shader keys, the one Python copy of the rule (the host's is graphics/nvn/gfx/nvn/nvn_key.h; each side is checked against hand-computed digests).

Key = sha256(the first nctl bytes of the control section + the code area)[:16], nctl = 0x880, or the section's own length at +0x20 when that is in [0x760, 0x880)
(SDK 10's shorter sections). Generation 2 zeroes [0x790, 0x798) and [0x7d0, 0x7e8) of those bytes before hashing (only the part inside nctl): shaders with the same
code differ there (a hash the compiler writes, fields the runtime writes) while their translations are byte for byte the same (the maintainers checked 383 pairs); with
generation 1 seven to eight in ten of a Unity game's library were such duplicates, and players still hit keys missing from the library that differed only there.
Offline tools and packing write generation 2 only. Generation 1 is kept for reading what older builds wrote (runtime dumps named by their key, see rt_dump_merge.py);
the host falls back to it at run time for packages built before (hle_nvn.c keys_hash).
Switch 2 (NVN2) control sections have their own rule (ns2_shaders.key_ctl); skey dispatches to it."""
import hashlib, os, struct, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ns2_shaders as ns2

CTL_MAX, CTL_MIN = 0x880, 0x760
VOLATILE = ((0x790, 0x798), (0x7d0, 0x7e8))   # generation 2 zeroes these [begin, end) spans


def ctl_len(ctl):
    """Control bytes in a Switch 1 key: the section's own length at +0x20 when in [0x760, 0x880), else 0x880."""
    n = struct.unpack_from('<I', ctl, 0x20)[0]
    return n if CTL_MIN <= n < CTL_MAX else CTL_MAX


def key_bytes(ctl, gen=2):
    """The hashed control bytes, ctl as given (callers slice it to the key length); generation 2 zeroes the volatile spans inside it."""
    if gen == 1: return bytes(ctl)
    b = bytearray(ctl)
    for lo, hi in VOLATILE:
        if lo < len(b): b[lo:min(hi, len(b))] = bytes(min(hi, len(b)) - lo)
    return bytes(b)


def skey(ctl, code, gen=2):
    """The runtime key (16 hex digits) of a control section and its code area; NVN2 sections take the Switch 2 rule (no generations)."""
    if ns2.is_nvn2(ctl): return hashlib.sha256(ns2.key_ctl(ctl) + code).hexdigest()[:16]
    return hashlib.sha256(key_bytes(ctl[:ctl_len(ctl)], gen) + code).hexdigest()[:16]
