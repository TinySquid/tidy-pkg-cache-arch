<#
.SYNOPSIS
    Reclaim disk space taken by an ext4.vhdx after cleaning the package cache
    inside a WSL distro.

.DESCRIPTION
    Deleting files inside WSL (e.g. with scripts/prune-pkg-cache.sh) does not
    shrink the virtual hard disk file on the Windows host. This script:

      1. Lists registered WSL distros (interactive menu, or -Distro for
         unattended use).
      2. Resolves the distro's VHDX path from the Lxss registry key.
      3. Terminates the target distro only (wsl --terminate).
      4. Runs diskpart's compact vdisk against the VHDX.

    The PowerShell script MUST be run on the Windows host, not inside WSL.
    It checks the exit status of WSL and DiskPart commands and reports the
    VHDX size before and after compaction.

.EXAMPLE
    PS> .\compact-wsl-vhdx.ps1              # interactive distro chooser
    PS> .\compact-wsl-vhdx.ps1 -Distro Arch # unattended
#>
[CmdletBinding()]
param(
    [string]$Distro
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- helpers -----------------------------------------------------------------

function Test-Elevated {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal] $identity
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-WslDistroNames {
    # Preserve line boundaries: joining with an empty separator concatenates
    # names (e.g. Ubuntu + Debian becomes UbuntuDebian).
    $lines = @(wsl --list --quiet 2>$null)
    $wslExitCode = $LASTEXITCODE
    if ($wslExitCode -ne 0) {
        throw "'wsl --list --quiet' failed with exit code $wslExitCode."
    }

    return @($lines | ForEach-Object { ($_ -replace "`0", '').Trim() } | Where-Object { $_ })
}

function Select-Distro {
    $names = Get-WslDistroNames
    if (-not $names) { throw "No WSL distros found (is WSL installed?)." }

    Write-Host "`nRegistered WSL distros:"
    for ($i = 0; $i -lt $names.Count; $i++) {
        Write-Host ("  [{0}] {1}" -f ($i + 1), $names[$i])
    }

    do {
        $choice = Read-Host "Which distro to compact? (1-$($names.Count))"
    } while (-not ($choice -match '^\d+$' -and [int]$choice -ge 1 -and [int]$choice -le $names.Count))

    return $names[[int]$choice - 1]
}

function Get-DistroVhdxPath {
    param([string]$Name)

    $lxssKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss'
    $entry = Get-ChildItem $lxssKey -ErrorAction SilentlyContinue |
        ForEach-Object { Get-ItemProperty $_.PSPath } |
        Where-Object { $_.DistributionName -ieq $Name }

    if (-not $entry) {
        throw "Distro '$Name' not found in the registry ($lxssKey). " +
              "Provide the ext4.vhdx path manually this time; " +
              "see prune-pkg-cache-arch.md for details."
    }

    $basePath = $entry.BasePath.TrimEnd('\')
    $vhdx = Join-Path $basePath 'ext4.vhdx'
    if (Test-Path $vhdx) { return $vhdx }

    $candidates = Get-ChildItem -Path $basePath -Recurse -Filter '*.vhdx' -ErrorAction SilentlyContinue
    if ($candidates) { return ($candidates | Select-Object -First 1).FullName }

    throw "No *.vhdx found under '$basePath'. Locate the file manually " +
          "(Registry: DistributionName = $Name)."
}

function Compact-Vhdx {
    param([string]$VhdxPath)

    $sizeBeforeBytes = (Get-Item $VhdxPath).Length
    $sizeBefore = [math]::Round($sizeBeforeBytes / 1GB, 2)

    Write-Host "`nCompacting:$VhdxPath"
    Write-Host ("  Size before:{0} GB" -f $sizeBefore)

    $diskpartScript = Join-Path $env:TEMP 'compact-vhdx-diskpart.txt'
    Set-Content -Path $diskpartScript -Value @(
        "select vdisk file=`"$VhdxPath`""
        "compact vdisk"
    ) -Encoding Ascii

    try {
        $dpOutput = @(diskpart /s $diskpartScript)
        $diskpartExitCode = $LASTEXITCODE
    } finally {
        Remove-Item $diskpartScript -ErrorAction SilentlyContinue
    }

    Write-Host ($dpOutput -join "`n")
    $diskpartReportedFailure = ($dpOutput -join ' ' -match '(?i)(DiskPart has encountered an error|Virtual Disk Service error)')
    if ($diskpartExitCode -ne 0 -or $diskpartReportedFailure) {
        throw "diskpart failed (exit code $diskpartExitCode). If the VHDX is locked, run 'wsl --shutdown' and retry."
    }

    $sizeAfterBytes = (Get-Item $VhdxPath).Length
    $sizeAfter = [math]::Round($sizeAfterBytes / 1GB, 2)
    $reclaimed = [math]::Round(($sizeBeforeBytes - $sizeAfterBytes) / 1GB, 2)
    $reportedSuccess = ($dpOutput -join ' ' -match 'DiskPart successfully compacted')
    if ($sizeAfterBytes -lt $sizeBeforeBytes -or $reportedSuccess) {
        Write-Host ("  Size after: {0} GB  (reclaimed {1} GB)" -f $sizeAfter, $reclaimed) -ForegroundColor Green
    } else {
        # Localized success text cannot be parsed reliably. Fail closed when
        # neither the file size nor the English success marker verifies that
        # compaction happened, rather than silently returning success.
        throw "Compaction could not be verified: DiskPart returned exit code 0, but the VHDX did not shrink and no recognized success message was found. Inspect DiskPart output above; if the VHDX is locked, run 'wsl --shutdown' and retry."
    }
}

# --- main --------------------------------------------------------------------

function Invoke-Main {
    param([string]$Distro)

    if (-not (Test-Elevated)) {
        throw @'
diskpart requires administrator privileges.
Run this script from an elevated PowerShell window, e.g.:
  Start-Process powershell -Verb RunAs
'@
    }

    try {
        wsl --status | Out-Null
        if ($LASTEXITCODE -ne 0) { throw }
    } catch {
        throw "Failed to run 'wsl --status'. Is WSL installed and wsl.exe in PATH?"
    }

    if (-not $Distro) {
        $Distro = Select-Distro
    }

    # Allow the user to find out if the distro even exists, before doing anything destructive.
    Write-Host "`nTarget distro:$Distro"
    $vhdxPath = Get-DistroVhdxPath -Name $Distro

    Write-Host "Terminating '$Distro'..."
    wsl --terminate $Distro
    if ($LASTEXITCODE -ne 0) {
        throw "'wsl --terminate $Distro' failed with exit code $LASTEXITCODE."
    }
    Start-Sleep -Seconds 2 # give instances a moment to let go of the VHDX

    Compact-Vhdx -VhdxPath $vhdxPath

    Write-Host "`nDone. Other running distros were not touched; compact THEIR" +
                " vhdx files by running this script for each of them."
}

# Dot-sourcing exposes functions for tests without terminating a distro or
# invoking DiskPart. Normal script invocation still runs the complete workflow.
if ($MyInvocation.InvocationName -ne '.') {
    Invoke-Main -Distro $Distro
}
