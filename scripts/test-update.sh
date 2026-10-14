#!/usr/bin/env bash
# Run scripts/update.sh against the real GitHub releases that sources.json
# records and check what it does, so a change that breaks the updater fails a
# pull request instead of the first hourly update on main.
#
# Each case runs a copy of the updater on a copy of sources.json in a scratch
# directory, so the working tree is never touched. A `gh` wrapper answers
# "latest release" with the release sources.json already records: the inputs
# stay fixed, and an upstream release made in the meantime cannot fail an
# unrelated pull request. Some cases also rewrite that release's JSON to
# simulate a missing file or a release still uploading.
#
# Needs what update.sh needs. Downloads every recorded asset once (the full
# re-verification) and one more for the untrusted-key case.
set -euo pipefail

cd "$(dirname "$0")/.."

scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT

mkdir "$scratch/bin"
cat >"$scratch/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1-}" = api ] && [[ ${2-} =~ ^repos/([^/]+/[^/]+)/releases/latest$ ]]; then
    repo=${BASH_REMATCH[1]}
    tag=$(jq -r --arg p "https://github.com/${repo}/releases/download/" \
        'first(.[] | select(any(.urls[]?; startswith($p))) | .tag) // empty' "$PINNED_SOURCES")
    if [ -z "$tag" ]; then
        echo "gh wrapper: sources.json records no release of ${repo}" >&2
        exit 1
    fi
    "$REAL_GH" api "repos/${repo}/releases/tags/${tag}" | jq "$RELEASE_FILTER"
    exit
fi
exec "$REAL_GH" "$@"
EOF
chmod +x "$scratch/bin/gh"
REAL_GH=$(command -v gh)
PINNED_SOURCES=$PWD/sources.json
export REAL_GH PINNED_SOURCES PATH="$scratch/bin:$PATH"

die() {
    echo "FAIL: ${label}: $*" >&2
    exit 1
}

# prepare <label> <jq filter>: a fresh copy of the updater, and of sources.json
# passed through the filter, in $dir. $dir/input.json keeps that input.
prepare() {
    label=$1
    dir=$(mktemp -d "$scratch/case.XXXX")
    mkdir "$dir/scripts"
    cp scripts/update.sh "$dir/scripts/"
    jq -S "$2" sources.json >"$dir/sources.json"
    cp "$dir/sources.json" "$dir/input.json"
}

# run [jq filter]: runs the copy, with the release JSON passed through the
# filter. Its exit code lands in $status and its output in $dir/log.
run() {
    echo "--- ${label}" >&2
    status=0
    RELEASE_FILTER=${1:-.} "$dir/scripts/update.sh" >"$dir/log" 2>&1 || status=$?
    sed 's/^/    /' "$dir/log" >&2
}

# expect_success <file>: exit 0, and sources.json now byte for byte <file>.
expect_success() {
    [ "$status" = 0 ] || die "update.sh exited ${status}"
    diff -u "$1" "$dir/sources.json" >&2 || die "sources.json is not what it should be"
}

# expect_refusal <message>: a non-zero exit for that reason, and sources.json
# left exactly as it was.
expect_refusal() {
    [ "$status" != 0 ] || die "update.sh succeeded"
    grep -qF -- "$1" "$dir/log" || die "update.sh failed, but not with '$1'"
    cmp -s "$dir/input.json" "$dir/sources.json" || die "sources.json was modified"
}

no_urls='map_values(del(.urls))'
no_sigs='del(.assets[] | select(.name | endswith(".sig")))'

prepare "a release already recorded is not downloaded again" .
run
expect_success sources.json
if grep -q downloading "$dir/log"; then die "an asset was downloaded"; fi

prepare "without recorded URLs, every asset is downloaded and verified again" "$no_urls"
run
expect_success sources.json
[ "$(grep -c 'signature verified' "$dir/log")" = "$(jq '[.[].hashes[]] | length' sources.json)" ] ||
    die "not every asset had its signature verified"

prepare "an asset signed by a key the updater does not trust is refused" "$no_urls"
other_key=$(openssl genpkey -algorithm ed25519 | openssl pkey -pubout -outform DER |
    tail -c 32 | od -An -tx1 | tr -d ' \n')
sed -Ei "s/^( *)[0-9a-f]{64}\$/\1${other_key}/" "$dir/scripts/update.sh"
! cmp -s scripts/update.sh "$dir/scripts/update.sh" || die "found no key to replace"
run
expect_refusal "BAD SIGNATURE"

prepare "a latest release older than the recorded version is refused" 'map_values(.version = "9999")'
run
expect_refusal "is older than recorded"

prepare "a settled release without signatures is refused" "$no_urls"
run "${no_sigs} | .published_at = \"2000-01-01T00:00:00Z\""
expect_refusal "has no"

prepare "a young release still uploading its signatures is skipped" "$no_urls"
run "${no_sigs} | .published_at = (now | todateiso8601)"
expect_success "$dir/input.json"
grep -q "not ready yet" "$dir/log" || die "the release was not reported as skipped"

echo "all updater checks passed" >&2
