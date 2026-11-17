// 出图补帧的逐帧判定（nvn_present_fi.inc 用，单测 graphics/nvn/tests/t_nvn_fi_rule.c）。
// 只给游戏自己按 30 帧档（交换间隔 2）或更低档推进、并且这一帧跑满了自己节拍的帧补到显示刷新率；游戏声明 60 帧档（交换间隔 1）的一律不补：
//   60 帧档实际跑不满（掉到 30–40）时补出来是更顺滑的慢动作，游戏节拍是错的。档位只看游戏声明的节拍（交换间隔折成的出图周期），不看实测帧率；
//   「跑满」看这一帧与上一帧游戏交帧的间隔是否在声明周期的 1.25 倍以内，跑不满的那一帧原图直接上屏、不补
// declared_period：游戏声明的出图节拍（秒，hle_nvn.c present_period：交换间隔 × 刷新周期）；gap：这一帧与上一帧游戏交帧的间隔（秒，第一帧给 0）
#pragma once
static inline int dm_fi_should_interp(double declared_period, double gap) {
    if (!(declared_period >= 1.0 / 45)) return 0;   // 60 帧档（16.7 ms）及以上不补；30 帧档 33.3 ms、20 帧档 50 ms 补
    return gap > 0 && gap <= declared_period * 1.25;
}
