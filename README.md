# Project Colony packages for Nix

Nix expressions for the [Project Colony](https://github.com/Project-Colony)
ecosystem, kept current automatically.

Nix has no AUR. Nixpkgs is a reviewed monorepo, so it cannot follow our
releases at our pace; this repository is the equivalent of maintaining our own
package repo, and it picks up a new upstream release within a few hours (see
[How updates work](#how-updates-work)).

## Install

Try it once, install nothing:

```bash
nix run github:Project-Colony/nix#spherecord
```

Install it into your profile:

```bash
nix profile install github:Project-Colony/nix#spherecord
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
  environment.systemPackages = [ inputs.colony.packages.${pkgs.system}.spherecord ];
}
```

Move forward with `nix flake update colony`. There is also
`overlays.default`, if you would rather have the packages appear in `pkgs`.

## What is packaged

| Attribute | Upstream | Source | Systems |
|---|---|---|---|
| `spherecord` | [SphereCord](https://github.com/Project-Colony/SphereCord) | published AppImage | `x86_64-linux`, `aarch64-linux` |

These wrap the release artifacts we already build and sign. They do not build
from source, which is why installing is a download rather than a compile.

## How updates work

`scripts/update.sh` reads each upstream repo's latest release and rewrites
`sources.json`. `.github/workflows/update.yml` runs it, **builds every package
to prove the bump is good, and only then commits**.

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
in. A missing or invalid signature fails the update and nothing is committed,
except on a release less than two hours old that is still uploading, which is
skipped until a later run. A latest release older than the version already in
`sources.json` is refused, so an upstream release that is deleted or no longer
marked latest cannot roll anyone back. An asset whose API `digest` and download
URL still match what `sources.json` records was verified when it was recorded,
so a run with nothing new downloads nothing and finishes in seconds. The
updater needs `gh`, `jq`, `python3`, `curl` and `openssl`, and no Nix.

Once a week (Monday, 04:41 UTC) the same workflow also runs `nix flake update`,
so the pinned nixpkgs follows `nixos-unstable` through the same
build-before-commit gate. The commit names the move, for example
`chore: nixpkgs c59305b..e7439b6`. Tick `nixpkgs` when triggering the workflow
by hand to do it immediately.

The workflow is split in two jobs so the token that can push never meets Nix
or anything downloaded. The first job holds a read-only token: it runs the
updater, installs Nix, checks and builds every package, and passes
`sources.json` and `flake.lock` on as an artifact. The second job holds the
write token, installs nothing, refuses to commit if anything but those two
files changed, and pushes.

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
- **Disk.** The AppImage is 166 MB and Nix keeps both the fetched file and the
  extracted tree, so budget roughly 350 MB per retained version until
  `nix-collect-garbage` runs.
- **aarch64 is unverified.** The expression covers it and CI evaluates it, but
  no CI runner builds it yet.

## Adding a package

1. Add a line to the `PACKAGES` table at the top of `scripts/update.sh`. The
   upstream release must publish a signed `<asset>.sig` next to each asset.
2. Add `pkgs/<name>/package.nix`.
3. Add it to `packagesFor` in `flake.nix`.
4. Run `./scripts/update.sh` and commit the resulting `sources.json`.

CI derives the list of packages to build from the flake itself, so it needs no
change.
