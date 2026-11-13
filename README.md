# Arch Package Cache Cleanup for WSL

Small scripts to remove orphaned packages and reclaim space used by package caches in Arch Linux, including Arch running under WSL. A separate Windows-host script compacts the distro's virtual disk after Linux-side cleanup.

## What the scripts do

- [`scripts/prune-pkg-cache.sh`](scripts/prune-pkg-cache.sh) removes orphaned packages, cleans the pacman cache, and cleans the caches of any installed `yay` or `paru` helpers. Run it inside Arch as your normal user; it invokes `sudo` only for pacman-owned files.
- [`scripts/compact-wsl-vhdx.ps1`](scripts/compact-wsl-vhdx.ps1) compacts a WSL distro's VHDX from Windows. It lists distros interactively or accepts a distro name with `-Distro`.

## Requirements

- Arch Linux; optional AUR helpers: `yay` and/or `paru`.
- For VHDX compaction: Windows with WSL, an elevated PowerShell session, and the repository accessible from Windows.

## Quick start

Run the cleanup inside the Arch distro:

```bash
bash scripts/prune-pkg-cache.sh
```

The script displays the orphan packages before asking pacman to remove them, then prompts to clean caches. To run only one phase, or to automate prompts:

```bash
bash scripts/prune-pkg-cache.sh --skip-orphans
bash scripts/prune-pkg-cache.sh --skip-cache
bash scripts/prune-pkg-cache.sh --yes
```

| Option           | Effect                                                                                      |
| ---------------- | ------------------------------------------------------------------------------------------- |
| `--skip-orphans` | Do not remove orphaned packages.                                                            |
| `--skip-cache`   | Do not clean package caches.                                                                |
| `--nuclear`      | Also delete caches of currently installed package versions and all AUR helper build caches. |
| `--yes`          | Confirm prompts automatically; use with care, especially with `--nuclear`.                  |
| `-h`, `--help`   | Show all options.                                                                           |

> [!CAUTION]
> `--nuclear` removes package caches that could be useful for downgrading and deletes all cached AUR helper build data. `--yes` accepts cleanup prompts automatically.

## Reclaim Windows disk space

Deleting files inside Linux does not necessarily shrink the WSL virtual disk file on Windows. After cleaning the Arch distro, run the PowerShell companion from an **elevated** PowerShell window on the Windows host:

```powershell
.\scripts\compact-wsl-vhdx.ps1
# Or choose a registered distro explicitly:
.\scripts\compact-wsl-vhdx.ps1 -Distro Arch
```

The script terminates only the selected distro. If compaction fails because the VHDX is still in use, follow the error guidance and retry after `wsl --shutdown`. Compaction can be run independently for each distro.

## Tests

The tests are workflow dry runs: they put mock `pacman`, `sudo`, `yay`, `paru`, `wsl`, and DiskPart commands at the script boundary. They do not remove packages, clean real caches, terminate WSL distros, or compact a real VHDX.

- Bash workflow tests: Bats (`bats tests/prune-pkg-cache.bats`)
- PowerShell workflow tests: Pester 5 (`Invoke-Pester -Path tests/compact-wsl-vhdx.Tests.ps1`)
- Bash static checks: `bash -n scripts/prune-pkg-cache.sh` and `shellcheck scripts/prune-pkg-cache.sh`

See [`prune-pkg-cache-arch.md`](prune-pkg-cache-arch.md) for the detailed cleanup recipes and behavior notes.
