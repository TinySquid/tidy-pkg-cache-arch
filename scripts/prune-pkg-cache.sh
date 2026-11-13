#!/usr/bin/env bash
#
# prune-pkg-cache.sh - prune orphaned packages and clean package caches on Arch
# Linux (also works under WSL, see scripts/compact-wsl-vhdx.ps1 for the Windows
# host side).
#
# Automatically detects installed AUR helpers (yay, paru) and cleans:
#   1. Orphaned packages  - always via pacman, regardless of helpers installed
#   2. Package caches     - pacman's cache plus every detected helper's AUR cache
#
# Run as a normal user; sudo is only invoked per-command where needed, so AUR
# helper caches stay owned by you.

set -euo pipefail

C_GREEN='\033[1;32m'; C_RED='\033[1;31m'; C_YELLOW='\033[1;33m'; C_OFF='\033[0m'

info() { printf "${C_GREEN}==>${C_OFF} %s\n" "$*"; }
warn() { printf "${C_YELLOW}==>$(echo )${C_OFF} %s\n" "$*"; }
die()  { printf "${C_RED}ERROR:${C_OFF} %s\n" "$*" >&2; exit 1; }

# `yes` may get SIGPIPE after the helper has consumed its prompts and exits.
# With pipefail enabled, preserve the helper's status rather than treating that
# expected SIGPIPE as a cache-cleaning failure.
run_helper_yes() {
    local -a pipeline_status
    if yes | "$@"; then
        return 0
    fi
    pipeline_status=("${PIPESTATUS[@]}")
    return "${pipeline_status[1]}"
}

usage() {
    cat <<EOF
Usage: ${0##*/} [options]

Options:
  --skip-orphans   Do not remove orphaned packages
  --skip-cache     Do not clean package caches
  --nuclear        Delete ALL cached packages, including packages of currently
                   installed versions (default: keep those, for downgrading)
  --yes            Answer all prompts automatically (for unattended runs)
  -h, --help       Show this help

Orphan phase is always done with pacman, because it works whether or not any
AUR helper is installed. Cache cleaning covers pacman plus every detected
AUR helper.
EOF
    exit 0
}

OPT_SKIP_ORPHANS=false
OPT_SKIP_CACHE=false
OPT_NUCLEAR=false
OPT_YES=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --skip-orphans) OPT_SKIP_ORPHANS=true ;;
        --skip-cache)   OPT_SKIP_CACHE=true ;;
        --nuclear)      OPT_NUCLEAR=true ;;
        --yes)          OPT_YES=true ;;
        -h|--help)      usage ;;
        *) die "Unknown option: $1 (see --help)" ;;
    esac
    shift
done

# --- pre-flight checks -------------------------------------------------------

command -v pacman >/dev/null 2>&1 || die "pacman not found; this script is Arch-specific."

if [[ ${EUID} -eq 0 ]]; then
    die "Do not run as root. Run as your normal user; sudo is used only where needed."
fi

if [[ ${OPT_SKIP_ORPHANS} == true && ${OPT_SKIP_CACHE} == true ]]; then
    die "Nothing to do: both phases are skipped. See --help."
fi

# Auto-detect AUR helpers. Every helper found gets its own cache cleaned; there
# is no reliable way to tell which helper the user actually uses.
HELPERS=()
for helper in yay paru; do
    if command -v "${helper}" >/dev/null 2>&1; then
        HELPERS+=("${helper}")
    fi
done
if ((${#HELPERS[@]} > 0)); then
    info "Detected AUR helper(s): ${HELPERS[*]}"
else
    info "No AUR helper detected; cleaning pacman only."
fi

# --- phase 1: remove orphaned packages ---------------------------------------

if [[ ${OPT_SKIP_ORPHANS} != true ]]; then
    info "Checking for orphaned packages..."
    query_stderr=$(mktemp)
    if orphan_output=$(pacman -Qtdq 2>"${query_stderr}"); then
        query_status=0
    else
        query_status=$?
    fi
    if [[ -s ${query_stderr} ]]; then
        query_error=$(<"${query_stderr}")
        rm -f "${query_stderr}"
        die "Could not query orphaned packages: ${query_error}"
    fi
    rm -f "${query_stderr}"
    if ((query_status != 0)) && [[ -n ${orphan_output} ]]; then
        die "pacman -Qtdq failed with status ${query_status}."
    fi
    orphans=()
    if [[ -n ${orphan_output} ]]; then
        mapfile -t orphans <<< "${orphan_output}"
    fi
    if ((${#orphans[@]} == 0)); then
        info "No orphans found. Package set is already clean."
    else
        info "Orphaned packages to be removed:"
        printf '  %s\n' "${orphans[@]}"
        if [[ ${OPT_YES} == true ]]; then
            sudo pacman -Rns --noconfirm "${orphans[@]}"
        else
            sudo pacman -Rns "${orphans[@]}"
        fi
        info "Orphan removal complete."
    fi
fi

# --- phase 2: clean package caches -------------------------------------------

if [[ ${OPT_SKIP_CACHE} != true ]]; then
    # pacman (and AUR helpers) may leave transient download-XXXXXX directories
    # in the cache, which makes `pacman -Scc` abort because it only deletes
    # plain files. Remove them up front so the cache clean cannot error out.
    info "Removing leftover pacman download-* temp dirs..."
    sudo find /var/cache/pacman/pkg -maxdepth 1 -name 'download-*' \
        -exec rm -rf {} + 2>/dev/null || true

    if [[ ${OPT_NUCLEAR} == true ]]; then
        info "Nuclear mode: deleting ALL cached packages (pacman -Scc)."
        pacman_opts=(-Scc)
        if [[ ${OPT_YES} == true ]]; then
            pacman_opts+=(--noconfirm)
        fi
        sudo pacman "${pacman_opts[@]}"
    else
        info "Cleaning pacman cache (caches of installed packages are kept for downgrading)."
        if [[ ${OPT_YES} == true ]]; then
            sudo pacman -Sc --noconfirm
        else
            sudo pacman -Sc
        fi
    fi
    info "Pacman cache clean complete."

    for helper in "${HELPERS[@]}"; do
        # --aur restricts the helper to its own AUR cache; the pacman cache was
        # handled above. Without it the helper would clean the pacman cache a
        # second time (yay even tries to sudo for it).
        if [[ ${OPT_NUCLEAR} == true ]]; then
            # paru: -Sccd force-deletes build dirs that carry .git data;
            # plain -Scc skips those.
            op=$([[ ${helper} == paru ]] && echo "-Sccd" || echo "-Scc")
        else
            op="-Sc"
        fi

        if [[ ${OPT_NUCLEAR} == true && ${helper} == paru && ${OPT_YES} != true ]]; then
            warn "paru's upcoming 'clean ALL cache?' prompt defaults to No; answer y to delete everything."
        fi

        if [[ ${OPT_YES} == true ]]; then
            # Do NOT pass --noconfirm here: paru's "remove ALL cache" prompt
            # defaults to No, so --noconfirm would answer No and silently
            # clean nothing. Piping `yes` answers every prompt with y.
            if ! run_helper_yes "${helper}" "${op}" --aur; then
                die "${helper} AUR cache cleanup failed."
            fi
        else
            "${helper}" "${op}" --aur
        fi
        info "${helper} AUR cache clean complete."
    done
fi

info "All done."
