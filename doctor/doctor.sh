#!/bin/bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"

tmp=${TMPDIR:-/Users/josh/d/gcsf/.work/tmp}
mkdir -p "$tmp"
bin="$tmp/f0-doctor"
sdk=$(xcrun --show-sdk-path)

if ! swiftc -swift-version 6 -strict-concurrency=complete -parse-as-library \
    -sdk "$sdk" -target arm64-apple-macos27.0 \
    -framework FSKit \
    "$root/doctor/Doctor.swift" -o "$bin" >"$tmp/f0-doctor-swiftc.log" 2>&1; then
    cat "$tmp/f0-doctor-swiftc.log" >&2
    exit 1
fi

os=$(sw_vers -productVersion)
xcode=$(xcodebuild -version 2>&1)
swift_ver=$(swift --version 2>&1)
sdk_ver=$(xcrun --sdk macosx --show-sdk-version 2>&1)
arch=$(uname -m)

printf 'OS: %s\n' "$os"
printf 'Xcode: %s\n' "$xcode"
printf 'Swift: %s\n' "$swift_ver"
printf 'SDK: %s %s\n' "$sdk_ver" "$sdk"
printf 'arch: %s\n' "$arch"
printf 'code-signing state:\n'
security find-identity -v -p codesigning || true

if [[ "${OPEN_SETTINGS:-}" == "1" ]]; then
    OPEN_SETTINGS=1 "$bin"
else
    env -u OPEN_SETTINGS "$bin"
fi

boundary="$root/Sources/GCSFCore/Contract/RuntimeBoundary.swift"
constant=$(rg -N -o 'public static let sharedGroupIdentifier = "([^"]+)"' -r '$1' "$boundary")
matches=$(rg -c 'public static let sharedGroupIdentifier = "' "$boundary")
if [[ -z "$constant" || "$matches" != "1" ]]; then
    echo "sharedGroupIdentifier is not one constant" >&2
    exit 1
fi

files=(
    "$root/Host/GCSFHost.entitlements"
    "$root/Extension/GCSFExtension.entitlements"
    "$root/Sources/gcsf-cli/gcsf-cli.entitlements"
)
for f in "${files[@]}"; do
    if ! plutil -convert json -o - "$f" | jaq -e --arg c "$constant" '
        .["keychain-access-groups"] == [$c] and .["com.apple.security.application-groups"] == [$c]
    ' >/dev/null; then
        echo "access group mismatch: $f" >&2
        exit 1
    fi
    printf 'access group %s: %s\n' "$(basename "$f")" "$constant"
done

fail=0
[[ "$os" == 27* ]] || fail=1
[[ "$xcode" == *"Xcode 27"* ]] || fail=1
[[ "$swift_ver" == *"Swift version 6.4"* ]] || fail=1
[[ "$arch" == "arm64" ]] || fail=1
if [[ "$fail" != "0" ]]; then
    echo "toolchain is not the campaign baseline" >&2
    exit 1
fi
