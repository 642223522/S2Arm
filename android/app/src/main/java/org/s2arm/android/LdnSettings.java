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

    enum AddressError { EMPTY, INVALID }

    /** Dotted decimal only: no DNS, IPv6, port suffix or ambiguous leading zeroes. */
    AddressError addressError() {
        if (!"client".equals(mode)) return null;
        if (address.isEmpty()) return AddressError.EMPTY;
        String[] parts = address.split("\\.", -1);
        if (parts.length != 4) return AddressError.INVALID;
        for (String part : parts) {
            if (part.isEmpty() || part.length() > 3 || (part.length() > 1 && part.charAt(0) == '0'))
                return AddressError.INVALID;
            int value = 0;
            for (int i = 0; i < part.length(); i++) {
                char digit = part.charAt(i);
                if (digit < '0' || digit > '9') return AddressError.INVALID;
                value = value * 10 + digit - '0';
            }
            if (value > 255) return AddressError.INVALID;
        }
        return null;
    }

    interface Connector {
        void connect(String address, int port, int timeoutMs) throws java.io.IOException;
    }

    /** Optional diagnostic, never a save/start admission gate. Tests inject an offline connector. */
    void testConnection(Connector connector) throws java.io.IOException {
        if (!"client".equals(mode) || addressError() != null)
            throw new IllegalArgumentException("A relay IPv4 is required");
        connector.connect(address, 30456, 3000);
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
