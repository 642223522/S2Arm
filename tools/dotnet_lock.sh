#!/bin/bash
# 同一棵树里的 C# 编译串行（11-10 判据去负载化：门禁各步并行编同一批 compat/tree 工程，共用 obj/ 互踩——
#   10-31 services 钩子 MSB4018 写 Ryujinx.HLE.deps.json 失败、save_transfer_interop 打包 Ryujinx.Memory.nupkg 被占用、CS0006 找不到引用程序集）。
#   用法同 dotnet：tools/gate.sh 给各步设 DOTNET=本脚本、并在 PATH 最前放同名入口。编译类子命令（build / publish / restore / pack / msbuild / test / clean）
#   先拿本树的内核文件锁（tools/flock_hold.py，持锁者 = exec 后的 dotnet 进程本身，退出即放）；其余（dotnet x.dll、--info …）直接跑。
#   关 MSBuild 常驻节点（MSBUILDDISABLENODEREUSE=1）：常驻节点在构建结束后仍攥着输出文件，下一份构建写同一文件被占。
#   等锁时每 30 秒打一行，免得被门禁的无进展看门狗（tools/nostall.py）当成挂死。真 dotnet：S2A_DOTNET_REAL，缺省 ~/.dotnet/dotnet
real=${S2A_DOTNET_REAL:-$HOME/.dotnet/dotnet}
export MSBUILDDISABLENODEREUSE=1
case "${1:-}" in build|publish|restore|pack|msbuild|test|clean) ;; *) exec "$real" "$@";; esac
H=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd); lk=$H/build/.dotnet_build.lock; mkdir -p "${lk%/*}" || exec "$real" "$@"
w0=$SECONDS; lw=$SECONDS
until python3 "$H/tools/flock_hold.py" "$lk" $$ take dotnet_lock > /dev/null 2>&1; do
  [ $((SECONDS - lw)) -ge 30 ] && { lw=$SECONDS; echo "等本树 C# 构建锁（${lk}）已 $((SECONDS - w0)) 秒：别的步正在编 C#" >&2; }
  sleep 1; done
[ $((SECONDS - w0)) -ge 2 ] && echo "C# 构建锁：等了 $((SECONDS - w0)) 秒" >&2
exec "$real" "$@"
