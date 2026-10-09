<div align="center">

# Project Colony packages for Nix

**Nix packages for Project Colony programs, kept current from their signed releases automatically.**

</div>

[![License: GPL-3.0-or-later](https://img.shields.io/badge/License-GPL--3.0--or--later-blue.svg)](LICENSE)
[![Platforms](https://img.shields.io/badge/platforms-x86__64--linux%20%7C%20aarch64--linux-lightgrey)](#installation)

[Project Colony](https://github.com/Project-Colony) programs ship as signed
GitHub releases on their own schedule, which nixpkgs cannot follow. This flake wraps
those release files for Nix and NixOS, and an updater moves each package to the
newest release once its signature checks out, so a new version reaches
`nix profile upgrade` within a few hours (see
[How updates work](#how-updates-work)).

> **Status:** SphereCord is the only package. Both x86_64-linux and
> aarch64-linux are built natively in CI, which also checks the installed
> wrapper, desktop entry and icon on both, and they are built again before
> every bump is committed. Nobody has reported launching it on aarch64 yet.
> Signature verification has been proven by hand against SphereCord v3.3.5,
> but no scheduled run has yet met a new SphereCord release with it switched
> on. The `.meta` check is wired but not yet exercised: SphereCord does not
> publish `.meta` files, so today every bump rests on the `.sig` alone.

## Why a Nix repository

- **nixpkgs** is a reviewed monorepo. A version bump waits for a maintainer to
  review and merge it, then for the channel to advance. That is the right
  trade for a distribution, and too slow for programs that release on their
  own schedule.
- **NUR**, the [Nix User Repository](https://github.com/nix-community/NUR), is
  the real AUR equivalent. It is an index of user-maintained repositories like
  this one, which it evaluates but neither reviews nor builds, so it would add
  discovery and change nothing about how these packages are made. This
  repository is not listed there today.
- **This repository** wraps the files the org already builds and signs,
  refuses any hash the release key did not sign, and follows a new release
  within hours without anyone opening a pull request.

## What is packaged

| Attribute | Upstream | Source | Systems |
|---|---|---|---|
| `spherecord` | [SphereCord](https://github.com/Project-Colony/SphereCord) | published AppImage | `x86_64-linux`, `aarch64-linux` |

These wrap the release artifacts we already build and sign. They do not build
from source, which is why installing is a download rather than a compile.

## Installation

You need Nix with flakes. Determinate Nix turns them on by default; upstream
Nix needs `experimental-features = nix-command flakes` in `nix.conf`.

Try it once, install nothing:

```bash
nix run github:Project-Colony/nix#spherecord
```

Install it into your profile (older Nix calls this command
`nix profile install`):

```bash
nix profile add github:Project-Colony/nix#spherecord
```

Update it later. This is the `paru -Syu` of this repository:

```bash
nix profile upgrade spherecord
```

On older Nix, profile entries are addressed by index rather than by name.
`nix profile list` shows what yours is called, and `nix profile upgrade --all`
works everywhere.

Declaratively, in a NixOS or home-manager flake:

```nix
{
  inputs.colony.url = "github:Project-Colony/nix";

  # ... then, in your configuration:
  environment.systemPackages = [
    inputs.colony.packages.${pkgs.stdenv.hostPlatform.system}.spherecord
  ];
}
```

Move forward with `nix flake update colony`. There is also
`overlays.default`, if you would rather have the packages appear in `pkgs`.

## How updates work

`scripts/update.sh` reads each upstream repo's latest release and rewrites
`sources.json`. `.github/workflows/update.yml` runs it, **builds every package
on both x86_64 and aarch64 to prove the bump is good, and only then commits**.

The workflow is scheduled hourly, but GitHub delays and skips scheduled runs on
busy runners: from 1 September to 7 October 2026 they landed 2 to 9 hours apart,
about 4.5 hours on average. Expect a release here within a few hours, not
within the hour. A maintainer can trigger it immediately from the Actions tab
(`workflow_dispatch`).

Every new hash is checked against the release signature first. The updater
downloads the asset and its detached `<asset>.sig`, and verifies it with
`openssl` against the same ed25519 public key Colony embeds for its own
self-update. When the release also publishes `<asset>.meta`, its
`<asset>.meta.sig` must verify as well and the file must name exactly that tag,
asset and sha256, so a validly signed file from another release cannot stand
in. A missing or invalid signature fails the update and nothing is committed.
The one exception is a file not yet uploaded to a release under two hours old:
that release is skipped until a later run. A latest release older than the
version already in `sources.json` is refused, so an upstream release that is
deleted or no longer marked latest cannot roll anyone back. An asset whose API
`digest` and download URL still match what `sources.json` records was verified
when it was recorded, so a run with nothing new downloads nothing and finishes
in seconds. The updater needs `gh`, `jq`, `python3`, `curl` and `openssl`, and
no Nix.

What a valid `.sig` proves is that the file was signed with the org's release
key, not that SphereCord's own release job built it: every repository that
releases through the org's shared signing workflow signs with the same key.
The `.meta` check narrows that to the exact tag, file name and hash once
upstream publishes `.meta` files, which SphereCord does not do yet. The key
list at the top of `scripts/update.sh` is a copy of `RELEASE_PUBLIC_KEYS` in
Colony's `src/signing.rs`, and changes with it when the org rotates its key.

Once a week (Monday, 04:41 UTC) the same workflow also runs `nix flake update`,
so the pinned nixpkgs follows `nixos-unstable` through the same
build-before-commit gate. The commit names the move, for example
`chore: nixpkgs c59305b..e7439b6`. Tick `nixpkgs` when triggering the workflow
by hand to do it immediately.

The workflow is split in three jobs so the token that can push never meets Nix
or anything downloaded. The first job holds a read-only token: it runs the
updater, installs Nix, checks the flake, builds every x86_64 package, and
passes `sources.json` and `flake.lock` on as an artifact. The second, also
read-only, builds every aarch64 package from that artifact on a native arm64
runner. The last job waits for both, holds the write token, installs nothing,
refuses to commit if anything but those two files changed, and pushes. It only
pushes from `main`: a run started on another branch builds and stops there.

Those data-only commits are pushed straight to `main` by
`github-actions[bot]`. They are the one accepted exception to the org's rule
that changes land through pull requests: every change a person makes,
including to the updater and the workflows, goes through a squash-merged pull
request.

Run it by hand any time:

```bash
./scripts/update.sh
nix flake update   # only to move nixpkgs as well
```

## Known rough edges

- **Electron and the sandbox.** Electron applications inside an FHS
  environment sometimes fail with *"The SUID sandbox helper binary was found,
  but is not configured correctly"*. If SphereCord refuses to start with that
  message, that is the cause, and the fix belongs in
  `pkgs/spherecord/package.nix`. Please open an issue rather than working
  around it locally.
- **Disk.** The SphereCord 3.3.5 AppImage is about 158 MB and unpacks to about
  424 MB. Nix keeps both the fetched file and the unpacked tree, so budget
  roughly 580 MB per version until `nix-collect-garbage` runs. After that, each
  version still installed keeps its unpacked tree.
- **aarch64 is built, not run.** CI and every update build it natively on an
  arm64 runner, and CI checks the installed wrapper, desktop entry and icon.
  CI never launches the app, and nobody has reported running it on aarch64
  yet.

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
4. Run `./scripts/update.sh` and open a pull request with the package and the
   resulting `sources.json`.

CI derives the list of packages to build from the flake itself and builds each
one natively on x86_64 and aarch64, so it needs no change.

## Privacy

This repository collects, stores and sends nothing, and the SphereCord wrapper
adds no telemetry: it runs the upstream AppImage unchanged.

- **Installing or upgrading** makes Nix download the AppImage from the
  [SphereCord releases](https://github.com/Project-Colony/SphereCord/releases)
  on GitHub, nixpkgs from GitHub, and the nixpkgs packages the wrapper runs on
  from your configured binary cache (`cache.nixos.org` by default).
- **The updater** runs only in GitHub Actions, never on your machine.
  `scripts/update.sh` reads release metadata from `api.github.com` and
  downloads release files from `github.com`. Both workflows install Nix with
  `DeterminateSystems/nix-installer-action`, which fetches it from Determinate
  Systems. The update workflow turns the action's diagnostics reporting off;
  CI keeps its default, which reports install diagnostics about the CI runner
  to Determinate Systems.
- **SphereCord itself** is a Discord client and talks to Discord once you run
  it. This package changes nothing about that; see the
  [SphereCord repository](https://github.com/Project-Colony/SphereCord) for
  the app.

## License

GPL-3.0-or-later. See [LICENSE](LICENSE).
