// 安卓侧共用文档根绑定（runtime/include/s2a_docs.h 的 S2A_DOCS 契约）：iOS / Mac 由
//   启动上下文（launchctx.c 冻结）把 S2A_DOCS 写进进程环境；安卓没有这个环节，
//   起局时由 runtime 入口把本局 state 目录绑上去——它是应用私有、按款、可写的
//   持久目录（GameSession.prepareState 的 <saveRoot>/ryujinx-android），与 iOS
//   <Documents>/games/<gid> 同口径。必须在任何 s2a_docs_path 消费者（dguard 的
//   wire/direct_guard、patch 的 S2A/patches、envfile 的 env.txt 等）运行之前调；
//   环境是进程级的，不影响别的平台。
#pragma once

// state_dir 绑成 S2A_DOCS（覆盖写，同 launchctx 的 put 语义；只认绝对路径）。
// 0 = 成功；errno = 参数不是绝对路径或 setenv 失败。
int s2a_android_docs_bind(const char *state_dir);

// 停帧救场的「这款下次也关」（Mac 同口径：pack/jobs/cheats.py note_stall 把它转成这款「60 帧 / 帧率」写关）：
//   runtime/src/cpatch.c s2a_cpatch_stall_rescue 当场关掉社区帧率补丁时在 <docs>/cpatch_stall_off 留标记。安卓没有按款的帧率设置，
//   标记本身就是这款的「帧率关」：起局时在能力清单（s2a_caps_apply）之前读，有标记且启动环境没给 S2A_FPS60 → 写 S2A_FPS60=0，
//   清单的「验过默认开」就不再写 1（caps.c 只在未设时写），fps.c 起局按关跟随，社区帧率补丁不开。标记不删（删了下次又开）。
// → 1 有标记、已写 S2A_FPS60=0；2 有标记、启动环境已给 S2A_FPS60（玩家 / 调试显式给的优先，不覆盖）；0 没标记；-errno 写环境失败
int s2a_android_stall_off_apply(const char *docs);
