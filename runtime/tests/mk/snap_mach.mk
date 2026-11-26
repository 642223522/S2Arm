# native-test-snap_mach：即时存档「忙等线程按 Mach 现场挪到另一条线程接着跑」的机制单测（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来）
NATIVE_TEST_OWN += snap_mach
.PHONY: native-test-snap_mach
native-test-snap_mach:
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) -o $(BUILD)/tests/t_snap_mach runtime/tests/t_snap_mach.c
	$(BUILD)/tests/t_snap_mach
TEST_TARGETS += native-test-snap_mach
