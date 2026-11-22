Describe 'SpoolDoctor - Test-Spooler' {
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
        $script:logPath = Join-Path -Path 'TestDrive:\' -ChildPath ("test-spooler-{0}.log" -f [guid]::NewGuid().ToString('N'))

        Mock Test-IsAdministrator -ModuleName SpoolDoctor { return $false }
        Mock Get-SpoolerServiceStatus -ModuleName SpoolDoctor { return 'Running' }
        Mock Get-SpoolerPrinterRaw -ModuleName SpoolDoctor { return @() }
        Mock Get-SpoolerJobRaw -ModuleName SpoolDoctor { return @() }
        Mock Get-SpoolFile -ModuleName SpoolDoctor { return @() }
    }

    It 'declara CmdletBinding sem SupportsShouldProcess e executa sem exigir privilégio de administrador' {
        $command = Get-Command -Name 'Test-Spooler' -ErrorAction Stop
        $cmdletBinding = $command.ScriptBlock.Attributes |
            Where-Object { $_ -is [System.Management.Automation.CmdletBindingAttribute] } |
            Select-Object -First 1

        $cmdletBinding | Should -Not -BeNullOrEmpty
        $cmdletBinding.SupportsShouldProcess | Should -BeFalse

        $diag = Test-Spooler -LogPath $script:logPath
        $diag | Should -Not -BeNullOrEmpty
        Should -Invoke Test-IsAdministrator -ModuleName SpoolDoctor -Times 0 -Exactly
    }

    It 'retorna Healthy quando serviço está Running, sem impressoras com erro, sem jobs e sem arquivos em PRINTERS' {
        Mock Get-SpoolerPrinterRaw -ModuleName SpoolDoctor {
            return @([PSCustomObject]@{ Name = 'HP LaserJet'; PrinterStatus = 'Normal' })
        }

        $diag = Test-Spooler -LogPath $script:logPath

        $diag.PSObject.TypeNames | Should -Contain 'SpoolDoctor.Diagnostic'
        $diag.ComputerName | Should -Be $env:COMPUTERNAME
        $diag.ServiceStatus | Should -Be 'Running'
        $diag.PrinterCount | Should -Be 1
        $diag.UnhealthyPrinters.Count | Should -Be 0
        $diag.JobCount | Should -Be 0
        $diag.StuckJobs.Count | Should -Be 0
        $diag.SpoolFileCount | Should -Be 0
        $diag.HasOrphanSpoolFiles | Should -BeFalse
        $diag.Health | Should -Be 'Healthy'
        $diag.IsHealthy | Should -BeTrue
        $diag.Issues.Count | Should -Be 0
        $diag.Recommendation | Should -Match 'saudável'
        $diag.Timestamp | Should -BeOfType [datetime]

        Test-Path -LiteralPath $script:logPath -PathType Leaf | Should -BeTrue
        $logLines = @(Get-Content -LiteralPath $script:logPath -Encoding UTF8)
        $logLines.Count | Should -Be 1
        $logLines[0] | Should -Match 'Action=Test-Spooler'
        $logLines[0] | Should -Match 'Outcome=OK'
        $logLines[0] | Should -Match 'Healthy'
    }

    It 'retorna Critical quando serviço Spooler está Stopped e não consulta impressoras nem jobs' {
        Mock Get-SpoolerServiceStatus -ModuleName SpoolDoctor { return 'Stopped' }

        $diag = Test-Spooler -LogPath $script:logPath

        $diag.ServiceStatus | Should -Be 'Stopped'
        $diag.Health | Should -Be 'Critical'
        $diag.IsHealthy | Should -BeFalse
        ($diag.Issues -join ' ') | Should -Match 'Stopped'
        $diag.Recommendation | Should -Match 'Reset-Spooler'

        Should -Invoke Get-SpoolerPrinterRaw -ModuleName SpoolDoctor -Times 0 -Exactly
        Should -Invoke Get-SpoolerJobRaw -ModuleName SpoolDoctor -Times 0 -Exactly

        $logLines = @(Get-Content -LiteralPath $script:logPath -Encoding UTF8)
        $logLines.Count | Should -Be 1
        $logLines[0] | Should -Match 'Action=Test-Spooler'
        $logLines[0] | Should -Match 'Outcome=OK'
        $logLines[0] | Should -Match 'Critical'
    }

    It 'detecta job travado por idade (>= StuckThresholdMinutes) e respeita limiar customizado' {
        $now = Get-Date
        $script:agedJob = [PSCustomObject]@{
            Id            = 101
            PrinterName   = 'HP LaserJet'
            DocumentName  = 'Relatorio.pdf'
            SubmittedTime = $now.AddMinutes(-20)
            JobStatus     = 'Printing'
        }

        Mock Get-SpoolerPrinterRaw -ModuleName SpoolDoctor {
            return @([PSCustomObject]@{ Name = 'HP LaserJet'; PrinterStatus = 'Normal' })
        }
        Mock Get-SpoolerJobRaw -ModuleName SpoolDoctor {
            return @($script:agedJob)
        }

        $diagDefault = Test-Spooler -LogPath $script:logPath
        $diagDefault.JobCount | Should -Be 1
        $diagDefault.StuckJobs.Count | Should -Be 1
        $diagDefault.StuckJobs[0].Id | Should -Be 101
        $diagDefault.Health | Should -Be 'Warning'
        $diagDefault.IsHealthy | Should -BeFalse
        $diagDefault.Recommendation | Should -Match 'Remove-SpoolerJob'

        $customLogPath = Join-Path -Path 'TestDrive:\' -ChildPath ("test-spooler-custom-{0}.log" -f [guid]::NewGuid().ToString('N'))
        $diagCustom = Test-Spooler -StuckThresholdMinutes 30 -LogPath $customLogPath
        $diagCustom.JobCount | Should -Be 1
        $diagCustom.StuckJobs.Count | Should -Be 0
        $diagCustom.Health | Should -Be 'Healthy'
        $diagCustom.IsHealthy | Should -BeTrue
    }

    It 'detecta jobs travados por status problemático simples e composto separado por vírgula mesmo quando recentes' {
        $now = Get-Date
        $script:flagJobs = @(
            [PSCustomObject]@{
                Id            = 201
                PrinterName   = 'HP LaserJet'
                DocumentName  = 'Boleto.pdf'
                SubmittedTime = $now.AddMinutes(-1)
                JobStatus     = 'Error, Printing'
            },
            [PSCustomObject]@{
                Id            = 202
                PrinterName   = 'HP LaserJet'
                DocumentName  = 'Etiqueta.pdf'
                SubmittedTime = $now.AddMinutes(-1)
                JobStatus     = 'Deleting, Offline'
            }
        )

        Mock Get-SpoolerPrinterRaw -ModuleName SpoolDoctor {
            return @([PSCustomObject]@{ Name = 'HP LaserJet'; PrinterStatus = 'Normal' })
        }
        Mock Get-SpoolerJobRaw -ModuleName SpoolDoctor {
            return $script:flagJobs
        }

        $diag = Test-Spooler -LogPath $script:logPath

        $diag.JobCount | Should -Be 2
        $diag.StuckJobs.Count | Should -Be 2
        $diag.StuckJobs[0].Id | Should -Be 201
        $diag.StuckJobs[1].Id | Should -Be 202
        $diag.Health | Should -Be 'Warning'
        $diag.IsHealthy | Should -BeFalse
        $diag.Recommendation | Should -Match 'Remove-SpoolerJob'
    }

    It 'detecta impressora com status composto de erro ou offline em UnhealthyPrinters' {
        Mock Get-SpoolerPrinterRaw -ModuleName SpoolDoctor {
            return @([PSCustomObject]@{ Name = 'HP Financeiro'; PrinterStatus = 'Offline, PaperOut' })
        }

        $diag = Test-Spooler -LogPath $script:logPath

        $diag.PrinterCount | Should -Be 1
        $diag.UnhealthyPrinters.Count | Should -Be 1
        $diag.UnhealthyPrinters[0].Name | Should -Be 'HP Financeiro'
        $diag.UnhealthyPrinters[0].Status | Should -Be 'Offline, PaperOut'
        $diag.Health | Should -Be 'Warning'
        $diag.IsHealthy | Should -BeFalse
        ($diag.Issues -join ' ') | Should -Match 'HP Financeiro'
        ($diag.Issues -join ' ') | Should -Match 'Offline, PaperOut'
    }

    It 'detecta arquivos órfãos .SPL e .SHD em PRINTERS com 0 jobs e classifica como Critical recomendando Reset-Spooler' {
        Mock Get-SpoolFile -ModuleName SpoolDoctor {
            return @(
                [PSCustomObject]@{ FullName = 'C:\Windows\System32\spool\PRINTERS\00001.SPL' },
                [PSCustomObject]@{ FullName = 'C:\Windows\System32\spool\PRINTERS\00001.SHD' }
            )
        }

        $diag = Test-Spooler -LogPath $script:logPath

        $diag.JobCount | Should -Be 0
        $diag.SpoolFileCount | Should -Be 2
        $diag.HasOrphanSpoolFiles | Should -BeTrue
        $diag.Health | Should -Be 'Critical'
        $diag.IsHealthy | Should -BeFalse
        ($diag.Issues -join ' ') | Should -Match 'órfão'
        $diag.Recommendation | Should -Match 'Reset-Spooler'
    }

    It 'trata UnauthorizedAccessException em PRINTERS graciosamente com SpoolFileCount nulo e aviso em Issues' {
        Mock Get-SpoolFile -ModuleName SpoolDoctor {
            throw (New-Object -TypeName System.UnauthorizedAccessException -ArgumentList 'Acesso negado à pasta PRINTERS.')
        }

        $diag = Test-Spooler -LogPath $script:logPath

        ($null -eq $diag.SpoolFileCount) | Should -BeTrue
        $diag.HasOrphanSpoolFiles | Should -BeFalse
        $diag.Health | Should -Be 'Warning'
        $diag.IsHealthy | Should -BeFalse
        ($diag.Issues -join ' ') | Should -Match 'PRINTERS'
        ($diag.Issues -join ' ') | Should -Match 'Administrador'

        $logLines = @(Get-Content -LiteralPath $script:logPath -Encoding UTF8)
        $logLines.Count | Should -Be 1
        $logLines[0] | Should -Match 'Action=Test-Spooler'
        $logLines[0] | Should -Match 'Outcome=OK'
    }

    It 'registra Outcome Failed no log e propaga erro quando Get-SpoolerServiceStatus falha' {
        Mock Get-SpoolerServiceStatus -ModuleName SpoolDoctor {
            throw 'Falha ao consultar serviço Spooler.'
        }

        { Test-Spooler -LogPath $script:logPath } | Should -Throw '*Falha ao consultar serviço Spooler.*'

        $logLines = @(Get-Content -LiteralPath $script:logPath -Encoding UTF8)
        $logLines.Count | Should -Be 1
        $logLines[0] | Should -Match 'Action=Test-Spooler'
        $logLines[0] | Should -Match 'Outcome=Failed'
        $logLines[0] | Should -Match 'Falha ao consultar serviço Spooler\.'
    }

    It 'registra Outcome Failed no log e propaga erro quando Get-SpoolerPrinterRaw ou Get-SpoolerJobRaw falha com serviço Running' {
        Mock Get-SpoolerPrinterRaw -ModuleName SpoolDoctor {
            throw 'Erro WMI ao listar impressoras.'
        }

        { Test-Spooler -LogPath $script:logPath } | Should -Throw '*Erro WMI ao listar impressoras.*'

        $logLines = @(Get-Content -LiteralPath $script:logPath -Encoding UTF8)
        $logLines.Count | Should -Be 1
        $logLines[0] | Should -Match 'Action=Test-Spooler'
        $logLines[0] | Should -Match 'Outcome=Failed'
        $logLines[0] | Should -Match 'Erro WMI ao listar impressoras\.'

        $jobFailLogPath = Join-Path -Path 'TestDrive:\' -ChildPath ("test-spooler-jobfail-{0}.log" -f [guid]::NewGuid().ToString('N'))
        Mock Get-SpoolerPrinterRaw -ModuleName SpoolDoctor {
            return @([PSCustomObject]@{ Name = 'HP LaserJet'; PrinterStatus = 'Normal' })
        }
        Mock Get-SpoolerJobRaw -ModuleName SpoolDoctor {
            throw 'Erro ao ler fila da impressora.'
        }

        { Test-Spooler -LogPath $jobFailLogPath } | Should -Throw '*Erro ao ler fila da impressora.*'

        $jobFailLogs = @(Get-Content -LiteralPath $jobFailLogPath -Encoding UTF8)
        $jobFailLogs.Count | Should -Be 1
        $jobFailLogs[0] | Should -Match 'Action=Test-Spooler'
        $jobFailLogs[0] | Should -Match 'Outcome=Failed'
        $jobFailLogs[0] | Should -Match 'Erro ao ler fila da impressora\.'
    }
}
