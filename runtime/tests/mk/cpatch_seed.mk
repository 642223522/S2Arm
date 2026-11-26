# native-test-cpatch_seed：随包金手指放不放（cpatch.c s2a_cheat_seed_action，#1517），同 t_cpatch 链 cpatch.c
NATIVE_TEST_OWN += cpatch_seed
.PHONY: native-test-cpatch_seed
native-test-cpatch_seed:
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) -Iruntime/include -DS2A_UNIT_TEST -o $(BUILD)/tests/t_cpatch_seed runtime/tests/t_cpatch_seed.c runtime/src/cpatch.c $(S2A_HOST_WEAK)
	$(BUILD)/tests/t_cpatch_seed
TEST_TARGETS += native-test-cpatch_seed
