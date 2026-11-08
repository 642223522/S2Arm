#!/usr/bin/env python3
"""Mac GUI command bridge. Compilation belongs to S2Arm's existing scripts.

Reuse the launcher's job/log/cancellation protocol without changing pack/jobs.
No engine stages, resource conversion or platform packaging are implemented here.
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import shutil
import signal
import sys
import threading
import uuid

HERE = Path(__file__).resolve().parent
SHARED = HERE.parent / "Jobs"
if not (SHARED / "core.py").is_file():
    SHARED = HERE.parents[2] / "pack/jobs"
sys.path.insert(0, str(SHARED))
sys.path.insert(0, str(HERE))  # -I excludes the script directory from sys.path.
from core import Cancelled, Context, Failure

REPOSITORY = "https://github.com/jhaizhou-ops/S2Arm.git"
ENTRIES = {"android": "android/docker/build.sh",
           "ohos": "runtime/ohos/build.sh"}


def platform_source(c):
    """Reuse the installed engine first, then an app-managed optional component.

    Old user-selected source/output/SDK preferences are intentionally ignored.
    """
    entry = ENTRIES[c.r["target"]]
    if c.r["target"] == "android":
        # Android packaging and shared stages must come from one engine identity.
        return c.engine if (c.engine / entry).is_file() else None
    for root in (c.engine, c.private / "platform-sources" / c.r["target"]):
        if (root / entry).is_file():
            return root
    return None


def ohos_ndk(c):
    candidates = [Path(os.environ[key]).expanduser() for key in ("OHOS_NDK",) if os.environ.get(key)]
    candidates.append(c.private / "toolchains/ohos/native")
    for key in ("OHOS_SDK_HOME", "DEVECO_SDK_HOME"):
        if os.environ.get(key):
            sdk = Path(os.environ[key]).expanduser()
            candidates += [sdk / "native", sdk / "openharmony/native"]
            candidates += sorted(sdk.glob("*/native"), reverse=True)
    # Discover installed SDKs in DevEco app bundles; no compiler path is exposed
    # in the player UI. Missing SDKs remain unavailable rather than prompting for
    # a source/build directory.
    for applications in (Path("/Applications"), Path.home() / "Applications"):
        for app in sorted(applications.glob("*DevEco*.app")):
            candidates += sorted((app / "Contents").glob("sdk/**/native"), reverse=True)
    for ndk in candidates:
        if (ndk / "sysroot").is_dir() and any(os.access(ndk / ("llvm/bin/" + name), os.X_OK)
                                             for name in ("clang", "clang.exe")):
            return ndk.resolve()
    return None


def output_directory(c):
    return c.private / "exports" / c.r["target"] / "native"


def source_environment(c):
    env = c.env()
    # Source builds need the host SDK, rather than the app's runtime-only .NET.
    for key in ("DOTNET_ROOT", "DOTNET_MULTILEVEL_LOOKUP", "S2A_PREBUILT_TOOLS"):
        env.pop(key, None)
    paths = [str(Path(sys.executable).parent), "/opt/homebrew/bin", "/usr/local/bin",
             "/usr/bin", "/bin", "/usr/sbin", "/sbin", env.get("PATH", "")]
    env["PATH"] = os.pathsep.join(dict.fromkeys(paths))
    env.update(S2A_TARGET=c.r["target"], S2A_PACK_PLAT=c.r["target"],
               DOCKER_DEFAULT_PLATFORM="linux/amd64", S2ARM_ANDROID_IMAGE="s2arm-android-build:1",
               S2ARM_ANDROID_CS_SERVICES="static", GIT_TERMINAL_PROMPT="0")
    developer = env["DEVELOPER_DIR"].replace("\\", "\\\\").replace(" ", "\\ ")
    env["MAKEFLAGS"] = "-- DEVELOPER_DIR=" + developer
    return env


def environment_checks(c):
    """Read paths and invoke only existing tool inspection commands; never install."""
    target = c.r["target"]
    source = platform_source(c)
    env = source_environment(c)
    checks = []

    def add(name, ok, message):
        checks.append(dict(name=name, ok=bool(ok), message=message))

    def probe(args):
        # Use Context.run for the same process ownership/cancellation as builds.
        # The shell's conditional turns a missing tool into a check, not a failed job.
        lines = []
        command = 'if "$@"; then echo S2ARM_CHECK_OK; fi'
        c.run(["/bin/bash", "-c", command, "s2arm-check", *args], env=env,
              on_line=lines.append)
        return lines, "S2ARM_CHECK_OK" in lines

    add("平台支持", source is not None, "已复用 S2Arm 提供的平台功能。" if source else "请先添加此平台支持。")
    if target == "android":
        _, ok = probe(["docker", "image", "inspect", "s2arm-android-build:1"])
        add("Docker 工具链", ok, "Docker 需运行，镜像 s2arm-android-build:1 需准备完成")
        gradle = source / "android/app/build.gradle" if source else None
        activity = source / "android/app/src/main/java/org/s2arm/android/LibraryActivity.java" if source else None
        runtime = bool(gradle and gradle.is_file() and "s2arm.nativeMode" in gradle.read_text() and activity.is_file())
        add("安卓游戏运行时", runtime, "游戏运行时已接入。" if runtime else "安卓游戏运行时尚未接入。")
    else:
        ndk = ohos_ndk(c)
        add("OpenHarmony NDK", ndk is not None,
            "已自动识别 OpenHarmony NDK。" if ndk else "请安装 DevEco Studio 与 OpenHarmony NDK 后重新检查。")
    return checks


def android_build(c):
    # The engine owns the production target adapter, while this bridge retains
    # the launcher's existing Context, cancellation and private job storage.
    sys.path.insert(0, str(c.engine))
    from pack.targets.android.adapter import build
    return build(c)


def dispatch_build(c):
    c.begin("检查编译配置")
    checks = environment_checks(c)
    missing = [item["name"] for item in checks if not item["ok"]]
    if missing:
        raise Failure("编译条件未满足：" + "、".join(missing))
    source = platform_source(c)
    target = c.r["target"]
    env = source_environment(c)
    args = ["/bin/bash", str(source / ENTRIES[target])]
    if target == "android":
        return android_build(c)
    else:
        output = output_directory(c)
        env["OHOS_NDK"] = str(ohos_ndk(c))
        args += [str(output)]
    c.begin("执行源码编译入口")
    c.run(args, env=env, cwd=source)
    if not output.exists():
        raise Failure("源码入口已结束，但未找到输出，请查看日志。")
    return dict(outputPath=str(output), target=target)


def download_source(c):
    available = platform_source(c)
    if available:
        return dict(componentsReady=True, target=c.r["target"])
    if c.r["target"] == "android":
        raise Failure("内置安卓组件缺失，请安装完整的最新版 S2Arm。")
    target = c.r["target"]
    destination = c.private / "platform-sources" / target
    if destination.exists():
        raise Failure("平台组件不完整，请检查任务日志或重新安装应用。")
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.with_name(target + "." + uuid.uuid4().hex + ".partial")
    branch = "ohos/harmony-port" if target == "ohos" else "main"
    c.begin("下载所选平台源码")
    try:
        c.run(["/usr/bin/git", "clone", "--depth", "1", "--single-branch", "--branch", branch,
               REPOSITORY, str(temporary)], env=source_environment(c), cwd=c.private)
        c.check()
        if not (temporary / ENTRIES[target]).is_file():
            raise Failure("平台组件不完整，请检查任务日志或重新安装应用。")
        temporary.rename(destination)
    finally:
        if temporary.exists():
            shutil.rmtree(temporary)
    return dict(componentsReady=True, target=target)


def prepare_tools(c):
    source = platform_source(c)
    if c.r["target"] != "android" or not source or not (source / "android/docker/Dockerfile").is_file():
        raise Failure("请先添加安卓平台支持。")
    c.begin("由源码 Dockerfile 准备工具链")
    c.run(["docker", "build", "--platform", "linux/amd64", "-t", "s2arm-android-build:1",
           str(source / "android/docker")], env=source_environment(c), cwd=source)
    return dict(target="android")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--request", required=True)
    path = Path(parser.parse_args().request)
    if path.stat().st_mode & 0o077 or path.stat().st_uid != os.getuid():
        raise SystemExit("request must be owned by this user and private (0600)")
    request = json.loads(path.read_text())
    if request.get("schema") != 1 or request.get("target") not in ENTRIES:
        raise SystemExit("unsupported GUI request")
    c = Context(request)
    c.job["target"] = request["target"]
    signal.signal(signal.SIGTERM, lambda *_: c.stop())
    signal.signal(signal.SIGINT, lambda *_: c.stop())
    ended = threading.Event()

    def supervise():
        while not ended.wait(1):
            if request.get("parentPid"):
                try:
                    os.kill(int(request["parentPid"]), 0)
                except ProcessLookupError:
                    c.stop()
            if not c.cancelled:
                c.emit("heartbeat")

    threading.Thread(target=supervise, daemon=True).start()
    try:
        # Use the same verified writable engine installation as Mac jobs. GUI
        # requests never ask the player to locate or choose compilation code.
        from embedded import install
        install(c)
        if c.operation == "platformCheck":
            c.begin("检查编译配置")
            result = dict(checks=environment_checks(c))
        elif c.operation == "platformBuild":
            result = dispatch_build(c)
        elif c.operation == "platformSource":
            result = download_source(c)
        elif c.operation == "platformSetup":
            result = prepare_tools(c)
        else:
            raise Failure("不支持的界面任务。")
        c.check()
        ended.set()
        c.finish("completed", "操作完成", result)
        return 0
    except (Cancelled, KeyboardInterrupt):
        ended.set()
        c.finish("cancelled", "任务已取消。")
        return 130
    except Exception as error:
        ended.set()
        message = str(error) if isinstance(error, Failure) else "界面任务失败：" + c.redact(error)
        if not c.job["diagnostics"]:
            c.diagnostic(message)
        c.finish("failed", message)
        return 1
    finally:
        ended.set()


if __name__ == "__main__":
    sys.exit(main())
