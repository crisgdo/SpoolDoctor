Describe 'Get-SpoolerAllowedComputer (exposição pública da allow-list)' {
    BeforeAll {
        $repoRoot = Split-Path -Path $PSScriptRoot -Parent
        $manifestPath = Join-Path -Path $repoRoot -ChildPath 'src\SpoolDoctor.psd1'

        if (Get-Module -Name 'SpoolDoctor') {
            Remove-Module -Name 'SpoolDoctor' -Force -ErrorAction Stop
        }

        Import-Module -Name $manifestPath -Force -ErrorAction Stop
    }

    AfterAll {
        if (Get-Module -Name 'SpoolDoctor') {
            Remove-Module -Name 'SpoolDoctor' -Force -ErrorAction Stop
        }
    }

    It 'é função pública somente leitura sem SupportsShouldProcess' {
        $cmd = Get-Command -Name 'Get-SpoolerAllowedComputer' -Module 'SpoolDoctor' -ErrorAction Stop
        $cmd | Should -Not -BeNullOrEmpty

        $cmdletBinding = $cmd.ScriptBlock.Attributes |
            Where-Object { $_ -is [System.Management.Automation.CmdletBindingAttribute] } |
            Select-Object -First 1
        $cmdletBinding | Should -Not -BeNullOrEmpty
        $cmdletBinding.SupportsShouldProcess | Should -BeFalse
    }

    It 'lê config/allowed-computers.txt padrão sem erro retornando vazio quando só há comentários' {
        $entries = @(Get-SpoolerAllowedComputer)
        $entries.Count | Should -Be 0
    }

    It 'lê arquivo em TestDrive:\ ignorando comentários, marcando PrintServer e deduplicando entradas' {
        $allowListPath = Join-Path -Path 'TestDrive:\' -ChildPath ("public-allowed-{0}.txt" -f [guid]::NewGuid().ToString('N'))
        $content = @(
            '# Comentário inicial'
            ''
            '  PC-FIN-01  '
            'SRV-PRINT-01|PrintServer'
            'pc-fin-01|printserver'
            'ESTACAO-02.empresa.local'
        ) -join "`r`n"
        Set-Content -LiteralPath $allowListPath -Value $content -Encoding UTF8

        $entries = @(Get-SpoolerAllowedComputer -AllowedComputersPath $allowListPath)

        $entries.Count | Should -Be 3
        $entries[0].PSObject.TypeNames | Should -Contain 'SpoolDoctor.AllowedComputer'
        $entries[0].ComputerName | Should -Be 'PC-FIN-01'
        $entries[0].IsPrintServer | Should -BeTrue
        $entries[1].ComputerName | Should -Be 'SRV-PRINT-01'
        $entries[1].IsPrintServer | Should -BeTrue
        $entries[2].ComputerName | Should -Be 'ESTACAO-02.empresa.local'
        $entries[2].IsPrintServer | Should -BeFalse
    }

    It 'delega diretamente para Get-AllowedComputer com e sem -AllowedComputersPath' {
        $script:capturedAllowedCalls = New-Object -TypeName 'System.Collections.Generic.List[hashtable]'

        Mock Get-AllowedComputer -ModuleName SpoolDoctor {
            param([string]$Path)
            $script:capturedAllowedCalls.Add(@{} + $PSBoundParameters)
            return @(
                [PSCustomObject]@{
                    PSTypeName    = 'SpoolDoctor.AllowedComputer'
                    ComputerName  = 'PC-DELEGADO'
                    IsPrintServer = $false
                }
            )
        }

        $defaultRes = @(Get-SpoolerAllowedComputer)
        $defaultRes.Count | Should -Be 1
        $defaultRes[0].ComputerName | Should -Be 'PC-DELEGADO'

        $customFile = Join-Path -Path 'TestDrive:\' -ChildPath 'custom-allow.txt'
        $customRes = @(Get-SpoolerAllowedComputer -AllowedComputersPath $customFile)
        $customRes.Count | Should -Be 1

        Should -Invoke Get-AllowedComputer -ModuleName SpoolDoctor -Times 2 -Exactly
        $script:capturedAllowedCalls[0].ContainsKey('Path') | Should -BeFalse
        $script:capturedAllowedCalls[1]['Path'] | Should -Be $customFile
    }

    It 'lança erro explícito para arquivo inexistente, espaços em branco, entrada malformada ou IP literal' {
        $missingPath = Join-Path -Path 'TestDrive:\' -ChildPath 'inexistente-allowed.txt'
        { Get-SpoolerAllowedComputer -AllowedComputersPath $missingPath } | Should -Throw '*não encontrado*'
        { Get-SpoolerAllowedComputer -AllowedComputersPath '   ' } | Should -Throw '*espaços em branco*'

        foreach ($badLine in @('PC-01|OutraTag', 'PC-01|PrintServer|Extra', 'PC;bad', '192.168.1.10')) {
            $badPath = Join-Path -Path 'TestDrive:\' -ChildPath ("bad-{0}.txt" -f [guid]::NewGuid().ToString('N'))
            Set-Content -LiteralPath $badPath -Value $badLine -Encoding UTF8
            { Get-SpoolerAllowedComputer -AllowedComputersPath $badPath } | Should -Throw
        }
    }
}
