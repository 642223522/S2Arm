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
        check(new LdnSettings("client", " ").addressError() == LdnSettings.AddressError.EMPTY,
            "empty client address must be reported before saving");
        String[] invalid = {"256.1.2.3", "1.2.3", "1.2.3.4.5", "1..2.3", "-1.2.3.4",
            "1.2.3.a", "relay.example", "::1", "1.2.3.4:30456", "01.2.3.4", "１.2.3.4"};
        for (String address : invalid)
            check(new LdnSettings("client", address).addressError() == LdnSettings.AddressError.INVALID,
                "invalid IPv4 accepted: " + address);
        for (String address : new String[] {"100.64.1.8", "192.168.0.1", "127.0.0.1", "255.255.255.255", "0.0.0.0"})
            check(new LdnSettings("client", " " + address + " ").addressError() == null,
                "valid IPv4 rejected: " + address);
        check(new LdnSettings("host", "bad").addressError() == null
            && new LdnSettings("auto", "").addressError() == null, "only clients need an address");
        try {
            new LdnSettings("client", "100.64.1.8").testConnection((address, port, timeout) -> {
                check("100.64.1.8".equals(address), "probe target");
                check(port == 30456 && timeout == 3000, "probe must use relay TCP port with bounded timeout");
            });
            boolean failed = false;
            try {
                new LdnSettings("client", "100.64.1.8").testConnection((address, port, timeout) -> {
                    throw new java.io.IOException("refused");
                });
            } catch (java.io.IOException expected) { failed = true; }
            check(failed, "failed probe must not report success");
            boolean invalidRejected = false;
            try {
                new LdnSettings("client", "relay.example").testConnection((address, port, timeout) -> {
                    throw new AssertionError("invalid address reached connector");
                });
            } catch (IllegalArgumentException expected) { invalidRejected = true; }
            check(invalidRejected, "probe validates before connecting");
        } catch (java.io.IOException error) { throw new AssertionError(error); }
        System.out.println("LDN policy: environment, IPv4 validation and offline probe contracts passed");
    }
}
