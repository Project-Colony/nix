# Contributing

Issues and pull requests are welcome. Report a security problem privately, as
[SECURITY.md](SECURITY.md) describes, never in a public issue.

## Checking a change locally

You need Nix with flakes (see the [README](README.md#installation)). The
updater also needs `gh` signed in (`gh auth login`, or `GH_TOKEN` set), `jq`,
`python3`, `curl` and `openssl`.

```bash
./scripts/update.sh                 # refresh sources.json from the latest releases
nix flake check --all-systems       # evaluate the flake for x86_64 and aarch64
nix build .#spherecord              # build one package: nix build .#<attribute>
./scripts/test-update.sh            # when the updater changed: run it through its checks
shellcheck scripts/*.sh             # when a script changed
```

`scripts/test-update.sh` runs copies of the updater in a scratch directory, so
it never changes your `sources.json`. It answers "latest release" with the
release `sources.json` records, and checks that the updater downloads nothing
new, reproduces every recorded hash and URL after verifying each asset again,
refuses an untrusted key, a downgrade and a release without signatures, and
skips a release still uploading. It downloads every recorded asset once, plus
one more. CI runs it and `shellcheck` on every pull request.

`nix build` only builds for the system you are on. CI builds every package
natively on both x86_64-linux and aarch64-linux, and smoke-tests the installed
wrapper, desktop entry and icon, so a pull request proves the architecture you
could not build.

A change to `.github/workflows/update.yml` can be tried before it merges: run
the workflow from the Actions tab on your branch. It updates, checks and builds
everything as on `main`, and stops before pushing, because only a run on `main`
commits.

## Adding a package

1. Add a line to the `PACKAGES` table at the top of `scripts/update.sh`:
   `<nix attribute> | <github repo> | <x86_64 asset> | <aarch64 asset> | <meta>`.
   `%V` in an asset name stands for the release version (the tag without a
   leading `v`), and an asset field stays empty when that architecture is not
   published. The upstream release must publish a signed `<asset>.sig` next to
   each asset. Set `<meta>` to `required` when it also publishes
   `<asset>.meta` and `<asset>.meta.sig`, as every release made with the org's
   shared signing workflow does. Left empty, a `.meta` is checked when the
   release has one but not demanded.
2. Add `pkgs/<name>/package.nix`. Take the version from
   `sources.<name>.version` and fetch `sources.<name>.urls.${system}` with
   `sources.<name>.hashes.${system}`, as `pkgs/spherecord/package.nix` does, so
   no package body carries a hand-written URL or hash.
3. Add it to `packagesFor` in `flake.nix`.
4. Run `./scripts/update.sh`, then `nix flake check --all-systems` and
   `nix build .#<name>`, and open a pull request with the package and the
   resulting `sources.json`.

CI derives the list of packages to build from the flake itself and builds each
one natively on x86_64 and aarch64, so it needs no change.

## Pull requests

- **The title is a conventional commit**, written for the person who installs
  the package: `feat: package Grape`, `fix(spherecord): ...`, `ci: ...`,
  `docs: ...`. Pull requests are squash-merged and the title becomes the commit
  subject on `main`, so it is the line people read in the history.
- **One topic per pull request.** Say in the description what changed and how
  you checked it, including which of the commands above you ran.
- **Everything lands through a pull request.** Nobody pushes to `main`. The
  one exception is the updater itself: `github-actions[bot]` commits
  `sources.json` and `flake.lock` directly, and its publish job refuses any
  other file.
- Code, comments and documentation are in English.
