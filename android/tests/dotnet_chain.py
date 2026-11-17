"""真编译器链测试共用（gs_compiler_chain_test / tbuf_compiler_chain_test）：先单独 dotnet build、再 dotnet run --no-build。

门禁里同一钩子有几条链并行编同一个编译器工程，dotnet run 现编时常驻的编译服务器 / 节点被别处收掉，
run 那一步拿到空输出、退出码却是 0（11-16 main 上 android_vk_test 的 JSONDecodeError 短红，紧挨一行 Terminated: 15）。
照 android/cs/build.sh --direct-identity：关节点复用与编译服务器单独 build、日志落盘，再 --no-build 运行；
非零退出、要输出却是空，当场报红并打出编译日志尾部，不留到下游 json.loads 才炸。"""
import os
import subprocess
import sys
from pathlib import Path

ENV = dict(os.environ, MSBUILDDISABLENODEREUSE='1', DOTNET_CLI_USE_MSBUILD_SERVER='0',
           DOTNET_CLI_TELEMETRY_OPTOUT='1', DOTNET_NOLOGO='1')
_built = {}


def _red(msg, log=None):
    tail = ''
    if log and Path(log).is_file():
        tail = '\n'.join(Path(log).read_text(errors='replace').splitlines()[-40:])
    sys.exit(f'【红】{msg}' + (f'\n编译日志尾部（{log}）：\n{tail}' if tail else ''))


def build(project, log_dir):
    """每个工程本进程只编一次；日志写 log_dir/<工程名>.build.log"""
    p = str(project)
    if p in _built:
        return _built[p]
    log = Path(log_dir) / (Path(p).name + '.build.log')
    log.parent.mkdir(parents=True, exist_ok=True)
    with open(log, 'w') as f:
        rc = subprocess.run(['dotnet', 'build', p, '-c', 'Release', '-nologo', '--disable-build-servers', '-nodeReuse:false'],
                            stdout=f, stderr=subprocess.STDOUT, env=ENV).returncode
    if rc:
        _red(f'dotnet build {Path(p).name} 失败（rc={rc}）', log)
    _built[p] = log
    return log


def run(project, args, log_dir, capture=False):
    """dotnet run --no-build；capture=True 返回 stdout（空就报红）。失败一律报红"""
    log = build(project, log_dir)
    cmd = ['dotnet', 'run', '--no-build', '-c', 'Release', '--project', str(project), '--', *map(str, args)]
    r = subprocess.run(cmd, env=ENV, capture_output=capture, text=True)
    if r.returncode:
        _red(f'{" ".join(map(str, args[:1]))}：dotnet run 退出 {r.returncode}' + (f'；stderr：{r.stderr[-800:]}' if capture else ''), log)
    if capture:
        if not r.stdout.strip():
            _red(f'{" ".join(map(str, args[:1]))}：dotnet run 退出 0 但输出为空', log)
        return r.stdout
    return None


def run_result(project, args, log_dir):
    """要看退出码的调用（负对照会故意失败）：编译失败报红，运行结果原样返回 CompletedProcess"""
    build(project, log_dir)
    cmd = ['dotnet', 'run', '--no-build', '-c', 'Release', '--project', str(project), '--', *map(str, args)]
    return subprocess.run(cmd, env=ENV, capture_output=True, text=True)
