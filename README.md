<div align="center">

# Dotweave

**Git-backed configuration sync for your development environment.**

[![CI](https://github.com/tinyrack-net/dotweave/actions/workflows/pipeline.yml/badge.svg)](https://github.com/tinyrack-net/dotweave/actions/workflows/pipeline.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

[Documentation](https://dotweave.tinyrack.net/en/) · [Getting Started](https://dotweave.tinyrack.net/en/getting-started/) · [한국어](https://dotweave.tinyrack.net/ko/)

</div>

---

Dotweave is a cross-platform CLI that syncs the configuration files in your home directory across multiple devices using git.

Most dotfiles tools start from the repository and ask you to shape your local system around it. Dotweave takes the opposite approach — your real config under `HOME` is the source of truth, and the git repository is just the sync artifact.

## Features

- **Track files and directories** under your home directory
- **Encrypt secrets** with [age](https://github.com/FiloSottile/age) before storing in the repo
- **Profiles** for syncing different subsets on different machines
- **Platform-specific paths** across Windows, macOS, Linux, and WSL
- **Dry-run previews** for both push and pull directions

## Installation

### Windows

```powershell
winget install tinyrack.dotweave
```

### macOS / Linux

```bash
brew install tinyrack-net/tap/dotweave
```

Prebuilt binaries for all supported platforms are also available on the [GitHub Releases](https://github.com/tinyrack-net/dotweave/releases) page.

## Quick Start

```bash
# Initialize
dotweave init

# Track some configs
dotweave track ~/.gitconfig
dotweave track ~/.zshrc
dotweave track ~/.ssh/config --mode secret

# Push local state to sync repo
dotweave push
```

## Documentation

For detailed guides, command reference, and troubleshooting, visit the **[Dotweave documentation site](https://dotweave.tinyrack.net/en/)**.

## License

[MIT](LICENSE)
