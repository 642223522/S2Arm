cmake_minimum_required(VERSION 3.16)
project(s2arm_ohos_shell LANGUAGES C CXX)
set(CMAKE_CXX_STANDARD 17)
add_library(s2aprobehost SHARED bridge_ohos.cpp controller_ohos.cpp)
target_compile_options(s2aprobehost PRIVATE -Wall -Wextra)
target_link_options(s2aprobehost PRIVATE -Wl,--no-undefined)
target_link_libraries(s2aprobehost PRIVATE libace_napi.z.so libace_ndk.z.so libhilog_ndk.z.so libnative_window.so libohgame_controller.z.so libohvibrator.z.so dl)
# The engine is loaded explicitly at runtime. Shell-only builds need no game or engine binary.
