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
        $diag.Recommendation | Should -Match 'Restart-Spooler'
        $diag.Recommendation | Should -Match 'preserv'
        $diag.Recommendation | Should -Match 'Reset-Spooler'
        $diag.Recommendation.IndexOf('Restart-Spooler') | Should -BeLessThan ($diag.Recommendation.IndexOf('Reset-Spooler'))

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

    Context 'Execução remota (Operação 6)' {
        BeforeEach {
            $script:remoteAllowListPath = Join-Path -Path 'TestDrive:\' -ChildPath ("test-spooler-allow-{0}.txt" -f [guid]::NewGuid().ToString('N'))
            @(
                'PC-REMOTO-01'
                'SRV-PRINT-01|PrintServer'
            ) | Set-Content -LiteralPath $script:remoteAllowListPath -Encoding UTF8

            $script:remoteSessionObj = [PSCustomObject]@{ ComputerName = 'PC-REMOTO-01'; Id = 4 }
            Mock New-SpoolerRemoteSession -ModuleName SpoolDoctor { return $script:remoteSessionObj }
            Mock Invoke-SpoolerRemoteScript -ModuleName SpoolDoctor {
                return [PSCustomObject]@{
                    PSTypeName          = 'Deserialized.SpoolDoctor.Diagnostic'
                    ComputerName        = 'PC-REMOTO-01'
                    ServiceStatus       = 'Running'
                    PrinterCount        = 1
                    UnhealthyPrinters   = @()
                    JobCount            = 0
                    StuckJobs           = @()
                    SpoolFileCount      = 0
                    HasOrphanSpoolFiles = $false
                    Health              = 'Healthy'
                    IsHealthy           = $true
                    Issues              = @()
                    Recommendation      = 'Spooler saudável. Nenhuma ação corretiva necessária.'
                    Timestamp           = Get-Date
                }
            }
            Mock Remove-SpoolerRemoteSession -ModuleName SpoolDoctor {}
        }

        It 'preserva execução local quando -ComputerName aponta para a máquina local' {
            $diag = Test-Spooler -ComputerName $env:COMPUTERNAME -AllowedComputersPath $script:remoteAllowListPath -LogPath $script:logPath

            $diag.ComputerName | Should -Be $env:COMPUTERNAME
            $diag.Health | Should -Be 'Healthy'
            Should -Invoke New-SpoolerRemoteSession -ModuleName SpoolDoctor -Times 0 -Exactly
            Should -Invoke Get-SpoolerServiceStatus -ModuleName SpoolDoctor -Times 1 -Exactly
        }

        It 'executa diagnóstico remoto reconstruindo SpoolDoctor.Diagnostic com hostname e grava log' {
            $cred = New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList @(
                'DOMINIO\operador',
                (New-Object -TypeName System.Security.SecureString)
            )

            Mock Invoke-SpoolerRemoteScript -ModuleName SpoolDoctor {
                return [PSCustomObject]@{
                    PSTypeName          = 'Deserialized.SpoolDoctor.Diagnostic'
                    ComputerName        = 'PC-REMOTO-01'
                    ServiceStatus       = 'Running'
                    PrinterCount        = 2
                    UnhealthyPrinters   = @([PSCustomObject]@{ Name = 'HP Remota'; Status = 'Offline' })
                    JobCount            = 1
                    StuckJobs           = @([PSCustomObject]@{ Id = 77; PrinterName = 'HP Remota'; Document = 'Doc.pdf'; Status = 'Error'; Age = [timespan]::FromMinutes(20); Reason = 'Status=Error' })
                    SpoolFileCount      = $null
                    HasOrphanSpoolFiles = $false
                    Health              = 'Warning'
                    IsHealthy           = $false
                    Issues              = @("Impressora 'HP Remota' com status de alerta ('Offline').")
                    Recommendation      = 'Tente cancelar com Remove-SpoolerJob.'
                    Timestamp           = Get-Date
                }
            }

            $diag = Test-Spooler -ComputerName 'pc-remoto-01' -StuckThresholdMinutes 20 -Credential $cred -AllowedComputersPath $script:remoteAllowListPath -LogPath $script:logPath

            $diag.PSObject.TypeNames | Should -Contain 'SpoolDoctor.Diagnostic'
            $diag.ComputerName | Should -Be 'PC-REMOTO-01'
            $diag.Health | Should -Be 'Warning'
            $diag.UnhealthyPrinters.Count | Should -Be 1
            $diag.StuckJobs.Count | Should -Be 1
            ($null -eq $diag.SpoolFileCount) | Should -BeTrue
            $diag.Issues.Count | Should -Be 1

            Should -Invoke New-SpoolerRemoteSession -ModuleName SpoolDoctor -Times 1 -Exactly -ParameterFilter {
                $ComputerName -eq 'PC-REMOTO-01' -and $null -ne $Credential
            }
            Should -Invoke Invoke-SpoolerRemoteScript -ModuleName SpoolDoctor -Times 1 -Exactly
            Should -Invoke Remove-SpoolerRemoteSession -ModuleName SpoolDoctor -Times 1 -Exactly

            $logLines = @(Get-Content -LiteralPath $script:logPath -Encoding UTF8)
            $logLines.Count | Should -Be 1
            $logLines[0] | Should -Match 'Computer=PC-REMOTO-01'
            $logLines[0] | Should -Match 'Action=Test-Spooler'
            $logLines[0] | Should -Match 'Outcome=OK'
            $logLines[0] | Should -Match 'Warning'
        }

        It 'recusa -ComputerName inválido ou fora da allow-list com log Failed e sem abrir sessão' {
            { Test-Spooler -ComputerName 'PC;bad' -AllowedComputersPath $script:remoteAllowListPath -LogPath $script:logPath } | Should -Throw

            $unlistedLog = Join-Path -Path 'TestDrive:\' -ChildPath ("test-unlisted-{0}.log" -f [guid]::NewGuid().ToString('N'))
            { Test-Spooler -ComputerName 'PC-INTRUSO' -AllowedComputersPath $script:remoteAllowListPath -LogPath $unlistedLog } | Should -Throw '*allow-list*'

            Should -Invoke New-SpoolerRemoteSession -ModuleName SpoolDoctor -Times 0 -Exactly

            $logLines = @(Get-Content -LiteralPath $unlistedLog -Encoding UTF8)
            $logLines.Count | Should -Be 1
            $logLines[0] | Should -Match 'Computer=PC-INTRUSO'
            $logLines[0] | Should -Match 'Outcome=Failed'
        }

        It 'recusa -Credential sem alvo remoto com log Failed e sem abrir sessão' {
            $cred = New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList @(
                'DOMINIO\operador',
                (New-Object -TypeName System.Security.SecureString)
            )

            { Test-Spooler -Credential $cred -LogPath $script:logPath } | Should -Throw '*Credential*'
            Should -Invoke New-SpoolerRemoteSession -ModuleName SpoolDoctor -Times 0 -Exactly

            $logLines = @(Get-Content -LiteralPath $script:logPath -Encoding UTF8)
            $logLines.Count | Should -Be 1
            $logLines[0] | Should -Match 'Outcome=Failed'
        }

        It 'registra Unreachable, fecha sessão no finally e propaga erro em falha de conectividade WinRM' {
            Mock Invoke-SpoolerRemoteScript -ModuleName SpoolDoctor {
                throw (New-Object -TypeName System.Management.Automation.Remoting.PSRemotingTransportException -ArgumentList 'WinRM unreachable.')
            }

            { Test-Spooler -ComputerName 'PC-REMOTO-01' -AllowedComputersPath $script:remoteAllowListPath -LogPath $script:logPath } | Should -Throw '*PC-REMOTO-01*'

            Should -Invoke Remove-SpoolerRemoteSession -ModuleName SpoolDoctor -Times 1 -Exactly
            $logLines = @(Get-Content -LiteralPath $script:logPath -Encoding UTF8)
            $logLines.Count | Should -Be 1
            $logLines[0] | Should -Match 'Computer=PC-REMOTO-01'
            $logLines[0] | Should -Match 'Outcome=Unreachable'
        }

        It 'registra Failed e propaga erro em falha de autenticação WinRM' {
            Mock New-SpoolerRemoteSession -ModuleName SpoolDoctor {
                throw (New-Object -TypeName System.UnauthorizedAccessException -ArgumentList 'Access denied.')
            }

            { Test-Spooler -ComputerName 'PC-REMOTO-01' -AllowedComputersPath $script:remoteAllowListPath -LogPath $script:logPath } | Should -Throw '*PC-REMOTO-01*'

            Should -Invoke Remove-SpoolerRemoteSession -ModuleName SpoolDoctor -Times 0 -Exactly
            $logLines = @(Get-Content -LiteralPath $script:logPath -Encoding UTF8)
            $logLines.Count | Should -Be 1
            $logLines[0] | Should -Match 'Computer=PC-REMOTO-01'
            $logLines[0] | Should -Match 'Outcome=Failed'
        }
    }

    Context 'Execução remota em lote (Operação 7)' {
        BeforeEach {
            $script:batchAllowListPath = Join-Path -Path 'TestDrive:\' -ChildPath ("test-spooler-batch-allow-{0}.txt" -f [guid]::NewGuid().ToString('N'))
            @(
                'PC-REMOTO-01'
                'PC-REMOTO-02'
                'PC-REMOTO-03'
                'SRV-PRINT-01|PrintServer'
            ) | Set-Content -LiteralPath $script:batchAllowListPath -Encoding UTF8

            $script:openedSessionTargets = New-Object -TypeName 'System.Collections.Generic.List[string]'
            $script:closedSessionTargets = New-Object -TypeName 'System.Collections.Generic.List[string]'

            Mock New-SpoolerRemoteSession -ModuleName SpoolDoctor {
                param([string]$ComputerName, [PSCredential]$Credential)
                $script:openedSessionTargets.Add($ComputerName)
                return [PSCustomObject]@{ ComputerName = $ComputerName; Id = $script:openedSessionTargets.Count }
            }
            Mock Invoke-SpoolerRemoteScript -ModuleName SpoolDoctor {
                param($Session, $ScriptBlock, $ArgumentList)
                $targetHost = [string]$ArgumentList[0]
                $health = switch ($targetHost) {
                    'PC-REMOTO-01' { 'Healthy' }
                    'PC-REMOTO-02' { 'Warning' }
                    default        { 'Critical' }
                }
                return [PSCustomObject]@{
                    PSTypeName          = 'Deserialized.SpoolDoctor.Diagnostic'
                    ComputerName        = $targetHost
                    ServiceStatus       = if ($health -eq 'Critical') { 'Stopped' } else { 'Running' }
                    PrinterCount        = 1
                    UnhealthyPrinters   = @()
                    JobCount            = if ($health -eq 'Warning') { 1 } else { 0 }
                    StuckJobs           = @()
                    SpoolFileCount      = 0
                    HasOrphanSpoolFiles = $false
                    Health              = $health
                    IsHealthy           = ($health -eq 'Healthy')
                    Issues              = if ($health -eq 'Healthy') { @() } else { @("Alerta em $targetHost") }
                    Recommendation      = "Recomendação para $targetHost"
                    Timestamp           = Get-Date
                }
            }
            Mock Remove-SpoolerRemoteSession -ModuleName SpoolDoctor {
                param($Session)
                $script:closedSessionTargets.Add([string]$Session.ComputerName)
            }
        }

        It 'executa diagnóstico em lote 100% bem-sucedido em 3 máquinas retornando SpoolDoctor.Diagnostic e logs' {
            $diags = @(Test-Spooler -ComputerName @('PC-REMOTO-01', 'pc-remoto-02', 'PC-REMOTO-03') -AllowedComputersPath $script:batchAllowListPath -LogPath $script:logPath)

            $diags.Count | Should -Be 3
            foreach ($diag in $diags) {
                $diag.PSObject.TypeNames | Should -Contain 'SpoolDoctor.Diagnostic'
            }
            $diags[0].ComputerName | Should -Be 'PC-REMOTO-01'
            $diags[0].Health | Should -Be 'Healthy'
            $diags[0].IsHealthy | Should -BeTrue
            $diags[1].ComputerName | Should -Be 'PC-REMOTO-02'
            $diags[1].Health | Should -Be 'Warning'
            $diags[1].IsHealthy | Should -BeFalse
            $diags[2].ComputerName | Should -Be 'PC-REMOTO-03'
            $diags[2].Health | Should -Be 'Critical'
            $diags[2].IsHealthy | Should -BeFalse

            $script:openedSessionTargets.ToArray() | Should -Be @('PC-REMOTO-01', 'PC-REMOTO-02', 'PC-REMOTO-03')
            $script:closedSessionTargets.ToArray() | Should -Be @('PC-REMOTO-01', 'PC-REMOTO-02', 'PC-REMOTO-03')

            $logLines = @(Get-Content -LiteralPath $script:logPath -Encoding UTF8)
            $logLines.Count | Should -Be 3
            $logLines[0] | Should -Match 'Computer=PC-REMOTO-01.*Outcome=OK'
            $logLines[1] | Should -Match 'Computer=PC-REMOTO-02.*Outcome=OK'
            $logLines[2] | Should -Match 'Computer=PC-REMOTO-03.*Outcome=OK'
        }

        It 'isola falhas Unreachable, allow-list e entrada vazia retornando SpoolDoctor.Diagnostic de falha no lote' {
            Mock Invoke-SpoolerRemoteScript -ModuleName SpoolDoctor {
                param($Session, $ScriptBlock, $ArgumentList)
                $targetHost = [string]$ArgumentList[0]
                if ($targetHost -eq 'PC-REMOTO-02') {
                    throw (New-Object -TypeName System.Management.Automation.Remoting.PSRemotingTransportException -ArgumentList 'WinRM unreachable.')
                }
                $health = if ($targetHost -eq 'PC-REMOTO-03') { 'Warning' } else { 'Healthy' }
                return [PSCustomObject]@{
                    PSTypeName          = 'Deserialized.SpoolDoctor.Diagnostic'
                    ComputerName        = $targetHost
                    ServiceStatus       = 'Running'
                    PrinterCount        = 1
                    UnhealthyPrinters   = @()
                    JobCount            = 0
                    StuckJobs           = @()
                    SpoolFileCount      = 0
                    HasOrphanSpoolFiles = $false
                    Health              = $health
                    IsHealthy           = ($health -eq 'Healthy')
                    Issues              = @()
                    Recommendation      = 'OK'
                    Timestamp           = Get-Date
                }
            }

            $diags = @(Test-Spooler -ComputerName @('PC-REMOTO-01', 'PC-REMOTO-02', 'PC-INTRUSO', '', 'PC-REMOTO-03') -AllowedComputersPath $script:batchAllowListPath -LogPath $script:logPath)

            $diags.Count | Should -Be 5
            foreach ($diag in $diags) {
                $diag.PSObject.TypeNames | Should -Contain 'SpoolDoctor.Diagnostic'
            }

            $diags[0].ComputerName | Should -Be 'PC-REMOTO-01'
            $diags[0].Health | Should -Be 'Healthy'
            $diags[0].IsHealthy | Should -BeTrue

            $diags[1].ComputerName | Should -Be 'PC-REMOTO-02'
            $diags[1].Health | Should -Be 'Unreachable'
            $diags[1].IsHealthy | Should -BeFalse
            $diags[1].ServiceStatus | Should -Be 'Unknown'
            ($null -eq $diags[1].PrinterCount) | Should -BeTrue
            ($null -eq $diags[1].JobCount) | Should -BeTrue
            ($null -eq $diags[1].SpoolFileCount) | Should -BeTrue
            $diags[1].Issues.Count | Should -BeGreaterThan 0
            $diags[1].Recommendation | Should -Match 'WinRM|rede'

            $diags[2].ComputerName | Should -Be 'PC-INTRUSO'
            $diags[2].Health | Should -Be 'Failed'
            $diags[2].IsHealthy | Should -BeFalse
            ($null -eq $diags[2].PrinterCount) | Should -BeTrue
            ($null -eq $diags[2].JobCount) | Should -BeTrue
            ($diags[2].Issues -join ' ') | Should -Match 'allow-list'

            $diags[3].ComputerName | Should -Be '(inválido)'
            $diags[3].Health | Should -Be 'Failed'
            $diags[3].IsHealthy | Should -BeFalse

            $diags[4].ComputerName | Should -Be 'PC-REMOTO-03'
            $diags[4].Health | Should -Be 'Warning'
            $diags[4].IsHealthy | Should -BeFalse

            $script:openedSessionTargets.ToArray() | Should -Be @('PC-REMOTO-01', 'PC-REMOTO-02', 'PC-REMOTO-03')
            $script:closedSessionTargets.ToArray() | Should -Be @('PC-REMOTO-01', 'PC-REMOTO-02', 'PC-REMOTO-03')

            $logLines = @(Get-Content -LiteralPath $script:logPath -Encoding UTF8)
            $logLines.Count | Should -Be 5
            $logLines[0] | Should -Match 'Computer=PC-REMOTO-01.*Outcome=OK'
            $logLines[1] | Should -Match 'Computer=PC-REMOTO-02.*Outcome=Unreachable'
            $logLines[2] | Should -Match 'Computer=PC-INTRUSO.*Outcome=Failed'
            $logLines[3] | Should -Match 'Computer=\(inválido\).*Outcome=Failed'
            $logLines[4] | Should -Match 'Computer=PC-REMOTO-03.*Outcome=OK'
        }

        It 'suporta lote misto, deduplicação, colapso de duplicata para 1 alvo falhando e @() vazio sob StrictMode' {
            $mixedDiags = @(& {
                Set-StrictMode -Version Latest
                Test-Spooler -ComputerName @('localhost', $env:COMPUTERNAME, 'pc-remoto-01', 'PC-REMOTO-01') -AllowedComputersPath $script:batchAllowListPath -LogPath $script:logPath
            })

            $mixedDiags.Count | Should -Be 2
            $mixedDiags[0].ComputerName | Should -Be $env:COMPUTERNAME
            $mixedDiags[0].Health | Should -Be 'Healthy'
            $mixedDiags[1].ComputerName | Should -Be 'PC-REMOTO-01'
            $mixedDiags[1].Health | Should -Be 'Healthy'
            Should -Invoke Get-SpoolerServiceStatus -ModuleName SpoolDoctor -Times 1 -Exactly
            Should -Invoke New-SpoolerRemoteSession -ModuleName SpoolDoctor -Times 1 -Exactly

            $collapseLog = Join-Path -Path 'TestDrive:\' -ChildPath ("test-spooler-collapse-{0}.log" -f [guid]::NewGuid().ToString('N'))
            Mock Invoke-SpoolerRemoteScript -ModuleName SpoolDoctor {
                throw (New-Object -TypeName System.Management.Automation.Remoting.PSRemotingTransportException -ArgumentList 'WinRM unreachable.')
            }

            {
                Set-StrictMode -Version Latest
                Test-Spooler -ComputerName @('PC-REMOTO-01', 'pc-remoto-01') -AllowedComputersPath $script:batchAllowListPath -LogPath $collapseLog
            } | Should -Throw '*PC-REMOTO-01*'

            $collapseLogs = @(Get-Content -LiteralPath $collapseLog -Encoding UTF8)
            $collapseLogs.Count | Should -Be 1
            $collapseLogs[0] | Should -Match 'Computer=PC-REMOTO-01.*Outcome=Unreachable'

            $emptyLog = Join-Path -Path 'TestDrive:\' -ChildPath ("test-spooler-empty-{0}.log" -f [guid]::NewGuid().ToString('N'))
            {
                Set-StrictMode -Version Latest
                Test-Spooler -ComputerName @() -AllowedComputersPath $script:batchAllowListPath -LogPath $emptyLog
            } | Should -Throw

            $emptyLogs = @(Get-Content -LiteralPath $emptyLog -Encoding UTF8)
            $emptyLogs.Count | Should -Be 1
            $emptyLogs[0] | Should -Match 'Computer=\(inválido\).*Outcome=Failed'
        }
    }
}
