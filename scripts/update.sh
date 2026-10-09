#!/usr/bin/env bash
# Regenerate sources.json from the latest GitHub release of each packaged app.
#
# Deliberately does NOT need Nix: gh + jq + python3 + curl + openssl.
#
# Every NEW asset hash is fail-closed on the org's release signature: the asset
# and its detached `<asset>.sig` are downloaded and verified with ed25519
# against the same keys Colony trusts for its own self-update (below). When the
# release also publishes `<asset>.meta`, its `<asset>.meta.sig` is verified the
# same way and the file must say exactly `version=<tag>`, `asset=<name>` and
# `sha256=<hash of the downloaded asset>`, so a validly signed file from another
# release or under another name is refused. A missing or bad signature aborts
# the run, so the bump is never committed.
#
# An asset is not downloaded again when its API `digest` still matches the hash
# in sources.json AND sources.json records the exact URL it comes from. This
# script writes a URL only next to a hash it verified, so such a hash
# was verified by this script when it was recorded, and a run with nothing new
# finishes in a few seconds.
#
# Two more guards:
# - A latest release OLDER than the recorded version is refused, so an upstream
#   release that is deleted or no longer marked latest cannot roll users back.
# - An upstream release is public before its build has finished uploading. A
#   release under two hours old that still misses a file is skipped (its
#   previous entry kept, exit 0) and picked up by a later run. On an older
#   release the same gap fails the run.
set -euo pipefail

cd "$(dirname "$0")/.."

# One line per package:
#   <nix attribute> | <github repo> | <x86_64 asset> | <aarch64 asset> | <meta>
# %V is replaced by the release version (tag without a leading v). Leave an
# asset field empty when that architecture is not published. <meta> is empty
# or `required`: `required` fails the run when an asset has no signed
# <asset>.meta, while empty accepts .sig alone but still checks a .meta that
# the release does publish. Limit of empty: on a young release that does not
# list any .meta file yet, the hash is recorded on .sig alone and that tag's
# .meta is never checked later. `required` closes that gap.
PACKAGES=(
    # Set spherecord's <meta> to `required` once SphereCord releases through
    # the shared sign-and-publish.yml, which publishes .meta and .meta.sig.
    "spherecord|Project-Colony/SphereCord|SphereCord-%V.AppImage|SphereCord-%V-arm64.AppImage|"
)

# Org release signing public keys (raw ed25519, hex). Copied from
# RELEASE_PUBLIC_KEYS in Project-Colony/Colony src/signing.rs; keep the two in
# sync on rotation. A signature from ANY listed key is accepted.
RELEASE_PUBLIC_KEYS=(
    44d8e0dcd9fc1fafda060d6e9f01a39144dcadd4f111135e7d56aa53c705bb4b
)

# A release asset is ~160 MB; .sig and .meta are a few bytes.
CURL_ASSET=(curl -fsSL --connect-timeout 30 --max-time 900 --retry 3 --retry-all-errors)
CURL_SMALL=(curl -fsSL --max-time 60 --retry 3 --retry-all-errors)

# A release this young may still be uploading its files.
UPLOAD_WINDOW_SECONDS=7200

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

# has_asset <name>: whether the current $release has finished uploading an
# asset by that name. One still uploading counts as missing.
has_asset() {
    jq -e --arg n "$1" 'any(.assets[]; .name == $n and .state == "uploaded")' <<<"$release" >/dev/null
}

# lists_meta <asset>: whether the current $release lists <asset>.meta or
# <asset>.meta.sig in any state.
lists_meta() {
    jq -e --arg n "$1.meta" 'any(.assets[]; .name == $n or .name == $n + ".sig")' <<<"$release" >/dev/null
}

