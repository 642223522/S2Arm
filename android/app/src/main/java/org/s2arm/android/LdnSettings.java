// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
package org.s2arm.android;

/** Cold-start policy shared by production settings and host-side tests. */
final class LdnSettings {
    interface Environment {
        String get(String key);
        void set(String key, String value);
    }
    final String mode;
    final String address;

    LdnSettings(String mode, String address) {
        this.mode = "host".equals(mode) || "client".equals(mode) ? mode : "auto";
        this.address = address == null ? "" : address.trim();
    }

    void apply(Environment env) {
        String external = env.get("S2A_LDN_SERVER");
        if (external != null && !external.isEmpty()) return;
        if ("host".equals(mode)) {
            env.set("S2A_LDN_SERVER", "127.0.0.1");
            env.set("S2A_LDN_RELAY", "1");
            env.set("S2A_LDN_LISTEN", "0.0.0.0");
        } else if ("client".equals(mode)) {
            // An empty manual target must not silently re-enable discovery/election.
            env.set("S2A_LDN_SERVER", address.isEmpty() ? "0.0.0.0" : address);
            env.set("S2A_LDN_RELAY", "0");
        }
    }
}
