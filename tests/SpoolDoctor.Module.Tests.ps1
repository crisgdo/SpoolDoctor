Describe 'SpoolDoctor - Manifesto e carregamento do módulo' {
    BeforeAll {
        $repoRoot = Split-Path -Path $PSScriptRoot -Parent
        $manifestPath = Join-Path -Path $repoRoot -ChildPath 'src\SpoolDoctor.psd1'
        $privateFolderPath = Join-Path -Path $repoRoot -ChildPath 'src\Private'
        $remoteFolderPath = Join-Path -Path $repoRoot -ChildPath 'src\Remote'

        if (Get-Module -Name 'SpoolDoctor') {
            Remove-Module -Name 'SpoolDoctor' -Force -ErrorAction Stop
        }
    }

    AfterAll {
        if (Get-Module -Name 'SpoolDoctor') {
            Remove-Module -Name 'SpoolDoctor' -Force -ErrorAction Stop
        }
    }

    It 'possui manifesto válido para Windows PowerShell 5.1' {
        $manifest = Test-ModuleManifest -Path $manifestPath -ErrorAction Stop

        $manifest | Should -Not -BeNullOrEmpty
        $manifest.Name | Should -Be 'SpoolDoctor'
        $manifest.RootModule | Should -Be 'SpoolDoctor.psm1'
        $manifest.PowerShellVersion | Should -Be ([version]'5.1')
    }

    It 'importa o módulo exportando apenas as funções públicas esperadas e nenhuma função privada' {
        { Import-Module -Name $manifestPath -Force -ErrorAction Stop } | Should -Not -Throw

        $module = Get-Module -Name 'SpoolDoctor'
        $module | Should -Not -BeNullOrEmpty
        $module.ExportedFunctions.Count | Should -Be 4
        $module.ExportedFunctions.Keys | Should -Contain 'Reset-Spooler'
        $module.ExportedFunctions.Keys | Should -Contain 'Get-SpoolerJob'
        $module.ExportedFunctions.Keys | Should -Contain 'Remove-SpoolerJob'
        $module.ExportedFunctions.Keys | Should -Contain 'Test-Spooler'

        $privateFunctions = @(
            Get-ChildItem -Path $privateFolderPath -Filter '*.ps1' -File -ErrorAction Stop |
                Select-Object -ExpandProperty BaseName
        )
        $privateFunctions.Count | Should -BeGreaterThan 0
        $privateFunctions | Should -Contain 'Get-SpoolerPrinterRaw'
        $privateFunctions | Should -Contain 'Get-SpoolerJobRaw'
        $privateFunctions | Should -Contain 'Remove-SpoolerJobRaw'
        $privateFunctions | Should -Contain 'Copy-SpoolFile'
        $privateFunctions | Should -Contain 'Remove-OldSpoolBackup'

        foreach ($privateFunction in $privateFunctions) {
            $module.ExportedFunctions.Keys | Should -Not -Contain $privateFunction
        }

        $remoteFunctions = @(
            Get-ChildItem -Path $remoteFolderPath -Filter '*.ps1' -File -ErrorAction Stop |
                Select-Object -ExpandProperty BaseName
        )
        $expectedRemoteFunctions = @(
            'Test-ValidComputerName',
            'Get-AllowedComputer',
            'Resolve-SpoolerTarget',
            'Get-RemoteFailureOutcome',
            'Test-SpoolerPrintServer',
            'New-SpoolerRemoteSession',
            'Invoke-SpoolerRemoteScript',
            'Remove-SpoolerRemoteSession',
            'Invoke-SpoolerRemoteOperation'
        )
        $remoteFunctions.Count | Should -Be $expectedRemoteFunctions.Count
        foreach ($expectedRemote in $expectedRemoteFunctions) {
            $remoteFunctions | Should -Contain $expectedRemote
        }

        foreach ($remoteFunction in $remoteFunctions) {
            $module.ExportedFunctions.Keys | Should -Not -Contain $remoteFunction
        }
    }
}
