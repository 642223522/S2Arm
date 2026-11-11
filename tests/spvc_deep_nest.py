#!/usr/bin/env python3
# 门禁手动：被 tests/spvc_deep_stack_test.sh 调（生成夹具），不单独跑
# 合成「嵌套 N 层 if」的片元着色器 SPIR-V（原创字节，不含任何游戏数据）：spirv-cross 出 MSL 时按嵌套深度递归，用来量翻译线程要多大的栈
# Deeply nested structured-if fragment shader as SPIR-V binary.
import struct, sys
N = int(sys.argv[1]); out = sys.argv[2]
words = []; ids = [0]
def nid(): ids[0] += 1; return ids[0]
def op(code, *ops): words.extend([((len(ops)+1) << 16) | code, *ops])
def s(st):
    b = st.encode() + b'\0'; b += b'\0' * (-len(b) % 4)
    return list(struct.unpack('<%dI' % (len(b)//4), b))
void, fn, boolt, f32, v4, pout = (nid() for _ in range(6))
outv, main, tru, f1, c4 = (nid() for _ in range(5))
body = []
op(17, 1)                                   # Capability Shader
op(14, 0, 1)                                # MemoryModel Logical GLSL450
words.extend([((3 + len(s("main")) + 1) << 16) | 15, 4, main, *s("main"), outv])  # EntryPoint Fragment
op(16, main, 7)                             # ExecutionMode OriginUpperLeft
op(71, outv, 30, 0)                         # Decorate Location 0
op(19, void); op(33, fn, void); op(20, boolt); op(22, f32, 32); op(23, v4, f32, 4); op(32, pout, 3, v4)
op(59, pout, outv, 3)                       # Variable Output
op(41, boolt, tru); op(43, f32, f1, 0x3f800000); op(44, v4, c4, f1, f1, f1, f1)
op(54, void, main, 0, fn); op(248, nid())   # Function, Label
merges = []
for i in range(N):
    t, m = nid(), nid(); merges.append(m)
    op(247, m, 0); op(250, tru, t, m); op(248, t)   # SelectionMerge, BranchConditional, Label
op(62, outv, c4)                            # Store
for m in reversed(merges):
    op(249, m); op(248, m)                  # Branch, Label
op(253); op(56)                             # Return, FunctionEnd
hdr = [0x07230203, 0x00010000, 0, ids[0] + 1, 0]
open(out, 'wb').write(struct.pack('<%dI' % (len(hdr) + len(words)), *hdr, *words))
