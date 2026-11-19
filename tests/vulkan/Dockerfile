# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
# Official Microsoft SDK 10.0.403 noble multi-architecture manifest, verified
# against mcr.microsoft.com; apt packages come from one signed Ubuntu snapshot.
FROM --platform=linux/amd64 mcr.microsoft.com/dotnet/sdk:10.0.403-noble@sha256:de4fe90a98845d75910b9769662465c84de1a934665c431279d1382b2bddc02b
ARG APT_SNAPSHOT=20261030T000000Z
RUN apt-get update --snapshot "$APT_SNAPSHOT" \
 && apt-get install -y --no-install-recommends --snapshot "$APT_SNAPSHOT" \
      python3 git build-essential libvulkan-dev mesa-vulkan-drivers \
      vulkan-tools glslc spirv-tools curl ca-certificates xz-utils \
 && rm -rf /var/lib/apt/lists/*
# Khronos validation layer 1.4.341 from the official LunarG SDK (noble's package is 1.3.275, which lacks
# syncval_shader_accesses_heuristic: android/tests/vk/run_compute_read.sh exits 75 on it). Same VVL version as the
# GitHub CI runner. Pinned by the SDK's published sha256; only the layer library and its manifest are installed,
# in the system locations the test scripts search first.
ARG VVL_SDK=1.4.341.0
ARG VVL_SDK_SHA256=ed66477d587a5587dc3601b1c2cdcc1fab5529c505f53a00171876cecd9b4fbe
RUN curl -fsSL -o /tmp/vulkansdk.tar.xz "https://sdk.lunarg.com/sdk/download/${VVL_SDK}/linux/vulkansdk-linux-x86_64-${VVL_SDK}.tar.xz" \
 && echo "${VVL_SDK_SHA256}  /tmp/vulkansdk.tar.xz" | sha256sum -c - \
 && tar -xJf /tmp/vulkansdk.tar.xz -C /tmp "${VVL_SDK}/x86_64/lib/libVkLayer_khronos_validation.so" \
      "${VVL_SDK}/x86_64/share/vulkan/explicit_layer.d/VkLayer_khronos_validation.json" \
 && install -m 0644 "/tmp/${VVL_SDK}/x86_64/lib/libVkLayer_khronos_validation.so" /usr/lib/x86_64-linux-gnu/ \
 && install -D -m 0644 "/tmp/${VVL_SDK}/x86_64/share/vulkan/explicit_layer.d/VkLayer_khronos_validation.json" \
      /usr/share/vulkan/explicit_layer.d/VkLayer_khronos_validation.json \
 && grep -q syncval_shader_accesses_heuristic /usr/share/vulkan/explicit_layer.d/VkLayer_khronos_validation.json \
 && rm -rf /tmp/vulkansdk.tar.xz "/tmp/${VVL_SDK}"
COPY entrypoint.sh result.sh /opt/s2arm-vulkan/
ENV DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_SKIP_FIRST_TIME_EXPERIENCE=1 \
    DOTNET_NOLOGO=1 LP_NUM_THREADS=1 HOME=/tmp/s2arm-home \
    XDG_CACHE_HOME=/tmp/s2arm-cache XDG_RUNTIME_DIR=/tmp/s2arm-runtime
WORKDIR /src
ENTRYPOINT ["bash", "/opt/s2arm-vulkan/entrypoint.sh"]
