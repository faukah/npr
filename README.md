<div align="center">
  <h1 id="header">npr</h1>
  <p>A pull request tracker for Nixpkgs.</p>
  <a alt="CI" href="https://github.com/sisyphean-group/npr/actions">
    <img
      src="https://github.com/sisyphean-group/npr/actions/workflows/build.yaml/badge.svg"
      alt="Build Status"
    />
  </a>
  <a alt="Deps" href="https://deps.rs/repo/github/sisyphean-group/npr">
    <img
      src="https://deps.rs/repo/github/sisyphean-group/npr/status.svg"
      alt="Dependency Status"
    />
  </a>
  <a alt="License" href="https://github.com/sisyphean-group/npr/blob/master/LICENSE">
    <img
      src="https://img.shields.io/github/license/sisyphean-group/npr?label=License"
      alt="License"
    />
  </a>
  <br/>
</div>

A small handy tool to track GitHub pull requests targeting a package in nixpkgs
in the last `n` (default: 15) days.

Uses the GitHub CLI (`gh`) when it is installed and authenticated. If `gh` is
not available, `npr` notes that and calls the GitHub API directly. If `gh` is
installed but not authenticated, `npr` links to
<https://github.com/settings/personal-access-tokens/new>.

For direct API calls, authentication is loaded from `NPR_GITHUB_TOKEN`,
`GH_TOKEN`, or `GITHUB_TOKEN`. If none are set and stdin is interactive, `npr`
asks for a token and stores it at `$XDG_CONFIG_HOME/npr/github-token` (or
`~/.config/npr/github-token`) with user-only permissions. Set
`NPR_GITHUB_TOKEN_FILE` to choose another token file. No token permissions are
needed; it is only used so GitHub treats requests as authenticated.

# Installation

The flake exports `npr` as both a package and an app. If you need this you know
how to install it.

### Examples:

```bash
npr dix

Searching for dix...
PR: [Backport release-25.11] dix: 1.4.0 -> 1.4.1 (merged) #483480
   └─ Reachable in: None (pending Hydra/Mirror)
PR: dix: 1.4.0 -> 1.4.1 (merged) #483473
   └─ Reachable in: nixpkgs-unstable, nixos-unstable, nixos-unstable-small
PR: [Backport release-25.11] dix: 1.3.0 -> 1.4.0 (merged) #481653
   └─ Reachable in: None (pending Hydra/Mirror)
```

```bash
npr --help

Search for recent NixOS PRs affecting a package and show which branches they've reached.

Usage: npr [OPTIONS] <PACKAGE_NAME>

Arguments:
  <PACKAGE_NAME>  Package name to search for

Options:
  -d, --days <DAYS>  Search PRs from last n days [default: 15]
  -h, --help         Print help
```

# License:

npr is licensed under the GNU General Public License v3.0 or later (GPL-3.0+).
See [LICENSE.md](./LICENSE.md) for details.