recorded=$(cat sources.json 2>/dev/null || echo '{}')
out='{}'
for entry in "${PACKAGES[@]}"; do
    IFS='|' read -r name repo tmpl_x86 tmpl_arm meta <<<"$entry"

    release=$(gh api "repos/${repo}/releases/latest")
    tag=$(jq -r .tag_name <<<"$release")
    version=${tag#v}
    echo "${name}: ${repo} @ ${tag}" >&2

    prev_tag=$(jq -r --arg n "$name" '.[$n].tag // empty' <<<"$recorded")
    prev_version=$(jq -r --arg n "$name" '.[$n].version // empty' <<<"$recorded")

    if [ -n "$prev_version" ] && [ "$prev_version" != "$version" ] &&
        [ "$(printf '%s\n' "$version" "$prev_version" | sort -V | tail -n 1)" = "$prev_version" ]; then
        echo "!! ${name}: latest release ${version} is older than recorded ${prev_version}" >&2
        exit 1
    fi

    missing=()
    for tmpl in "$tmpl_x86" "$tmpl_arm"; do
        [ -n "$tmpl" ] || continue
        asset=${tmpl//%V/$version}
        needed=("$asset" "$asset.sig")
        # A listed .meta is checked even when not required, so both of its
        # files must be complete, like the asset and its .sig.
        if [ "$meta" = required ] || lists_meta "$asset"; then
            needed+=("$asset.meta" "$asset.meta.sig")
        fi
        for file in "${needed[@]}"; do
            has_asset "$file" || missing+=("$file")
        done
    done
    if [ "${#missing[@]}" -gt 0 ]; then
        if jq -e --argjson w "$UPLOAD_WINDOW_SECONDS" \
            '.published_at | fromdateiso8601 > now - $w' <<<"$release" >/dev/null; then
            echo "  .. not ready yet, skipping ${name} ${tag} (no ${missing[*]})" >&2
            out=$(jq --arg n "$name" --argjson r "$recorded" \
                'if $r | has($n) then .[$n] = $r[$n] else . end' <<<"$out")
            continue
        fi
        echo "  !! ${name}: ${tag} has no ${missing[*]}" >&2
        exit 1
    fi

    pkg=$(jq -n --arg v "$version" --arg t "$tag" '{version: $v, tag: $t, hashes: {}, urls: {}}')

    for pair in "x86_64-linux=${tmpl_x86}" "aarch64-linux=${tmpl_arm}"; do
        system=${pair%%=*}
        tmpl=${pair#*=}
        [ -n "$tmpl" ] || continue
        asset=${tmpl//%V/$version}

        url=$(jq -r --arg n "$asset" '.assets[] | select(.name==$n) | .browser_download_url' <<<"$release")
        digest=$(jq -r --arg n "$asset" '.assets[] | select(.name==$n) | .digest // empty' <<<"$release")
        prev=$(jq -r --arg n "$name" --arg s "$system" '.[$n].hashes[$s] // empty' <<<"$recorded")
        prev_url=$(jq -r --arg n "$name" --arg s "$system" '.[$n].urls[$s] // empty' <<<"$recorded")

        if [ -n "$digest" ] && [ "$tag" = "$prev_tag" ] && [ "$url" = "$prev_url" ] &&
            [ "$(to_sri "${digest#sha256:}")" = "$prev" ]; then
            sri=$prev
        else
            echo "  .. ${system}: downloading ${asset} and its signature to verify" >&2
            "${CURL_ASSET[@]}" -o "$work/asset" "$url"
            "${CURL_SMALL[@]}" -o "$work/asset.sig" "${url}.sig"
            if ! verify_signature "$work/asset" "$work/asset.sig"; then
                echo "  !! ${system}: BAD SIGNATURE on ${asset} in ${tag}" >&2
                exit 1
            fi
            hex=$(sha256sum "$work/asset" | cut -d' ' -f1)
            if [ -n "$digest" ] && [ "$hex" != "${digest#sha256:}" ]; then
                echo "  !! ${system}: ${asset} does not match the API digest" >&2
                exit 1
            fi
            echo "  ok ${system}: signature verified" >&2

            # Presence comes from the asset list rather than from a failed
            # download, so a network error can never pass for "no .meta". The
            # check above already made sure a listed .meta has its .meta.sig.
            if has_asset "$asset.meta"; then
                "${CURL_SMALL[@]}" -o "$work/asset.meta" "${url}.meta"
                "${CURL_SMALL[@]}" -o "$work/asset.meta.sig" "${url}.meta.sig"
                if ! verify_signature "$work/asset.meta" "$work/asset.meta.sig"; then
                    echo "  !! ${system}: BAD SIGNATURE on ${asset}.meta in ${tag}" >&2
                    exit 1
                fi
                # Byte for byte what sign-and-publish.yml writes.
                if ! printf 'version=%s\nasset=%s\nsha256=%s\n' "$tag" "$asset" "$hex" |
                    cmp -s - "$work/asset.meta"; then
                    echo "  !! ${system}: ${asset}.meta does not describe ${asset} in ${tag}" >&2
                    exit 1
                fi
                echo "  ok ${system}: .meta verified" >&2
            fi
            sri=$(to_sri "$hex")
        fi

        echo "  ok ${system}: ${asset} ${sri}" >&2
        pkg=$(jq --arg s "$system" --arg h "$sri" --arg u "$url" \
            '.hashes[$s] = $h | .urls[$s] = $u' <<<"$pkg")
    done

    out=$(jq --arg n "$name" --argjson p "$pkg" '.[$n] = $p' <<<"$out")
done

printf '%s\n' "$out" | jq -S . > sources.json
echo "wrote sources.json" >&2
