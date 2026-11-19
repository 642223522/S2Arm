# 随包 Impactor / plumesign 的补丁（基于上游 claration/Impactor v2.7.3 的修改版）

随包的 Impactor 与 plumesign 由 `tools/plumesign_build.py` 从上游 v2.7.3 源码（标签提交 2ba32ea4，源码树 7e4416b8）
打上本目录的补丁后编出；许可照上游：Impactor 为 MIT（`../LICENSE-Impactor-MIT.txt`），内嵌的 apple-codesign 0.29.0 为
MPL-2.0（`../LICENSE-apple-codesign-MPL-2.0.txt`）。

## 0001-anisette-v3-server.patch

- 现象：Windows / Mac 上用随包 Impactor 登录 Apple ID，部分账号被 Apple 拒绝：
  `Authentication SRP error -23782: A Mac with macOS 10.13 or later is required`。
- 原因：上游写死的 anisette v3 服务器 `mac-ani.jkcoxson.com` 的 `/v3/client_info` 报
  `<MacBookPro13,3> <Mac OS X;10.12.6;16G29>`，plumesign 把它原样作为 `X-Mme-Client-Info` 发给 Apple；
  Apple 对部分账号要求 macOS 10.13 以上。v2.7.2 时这个值被转成小写，Apple 解析不了，回 HTTP 403；
  v2.7.3（上游 PR #317）改成原样发送后，就变成上面的 -23782。
- 为什么不直接整体换服务器：Apple 把登录会话和 anisette 服务器绑在一起，换服务器后所有已登录的账号都要重新输密码和验证码
  （11-18 实测：同一份数据目录，官方 2.7.3 照常，换了服务器的版本两个账号都报「会话已过期」，沿用旧开通数据也一样）。
- 改法（被拒才换）：
  1. `3rdparty/omnisette/src/lib.rs`：默认服务器不动；新增备用服务器 `https://ani.sidestore.io`（其 `client_info` 报 `<macOS;13.1;22C65>`）。
     数据目录里有 `anisette-v3-url` 文件时改用文件里的服务器；开通状态按服务器分文件（默认服务器仍是 `state.plist`，已有数据照常有效，
     备用服务器是 `state-ani.sidestore.io.plist`）。
  2. `3rdparty/omnisette/src/remote_anisette_v3.rs`：开通状态文件名按服务器取（同上）。
  3. `crates/plume_core/src/auth/account/login.rs`：登录在默认服务器上被 Apple 以 SRP -23782 拒绝时，在数据目录记下备用服务器、
     写一行日志（哪个账号、从哪台换到哪台、原因），用第一次拿到的账号密码在备用服务器上重试一次（-23782 出在 SRP 这一步，
     在双重认证之前，玩家不会多输一次验证码）；之后这个数据目录一直用备用服务器。别的错误、已在备用服务器上又被拒，都不重试。
     控制流抽成 `login_with_anisette_fallback`（`account/mod.rs` 导出），`check/login_fallback_check.rs` 用假的登录模拟上面五种情况，
     `tools/plumesign_build.py` 编之前跑。
  4. `apps/plumeimpactor/src/screen/settings.rs`：「重置 anisette 数据」删掉各服务器的开通状态文件。

## 自编产物（v2.7.3-s2a1）

| 平台 | 文件 | SHA-256 | Rust |
|---|---|---|---|
| Windows | plumesign-windows-x86_64.exe | 84ce275398d2fa008eadbd11b2a6da2ffe012d18e1dd874cf1814bddc9f2c2d1 | 1.99.1 |
| Windows | Impactor-windows-x86_64-portable.exe | 1748e5595cc8750fb34cf48d7265d65d3cd6d07dced23a4595a0c5b5f028ab23 | 1.99.1 |
| macOS | plumesign-macos-universal | d3ca590e1e92a1e7416f1c27c1ec6749c4ad05389c9c8724faaa53bbf63ce511 | 1.94.0 |

可重复：同一台机器、两个工作目录各编一次（Mac 先清空固定编译目录），产物逐字节相同（11-18 核过）。
