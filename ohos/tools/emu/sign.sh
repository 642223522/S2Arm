#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
# Sign an unsigned HAP for the OpenHarmony emulator with the SDK's public debug keystore (no account).
# Usage: bash sign.sh <unsigned.hap> <signed.hap> <bundle.name>
#
# The certificates stored next to the keys in OpenHarmony.p12 do not chain (hap-sign-tool reports
# "verify certificate chain failed"), so a root -> sub CA -> app chain is regenerated from the same
# keys under the same subjects, and the profile's distribution-certificate is set to that leaf.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=common.sh
source "${here}/common.sh"
[ $# -eq 3 ] || die "usage: sign.sh <unsigned.hap> <signed.hap> <bundle.name>"
in=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
out=$(mkdir -p "$(dirname "$2")" && cd "$(dirname "$2")" && pwd)/$(basename "$2")
bundle=$3
[ -f "${in}" ] || die "no such HAP: ${in}"
lib=${SDK_DIR}/toolchains/lib
[ -f "${lib}/hap-sign-tool.jar" ] || die "SDK toolchains missing; run setup.sh first"
JAVA_HOME=$(java_home); export JAVA_HOME
keys=${OHOS_EMU_HOME}/signing
mkdir -p "${keys}"
pw=123456   # public password of the SDK's debug keystore, not a secret
tool() {
    local o
    if ! o=$("${JAVA_HOME}/bin/java" -jar "${lib}/hap-sign-tool.jar" "$@" 2>&1); then
        printf '%s\n' "${o}" >&2; die "hap-sign-tool $1 failed"
    fi
    if printf '%s\n' "${o}" | grep -q -E 'ERROR|failed'; then
        printf '%s\n' "${o}" >&2; die "hap-sign-tool $1 failed"
    fi
}
O='C=CN,O=OpenHarmony,OU=OpenHarmony Team,CN=OpenHarmony Application'
if [ ! -f "${keys}/app-chain.cer" ]; then
    cp "${lib}/OpenHarmony.p12" "${keys}/ks.p12"
    common=(-keystoreFile "${keys}/ks.p12" -keystorePwd "${pw}" -keyPwd "${pw}" -validity 3650)
    tool generate-ca -keyAlias "openharmony application root ca" -keyAlg ECC -keySize NIST-P-384 \
        -signAlg SHA384withECDSA -subject "${O} Root CA" -outFile "${keys}/root.cer" -basicConstraintsPathLen 0 "${common[@]}"
    tool generate-ca -keyAlias "openharmony application ca" -issuer "${O} Root CA" \
        -issuerKeyAlias "openharmony application root ca" -issuerKeyPwd "${pw}" -keyAlg ECC -keySize NIST-P-384 \
        -signAlg SHA384withECDSA -subject "${O} CA" -outFile "${keys}/sub.cer" -basicConstraintsPathLen 0 "${common[@]}"
    tool generate-app-cert -keyAlias "openharmony application release" -issuer "${O} CA" \
        -issuerKeyAlias "openharmony application ca" -issuerKeyPwd "${pw}" -subject "${O} Release" \
        -signAlg SHA256withECDSA -outForm certChain -rootCaCertFile "${keys}/root.cer" \
        -subCaCertFile "${keys}/sub.cer" -outFile "${keys}/app-chain.partial.cer" "${common[@]}"
    mv "${keys}/app-chain.partial.cer" "${keys}/app-chain.cer"
fi
python3 - "${lib}/UnsgnedReleasedProfileTemplate.json" "${keys}/app-chain.cer" "${bundle}" "${keys}/profile-${bundle}.json" <<'P'
import json, re, sys, time
template, chain, bundle, out = sys.argv[1:]
leaf = re.findall(r"-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----", open(chain).read(), re.S)[0] + "\n"
d = json.load(open(template))
d["bundle-info"].update({"bundle-name": bundle, "distribution-certificate": leaf, "apl": "normal"})
d["validity"] = {"not-before": int(time.time()) - 86400, "not-after": int(time.time()) + 3650 * 86400}
json.dump(d, open(out, "w"), indent=1)
P
tool sign-profile -keyAlias "openharmony application profile release" -signAlg SHA256withECDSA -mode localSign \
    -profileCertFile "${lib}/OpenHarmonyProfileRelease.pem" -inFile "${keys}/profile-${bundle}.json" \
    -keystoreFile "${keys}/ks.p12" -outFile "${keys}/profile-${bundle}.p7b" -keyPwd "${pw}" -keystorePwd "${pw}"
tool sign-app -keyAlias "openharmony application release" -signAlg SHA256withECDSA -mode localSign \
    -appCertFile "${keys}/app-chain.cer" -profileFile "${keys}/profile-${bundle}.p7b" -inFile "${in}" \
    -keystoreFile "${keys}/ks.p12" -outFile "${out}" -keyPwd "${pw}" -keystorePwd "${pw}" -signCode 1
log "signed ${out}"
