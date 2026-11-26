#pragma once
#include <cstdint>
#include <string>
struct OhosControllerStatus { bool available; bool connected; std::string name; std::string detail; };
void ohos_controller_init(void *engine,void (*input)(uint32_t,int32_t,int32_t,int32_t,int32_t));
void ohos_controller_touch(uint32_t buttons,int32_t lx,int32_t ly,int32_t rx,int32_t ry);
void ohos_controller_block(bool blocked);
void ohos_controller_foreground(bool foreground);
void ohos_controller_game_feedback(bool enabled);
void ohos_controller_stop_feedback();
OhosControllerStatus ohos_controller_status();
