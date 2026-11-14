# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
# game 模式没显式给 S2A_ANDROID_CODEC_LIBS 时，按 android/codecs/build.sh 的缓存约定找三份编解码静态库。
# 静态服务（S2A_CS_SERVICES=static）不探测：cs/build.sh 已把本次刚编的三份写进 link.txt（并核过恰好三份），
# 链接时随 link.txt 一起进来。缓存目录名是配方哈希，按名排序取最后一个是任意一代；再把它加到链接行
# 最前面，旧一代的定义会先被链接器选中。
function(s2a_android_codec_archives out _codec_cache)
    if(S2A_CS_SERVICES STREQUAL "static")
        message(STATUS "Android game mode: codec archives come from cs/build.sh link.txt (static services)")
        return()
    endif()
    file(GLOB _avc "${_codec_cache}/codecs/*/libs2a_avc.a")
    file(GLOB _opus "${_codec_cache}/codecs/*/s2a-*/libs2a_opus.a")
    file(GLOB _vpx "${_codec_cache}/codecs/*/s2a-*/libs2a_vpx.a")
    if(_avc AND _opus AND _vpx)
        list(SORT _avc)
        list(SORT _opus)
        list(SORT _vpx)
        list(GET _avc -1 _avc)
        list(GET _opus -1 _opus)
        list(GET _vpx -1 _vpx)
        set(${out} "${_avc};${_opus};${_vpx}" PARENT_SCOPE)
        message(STATUS "Android game mode: codec archives auto-detected: ${_avc};${_opus};${_vpx}")
    else()
        message(WARNING "Android game mode: no codec archives found under ${_codec_cache}/codecs; run android/codecs/build.sh or pass -DS2A_ANDROID_CODEC_LIBS=\"a;b;c\" (link will fail with undefined avc/opus/vpx symbols)")
    endif()
endfunction()
