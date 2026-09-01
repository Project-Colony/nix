#!/usr/bin/env bash
# Regenerate sources.json from the latest GitHub release of each packaged app.
#
# Deliberately does NOT need Nix, and does not download the release asset:
# GitHub's release API returns each asset's sha256 in `digest`, and a Nix SRI
# hash is the same digest, base64-encoded. So the whole thing is gh + jq +
# python. The download path below exists only for assets published before
# GitHub started emitting `digest`.
set -euo pipefail

cd "$(dirname "$0")/.."

# One line per package:
#   <nix attribute> | <github repo> | <x86_64 asset> | <aarch64 asset>
# %V is replaced by the release version (tag without a leading v). Leave an
# asset field empty when that architecture is not published.
PACKAGES=(
    "spherecord|Project-Colony/SphereCord|SphereCord-%V.AppImage|SphereCord-%V-arm64.AppImage"
)

to_sri() {
    python3 -c 'import base64,sys; print("sha256-"+base64.b64encode(bytes.fromhex(sys.argv[1])).decode())' "$1"
}

out='{}'
for entry in "${PACKAGES[@]}"; do
    IFS='|' read -r name repo tmpl_x86 tmpl_arm <<<"$entry"

    release=$(gh api "repos/${repo}/releases/latest")
    tag=$(jq -r .tag_name <<<"$release")
    version=${tag#v}
    echo "${name}: ${repo} @ ${tag}" >&2

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
        if [ -n "$digest" ]; then
            hex=${digest#sha256:}
        else
            # Pre-digest asset: pay for the download rather than guess.
            echo "  .. ${system}: no digest from the API, hashing ${asset} by download" >&2
            hex=$(curl -fsSL "$url" | sha256sum | cut -d' ' -f1)
        fi

        sri=$(to_sri "$hex")
        echo "  ok ${system}: ${asset} ${sri}" >&2
        pkg=$(jq --arg s "$system" --arg h "$sri" '.hashes[$s] = $h' <<<"$pkg")
    done

    out=$(jq --arg n "$name" --argjson p "$pkg" '.[$n] = $p' <<<"$out")
done

printf '%s\n' "$out" | jq -S . > sources.json
echo "wrote sources.json" >&2
