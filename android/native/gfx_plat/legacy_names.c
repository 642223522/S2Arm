// 层外代码（bridge.cpp）还在按旧层的名字调用的入口。新层里它们无事可做：留空实现让层外不用跟着改。
// 旧层删除时，连同 bridge.cpp 里的调用点一起删掉本文件。
#include <stdint.h>

void s2a_fd_set_draw_log(int on) { (void)on; }       // Java NativeBridge.setDrawLog：旧绘制路径的逐笔日志开关
void nvn_vk_callring_dump(int fd) { (void)fd; }      // 崩溃现场：旧层的最近 Vulkan 调用环
