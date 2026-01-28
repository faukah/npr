# npr - Nix pull request tracker

A small handy tool to track GitHub pull requests targeting a package in nixpkgs in the last `n` (default: 15) days.

Requires the GitHub CLI (`gh`) to be installed and authenticated.


# Installation
The flake exports `npr` as both a package and an app.
If you need this you know how to install it.

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
npr zig --tree --days 5

Searching for zig...
PR: cargo-zigbuild: 0.21.1 -> 0.21.4 (merged) #484496
✗ master
  ✗ nixpkgs-unstable
  ✓ nixos-unstable-small
    ✗ nixos-unstable

PR: neovim-unwrapped: 0.11.5 -> 0.11.6 (merged) #484182
✗ master
  ✗ nixpkgs-unstable
  ✓ nixos-unstable-small
    ✗ nixos-unstable

PR: vimPlugins: update on 2026-01-24 (merged) #483824
✗ master
  ✓ nixpkgs-unstable
  ✓ nixos-unstable-small
    ✓ nixos-unstable

PR: ly: cleanup (merged) #483770
✗ master
  ✗ nixpkgs-unstable
  ✓ nixos-unstable-small
    ✓ nixos-unstable
```

```bash
npr --help

Usage: npr [options] <package-name>

Search for recent NixOS PRs affecting a package and show which branches they've reached.

Options:
  --days <n>     Search PRs from last n days (default: 15)
  --tree         Show detailed branch tree for each PR
  --help         Show this help message

Requires the GitHub CLI (gh) to be installed and authenticated.

Examples:
  npr forgejo
  npr --days 30 --tree python311
```

# License: 
GPL or GTFO
