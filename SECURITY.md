# Security policy

This repository is a supply-chain path: whatever `scripts/update.sh` accepts
ends up on the machine of everyone who installs from it. Reports are welcome
and handled privately.

## Reporting a vulnerability

**Do not open a public issue.** Use **Security > Report a vulnerability** on
this repository, or go straight to
<https://github.com/Project-Colony/nix/security/advisories/new>. The report
stays between you and the maintainers until a fix is out.

Include what an attacker controls, what they get, and how to reproduce it.

What to expect: this is a small project, so no response time is guaranteed,
but the aim is an acknowledgement within 7 days. The fix lands on `main`
through a pull request, and you get credit in the advisory unless you ask
otherwise.

## Supported versions

There are no releases. Only the current `main` is supported, and a fix reaches
users with their next `nix flake update` or `nix profile upgrade`.

## In scope

- **Signature and metadata verification in `scripts/update.sh`.** Anything
  that gets a hash into `sources.json` without a valid signature from the
  org's release key, accepts an `<asset>.meta` that does not describe that
  asset and tag, moves a package back to an older release, or records a
  download URL other than the one it verified.
- **The workflows in `.github/workflows/`.** Above all the `publish` job of
  `update.yml`, the only job holding a token that can push: anything that lets
  it commit files other than `sources.json` and `flake.lock`, or lets code from
  a release asset or a Nix build reach that token.
- **The package wrappers in `pkgs/`**, today `pkgs/spherecord/package.nix`.
  Anything in the wrapper, its desktop entry or its FHS environment that runs
  something other than the verified AppImage, or gives the app more than
  upstream intended.

## Out of scope

- Vulnerabilities in SphereCord itself. Report them privately to
  [Project-Colony/SphereCord](https://github.com/Project-Colony/SphereCord/security/advisories/new).
- The org's release signing key and shared signing workflow. Report those
  privately to
  [Project-Colony/Project-Colony-Resources](https://github.com/Project-Colony/Project-Colony-Resources/security/advisories/new).
- Bugs in Nix, nixpkgs or GitHub Actions. Report those upstream, and tell us
  too if this repository makes one meaningfully worse.
