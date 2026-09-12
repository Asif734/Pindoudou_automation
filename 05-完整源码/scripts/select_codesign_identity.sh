#!/bin/zsh
set -euo pipefail

if [[ -n "${PDD_AX_SIGNING_IDENTITY:-}" ]]; then
    print -r -- "$PDD_AX_SIGNING_IDENTITY"
    exit 0
fi

identities="${PDD_CODESIGN_IDENTITIES_TEXT:-$(/usr/bin/security find-identity -v -p codesigning 2>/dev/null || true)}"

developer_id="$(print -r -- "$identities" | /usr/bin/sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' | /usr/bin/head -n 1)"
if [[ -n "$developer_id" ]]; then
    print -r -- "$developer_id"
    exit 0
fi

apple_development="$(print -r -- "$identities" | /usr/bin/sed -n 's/.*"\(Apple Development:[^"]*\)".*/\1/p' | /usr/bin/head -n 1)"
if [[ -n "$apple_development" ]]; then
    print -r -- "$apple_development"
    exit 0
fi

local_signing="$(print -r -- "$identities" | /usr/bin/sed -n 's/.*"\(Qianniu AutoReply Local Signing\)".*/\1/p' | /usr/bin/head -n 1)"
if [[ -n "$local_signing" ]]; then
    print -r -- "$local_signing"
    exit 0
fi

print -- "-"
