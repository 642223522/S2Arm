# Apple TV 版内测说明 / Apple TV Beta Guide

> 开发者预览：Apple TV 版的代码已写完，但开发组没有 Apple TV，**还没在真机上跑过**。你装上之后遇到的任何问题都很有价值，请按文末办法把诊断传给我们。
> Developer preview: the Apple TV build is code-complete, but the team has no Apple TV, so it **has not run on real hardware yet**. Anything you hit is valuable — please send diagnostics as described at the end.

## 需要什么 / What you need

| 项 | 要求 |
|---|---|
| Apple TV | Apple TV 4K（第三代，A15）或更新，tvOS 26 及以上 |
| 电脑 | Apple 芯片的 Mac，装好 Xcode（Xcode → 设置 → 账户 里登录你的 Apple ID） |
| Apple 账号 | **建议付费开发者账号**（Apple Developer Program）。免费账号能装，但 tvOS 上「提高内存上限」权限会被系统丢掉，能不能起局要靠你的反馈确认 |
| 手柄 | 扩展手柄（Xbox / PlayStation / 8BitDo 等）。Siri 遥控器只能在游戏库里移动选择，玩不了游戏 |
| S2Arm | Mac 版 S2Arm（内测版，带「Apple TV」出包选项） |

| Item | Requirement |
|---|---|
| Apple TV | Apple TV 4K (3rd gen, A15) or newer, tvOS 26 or later |
| Computer | Apple-silicon Mac with Xcode, signed in with your Apple ID (Xcode → Settings → Accounts) |
| Apple account | **A paid Apple Developer Program account is recommended.** A free account can install, but tvOS silently drops the Increased Memory Limit entitlement for it; whether games start then is something we need your feedback on |
| Controller | An extended gamepad (Xbox / PlayStation / 8BitDo …). The Siri Remote can browse the library but cannot play |
| S2Arm | The Mac S2Arm beta with the "Apple TV" export option |

付费账号还要在 Apple 开发者网站给这款 App 的 App ID 开两项能力：Increased Memory Limit（提高内存上限）和 Extended Virtual Addressing（扩展虚拟寻址）。S2Arm 出包时自动申请描述文件；如果报「需要付费开发者账号」，就是这一步没过。
With a paid account, enable two capabilities on the app's App ID at developer.apple.com: Increased Memory Limit and Extended Virtual Addressing. S2Arm requests the provisioning profile automatically; an error saying a paid developer account is required means this step failed.

## 一次性：配对 Apple TV / One-time: pair the Apple TV

1. Apple TV 和 Mac 连同一个网络。 / Put the Apple TV and the Mac on the same network.
2. Apple TV：设置 → 遥控器与设备 → 遥控 App 与设备。 / Apple TV: Settings → Remotes and Devices → Remote App and Devices.
3. Mac：Xcode → Window → Devices and Simulators，选中出现的 Apple TV，点「Pair」，输入电视上显示的配对码。 / Mac: Xcode → Window → Devices and Simulators, select the Apple TV, click Pair and enter the code shown on the TV.

## 出包并装到 Apple TV / Export and install

1. 在 S2Arm 里照常导入游戏（同 iPhone）。 / Import the game in S2Arm as usual (same as for iPhone).
2. 出包页勾「Apple TV」，点出包。第一次出 Apple TV 包会多两步：把贴图预转成 Apple TV 能直接用的格式（只做一次，几分钟）、出 Apple TV 预编壳。 / On the export page tick "Apple TV" and export. The first Apple TV export adds two steps: converting textures to a format the Apple TV can use directly (once, a few minutes) and building the Apple TV shell.
3. 在出包页选你的 Apple TV，点「装到 Apple TV」。游戏资源（几 GB）经网络推到电视上，第一次较慢。 / Pick your Apple TV on the export page and click "Install to Apple TV". The game data (several GB) is pushed over the network, so the first time is slow.
4. 电视上打开 S2Arm：游戏库里用遥控器或手柄选游戏、按确定开始。 / Open S2Arm on the TV: pick a game with the remote or a controller and press select to start.

免费账号的安装 7 天后会打不开，在 S2Arm 里再点一次「装到 Apple TV」续上。
Installs signed with a free account stop opening after 7 days; click "Install to Apple TV" again in S2Arm to renew.

## 存档 / Saves

- tvOS 会在空间紧张时清掉 App 的缓存目录（游戏资源和存档都在那里）。S2Arm 每次切到后台时把存档压缩存进系统偏好（不会被清），资源被清了下次进游戏前会自动还原存档；资源本身要回电脑再点一次「装到 Apple TV」。
- Mac 端每 30 分钟自动把电视上的存档备份回电脑（游戏库里这款的存档备份目录，每款保留最近 10 份）。
- tvOS may purge the app's cache folder (where game data and saves live) when storage runs low. S2Arm copies saves into the system preferences (which are kept) whenever it goes to the background and restores them before the next game; the game data itself needs another "Install to Apple TV" from the Mac.
- The Mac backs up the TV's saves every 30 minutes (this game's save-backup folder in the library, latest 10 kept).

## 出了问题怎么告诉我们 / Reporting problems

1. 在 Mac 版 S2Arm 里「拉回诊断」（会列出 Apple TV），拉回后点上传，拿到短码。 / In Mac S2Arm use "Pull diagnostics" (the Apple TV is listed), then upload and get the short code.
2. 在 GitHub 发帖，写上短码、Apple TV 型号与 tvOS 版本、账号是付费还是免费、哪款游戏、出现了什么。 / Open a GitHub issue with the short code, Apple TV model and tvOS version, paid or free account, which game, and what happened.

我们特别想知道：能不能进游戏、大概多久被系统结束（如果有）、画面和声音是否正常、手柄是否全键可用。
We especially want to know: whether the game starts, how long until the system ends it (if it does), whether picture and sound are right, and whether every controller button works.
