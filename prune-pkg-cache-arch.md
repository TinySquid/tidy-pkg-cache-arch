# prune-pkg-cache-arch

Prunes unused packages and cleans up disk space in the Arch Linux distro on WSL. Covers pacman, paru, and yay.

## Scripts

The recipes below are automated by two scripts:

- `scripts/prune-pkg-cache.sh` — the smart bash script. Auto-detects installed AUR helpers
  (yay, paru) and does the right thing for each. Flags:
  - `--skip-orphans` / `--skip-cache` — skip phases
  - `--nuclear` — delete ALL cached packages instead of keeping caches of currently
    installed ones
  - `--yes` — answer every prompt automatically (unattended runs)
- `scripts/compact-wsl-vhdx.ps1` — PowerShell companion for the Windows host (see the
  WSL section below).

Key behavior decisions:

- Orphan phase always uses the pacman recipe, never `yay -Yc` / `paru -Yc`, because
  pacman works whether or not a helper is installed.
- Orphan list is pre-checked: zero orphans → friendly message, no error.
- Script runs as the normal user; `sudo` is invoked per-command only (root-owned AUR
  caches would break helper cleanup).
- Helper commands always get `--aur` so they clean only their own AUR cache; the pacman
  cache is handled by the script itself (otherwise it gets cleaned twice, and `yay`
  would additionally try to sudo for it).
- `--nuclear` maps to `pacman -Scc`, `yay -Scc --aur`, `paru -Sccd --aur` (paru needs the
  extra `d` to also delete build dirs that carry `.git` data).
- In `--yes` mode, pacman uses `--noconfirm`, while helpers are driven by piping
  `yes`: paru's "remove ALL cache?" prompt defaults to **No**, so `--noconfirm`
  would silently clean nothing. The script ignores `yes`'s expected SIGPIPE after
  a helper exits, but still propagates helper failures. (Verified locally:
  `paru -Sccd --aur --noconfirm` deletes nothing.)

## Pacman Package Cache Pruning

Orphaned packages are dependencies that were automatically installed by other programs but are no longer needed by anything on your system.

`sudo pacman -Rns $(pacman -Qtdq)`

- `pacman -Qtdq`: Lists all "true" orphans (packages installed as dependencies that are no longer needed).

- `-Rns`: Recursively removes the target packages, their configuration files, and any of their unneeded dependencies.

### Step notes

When downloading packages, pacman (and AUR helpers like yay or paru) creates temporary download-XXXXXX folders but the command only deletes as files so the command will error. In that case, run this:

`sudo rm -rf /var/cache/pacman/pkg/download-*`

If no orphans are found, pacman will return an error stating error: no targets specified. This simply means your system is already clean.

## Clear the Pacman Cache

By default, Arch Linux keeps a local cache of every package you download.

`sudo pacman -Scc`

### Step notes

In case you want to keep the cache of currently installed programs (for downgrading) run: `sudo pacman -Sc` instead.

## Paru Cache Pruning

If you also use paru, you can automatically handle both your native repository cache (/var/cache/pacman/pkg/) and paru's local AUR build cache (~/.cache/paru/) with the following command:

`paru -Scc`

### Step notes

- First prompt: Asks to clear the pacman cache.
- Second prompt: Asks to clear the unneeded database sync repositories.
- Third prompt: Asks to clear all cached AUR packages (`~/.cache/paru/clone`).
- Fourth prompt: Asks to remove saved build diffs.

Because paru clones Git repositories for AUR builds, a simple clean might skip folders with trackable `.git` data. If you notice your `~/.cache/paru/` folder is still massive, pass the -d flag to force-delete the directories:

`paru -Sccd`

## Yay Cache Pruning

If you use yay instead of (or alongside) paru:

`yay -Sc --aur`

- Cleans yay's AUR cache (`~/.cache/yay`); the pacman part is skipped because of
  `--aur`, so run the pacman recipe separately (as the script does).
- Prompts: "remove all other AUR packages from cache?" (default Y) and
  "remove ALL untracked AUR files?" (default Y). Answering yes to untracked files
  wipes downloaded sources/build artifacts but keeps already-downloaded VCS sources.

Nuclear version (delete ALL AUR cache, not just packages not installed):

`yay -Scc --aur`

- Single prompt, "Do you want to remove ALL AUR packages from cache?" (default Y).
- Unlike paru, no `-d` variant is needed: yay removes the whole build directory
  (including `.git` data) via its AUR cache clean.
- yay's native orphan cleanup is `yay -Yc` (true orphans) or `yay -Ycc` (also packages
  optionally required by others). The script still prefers the pacman recipe, see the
  decisions log above.

Paru+yay coexistence: each helper keeps its own cache directory
(`~/.cache/paru`, `~/.cache/yay`), so if both are installed both must be cleaned —
which is exactly what the script's auto-detection does.

## WSL Users (Reclaiming Windows Space)

Running `pacman -Rns` or `pacman -Scc` deletes the files inside Linux, but Windows will not automatically shrink the virtual hard disk (`.vhdx`) file on your host machine.

```bash
wsl --shutdown

diskpart

select vdisk file="C:\Users\YOUR_USERNAME\AppData\Local\packages\...\ext4.vhdx"
compact vdisk
```

Automated version: run `scripts/compact-wsl-vhdx.ps1` on the Windows host in an
**elevated** PowerShell window. It lists registered distros and asks which one to
compact (or pass `-Distro <name>` for unattended use), resolves the `.vhdx` path from
the `HKCU:\...\Lxss` registry key, terminates only the target distro
(`wsl --terminate`), and runs `compact vdisk` for you. If the VHDX is still locked,
it exits with an error and tells you to `wsl --shutdown` and retry. If DiskPart
returns success but neither the VHDX size decreases nor an English success message
is recognized, compaction is reported as unverified rather than silently treated
as success (this can happen with localized Windows output).
