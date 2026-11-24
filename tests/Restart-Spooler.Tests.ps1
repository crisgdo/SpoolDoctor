Describe 'SpoolDoctor - Restart-Spooler' {
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
        $script:logPath = Join-Path -Path 'TestDrive:\' -ChildPath ("restart-{0}.log" -f [guid]::NewGuid().ToString('N'))

        Mock Test-IsAdministrator -ModuleName SpoolDoctor { return $true }
        Mock Get-SpoolerServiceStatus -ModuleName SpoolDoctor { return 'Running' }
        Mock Stop-SpoolerService -ModuleName SpoolDoctor {}
        Mock Start-SpoolerService -ModuleName SpoolDoctor {}
        Mock Get-SpoolFile -ModuleName SpoolDoctor { return @() }
        Mock Copy-SpoolFile -ModuleName SpoolDoctor {}
        Mock Remove-SpoolFile -ModuleName SpoolDoctor {}
        Mock Remove-OldSpoolBackup -ModuleName SpoolDoctor {
            return [PSCustomObject]@{
                RemovedCount = 0
                Warnings     = @()
            }
        }
    }

    It 'declara SupportsShouldProcess e ConfirmImpact = High' {
        $command = Get-Command -Name 'Restart-Spooler' -ErrorAction Stop
        $cmdletBinding = $command.ScriptBlock.Attributes |
            Where-Object { $_ -is [System.Management.Automation.CmdletBindingAttribute] } |
            Select-Object -First 1

        $cmdletBinding | Should -Not -BeNullOrEmpty
        $cmdletBinding.SupportsShouldProcess | Should -BeTrue
        $cmdletBinding.ConfirmImpact | Should -Be ([System.Management.Automation.ConfirmImpact]::High)
    }

    It 'recusa execução sem privilégio de administrador, registra log e não toca no serviço nem em PRINTERS' {
        Mock Test-IsAdministrator -ModuleName SpoolDoctor { return $false }

        $result = Restart-Spooler -Confirm:$false -LogPath $script:logPath

        $result.PSObject.TypeNames | Should -Contain 'SpoolDoctor.ActionResult'
        $result.ComputerName | Should -Be $env:COMPUTERNAME
        $result.Action | Should -Be 'Restart-Spooler'
        $result.Outcome | Should -Be 'Failed'
        $result.Message | Should -Match 'Administrador'
        $result.Timestamp | Should -BeOfType [datetime]

        Should -Invoke Get-SpoolerServiceStatus -ModuleName SpoolDoctor -Times 0 -Exactly
        Should -Invoke Stop-SpoolerService -ModuleName SpoolDoctor -Times 0 -Exactly
        Should -Invoke Start-SpoolerService -ModuleName SpoolDoctor -Times 0 -Exactly
        Should -Invoke Get-SpoolFile -ModuleName SpoolDoctor -Times 0 -Exactly
        Should -Invoke Copy-SpoolFile -ModuleName SpoolDoctor -Times 0 -Exactly
        Should -Invoke Remove-SpoolFile -ModuleName SpoolDoctor -Times 0 -Exactly
        Should -Invoke Remove-OldSpoolBackup -ModuleName SpoolDoctor -Times 0 -Exactly

        Test-Path -LiteralPath $script:logPath -PathType Leaf | Should -BeTrue
        $logLines = @(Get-Content -LiteralPath $script:logPath -Encoding UTF8)
        $logLines.Count | Should -Be 1
        $logLines[0] | Should -Match 'Action=Restart-Spooler'
        $logLines[0] | Should -Match 'Outcome=Failed'
    }

    It 'em modo -WhatIf não chama wrappers de serviço nem de arquivo, grava log e retorna Simulated' {
        $result = Restart-Spooler -WhatIf -LogPath $script:logPath

        $result.ComputerName | Should -Be $env:COMPUTERNAME
        $result.Action | Should -Be 'Restart-Spooler'
        $result.Outcome | Should -Be 'Simulated'
        $result.Timestamp | Should -BeOfType [datetime]

        Should -Invoke Get-SpoolerServiceStatus -ModuleName SpoolDoctor -Times 0 -Exactly
        Should -Invoke Stop-SpoolerService -ModuleName SpoolDoctor -Times 0 -Exactly
        Should -Invoke Start-SpoolerService -ModuleName SpoolDoctor -Times 0 -Exactly
        Should -Invoke Get-SpoolFile -ModuleName SpoolDoctor -Times 0 -Exactly
        Should -Invoke Copy-SpoolFile -ModuleName SpoolDoctor -Times 0 -Exactly
        Should -Invoke Remove-SpoolFile -ModuleName SpoolDoctor -Times 0 -Exactly
        Should -Invoke Remove-OldSpoolBackup -ModuleName SpoolDoctor -Times 0 -Exactly

        Test-Path -LiteralPath $script:logPath -PathType Leaf | Should -BeTrue
        $logLines = @(Get-Content -LiteralPath $script:logPath -Encoding UTF8)
        $logLines.Count | Should -Be 1
        $logLines[0] | Should -Match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}'
        $logLines[0] | Should -Match 'Action=Restart-Spooler'
        $logLines[0] | Should -Match 'Outcome=Simulated'
    }

    It 'retorna Skipped e registra log quando o usuário recusa a confirmação' {
        $physicalTestDrive = (Get-PSDrive -Name 'TestDrive').Root
        $childLogPath = Join-Path -Path $physicalTestDrive -ChildPath ("restart-skipped-{0}.log" -f [guid]::NewGuid().ToString('N'))

        $childScript = @"
`$ErrorActionPreference = 'Stop'
Import-Module -Name '$manifestPath' -Force
& (Get-Module -Name 'SpoolDoctor') {
    function script:Test-IsAdministrator { return `$true }
    function script:Get-SpoolerServiceStatus { throw 'Não deveria chamar Get-SpoolerServiceStatus.' }
    function script:Stop-SpoolerService { [CmdletBinding(SupportsShouldProcess)] param() throw 'Não deveria chamar Stop-SpoolerService.' }
    function script:Start-SpoolerService { [CmdletBinding(SupportsShouldProcess)] param() throw 'Não deveria chamar Start-SpoolerService.' }
    function script:Get-SpoolFile { throw 'Não deveria chamar Get-SpoolFile.' }
    function script:Copy-SpoolFile { [CmdletBinding(SupportsShouldProcess)] param([string]`$Path, [string]`$DestinationDirectory) throw 'Não deveria chamar Copy-SpoolFile.' }
    function script:Remove-SpoolFile { [CmdletBinding(SupportsShouldProcess)] param([string]`$Path) throw 'Não deveria chamar Remove-SpoolFile.' }
    function script:Remove-OldSpoolBackup { [CmdletBinding(SupportsShouldProcess)] param([string]`$BackupRoot, [int]`$RetentionDays = 7) throw 'Não deveria chamar Remove-OldSpoolBackup.' }
}
Restart-Spooler -LogPath '$childLogPath' | ConvertTo-Json -Compress
"@

        $rawOutput = @('N' | & powershell.exe -NoProfile -Command $childScript)
        $LASTEXITCODE | Should -Be 0

        $jsonLine = $rawOutput | Where-Object { $_ -match '^\s*\{.*\}\s*$' } | Select-Object -Last 1
        $jsonLine | Should -Not -BeNullOrEmpty

        $parsedResult = $jsonLine | ConvertFrom-Json
        $parsedResult.Outcome | Should -Be 'Skipped'
        $parsedResult.Action | Should -Be 'Restart-Spooler'
        $parsedResult.ComputerName | Should -Be $env:COMPUTERNAME

        Test-Path -LiteralPath $childLogPath -PathType Leaf | Should -BeTrue
        $logLines = @(Get-Content -LiteralPath $childLogPath -Encoding UTF8)
        $logLines.Count | Should -Be 1
        $logLines[0] | Should -Match 'Action=Restart-Spooler'
        $logLines[0] | Should -Match 'Outcome=Skipped'
    }

    It 'quando serviço já está Stopped, executa apenas Start-SpoolerService, verifica Running e nunca toca em PRINTERS' {
        $script:stoppedCalls = 0
        Mock Get-SpoolerServiceStatus -ModuleName SpoolDoctor {
            $script:stoppedCalls++
            if ($script:stoppedCalls -eq 1) {
                return 'Stopped'
            }
            return 'Running'
        }

        $result = Restart-Spooler -Confirm:$false -LogPath $script:logPath

        $result.PSObject.TypeNames | Should -Contain 'SpoolDoctor.ActionResult'
        $result.ComputerName | Should -Be $env:COMPUTERNAME
        $result.Action | Should -Be 'Restart-Spooler'
        $result.Outcome | Should -Be 'OK'
        $result.Message | Should -Match 'iniciado'
        $result.Message | Should -Match 'preserv'
        $result.Timestamp | Should -BeOfType [datetime]

        Should -Invoke Get-SpoolerServiceStatus -ModuleName SpoolDoctor -Times 2 -Exactly
        Should -Invoke Stop-SpoolerService -ModuleName SpoolDoctor -Times 0 -Exactly
        Should -Invoke Start-SpoolerService -ModuleName SpoolDoctor -Times 1 -Exactly
        Should -Invoke Get-SpoolFile -ModuleName SpoolDoctor -Times 0 -Exactly
        Should -Invoke Copy-SpoolFile -ModuleName SpoolDoctor -Times 0 -Exactly
        Should -Invoke Remove-SpoolFile -ModuleName SpoolDoctor -Times 0 -Exactly
        Should -Invoke Remove-OldSpoolBackup -ModuleName SpoolDoctor -Times 0 -Exactly

        $logLines = @(Get-Content -LiteralPath $script:logPath -Encoding UTF8)
        $logLines.Count | Should -Be 1
        $logLines[0] | Should -Match 'Action=Restart-Spooler'
        $logLines[0] | Should -Match 'Outcome=OK'
    }

    It 'quando serviço está Running, para e inicia em ordem, verifica Running e nunca toca em PRINTERS' {
        $script:callOrder = New-Object -TypeName 'System.Collections.Generic.List[string]'
        $script:runningCalls = 0

        Mock Get-SpoolerServiceStatus -ModuleName SpoolDoctor {
            $script:runningCalls++
            $script:callOrder.Add("Status:$script:runningCalls")
            return 'Running'
        }
        Mock Stop-SpoolerService -ModuleName SpoolDoctor {
            $script:callOrder.Add('Stop')
        }
        Mock Start-SpoolerService -ModuleName SpoolDoctor {
            $script:callOrder.Add('Start')
        }

        $result = Restart-Spooler -Confirm:$false -LogPath $script:logPath

        $result.PSObject.TypeNames | Should -Contain 'SpoolDoctor.ActionResult'
        $result.ComputerName | Should -Be $env:COMPUTERNAME
        $result.Action | Should -Be 'Restart-Spooler'
        $result.Outcome | Should -Be 'OK'
        $result.Message | Should -Match 'reiniciado'
        $result.Message | Should -Match 'preserv'
        $result.Timestamp | Should -BeOfType [datetime]

        $script:callOrder.ToArray() | Should -Be @('Status:1', 'Stop', 'Start', 'Status:2')

        Should -Invoke Get-SpoolerServiceStatus -ModuleName SpoolDoctor -Times 2 -Exactly
        Should -Invoke Stop-SpoolerService -ModuleName SpoolDoctor -Times 1 -Exactly
        Should -Invoke Start-SpoolerService -ModuleName SpoolDoctor -Times 1 -Exactly
        Should -Invoke Get-SpoolFile -ModuleName SpoolDoctor -Times 0 -Exactly
        Should -Invoke Copy-SpoolFile -ModuleName SpoolDoctor -Times 0 -Exactly
        Should -Invoke Remove-SpoolFile -ModuleName SpoolDoctor -Times 0 -Exactly
        Should -Invoke Remove-OldSpoolBackup -ModuleName SpoolDoctor -Times 0 -Exactly

        $logLines = @(Get-Content -LiteralPath $script:logPath -Encoding UTF8)
        $logLines.Count | Should -Be 1
        $logLines[0] | Should -Match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}'
        $logLines[0] | Should -Match "Computer=$([regex]::Escape($env:COMPUTERNAME))"
        $logLines[0] | Should -Match 'Action=Restart-Spooler'
        $logLines[0] | Should -Match 'Outcome=OK'
    }

    It 'retorna Failed e grava log quando Stop-SpoolerService falha sem chamar Start-SpoolerService' {
        Mock Stop-SpoolerService -ModuleName SpoolDoctor { throw 'Falha simulada ao parar o Spooler.' }

        $result = Restart-Spooler -Confirm:$false -LogPath $script:logPath

        $result.Outcome | Should -Be 'Failed'
        $result.Message | Should -Match 'Falha simulada ao parar o Spooler\.'

        Should -Invoke Start-SpoolerService -ModuleName SpoolDoctor -Times 0 -Exactly

        $logLines = @(Get-Content -LiteralPath $script:logPath -Encoding UTF8)
        $logLines.Count | Should -Be 1
        $logLines[0] | Should -Match 'Outcome=Failed'
    }

    It 'retorna Failed e chama Start-SpoolerService apenas uma vez quando Start-SpoolerService falha (partindo de Running ou Stopped)' {
        Mock Start-SpoolerService -ModuleName SpoolDoctor { throw 'Serviço não respondeu ao iniciar.' }

        $resultRunning = Restart-Spooler -Confirm:$false -LogPath $script:logPath
        $resultRunning.Outcome | Should -Be 'Failed'
        $resultRunning.Message | Should -Match 'Serviço não respondeu ao iniciar\.'
        Should -Invoke Stop-SpoolerService -ModuleName SpoolDoctor -Times 1 -Exactly
        Should -Invoke Start-SpoolerService -ModuleName SpoolDoctor -Times 1 -Exactly

        $stoppedFailLog = Join-Path -Path 'TestDrive:\' -ChildPath ("restart-startfail-stopped-{0}.log" -f [guid]::NewGuid().ToString('N'))
        Mock Get-SpoolerServiceStatus -ModuleName SpoolDoctor { return 'Stopped' }

        $resultStopped = Restart-Spooler -Confirm:$false -LogPath $stoppedFailLog
        $resultStopped.Outcome | Should -Be 'Failed'
        $resultStopped.Message | Should -Match 'Serviço não respondeu ao iniciar\.'
        Should -Invoke Stop-SpoolerService -ModuleName SpoolDoctor -Times 1 -Exactly
        Should -Invoke Start-SpoolerService -ModuleName SpoolDoctor -Times 2 -Exactly

        $logLines = @(Get-Content -LiteralPath $stoppedFailLog -Encoding UTF8)
        $logLines.Count | Should -Be 1
        $logLines[0] | Should -Match 'Outcome=Failed'
    }

    It 'retorna Failed na verificação final se o serviço não terminar em Running' {
        Mock Get-SpoolerServiceStatus -ModuleName SpoolDoctor { return 'Stopped' }

        $result = Restart-Spooler -Confirm:$false -LogPath $script:logPath

        $result.Outcome | Should -Be 'Failed'
        $result.Message | Should -Match 'Stopped'

        $logLines = @(Get-Content -LiteralPath $script:logPath -Encoding UTF8)
        $logLines.Count | Should -Be 1
        $logLines[0] | Should -Match 'Outcome=Failed'
    }

    It 'retorna Failed quando Get-SpoolerServiceStatus falha na consulta inicial ou na verificação final' {
        Mock Get-SpoolerServiceStatus -ModuleName SpoolDoctor { throw 'Erro ao consultar serviço Spooler.' }

        $resultInitial = Restart-Spooler -Confirm:$false -LogPath $script:logPath
        $resultInitial.Outcome | Should -Be 'Failed'
        $resultInitial.Message | Should -Match 'Erro ao consultar serviço Spooler\.'
        Should -Invoke Stop-SpoolerService -ModuleName SpoolDoctor -Times 0 -Exactly
        Should -Invoke Start-SpoolerService -ModuleName SpoolDoctor -Times 0 -Exactly

        $finalFailLog = Join-Path -Path 'TestDrive:\' -ChildPath ("restart-final-status-fail-{0}.log" -f [guid]::NewGuid().ToString('N'))
        $script:statusFailCalls = 0
        Mock Get-SpoolerServiceStatus -ModuleName SpoolDoctor {
            $script:statusFailCalls++
            if ($script:statusFailCalls -eq 1) {
                return 'Running'
            }
            throw 'Erro na consulta final do serviço.'
        }

        $resultFinal = Restart-Spooler -Confirm:$false -LogPath $finalFailLog
        $resultFinal.Outcome | Should -Be 'Failed'
        $resultFinal.Message | Should -Match 'Erro na consulta final do serviço\.'

        $logLines = @(Get-Content -LiteralPath $finalFailLog -Encoding UTF8)
        $logLines.Count | Should -Be 1
        $logLines[0] | Should -Match 'Outcome=Failed'
    }

    Context 'Execução remota (1 máquina)' {
        BeforeEach {
            $script:remoteAllowListPath = Join-Path -Path 'TestDrive:\' -ChildPath ("restart-allow-{0}.txt" -f [guid]::NewGuid().ToString('N'))
            @(
                'PC-REMOTO-01'
                'SRV-PRINT-01|PrintServer'
            ) | Set-Content -LiteralPath $script:remoteAllowListPath -Encoding UTF8

            $script:remoteSessionObj = [PSCustomObject]@{ ComputerName = 'PC-REMOTO-01'; Id = 5 }
            Mock New-SpoolerRemoteSession -ModuleName SpoolDoctor { return $script:remoteSessionObj }
            Mock Invoke-SpoolerRemoteScript -ModuleName SpoolDoctor {
                return [PSCustomObject]@{
                    PSTypeName   = 'Deserialized.SpoolDoctor.ActionResult'
                    ComputerName = 'PC-REMOTO-01'
                    Action       = 'Restart-Spooler'
                    Outcome      = 'OK'
                    Message      = "Spooler reiniciado com sucesso na máquina 'PC-REMOTO-01'. Arquivos da fila preservados e serviço em execução."
                    Timestamp    = Get-Date
                }
            }
            Mock Remove-SpoolerRemoteSession -ModuleName SpoolDoctor {}
        }

        It 'preserva execução local quando -ComputerName aponta para a máquina local' {
            $result = Restart-Spooler -ComputerName $env:COMPUTERNAME -AllowedComputersPath $script:remoteAllowListPath -Confirm:$false -LogPath $script:logPath

            $result.Outcome | Should -Be 'OK'
            $result.ComputerName | Should -Be $env:COMPUTERNAME
            Should -Invoke New-SpoolerRemoteSession -ModuleName SpoolDoctor -Times 0 -Exactly
            Should -Invoke Stop-SpoolerService -ModuleName SpoolDoctor -Times 1 -Exactly
            Should -Invoke Start-SpoolerService -ModuleName SpoolDoctor -Times 1 -Exactly
        }

        It 'executa fluxo remoto feliz sem exigir admin local, repassa -Credential, injeta Test-SpoolerPrintServer sem PRINTERS e fecha sessão' {
            Mock Test-IsAdministrator -ModuleName SpoolDoctor { return $false }
            $script:capturedRemoteArgs = $null
            $script:capturedRemoteScriptText = $null
            $cred = New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList @(
                'DOMINIO\operador',
                (New-Object -TypeName System.Security.SecureString)
            )

            Mock Invoke-SpoolerRemoteScript -ModuleName SpoolDoctor {
                param($Session, $ScriptBlock, $ArgumentList)
                $script:capturedRemoteArgs = $ArgumentList
                $script:capturedRemoteScriptText = $ScriptBlock.ToString()
                return [PSCustomObject]@{
                    PSTypeName   = 'Deserialized.SpoolDoctor.ActionResult'
                    ComputerName = 'PC-REMOTO-01'
                    Action       = 'Restart-Spooler'
                    Outcome      = 'OK'
                    Message      = "Spooler reiniciado com sucesso na máquina 'PC-REMOTO-01'. Arquivos da fila preservados."
                    Timestamp    = Get-Date
                }
            }

            $res = Restart-Spooler -ComputerName 'pc-remoto-01' -Credential $cred -AllowedComputersPath $script:remoteAllowListPath -Confirm:$false -LogPath $script:logPath

            $res.PSObject.TypeNames | Should -Contain 'SpoolDoctor.ActionResult'
            $res.Action | Should -Be 'Restart-Spooler'
            $res.Outcome | Should -Be 'OK'
            $res.ComputerName | Should -Be 'PC-REMOTO-01'

            $script:capturedRemoteArgs[1] | Should -Be 'Restart-Spooler'
            $script:capturedRemoteArgs[3].Keys | Should -Contain 'Test-SpoolerPrintServer'
            $script:capturedRemoteArgs[3].Keys | Should -Not -Contain 'Get-SpoolFile'
            $script:capturedRemoteArgs[3].Keys | Should -Not -Contain 'Copy-SpoolFile'
            $script:capturedRemoteArgs[3].Keys | Should -Not -Contain 'Remove-SpoolFile'
            $script:capturedRemoteArgs[3].Keys | Should -Not -Contain 'Remove-OldSpoolBackup'
            $script:capturedRemoteScriptText | Should -Match 'Confirm\s*=\s*\$false'

            Should -Invoke New-SpoolerRemoteSession -ModuleName SpoolDoctor -Times 1 -Exactly -ParameterFilter {
                $ComputerName -eq 'PC-REMOTO-01' -and $null -ne $Credential
            }
            Should -Invoke Remove-SpoolerRemoteSession -ModuleName SpoolDoctor -Times 1 -Exactly

            $logLines = @(Get-Content -LiteralPath $script:logPath -Encoding UTF8)
            $logLines.Count | Should -Be 1
            $logLines[0] | Should -Match 'Computer=PC-REMOTO-01'
            $logLines[0] | Should -Match 'Action=Restart-Spooler'
            $logLines[0] | Should -Match 'Outcome=OK'
        }

        It 'em modo -WhatIf remoto retorna Simulated com hostname no log e não abre sessão WinRM' {
            $result = Restart-Spooler -ComputerName 'PC-REMOTO-01' -AllowedComputersPath $script:remoteAllowListPath -WhatIf -LogPath $script:logPath

            $result.ComputerName | Should -Be 'PC-REMOTO-01'
            $result.Action | Should -Be 'Restart-Spooler'
            $result.Outcome | Should -Be 'Simulated'
            $result.Message | Should -Match 'PC-REMOTO-01'

            Should -Invoke New-SpoolerRemoteSession -ModuleName SpoolDoctor -Times 0 -Exactly
            Should -Invoke Invoke-SpoolerRemoteScript -ModuleName SpoolDoctor -Times 0 -Exactly
            Should -Invoke Remove-SpoolerRemoteSession -ModuleName SpoolDoctor -Times 0 -Exactly

            $logLines = @(Get-Content -LiteralPath $script:logPath -Encoding UTF8)
            $logLines.Count | Should -Be 1
            $logLines[0] | Should -Match 'Computer=PC-REMOTO-01'
            $logLines[0] | Should -Match 'Outcome=Simulated'
        }

        It 'retorna Skipped exibindo hostname remoto e sem abrir sessão quando confirmação é recusada' {
            $physicalTestDrive = (Get-PSDrive -Name 'TestDrive').Root
            $childLogPath = Join-Path -Path $physicalTestDrive -ChildPath ("restart-remote-skipped-{0}.log" -f [guid]::NewGuid().ToString('N'))
            $childAllowPath = Join-Path -Path $physicalTestDrive -ChildPath ("restart-remote-allow-{0}.txt" -f [guid]::NewGuid().ToString('N'))
            Set-Content -LiteralPath $childAllowPath -Value 'PC-REMOTO-01' -Encoding UTF8

            $childScript = @"
`$ErrorActionPreference = 'Stop'
Import-Module -Name '$manifestPath' -Force
& (Get-Module -Name 'SpoolDoctor') {
    function script:New-SpoolerRemoteSession { [CmdletBinding(SupportsShouldProcess)] param([string]`$ComputerName, [PSCredential]`$Credential) throw 'Não deveria chamar New-SpoolerRemoteSession.' }
    function script:Invoke-SpoolerRemoteScript { param(`$Session, `$ScriptBlock, `$ArgumentList) throw 'Não deveria chamar Invoke-SpoolerRemoteScript.' }
    function script:Remove-SpoolerRemoteSession { [CmdletBinding(SupportsShouldProcess)] param(`$Session) throw 'Não deveria chamar Remove-SpoolerRemoteSession.' }
}
Restart-Spooler -ComputerName 'PC-REMOTO-01' -AllowedComputersPath '$childAllowPath' -LogPath '$childLogPath' | ConvertTo-Json -Compress
"@

            $rawOutput = @('N' | & powershell.exe -NoProfile -Command $childScript 2>&1 | ForEach-Object { $_.ToString() })
            $LASTEXITCODE | Should -Be 0

            ($rawOutput -join "`n") | Should -Match 'PC-REMOTO-01'
            $jsonLine = $rawOutput | Where-Object { $_ -match '^\s*\{.*\}\s*$' } | Select-Object -Last 1
            $jsonLine | Should -Not -BeNullOrEmpty

            $parsedResult = $jsonLine | ConvertFrom-Json
            $parsedResult.Outcome | Should -Be 'Skipped'
            $parsedResult.Action | Should -Be 'Restart-Spooler'
            $parsedResult.ComputerName | Should -Be 'PC-REMOTO-01'
            $parsedResult.Message | Should -Match 'PC-REMOTO-01'

            $logLines = @(Get-Content -LiteralPath $childLogPath -Encoding UTF8)
            $logLines.Count | Should -Be 1
            $logLines[0] | Should -Match 'Computer=PC-REMOTO-01'
            $logLines[0] | Should -Match 'Outcome=Skipped'
        }

        It 'recusa -ComputerName inválido, fora da allow-list ou -Credential local retornando Failed sem abrir sessão' {
            $invalidRes = Restart-Spooler -ComputerName '   ' -AllowedComputersPath $script:remoteAllowListPath -Confirm:$false -LogPath $script:logPath
            $invalidRes.Outcome | Should -Be 'Failed'

            $ipLog = Join-Path -Path 'TestDrive:\' -ChildPath ("restart-ip-{0}.log" -f [guid]::NewGuid().ToString('N'))
            $ipRes = Restart-Spooler -ComputerName '192.168.1.50' -AllowedComputersPath $script:remoteAllowListPath -Confirm:$false -LogPath $ipLog
            $ipRes.Outcome | Should -Be 'Failed'

            $unlistedLog = Join-Path -Path 'TestDrive:\' -ChildPath ("restart-unlisted-{0}.log" -f [guid]::NewGuid().ToString('N'))
            $unlistedRes = Restart-Spooler -ComputerName 'PC-INTRUSO' -AllowedComputersPath $script:remoteAllowListPath -Confirm:$false -LogPath $unlistedLog
            $unlistedRes.Outcome | Should -Be 'Failed'
            $unlistedRes.ComputerName | Should -Be 'PC-INTRUSO'
            $unlistedRes.Message | Should -Match 'allow-list'

            $cred = New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList @(
                'DOMINIO\operador',
                (New-Object -TypeName System.Security.SecureString)
            )
            $localCredLog = Join-Path -Path 'TestDrive:\' -ChildPath ("restart-localcred-{0}.log" -f [guid]::NewGuid().ToString('N'))
            $localCredRes = Restart-Spooler -Credential $cred -Confirm:$false -LogPath $localCredLog
            $localCredRes.Outcome | Should -Be 'Failed'
            $localCredRes.Message | Should -Match 'Credential'

            Should -Invoke New-SpoolerRemoteSession -ModuleName SpoolDoctor -Times 0 -Exactly

            $logLines = @(Get-Content -LiteralPath $unlistedLog -Encoding UTF8)
            $logLines.Count | Should -Be 1
            $logLines[0] | Should -Match 'Computer=PC-INTRUSO'
            $logLines[0] | Should -Match 'Outcome=Failed'
        }

        It 'bloqueia servidor de impressão marcado na allow-list sem -AllowPrintServer antes de abrir sessão' {
            $result = Restart-Spooler -ComputerName 'SRV-PRINT-01' -AllowedComputersPath $script:remoteAllowListPath -Confirm:$false -LogPath $script:logPath

            $result.Outcome | Should -Be 'Failed'
            $result.ComputerName | Should -Be 'SRV-PRINT-01'
            $result.Message | Should -Match 'SRV-PRINT-01'
            $result.Message | Should -Match 'PrintServer|allow-list'
            $result.Message | Should -Match 'AllowPrintServer'

            Should -Invoke New-SpoolerRemoteSession -ModuleName SpoolDoctor -Times 0 -Exactly

            $logLines = @(Get-Content -LiteralPath $script:logPath -Encoding UTF8)
            $logLines.Count | Should -Be 1
            $logLines[0] | Should -Match 'Computer=SRV-PRINT-01'
            $logLines[0] | Should -Match 'Outcome=Failed'
        }

        It 'bloqueia servidor de impressão detectado dinamicamente no destino sem -AllowPrintServer' {
            Mock Invoke-SpoolerRemoteScript -ModuleName SpoolDoctor {
                return [PSCustomObject]@{
                    PSTypeName   = 'Deserialized.SpoolDoctor.ActionResult'
                    ComputerName = 'PC-REMOTO-01'
                    Action       = 'Restart-Spooler'
                    Outcome      = 'Failed'
                    Message      = "Reinício bloqueado na máquina 'PC-REMOTO-01' (servidor de impressão detectado: sistema operacional Windows Server (ProductType=3)). Informe -AllowPrintServer para confirmar a execução."
                    Timestamp    = Get-Date
                }
            }

            $result = Restart-Spooler -ComputerName 'PC-REMOTO-01' -AllowedComputersPath $script:remoteAllowListPath -Confirm:$false -LogPath $script:logPath

            $result.Outcome | Should -Be 'Failed'
            $result.ComputerName | Should -Be 'PC-REMOTO-01'
            $result.Message | Should -Match 'Windows Server'
            $result.Message | Should -Match 'AllowPrintServer'
            Should -Invoke Remove-SpoolerRemoteSession -ModuleName SpoolDoctor -Times 1 -Exactly

            $logLines = @(Get-Content -LiteralPath $script:logPath -Encoding UTF8)
            $logLines.Count | Should -Be 1
            $logLines[0] | Should -Match 'Computer=PC-REMOTO-01'
            $logLines[0] | Should -Match 'Outcome=Failed'
        }

        It 'permite servidor de impressão quando -AllowPrintServer é informado (em -WhatIf e com -Confirm:$false)' {
            $simResult = Restart-Spooler -ComputerName 'SRV-PRINT-01' -AllowedComputersPath $script:remoteAllowListPath -AllowPrintServer -WhatIf -LogPath $script:logPath
            $simResult.Outcome | Should -Be 'Simulated'
            $simResult.ComputerName | Should -Be 'SRV-PRINT-01'
            Should -Invoke New-SpoolerRemoteSession -ModuleName SpoolDoctor -Times 0 -Exactly

            $execLog = Join-Path -Path 'TestDrive:\' -ChildPath ("restart-printserver-ok-{0}.log" -f [guid]::NewGuid().ToString('N'))
            $script:capturedPrintArg = $null
            Mock Invoke-SpoolerRemoteScript -ModuleName SpoolDoctor {
                param($Session, $ScriptBlock, $ArgumentList)
                $script:capturedPrintArg = $ArgumentList[2]
                return [PSCustomObject]@{
                    PSTypeName   = 'Deserialized.SpoolDoctor.ActionResult'
                    ComputerName = 'SRV-PRINT-01'
                    Action       = 'Restart-Spooler'
                    Outcome      = 'OK'
                    Message      = "Spooler reiniciado com sucesso na máquina 'SRV-PRINT-01'."
                    Timestamp    = Get-Date
                }
            }

            $okResult = Restart-Spooler -ComputerName 'SRV-PRINT-01' -AllowedComputersPath $script:remoteAllowListPath -AllowPrintServer -Confirm:$false -LogPath $execLog
            $okResult.Outcome | Should -Be 'OK'
            $okResult.ComputerName | Should -Be 'SRV-PRINT-01'
            ([bool]$script:capturedPrintArg['AllowPrintServer']) | Should -BeTrue
            Should -Invoke New-SpoolerRemoteSession -ModuleName SpoolDoctor -Times 1 -Exactly
            Should -Invoke Remove-SpoolerRemoteSession -ModuleName SpoolDoctor -Times 1 -Exactly
        }

        It 'retorna Unreachable, fecha sessão no finally e grava log em falha de conectividade WinRM' {
            Mock Invoke-SpoolerRemoteScript -ModuleName SpoolDoctor {
                throw (New-Object -TypeName System.Management.Automation.Remoting.PSRemotingTransportException -ArgumentList 'WinRM unreachable.')
            }

            $result = Restart-Spooler -ComputerName 'PC-REMOTO-01' -AllowedComputersPath $script:remoteAllowListPath -Confirm:$false -LogPath $script:logPath

            $result.Outcome | Should -Be 'Unreachable'
            $result.ComputerName | Should -Be 'PC-REMOTO-01'
            Should -Invoke Remove-SpoolerRemoteSession -ModuleName SpoolDoctor -Times 1 -Exactly

            $logLines = @(Get-Content -LiteralPath $script:logPath -Encoding UTF8)
            $logLines.Count | Should -Be 1
            $logLines[0] | Should -Match 'Computer=PC-REMOTO-01'
            $logLines[0] | Should -Match 'Outcome=Unreachable'
        }

        It 'retorna Failed e grava log em falha de autenticação WinRM' {
            Mock New-SpoolerRemoteSession -ModuleName SpoolDoctor {
                throw (New-Object -TypeName System.UnauthorizedAccessException -ArgumentList 'Access is denied.')
            }

            $result = Restart-Spooler -ComputerName 'PC-REMOTO-01' -AllowedComputersPath $script:remoteAllowListPath -Confirm:$false -LogPath $script:logPath

            $result.Outcome | Should -Be 'Failed'
            $result.ComputerName | Should -Be 'PC-REMOTO-01'
            Should -Invoke Remove-SpoolerRemoteSession -ModuleName SpoolDoctor -Times 0 -Exactly

            $logLines = @(Get-Content -LiteralPath $script:logPath -Encoding UTF8)
            $logLines.Count | Should -Be 1
            $logLines[0] | Should -Match 'Computer=PC-REMOTO-01'
            $logLines[0] | Should -Match 'Outcome=Failed'
        }
    }

    Context 'Execução remota em lote' {
        BeforeEach {
            $script:batchAllowListPath = Join-Path -Path 'TestDrive:\' -ChildPath ("restart-batch-allow-{0}.txt" -f [guid]::NewGuid().ToString('N'))
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
                return [PSCustomObject]@{
                    PSTypeName   = 'Deserialized.SpoolDoctor.ActionResult'
                    ComputerName = $targetHost
                    Action       = 'Restart-Spooler'
                    Outcome      = 'OK'
                    Message      = "Spooler reiniciado com sucesso na máquina '$targetHost'."
                    Timestamp    = Get-Date
                }
            }
            Mock Remove-SpoolerRemoteSession -ModuleName SpoolDoctor {
                param($Session)
                $script:closedSessionTargets.Add([string]$Session.ComputerName)
            }
        }

        It 'executa lote 100% bem-sucedido em 3 máquinas com logs e encerramento de todas as sessões' {
            $results = @(Restart-Spooler -ComputerName @('PC-REMOTO-01', 'pc-remoto-02', 'PC-REMOTO-03') -AllowedComputersPath $script:batchAllowListPath -Confirm:$false -LogPath $script:logPath)

            $results.Count | Should -Be 3
            $results[0].ComputerName | Should -Be 'PC-REMOTO-01'
            $results[1].ComputerName | Should -Be 'PC-REMOTO-02'
            $results[2].ComputerName | Should -Be 'PC-REMOTO-03'
            foreach ($res in $results) {
                $res.PSObject.TypeNames | Should -Contain 'SpoolDoctor.ActionResult'
                $res.Action | Should -Be 'Restart-Spooler'
                $res.Outcome | Should -Be 'OK'
            }

            $script:openedSessionTargets.ToArray() | Should -Be @('PC-REMOTO-01', 'PC-REMOTO-02', 'PC-REMOTO-03')
            $script:closedSessionTargets.ToArray() | Should -Be @('PC-REMOTO-01', 'PC-REMOTO-02', 'PC-REMOTO-03')

            $logLines = @(Get-Content -LiteralPath $script:logPath -Encoding UTF8)
            $logLines.Count | Should -Be 3
            $logLines[0] | Should -Match 'Computer=PC-REMOTO-01.*Outcome=OK'
            $logLines[1] | Should -Match 'Computer=PC-REMOTO-02.*Outcome=OK'
            $logLines[2] | Should -Match 'Computer=PC-REMOTO-03.*Outcome=OK'
        }

        It 'isola falha Unreachable, allow-list, PrintServer bloqueado, entrada vazia e erro de autenticação no lote' {
            Mock New-SpoolerRemoteSession -ModuleName SpoolDoctor {
                param([string]$ComputerName, [PSCredential]$Credential)
                if ($ComputerName -eq 'PC-REMOTO-02') {
                    throw (New-Object -TypeName System.UnauthorizedAccessException -ArgumentList 'Access is denied.')
                }
                $script:openedSessionTargets.Add($ComputerName)
                return [PSCustomObject]@{ ComputerName = $ComputerName; Id = $script:openedSessionTargets.Count }
            }
            Mock Invoke-SpoolerRemoteScript -ModuleName SpoolDoctor {
                param($Session, $ScriptBlock, $ArgumentList)
                $targetHost = [string]$ArgumentList[0]
                if ($targetHost -eq 'PC-REMOTO-01') {
                    throw (New-Object -TypeName System.Management.Automation.Remoting.PSRemotingTransportException -ArgumentList 'WinRM unreachable.')
                }
                return [PSCustomObject]@{
                    PSTypeName   = 'Deserialized.SpoolDoctor.ActionResult'
                    ComputerName = $targetHost
                    Action       = 'Restart-Spooler'
                    Outcome      = 'OK'
                    Message      = "Spooler reiniciado com sucesso na máquina '$targetHost'."
                    Timestamp    = Get-Date
                }
            }

            $targets = @('PC-REMOTO-01', 'PC-INTRUSO', 'SRV-PRINT-01', '', 'PC-REMOTO-02', 'PC-REMOTO-03')
            $results = @(Restart-Spooler -ComputerName $targets -AllowedComputersPath $script:batchAllowListPath -Confirm:$false -LogPath $script:logPath)

            $results.Count | Should -Be 6
            $results[0].ComputerName | Should -Be 'PC-REMOTO-01'
            $results[0].Outcome | Should -Be 'Unreachable'
            $results[1].ComputerName | Should -Be 'PC-INTRUSO'
            $results[1].Outcome | Should -Be 'Failed'
            $results[2].ComputerName | Should -Be 'SRV-PRINT-01'
            $results[2].Outcome | Should -Be 'Failed'
            $results[2].Message | Should -Match 'AllowPrintServer'
            $results[3].ComputerName | Should -Be '(inválido)'
            $results[3].Outcome | Should -Be 'Failed'
            $results[4].ComputerName | Should -Be 'PC-REMOTO-02'
            $results[4].Outcome | Should -Be 'Failed'
            $results[5].ComputerName | Should -Be 'PC-REMOTO-03'
            $results[5].Outcome | Should -Be 'OK'

            $script:openedSessionTargets.ToArray() | Should -Be @('PC-REMOTO-01', 'PC-REMOTO-03')
            $script:closedSessionTargets.ToArray() | Should -Be @('PC-REMOTO-01', 'PC-REMOTO-03')

            $logLines = @(Get-Content -LiteralPath $script:logPath -Encoding UTF8)
            $logLines.Count | Should -Be 6
            $logLines[0] | Should -Match 'Computer=PC-REMOTO-01.*Outcome=Unreachable'
            $logLines[1] | Should -Match 'Computer=PC-INTRUSO.*Outcome=Failed'
            $logLines[2] | Should -Match 'Computer=SRV-PRINT-01.*Outcome=Failed'
            $logLines[3] | Should -Match 'Computer=\(inválido\).*Outcome=Failed'
            $logLines[4] | Should -Match 'Computer=PC-REMOTO-02.*Outcome=Failed'
            $logLines[5] | Should -Match 'Computer=PC-REMOTO-03.*Outcome=OK'
        }

        It 'em modo -WhatIf no lote não abre sessão WinRM e retorna Simulated por máquina autorizada' {
            $results = @(Restart-Spooler -ComputerName @('PC-REMOTO-01', 'SRV-PRINT-01', 'PC-REMOTO-02') -AllowedComputersPath $script:batchAllowListPath -WhatIf -LogPath $script:logPath)

            $results.Count | Should -Be 3
            $results[0].ComputerName | Should -Be 'PC-REMOTO-01'
            $results[0].Outcome | Should -Be 'Simulated'
            $results[1].ComputerName | Should -Be 'SRV-PRINT-01'
            $results[1].Outcome | Should -Be 'Failed'
            $results[2].ComputerName | Should -Be 'PC-REMOTO-02'
            $results[2].Outcome | Should -Be 'Simulated'

            Should -Invoke New-SpoolerRemoteSession -ModuleName SpoolDoctor -Times 0 -Exactly
            Should -Invoke Invoke-SpoolerRemoteScript -ModuleName SpoolDoctor -Times 0 -Exactly
            Should -Invoke Remove-SpoolerRemoteSession -ModuleName SpoolDoctor -Times 0 -Exactly
        }

        It 'avalia -Confirm individualmente por máquina exibindo o hostname correspondente' {
            if (-not ('SpoolDoctorRestartBatchConfirmHost' -as [type])) {
                Add-Type -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Globalization;
using System.Management.Automation;
using System.Management.Automation.Host;
using System.Security;

public class SpoolDoctorRestartBatchConfirmRawUI : PSHostRawUserInterface {
    public override ConsoleColor BackgroundColor { get { return ConsoleColor.Black; } set {} }
    public override ConsoleColor ForegroundColor { get { return ConsoleColor.White; } set {} }
    public override Coordinates CursorPosition { get { return new Coordinates(0, 0); } set {} }
    public override Coordinates WindowPosition { get { return new Coordinates(0, 0); } set {} }
    public override int CursorSize { get { return 1; } set {} }
    public override Size BufferSize { get { return new Size(120, 50); } set {} }
    public override Size WindowSize { get { return new Size(120, 50); } set {} }
    public override Size MaxWindowSize { get { return new Size(120, 50); } }
    public override Size MaxPhysicalWindowSize { get { return new Size(120, 50); } }
    public override bool KeyAvailable { get { return false; } }
    public override string WindowTitle { get { return "Test"; } set {} }
    public override void FlushInputBuffer() {}
    public override BufferCell[,] GetBufferContents(Rectangle rectangle) { return new BufferCell[0, 0]; }
    public override KeyInfo ReadKey(ReadKeyOptions options) { return new KeyInfo(); }
    public override void ScrollBufferContents(Rectangle source, Coordinates destination, Rectangle clip, BufferCell fill) {}
    public override void SetBufferContents(Coordinates origin, BufferCell[,] contents) {}
    public override void SetBufferContents(Rectangle rectangle, BufferCell fill) {}
}

public class SpoolDoctorRestartBatchConfirmHostUI : PSHostUserInterface {
    public Queue<int> Responses = new Queue<int>();
    public List<string> Prompts = new List<string>();
    private PSHostRawUserInterface _raw = new SpoolDoctorRestartBatchConfirmRawUI();
    public override PSHostRawUserInterface RawUI { get { return _raw; } }
    public override int PromptForChoice(string caption, string message, Collection<ChoiceDescription> choices, int defaultChoice) {
        Prompts.Add(caption + " | " + message);
        return Responses.Count > 0 ? Responses.Dequeue() : defaultChoice;
    }
    public override string ReadLine() { return string.Empty; }
    public override SecureString ReadLineAsSecureString() { return new SecureString(); }
    public override void Write(string value) {}
    public override void Write(ConsoleColor foregroundColor, ConsoleColor backgroundColor, string value) {}
    public override void WriteLine(string value) {}
    public override void WriteErrorLine(string value) {}
    public override void WriteDebugLine(string message) {}
    public override void WriteProgress(long sourceId, ProgressRecord record) {}
    public override void WriteVerboseLine(string message) {}
    public override void WriteWarningLine(string message) {}
    public override Dictionary<string, PSObject> Prompt(string caption, string message, Collection<FieldDescription> descriptions) { return new Dictionary<string, PSObject>(); }
    public override PSCredential PromptForCredential(string caption, string message, string userName, string targetName) { return null; }
    public override PSCredential PromptForCredential(string caption, string message, string userName, string targetName, PSCredentialTypes allowedCredentialTypes, PSCredentialUIOptions options) { return null; }
}

public class SpoolDoctorRestartBatchConfirmHost : PSHost {
    private Guid _id = Guid.NewGuid();
    private SpoolDoctorRestartBatchConfirmHostUI _ui = new SpoolDoctorRestartBatchConfirmHostUI();
    public SpoolDoctorRestartBatchConfirmHostUI TestUI { get { return _ui; } }
    public override string Name { get { return "SpoolDoctorRestartBatchConfirmHost"; } }
    public override Version Version { get { return new Version(1, 0); } }
    public override Guid InstanceId { get { return _id; } }
    public override PSHostUserInterface UI { get { return _ui; } }
    public override CultureInfo CurrentCulture { get { return CultureInfo.InvariantCulture; } }
    public override CultureInfo CurrentUICulture { get { return CultureInfo.InvariantCulture; } }
    public override void SetShouldExit(int exitCode) {}
    public override void EnterNestedPrompt() {}
    public override void ExitNestedPrompt() {}
    public override void NotifyBeginApplication() {}
    public override void NotifyEndApplication() {}
}
"@
            }

            $physicalTestDrive = (Get-PSDrive -Name 'TestDrive').Root
            $childLogPath = Join-Path -Path $physicalTestDrive -ChildPath ("restart-batch-confirm-{0}.log" -f [guid]::NewGuid().ToString('N'))
            $childAllowPath = Join-Path -Path $physicalTestDrive -ChildPath ("restart-batch-allow-{0}.txt" -f [guid]::NewGuid().ToString('N'))
            @('PC-REMOTO-01', 'PC-REMOTO-02') | Set-Content -LiteralPath $childAllowPath -Encoding UTF8

            $testHost = New-Object -TypeName SpoolDoctorRestartBatchConfirmHost
            $testHost.TestUI.Responses.Enqueue(2) # No para PC-REMOTO-01
            $testHost.TestUI.Responses.Enqueue(0) # Yes para PC-REMOTO-02

            $runspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace($testHost)
            $runspace.Open()
            $ps = $null
            try {
                $ps = [System.Management.Automation.PowerShell]::Create()
                $ps.Runspace = $runspace
                $null = $ps.AddScript(@"
`$ErrorActionPreference = 'Stop'
Import-Module -Name '$manifestPath' -Force
& (Get-Module -Name 'SpoolDoctor') {
    function script:New-SpoolerRemoteSession {
        [CmdletBinding(SupportsShouldProcess)]
        param([string]`$ComputerName, [PSCredential]`$Credential)
        if (`$ComputerName -eq 'PC-REMOTO-01') { throw 'Não deveria abrir sessão para PC-REMOTO-01.' }
        return [PSCustomObject]@{ ComputerName = `$ComputerName; Id = 1 }
    }
    function script:Invoke-SpoolerRemoteScript {
        param(`$Session, `$ScriptBlock, `$ArgumentList)
        return [PSCustomObject]@{
            PSTypeName   = 'Deserialized.SpoolDoctor.ActionResult'
            ComputerName = [string]`$ArgumentList[0]
            Action       = 'Restart-Spooler'
            Outcome      = 'OK'
            Message      = "Spooler reiniciado com sucesso na máquina '`$(`$ArgumentList[0])'."
            Timestamp    = Get-Date
        }
    }
    function script:Remove-SpoolerRemoteSession { [CmdletBinding(SupportsShouldProcess)] param(`$Session) }
}
Restart-Spooler -ComputerName @('PC-REMOTO-01', 'PC-REMOTO-02') -AllowedComputersPath '$childAllowPath' -LogPath '$childLogPath'
"@)
                $parsed = @($ps.Invoke())
                $ps.HadErrors | Should -BeFalse -Because ($ps.Streams.Error -join '; ')
            }
            finally {
                if ($null -ne $ps) {
                    $ps.Dispose()
                }
                $runspace.Dispose()
            }

            $testHost.TestUI.Prompts.Count | Should -Be 2
            $testHost.TestUI.Prompts[0] | Should -Match 'PC-REMOTO-01'
            $testHost.TestUI.Prompts[1] | Should -Match 'PC-REMOTO-02'

            $parsed.Count | Should -Be 2
            $parsed[0].ComputerName | Should -Be 'PC-REMOTO-01'
            $parsed[0].Outcome | Should -Be 'Skipped'
            $parsed[1].ComputerName | Should -Be 'PC-REMOTO-02'
            $parsed[1].Outcome | Should -Be 'OK'

            $logLines = @(Get-Content -LiteralPath $childLogPath -Encoding UTF8)
            $logLines.Count | Should -Be 2
            $logLines[0] | Should -Match 'Computer=PC-REMOTO-01.*Outcome=Skipped'
            $logLines[1] | Should -Match 'Computer=PC-REMOTO-02.*Outcome=OK'
        }

        It 'suporta lote misto local e remoto, deduplica alvos e recusa array vazio em StrictMode' {
            $mixedResults = @(& {
                Set-StrictMode -Version Latest
                Restart-Spooler -ComputerName @('localhost', $env:COMPUTERNAME, 'pc-remoto-01', 'PC-REMOTO-01') -AllowedComputersPath $script:batchAllowListPath -Confirm:$false -LogPath $script:logPath
            })

            $mixedResults.Count | Should -Be 2
            $mixedResults[0].ComputerName | Should -Be $env:COMPUTERNAME
            $mixedResults[0].Outcome | Should -Be 'OK'
            $mixedResults[1].ComputerName | Should -Be 'PC-REMOTO-01'
            $mixedResults[1].Outcome | Should -Be 'OK'

            Should -Invoke Stop-SpoolerService -ModuleName SpoolDoctor -Times 1 -Exactly
            Should -Invoke Start-SpoolerService -ModuleName SpoolDoctor -Times 1 -Exactly
            Should -Invoke New-SpoolerRemoteSession -ModuleName SpoolDoctor -Times 1 -Exactly
            Should -Invoke Remove-SpoolerRemoteSession -ModuleName SpoolDoctor -Times 1 -Exactly

            $emptyLog = Join-Path -Path 'TestDrive:\' -ChildPath ("restart-empty-batch-{0}.log" -f [guid]::NewGuid().ToString('N'))
            $emptyResults = @(& {
                Set-StrictMode -Version Latest
                Restart-Spooler -ComputerName @() -AllowedComputersPath $script:batchAllowListPath -Confirm:$false -LogPath $emptyLog
            })

            $emptyResults.Count | Should -Be 1
            $emptyResults[0].ComputerName | Should -Be '(inválido)'
            $emptyResults[0].Outcome | Should -Be 'Failed'

            $emptyLogs = @(Get-Content -LiteralPath $emptyLog -Encoding UTF8)
            $emptyLogs.Count | Should -Be 1
            $emptyLogs[0] | Should -Match 'Computer=\(inválido\).*Outcome=Failed'
        }
    }
}
