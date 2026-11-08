# Security Policy

## Reporting a Vulnerability

Use [GitHub Private Vulnerability Reporting](https://github.com/jhaizhou-ops/S2Arm/security/advisories/new) to report security vulnerabilities confidentially. Do not open a public issue.

### What to include

- Description of the vulnerability and its potential impact
- Steps to reproduce the issue
- Affected version or commit range
- Any suggested mitigations

### Scope

**In scope:** code in this repository — `runtime/`, `graphics/`, `translator/`, `services/`, `pack/`, `launchers/`, `android/` — and build tooling that processes untrusted input (e.g. game metadata parsing).

**Out of scope:**
- Third-party components listed in [THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md) — please report those to the respective upstream projects
- Issues that require the attacker to already have physical access to a device and the user's own game files
- Denial-of-service in local tooling that processes only files the user controls
- Game files, firmware keys, or console certificates — we do not distribute or handle these

We aim to respond within 5 business days and will coordinate a disclosure timeline with you.
