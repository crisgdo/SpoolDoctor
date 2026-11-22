Describe 'SpoolDoctor - Gravação de log (Write-SpoolDoctorLog)' {
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

    BeforeEach {
        $script:logPath = Join-Path -Path 'TestDrive:\' -ChildPath ("logs-{0}\sub\spooldoctor.log" -f [guid]::NewGuid().ToString('N'))
    }

    It 'cria subdiretórios inexistentes automaticamente ao gravar o log em TestDrive:\' {
        InModuleScope 'SpoolDoctor' -Parameters @{ TargetLogPath = $script:logPath } {
            param($TargetLogPath)
            Write-SpoolDoctorLog `
                -ComputerName 'PC-TESTE' `
                -Action 'Reset-Spooler' `
                -Outcome 'OK' `
                -Message 'Teste de criação automática de diretório.' `
                -LogPath $TargetLogPath
        }

        Test-Path -LiteralPath $script:logPath -PathType Leaf | Should -BeTrue
    }

    It 'grava exatamente uma linha estruturada com timestamp ISO-8601 e todos os campos' {
        $fixedTimestamp = [datetime]'2026-11-22T12:30:00-03:00'

        InModuleScope 'SpoolDoctor' -Parameters @{ TargetLogPath = $script:logPath; EventTime = $fixedTimestamp } {
            param($TargetLogPath, $EventTime)
            Write-SpoolDoctorLog `
                -ComputerName 'PC-01' `
                -UserName 'DOMINIO\operador' `
                -Action 'Reset-Spooler' `
                -Outcome 'OK' `
                -Message 'Fila limpa com sucesso.' `
                -Timestamp $EventTime `
                -LogPath $TargetLogPath
        }

        $lines = @(Get-Content -LiteralPath $script:logPath -Encoding UTF8)
        $lines.Count | Should -Be 1
        $lines[0] | Should -Match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}'
        $lines[0] | Should -Match '\| Computer=PC-01 \|'
        $lines[0] | Should -Match '\| User=DOMINIO\\operador \|'
        $lines[0] | Should -Match '\| Action=Reset-Spooler \|'
        $lines[0] | Should -Match '\| Outcome=OK \|'
        $lines[0] | Should -Match '\| Message=Fila limpa com sucesso\.$'
    }

    It 'sanitiza quebras de linha na mensagem mantendo uma única linha por evento' {
        $multilineMessage = "Linha 1`r`nLinha 2`nLinha 3"

        InModuleScope 'SpoolDoctor' -Parameters @{ TargetLogPath = $script:logPath; RawMessage = $multilineMessage } {
            param($TargetLogPath, $RawMessage)
            Write-SpoolDoctorLog `
                -ComputerName 'PC-02' `
                -Action 'Reset-Spooler' `
                -Outcome 'Failed' `
                -Message $RawMessage `
                -LogPath $TargetLogPath
        }

        $lines = @(Get-Content -LiteralPath $script:logPath -Encoding UTF8)
        $lines.Count | Should -Be 1
        $lines[0] | Should -Match 'Message=Linha 1 Linha 2 Linha 3$'
    }

    It 'preserva caracteres acentuados em português ao ler o log em UTF-8' {
        $accentedMessage = 'Ação concluída: fila de impressão e serviço verificados e não há pendências.'

        InModuleScope 'SpoolDoctor' -Parameters @{ TargetLogPath = $script:logPath; Text = $accentedMessage } {
            param($TargetLogPath, $Text)
            Write-SpoolDoctorLog `
                -ComputerName 'PC-03' `
                -Action 'Reset-Spooler' `
                -Outcome 'OK' `
                -Message $Text `
                -LogPath $TargetLogPath
        }

        $content = Get-Content -LiteralPath $script:logPath -Encoding UTF8 -Raw
        $content | Should -Match 'Ação concluída: fila de impressão e serviço verificados e não há pendências\.'
    }

    It 'grava o log normalmente mesmo quando $WhatIfPreference está ativo' {
        InModuleScope 'SpoolDoctor' -Parameters @{ TargetLogPath = $script:logPath } {
            param($TargetLogPath)
            $WhatIfPreference = $true
            Write-SpoolDoctorLog `
                -ComputerName 'PC-04' `
                -Action 'Reset-Spooler' `
                -Outcome 'Simulated' `
                -Message 'Simulação registrada no log.' `
                -LogPath $TargetLogPath
        }

        Test-Path -LiteralPath $script:logPath -PathType Leaf | Should -BeTrue
        $lines = @(Get-Content -LiteralPath $script:logPath -Encoding UTF8)
        $lines.Count | Should -Be 1
        $lines[0] | Should -Match 'Outcome=Simulated'
    }
}
