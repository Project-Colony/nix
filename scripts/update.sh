#!/usr/bin/env bash
# Regenerate sources.json from the latest GitHub release of each packaged app.
#
# Deliberately does NOT need Nix: gh + jq + python3 + curl + openssl.
#
# Every NEW asset hash is fail-closed on the org's release signature: the asset
# and its detached `<asset>.sig` are downloaded and verified with ed25519
# against the same keys Colony trusts for its own self-update (below). A
# missing or bad signature aborts the run, so the bump is never committed. An
# asset whose API `digest` still matches the hash already in sources.json was
# verified when that hash was recorded and is not downloaded again, which keeps
# a run with nothing new down to a few seconds.
set -euo pipefail

cd "$(dirname "$0")/.."

# One line per package:
#   <nix attribute> | <github repo> | <x86_64 asset> | <aarch64 asset>
# %V is replaced by the release version (tag without a leading v). Leave an
# asset field empty when that architecture is not published.
PACKAGES=(
    "spherecord|Project-Colony/SphereCord|SphereCord-%V.AppImage|SphereCord-%V-arm64.AppImage"
)

# Org release signing public keys (raw ed25519, hex). Copied from
# RELEASE_PUBLIC_KEYS in Project-Colony/Colony src/signing.rs; keep the two in
# sync on rotation. A signature from ANY listed key is accepted.
RELEASE_PUBLIC_KEYS=(
    44d8e0dcd9fc1fafda060d6e9f01a39144dcadd4f111135e7d56aa53c705bb4b
)

hex_b64() {
    python3 -c 'import base64,sys; print(base64.b64encode(bytes.fromhex(sys.argv[1])).decode())' "$1"
}

to_sri() {
    echo "sha256-$(hex_b64 "$1")"
}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# verify_signature <file> <raw 64-byte signature file>
verify_signature() {
    local key
    for key in "${RELEASE_PUBLIC_KEYS[@]}"; do
        # 302a300506032b6570032100 is the DER SubjectPublicKeyInfo prefix of
        # an ed25519 key; appending the raw 32 bytes makes a valid public key.
        printf -- '-----BEGIN PUBLIC KEY-----\n%s\n-----END PUBLIC KEY-----\n' \
            "$(hex_b64 "302a300506032b6570032100${key}")" >"$work/key.pem"
        if openssl pkeyutl -verify -pubin -inkey "$work/key.pem" -rawin \
            -in "$1" -sigfile "$2" >/dev/null 2>&1; then
            return 0
        fi
    done
    return 1
}

out='{}'
for entry in "${PACKAGES[@]}"; do
    IFS='|' read -r name repo tmpl_x86 tmpl_arm <<<"$entry"

    release=$(gh api "repos/${repo}/releases/latest")
    tag=$(jq -r .tag_name <<<"$release")
    version=${tag#v}
    echo "${name}: ${repo} @ ${tag}" >&2

    prev_tag=$(jq -r --arg n "$name" '.[$n].tag // empty' sources.json 2>/dev/null || true)
    pkg=$(jq -n --arg v "$version" --arg t "$tag" '{version: $v, tag: $t, hashes: {}}')

    for pair in "x86_64-linux=${tmpl_x86}" "aarch64-linux=${tmpl_arm}"; do
        system=${pair%%=*}
        tmpl=${pair#*=}
        [ -n "$tmpl" ] || continue
        asset=${tmpl//%V/$version}

        url=$(jq -r --arg n "$asset" '.assets[] | select(.name==$n) | .browser_download_url // empty' <<<"$release")
        if [ -z "$url" ]; then
            echo "  !! ${system}: no asset named ${asset} in ${tag}" >&2
            exit 1
        fi

        digest=$(jq -r --arg n "$asset" '.assets[] | select(.name==$n) | .digest // empty' <<<"$release")
        prev=$(jq -r --arg n "$name" --arg s "$system" '.[$n].hashes[$s] // empty' sources.json 2>/dev/null || true)

        if [ -n "$digest" ] && [ "$tag" = "$prev_tag" ] && [ "$(to_sri "${digest#sha256:}")" = "$prev" ]; then
            sri=$prev
        else
            echo "  .. ${system}: downloading ${asset} and ${asset}.sig to verify" >&2
            curl -fsSL -o "$work/asset" "$url"
            if ! curl -fsSL -o "$work/asset.sig" "${url}.sig"; then
                echo "  !! ${system}: no signature ${asset}.sig in ${tag}" >&2
                exit 1
            fi
            if ! verify_signature "$work/asset" "$work/asset.sig"; then
                echo "  !! ${system}: BAD SIGNATURE on ${asset} in ${tag}" >&2
                exit 1
            fi
            hex=$(sha256sum "$work/asset" | cut -d' ' -f1)
            if [ -n "$digest" ] && [ "$hex" != "${digest#sha256:}" ]; then
                echo "  !! ${system}: ${asset} does not match the API digest" >&2
                exit 1
            fi
            sri=$(to_sri "$hex")
            echo "  ok ${system}: signature verified" >&2
        fi

        echo "  ok ${system}: ${asset} ${sri}" >&2
        pkg=$(jq --arg s "$system" --arg h "$sri" '.hashes[$s] = $h' <<<"$pkg")
    done

    out=$(jq --arg n "$name" --argjson p "$pkg" '.[$n] = $p' <<<"$out")
done

printf '%s\n' "$out" | jq -S . > sources.json
echo "wrote sources.json" >&2
