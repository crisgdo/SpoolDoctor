Describe 'SpoolDoctor - Manifesto e carregamento do módulo' {
    BeforeAll {
        $repoRoot = Split-Path -Path $PSScriptRoot -Parent
        $manifestPath = Join-Path -Path $repoRoot -ChildPath 'src\SpoolDoctor.psd1'
        $privateFolderPath = Join-Path -Path $repoRoot -ChildPath 'src\Private'

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

    It 'importa o módulo exportando apenas Reset-Spooler e nenhuma função privada' {
        { Import-Module -Name $manifestPath -Force -ErrorAction Stop } | Should -Not -Throw

        $module = Get-Module -Name 'SpoolDoctor'
        $module | Should -Not -BeNullOrEmpty
        $module.ExportedFunctions.Count | Should -Be 1
        $module.ExportedFunctions.Keys | Should -Contain 'Reset-Spooler'

        $privateFunctions = @(
            Get-ChildItem -Path $privateFolderPath -Filter '*.ps1' -File -ErrorAction Stop |
                Select-Object -ExpandProperty BaseName
        )
        $privateFunctions.Count | Should -BeGreaterThan 0

        foreach ($privateFunction in $privateFunctions) {
            $module.ExportedFunctions.Keys | Should -Not -Contain $privateFunction
        }
    }
}
