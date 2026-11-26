#!/bin/bash
# 门禁覆盖：graphics/dsx/dsx_abi.h graphics/nvn/gfx/nvn/nvn_refl.h graphics/nvn/gfx/nvn/nvn_refl.m graphics/nvn/gfx/nvn/nvn_mtl.m graphics/tools/direct/dsh/Dsh.cs graphics/tools/direct/dsh/S2A.Dsh.csproj tests/dsh_harden_contract_test.sh
# 直连着色器加固的宿主侧文本约定（从 tests/dsh_harden_test.sh 拆出：那支要编 libdsx、在 GPU 上真跑约 2.5 分钟，键原先跟着 nvn_mtl.m 这类改得最勤的大文件一起变；
#   这几条只读源码文本、几秒跑完，留在这里随这些文件变）。期望按约定手写：
#   Dsh.cs 出 MSL 前先加固（Compile 与曲面 TessMsl 各 1 处）、翻译指纹输入含 gal_spvx.c；宿主表长 NVN_UBOLEN_N = 加固表长 NXGAL_DIRECT_UBOLEN_N；
#   Dsh.cs 反射认 gal_ubo_len / spvBufferSizeConstants / gal_tbl_ 前缀，nvn_refl.m 认 ubolen / sbsize / tblead，nvn_mtl.m encode_args 填 ubolen / sbsize 两张表
set -u; H=$(cd "$(dirname "$0")/.." && pwd); bad=0
ck() { if [ "$2" = "$3" ]; then echo "✓ $1"; else echo "✗ $1：期望 $2，实际 $3"; bad=1; fi; }
D=$H/graphics/tools/direct/dsh
ck "Compile 的 Msl 本地函数先加固" 1 "$(grep -c 'Xc.Msl(NxgalSpvCross.Harden(XIo.ReadAllBytes(spvPath))' "$D/Dsh.cs")"
ck "曲面 TessMsl 先加固" 1 "$(grep -c 'NxgalSpvCross.TessMsl(NxgalSpvCross.Harden(' "$D/Dsh.cs")"
ck "翻译指纹输入含 gal_spvx.c（#783 加固代码所在）" 1 "$(grep -c 'DshXfpInput Include="$(Nx)../dsx/gal_spvx.c;' "$D/S2A.Dsh.csproj")"
ck "宿主表长与加固表长一致" "$(sed -n 's/^#define NXGAL_DIRECT_UBOLEN_N \([0-9]*\).*/\1/p' "$H/graphics/dsx/dsx_abi.h")" "$(sed -n 's/^#define NVN_UBOLEN_N \([0-9]*\).*/\1/p' "$H/graphics/nvn/gfx/nvn/nvn_refl.h")"
ck "Dsh.cs 反射认 gal_ubo_len / spvBufferSizeConstants" 2 "$(grep -c 'nm == "gal_ubo_len") e.Set("kind", "ubolen")\|nm == "spvBufferSizeConstants") e.Set("kind", "sbsize")' "$D/Dsh.cs")"
ck "nvn_refl.m 认 ubolen / sbsize" 2 "$(grep -c 'isEqualToString:@"ubolen"\]) r->kind = NVN_RB_UBOLEN\|isEqualToString:@"sbsize"\]) r->kind = NVN_RB_SBSZ' "$H/graphics/nvn/gfx/nvn/nvn_refl.m")"
ck "nvn_mtl.m encode_args 填两张表" 3 "$(grep -c 'b->kind == NVN_RB_UBOLEN) { ul_aid = aid\|b->kind == NVN_RB_SBSZ) { slots\[aid\] = len_fill\|slots\[ul_aid\] = len_fill(sh, nvn_stage, NVN_RB_UBOLEN, ubcap)' "$H/graphics/nvn/gfx/nvn/nvn_mtl.m")"
ck "Dsh.cs 反射认 gal_tbl_ 前缀（kind tblead）" 1 "$(grep -c 'StartsWith("gal_tbl_", StringComparison.Ordinal)) e.Set("kind", "tblead")' "$D/Dsh.cs")"
ck "nvn_refl.m 认 tblead" 1 "$(grep -c 'isEqualToString:@"tblead"\]) {' "$H/graphics/nvn/gfx/nvn/nvn_refl.m")"
[ $bad = 0 ] && echo "✓ dsh_harden_contract：全过" || echo "✗ dsh_harden_contract：有不通"
exit $bad
