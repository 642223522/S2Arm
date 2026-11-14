// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
package org.s2arm.android;

import java.util.HashMap;
import java.util.Map;

public final class LdnSettingsTest {
    private static final class Env implements LdnSettings.Environment {
        final Map<String, String> values = new HashMap<>();
        int writes;
        public String get(String key) { return values.get(key); }
        public void set(String key, String value) { values.put(key, value); writes++; }
    }
    private static void check(boolean condition, String why) {
        if (!condition) throw new AssertionError(why);
    }
    public static void main(String[] args) {
        Env env = new Env();
        new LdnSettings("auto", "old address").apply(env);
        check(env.writes == 0, "auto must leave environment untouched");
        new LdnSettings("host", "unused").apply(env);
        check("127.0.0.1".equals(env.get("S2A_LDN_SERVER"))
            && "1".equals(env.get("S2A_LDN_RELAY"))
            && "0.0.0.0".equals(env.get("S2A_LDN_LISTEN")) && env.writes == 3, "host environment");
        env = new Env();
        new LdnSettings("client", " 100.64.1.8 ").apply(env);
        check("100.64.1.8".equals(env.get("S2A_LDN_SERVER"))
            && "0".equals(env.get("S2A_LDN_RELAY"))
            && !env.values.containsKey("S2A_LDN_LISTEN") && env.writes == 2, "client environment");
        env = new Env();
        new LdnSettings("client", " ").apply(env);
        check("0.0.0.0".equals(env.get("S2A_LDN_SERVER"))
            && "0".equals(env.get("S2A_LDN_RELAY")), "empty client must not silently become auto");
        env = new Env();
        env.values.put("S2A_LDN_SERVER", "192.0.2.4");
        env.values.put("S2A_LDN_RELAY", "0");
        env.values.put("S2A_LDN_LISTEN", "192.0.2.5");
        Map<String, String> before = new HashMap<>(env.values);
        new LdnSettings("host", "").apply(env);
        check(env.writes == 0 && before.equals(env.values), "explicit environment wins as a unit");
        env = new Env();
        env.values.put("S2A_LDN_SERVER", "");
        new LdnSettings("host", "").apply(env);
        check("127.0.0.1".equals(env.get("S2A_LDN_SERVER")), "empty external server is not an override");
        env = new Env();
        new LdnSettings("unknown", null).apply(env);
        check(env.writes == 0, "unknown persisted mode falls back to auto");
        System.out.println("LDN policy: 7 cases passed");
    }
}
