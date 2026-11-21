# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
NATIVE_TEST_OWN += dprompt_layout
.PHONY: native-test-dprompt_layout
native-test-dprompt_layout:
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) -fobjc-arc -framework Foundation -framework CoreGraphics -o $(BUILD)/tests/t_dprompt_layout runtime/tests/t_dprompt_layout.m
	$(BUILD)/tests/t_dprompt_layout
TEST_TARGETS += native-test-dprompt_layout
