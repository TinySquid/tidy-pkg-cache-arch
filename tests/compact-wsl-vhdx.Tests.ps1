BeforeAll {
    $scriptUnderTest = Join-Path $PSScriptRoot '..\scripts\compact-wsl-vhdx.ps1'

    # These command shims exercise the workflow without invoking the host's
    # WSL installation or DiskPart. The scripts under test resolve functions
    # before external executables with these names.
    function global:wsl {
        $global:WslCalls += ,($args -join ' ')
        switch ($args[0]) {
            '--list' {
                $global:LASTEXITCODE = $global:WslListExitCode
                return $global:WslDistroNames
            }
            '--status' {
                $global:LASTEXITCODE = $global:WslStatusExitCode
                return
            }
            '--terminate' {
                $global:LASTEXITCODE = $global:WslTerminateExitCode
                return
            }
            default {
                $global:LASTEXITCODE = 1
                return
            }
        }
    }

    function global:diskpart {
        $global:LASTEXITCODE = $global:DiskpartExitCode
        if ($global:DiskpartShouldShrink) {
            $stream = [System.IO.File]::Open(
                $global:DiskpartVhdxPath,
                [System.IO.FileMode]::Open,
                [System.IO.FileAccess]::Write,
                [System.IO.FileShare]::ReadWrite
            )
            try {
                $stream.SetLength([Math]::Max(1, $stream.Length - 32))
            } finally {
                $stream.Dispose()
            }
        }
        return $global:DiskpartOutput
    }

    . $scriptUnderTest
}

Describe 'WSL distro listing' {
    BeforeEach {
        $global:WslCalls = @()
        $global:WslListExitCode = 0
        $global:WslDistroNames = @('Arch', 'Ubuntu')
    }

    It 'preserves each distro name as a separate entry' {
        (Get-WslDistroNames) -join '|' | Should -Be 'Arch|Ubuntu'
    }

    It 'fails when wsl cannot list registered distros' {
        $global:WslListExitCode = 1

        { Get-WslDistroNames } | Should -Throw
    }
}

Describe 'WSL compaction workflow' {
    BeforeEach {
        $global:WslCalls = @()
        $global:WslStatusExitCode = 0
        $global:WslTerminateExitCode = 0
        Mock Test-Elevated { return $true }
        Mock Get-DistroVhdxPath { return 'mock-distro.vhdx' }
        Mock Compact-Vhdx {}
        Mock Start-Sleep {}
    }

    It 'terminates only the selected distro and then compacts its VHDX' {
        Invoke-Main -Distro 'Arch'

        $global:WslCalls | Should -Contain '--terminate Arch'
        Should -Invoke -CommandName Compact-Vhdx -Times 1 -Exactly -ParameterFilter {
            $VhdxPath -eq 'mock-distro.vhdx'
        }
    }

    It 'stops before compaction if terminating the target distro fails' {
        $global:WslTerminateExitCode = 7

        { Invoke-Main -Distro 'Arch' } | Should -Throw
        Should -Invoke -CommandName Compact-Vhdx -Times 0 -Exactly
    }
}

Describe 'VHDX compaction result handling' {
    BeforeEach {
        $global:DiskpartVhdxPath = Join-Path $TestDrive 'test.vhdx'
        [System.IO.File]::WriteAllBytes($global:DiskpartVhdxPath, (New-Object byte[] 128))
        $global:DiskpartExitCode = 0
        $global:DiskpartShouldShrink = $true
        $global:DiskpartOutput = @('Compaction completed')
    }

    It 'accepts localized DiskPart output when the VHDX shrinks' {
        $global:DiskpartOutput = @('Localized success text')

        { Compact-Vhdx -VhdxPath $global:DiskpartVhdxPath } | Should -Not -Throw
    }

    It 'fails when DiskPart returns a nonzero exit code' {
        $global:DiskpartExitCode = 2
        $global:DiskpartShouldShrink = $false

        { Compact-Vhdx -VhdxPath $global:DiskpartVhdxPath } | Should -Throw
    }

    It 'fails closed when success cannot be verified' {
        $global:DiskpartShouldShrink = $false
        $global:DiskpartOutput = @('Localized output without a success marker')

        { Compact-Vhdx -VhdxPath $global:DiskpartVhdxPath } | Should -Throw
    }

    It 'accepts the English success marker when there is no space to reclaim' {
        $global:DiskpartShouldShrink = $false
        $global:DiskpartOutput = @('DiskPart successfully compacted the virtual disk file.')

        { Compact-Vhdx -VhdxPath $global:DiskpartVhdxPath } | Should -Not -Throw
    }
}
