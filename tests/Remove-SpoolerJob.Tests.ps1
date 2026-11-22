Describe 'SpoolDoctor - Remove-SpoolerJob' {
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
        $script:logPath = Join-Path -Path 'TestDrive:\' -ChildPath ("remove-job-{0}.log" -f [guid]::NewGuid().ToString('N'))

        Mock Test-IsAdministrator -ModuleName SpoolDoctor { return $true }
        Mock Remove-SpoolerJobRaw -ModuleName SpoolDoctor {}
        Mock Get-SpoolerJobRaw -ModuleName SpoolDoctor { return @() }
        Mock Get-SpoolerPrinterRaw -ModuleName SpoolDoctor { return @() }
    }

    It 'declara SupportsShouldProcess, ConfirmImpact = Medium e parâmetros de pipeline por nome' {
        $command = Get-Command -Name 'Remove-SpoolerJob' -ErrorAction Stop
        $cmdletBinding = $command.ScriptBlock.Attributes |
            Where-Object { $_ -is [System.Management.Automation.CmdletBindingAttribute] } |
            Select-Object -First 1

        $cmdletBinding | Should -Not -BeNullOrEmpty
        $cmdletBinding.SupportsShouldProcess | Should -BeTrue
        $cmdletBinding.ConfirmImpact | Should -Be ([System.Management.Automation.ConfirmImpact]::Medium)

        $printerParamAttr = $command.Parameters['PrinterName'].Attributes |
            Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] } |
            Select-Object -First 1
        $idParamAttr = $command.Parameters['Id'].Attributes |
            Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] } |
            Select-Object -First 1

        $printerParamAttr | Should -Not -BeNullOrEmpty
        $printerParamAttr.Mandatory | Should -BeTrue
        $printerParamAttr.ValueFromPipelineByPropertyName | Should -BeTrue

        $idParamAttr | Should -Not -BeNullOrEmpty
        $idParamAttr.Mandatory | Should -BeTrue
        $idParamAttr.ValueFromPipelineByPropertyName | Should -BeTrue
    }

    It 'recusa execução sem privilégio de administrador, registra log e não chama wrappers' {
        Mock Test-IsAdministrator -ModuleName SpoolDoctor { return $false }

        $result = Remove-SpoolerJob -PrinterName 'HP LaserJet' -Id 10 -Confirm:$false -LogPath $script:logPath

        $result.PSObject.TypeNames | Should -Contain 'SpoolDoctor.ActionResult'
        $result.ComputerName | Should -Be $env:COMPUTERNAME
        $result.Action | Should -Be 'Remove-SpoolerJob'
        $result.Outcome | Should -Be 'Failed'
        $result.Message | Should -Match 'Administrador'
        $result.Message | Should -Match 'HP LaserJet'
        $result.Message | Should -Match '\b10\b'
        $result.Timestamp | Should -BeOfType [datetime]

        Should -Invoke Remove-SpoolerJobRaw -ModuleName SpoolDoctor -Times 0 -Exactly
        Should -Invoke Get-SpoolerJobRaw -ModuleName SpoolDoctor -Times 0 -Exactly

        Test-Path -LiteralPath $script:logPath -PathType Leaf | Should -BeTrue
        $logLines = @(Get-Content -LiteralPath $script:logPath -Encoding UTF8)
        $logLines.Count | Should -Be 1
        $logLines[0] | Should -Match 'Action=Remove-SpoolerJob'
        $logLines[0] | Should -Match 'Outcome=Failed'
        $logLines[0] | Should -Match 'HP LaserJet'
        $logLines[0] | Should -Match '\b10\b'
    }

    It 'em modo -WhatIf não chama wrappers destrutivos, grava log e retorna Simulated' {
        $result = Remove-SpoolerJob -PrinterName 'HP LaserJet' -Id 15 -WhatIf -LogPath $script:logPath

        $result.PSObject.TypeNames | Should -Contain 'SpoolDoctor.ActionResult'
        $result.ComputerName | Should -Be $env:COMPUTERNAME
        $result.Action | Should -Be 'Remove-SpoolerJob'
        $result.Outcome | Should -Be 'Simulated'
        $result.Message | Should -Match 'HP LaserJet'
        $result.Message | Should -Match '\b15\b'
        $result.Timestamp | Should -BeOfType [datetime]

        Should -Invoke Remove-SpoolerJobRaw -ModuleName SpoolDoctor -Times 0 -Exactly
        Should -Invoke Get-SpoolerJobRaw -ModuleName SpoolDoctor -Times 0 -Exactly

        Test-Path -LiteralPath $script:logPath -PathType Leaf | Should -BeTrue
        $logLines = @(Get-Content -LiteralPath $script:logPath -Encoding UTF8)
        $logLines.Count | Should -Be 1
        $logLines[0] | Should -Match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}'
        $logLines[0] | Should -Match 'Action=Remove-SpoolerJob'
        $logLines[0] | Should -Match 'Outcome=Simulated'
        $logLines[0] | Should -Match 'HP LaserJet'
        $logLines[0] | Should -Match '\b15\b'
    }

    It 'retorna Skipped e registra log quando o usuário recusa a confirmação' {
        $physicalTestDrive = (Get-PSDrive -Name 'TestDrive').Root
        $childLogPath = Join-Path -Path $physicalTestDrive -ChildPath ("remove-skipped-{0}.log" -f [guid]::NewGuid().ToString('N'))

        $childScript = @"
`$ErrorActionPreference = 'Stop'
Import-Module -Name '$manifestPath' -Force
& (Get-Module -Name 'SpoolDoctor') {
    function script:Test-IsAdministrator { return `$true }
    function script:Remove-SpoolerJobRaw { [CmdletBinding(SupportsShouldProcess)] param([string]`$PrinterName, [int]`$Id) throw 'Não deveria chamar Remove-SpoolerJobRaw.' }
    function script:Get-SpoolerJobRaw { param([string]`$PrinterName) throw 'Não deveria chamar Get-SpoolerJobRaw.' }
}
Remove-SpoolerJob -PrinterName 'HP LaserJet' -Id 42 -Confirm -LogPath '$childLogPath' | ConvertTo-Json -Compress
"@

        $rawOutput = @('N' | & powershell.exe -NoProfile -Command $childScript)
        $LASTEXITCODE | Should -Be 0

        $jsonLine = $rawOutput | Where-Object { $_ -match '^\s*\{.*\}\s*$' } | Select-Object -Last 1
        $jsonLine | Should -Not -BeNullOrEmpty

        $parsedResult = $jsonLine | ConvertFrom-Json
        $parsedResult.Outcome | Should -Be 'Skipped'
        $parsedResult.Action | Should -Be 'Remove-SpoolerJob'
        $parsedResult.ComputerName | Should -Be $env:COMPUTERNAME
        $parsedResult.Message | Should -Match 'HP LaserJet'
        $parsedResult.Message | Should -Match '\b42\b'

        Test-Path -LiteralPath $childLogPath -PathType Leaf | Should -BeTrue
        $logLines = @(Get-Content -LiteralPath $childLogPath -Encoding UTF8)
        $logLines.Count | Should -Be 1
        $logLines[0] | Should -Match 'Outcome=Skipped'
        $logLines[0] | Should -Match 'HP LaserJet'
        $logLines[0] | Should -Match '\b42\b'
    }

    It 'recusa -PrinterName apenas com espaços retornando Failed, registra log e não chama wrappers' {
        $result = Remove-SpoolerJob -PrinterName '   ' -Id 7 -Confirm:$false -LogPath $script:logPath

        $result.PSObject.TypeNames | Should -Contain 'SpoolDoctor.ActionResult'
        $result.Action | Should -Be 'Remove-SpoolerJob'
        $result.Outcome | Should -Be 'Failed'
        $result.Message | Should -Match '\b7\b'
        $result.Timestamp | Should -BeOfType [datetime]

        Should -Invoke Remove-SpoolerJobRaw -ModuleName SpoolDoctor -Times 0 -Exactly
        Should -Invoke Get-SpoolerJobRaw -ModuleName SpoolDoctor -Times 0 -Exactly

        Test-Path -LiteralPath $script:logPath -PathType Leaf | Should -BeTrue
        $logLines = @(Get-Content -LiteralPath $script:logPath -Encoding UTF8)
        $logLines.Count | Should -Be 1
        $logLines[0] | Should -Match 'Action=Remove-SpoolerJob'
        $logLines[0] | Should -Match 'Outcome=Failed'
    }

    It 'rejeita -Id inválido (<InvalidId>) na validação de parâmetro antes de acionar wrappers' -ForEach @(
        @{ InvalidId = 0 }
        @{ InvalidId = -5 }
    ) {
        param($InvalidId)

        { Remove-SpoolerJob -PrinterName 'HP LaserJet' -Id $InvalidId -Confirm:$false -LogPath $script:logPath } | Should -Throw

        Should -Invoke Remove-SpoolerJobRaw -ModuleName SpoolDoctor -Times 0 -Exactly
        Should -Invoke Get-SpoolerJobRaw -ModuleName SpoolDoctor -Times 0 -Exactly
    }

    It 'executa o fluxo feliz por parâmetros diretos, confirma ausência do job mesmo com outro job na fila e grava log' {
        Mock Get-SpoolerJobRaw -ModuleName SpoolDoctor {
            return @([PSCustomObject]@{ Id = 99; PrinterName = 'HP LaserJet'; JobStatus = 'Printing' })
        }

        $result = Remove-SpoolerJob -PrinterName 'HP LaserJet' -Id 21 -Confirm:$false -LogPath $script:logPath

        $result.PSObject.TypeNames | Should -Contain 'SpoolDoctor.ActionResult'
        $result.ComputerName | Should -Be $env:COMPUTERNAME
        $result.Action | Should -Be 'Remove-SpoolerJob'
        $result.Outcome | Should -Be 'OK'
        $result.Timestamp | Should -BeOfType [datetime]
        $result.Message | Should -Match 'HP LaserJet'
        $result.Message | Should -Match '\b21\b'

        Should -Invoke Remove-SpoolerJobRaw -ModuleName SpoolDoctor -Times 1 -Exactly -ParameterFilter {
            $PrinterName -eq 'HP LaserJet' -and $Id -eq 21
        }
        Should -Invoke Get-SpoolerJobRaw -ModuleName SpoolDoctor -Times 1 -Exactly -ParameterFilter {
            $PrinterName -eq 'HP LaserJet'
        }

        Test-Path -LiteralPath $script:logPath -PathType Leaf | Should -BeTrue
        $logLines = @(Get-Content -LiteralPath $script:logPath -Encoding UTF8)
        $logLines.Count | Should -Be 1
        $logLines[0] | Should -Match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}'
        $logLines[0] | Should -Match "Computer=$([regex]::Escape($env:COMPUTERNAME))"
        $logLines[0] | Should -Match 'Action=Remove-SpoolerJob'
        $logLines[0] | Should -Match 'Outcome=OK'
        $logLines[0] | Should -Match 'HP LaserJet'
        $logLines[0] | Should -Match '\b21\b'
    }

    It 'processa múltiplos jobs diretamente do pipeline de Get-SpoolerJob mantendo logs em TestDrive' {
        $now = Get-Date
        $getLogPath = Join-Path -Path 'TestDrive:\' -ChildPath ("get-jobs-pipe-{0}.log" -f [guid]::NewGuid().ToString('N'))
        $script:removedKeys = New-Object -TypeName 'System.Collections.Generic.HashSet[string]'
        $script:pipeJobsByPrinter = @{
            'HP LaserJet'      = @(
                [PSCustomObject]@{
                    Id            = 101
                    PrinterName   = 'HP LaserJet'
                    DocumentName  = 'DocA.pdf'
                    Size          = 2048
                    SubmittedTime = $now.AddMinutes(-5)
                    JobStatus     = 'Printing'
                    ComputerName  = 'PC-MATRIZ'
                }
            )
            'Canon Financeiro' = @(
                [PSCustomObject]@{
                    Id            = 202
                    PrinterName   = 'Canon Financeiro'
                    DocumentName  = 'DocB.pdf'
                    Size          = 4096
                    SubmittedTime = $now.AddMinutes(-10)
                    JobStatus     = 'Error'
                    ComputerName  = 'PC-MATRIZ'
                }
            )
        }

        Mock Get-SpoolerPrinterRaw -ModuleName SpoolDoctor {
            return @(
                [PSCustomObject]@{ Name = 'HP LaserJet' },
                [PSCustomObject]@{ Name = 'Canon Financeiro' }
            )
        }
        Mock Remove-SpoolerJobRaw -ModuleName SpoolDoctor {
            param([string]$PrinterName, [int]$Id)
            $null = $script:removedKeys.Add("$PrinterName|$Id")
        }
        Mock Get-SpoolerJobRaw -ModuleName SpoolDoctor {
            param([string]$PrinterName)
            $jobs = @($script:pipeJobsByPrinter[$PrinterName] | Where-Object {
                -not $script:removedKeys.Contains("$PrinterName|$($_.Id)")
            })
            return $jobs
        }

        $results = @(Get-SpoolerJob -LogPath $getLogPath | Remove-SpoolerJob -Confirm:$false -LogPath $script:logPath)

        $results.Count | Should -Be 2
        foreach ($res in $results) {
            $res.PSObject.TypeNames | Should -Contain 'SpoolDoctor.ActionResult'
            $res.Action | Should -Be 'Remove-SpoolerJob'
            $res.Outcome | Should -Be 'OK'
        }
        $results[0].Message | Should -Match 'HP LaserJet'
        $results[0].Message | Should -Match '\b101\b'
        $results[1].Message | Should -Match 'Canon Financeiro'
        $results[1].Message | Should -Match '\b202\b'

        Should -Invoke Remove-SpoolerJobRaw -ModuleName SpoolDoctor -Times 2 -Exactly

        Test-Path -LiteralPath $getLogPath -PathType Leaf | Should -BeTrue
        Test-Path -LiteralPath $script:logPath -PathType Leaf | Should -BeTrue
        $logLines = @(Get-Content -LiteralPath $script:logPath -Encoding UTF8)
        $logLines.Count | Should -Be 2
        $logLines[0] | Should -Match 'Outcome=OK'
        $logLines[0] | Should -Match 'HP LaserJet'
        $logLines[0] | Should -Match '\b101\b'
        $logLines[1] | Should -Match 'Outcome=OK'
        $logLines[1] | Should -Match 'Canon Financeiro'
        $logLines[1] | Should -Match '\b202\b'
    }

    It 'continua processando demais jobs do pipeline quando um job falha' {
        $inputJobs = @(
            [PSCustomObject]@{ PrinterName = 'HP LaserJet'; Id = 301 },
            [PSCustomObject]@{ PrinterName = 'Canon Financeiro'; Id = 302 }
        )

        Mock Remove-SpoolerJobRaw -ModuleName SpoolDoctor {
            param([string]$PrinterName, [int]$Id)
            if ($Id -eq 301) {
                throw 'Falha simulada no job 301.'
            }
        }
        Mock Get-SpoolerJobRaw -ModuleName SpoolDoctor { return @() }

        $results = @($inputJobs | Remove-SpoolerJob -Confirm:$false -LogPath $script:logPath)

        $results.Count | Should -Be 2
        $results[0].Outcome | Should -Be 'Failed'
        $results[0].Message | Should -Match '\b301\b'
        $results[0].Message | Should -Match 'Falha simulada no job 301\.'

        $results[1].Outcome | Should -Be 'OK'
        $results[1].Message | Should -Match '\b302\b'

        Should -Invoke Remove-SpoolerJobRaw -ModuleName SpoolDoctor -Times 2 -Exactly
        Should -Invoke Get-SpoolerJobRaw -ModuleName SpoolDoctor -Times 1 -Exactly -ParameterFilter {
            $PrinterName -eq 'Canon Financeiro'
        }

        $logLines = @(Get-Content -LiteralPath $script:logPath -Encoding UTF8)
        $logLines.Count | Should -Be 2
        $logLines[0] | Should -Match 'Outcome=Failed'
        $logLines[0] | Should -Match '\b301\b'
        $logLines[1] | Should -Match 'Outcome=OK'
        $logLines[1] | Should -Match '\b302\b'
    }

    It 'retorna Failed e grava log quando Remove-SpoolerJobRaw lança erro' {
        Mock Remove-SpoolerJobRaw -ModuleName SpoolDoctor {
            throw 'Acesso negado ao spooler.'
        }

        $result = Remove-SpoolerJob -PrinterName 'HP LaserJet' -Id 55 -Confirm:$false -LogPath $script:logPath

        $result.Outcome | Should -Be 'Failed'
        $result.Message | Should -Match 'Acesso negado ao spooler\.'
        $result.Message | Should -Match 'HP LaserJet'
        $result.Message | Should -Match '\b55\b'

        Should -Invoke Get-SpoolerJobRaw -ModuleName SpoolDoctor -Times 0 -Exactly

        $logLines = @(Get-Content -LiteralPath $script:logPath -Encoding UTF8)
        $logLines.Count | Should -Be 1
        $logLines[0] | Should -Match 'Outcome=Failed'
        $logLines[0] | Should -Match 'HP LaserJet'
        $logLines[0] | Should -Match '\b55\b'
    }

    It 'retorna Failed recomendando Reset-Spooler quando o job permanece na fila após remoção' {
        Mock Get-SpoolerJobRaw -ModuleName SpoolDoctor {
            return @([PSCustomObject]@{ Id = [uint32]77; PrinterName = 'HP LaserJet'; JobStatus = 'Deleting' })
        }

        $result = Remove-SpoolerJob -PrinterName 'HP LaserJet' -Id 77 -Confirm:$false -LogPath $script:logPath

        $result.Outcome | Should -Be 'Failed'
        $result.Message | Should -Match 'Reset-Spooler'
        $result.Message | Should -Match 'HP LaserJet'
        $result.Message | Should -Match '\b77\b'
        $result.Message | Should -Match 'Deleting'

        Should -Invoke Remove-SpoolerJobRaw -ModuleName SpoolDoctor -Times 1 -Exactly
        Should -Invoke Get-SpoolerJobRaw -ModuleName SpoolDoctor -Times 1 -Exactly

        $logLines = @(Get-Content -LiteralPath $script:logPath -Encoding UTF8)
        $logLines.Count | Should -Be 1
        $logLines[0] | Should -Match 'Outcome=Failed'
        $logLines[0] | Should -Match 'Reset-Spooler'
        $logLines[0] | Should -Match 'HP LaserJet'
        $logLines[0] | Should -Match '\b77\b'
    }

    It 'retorna Failed e grava log quando Get-SpoolerJobRaw lança erro na verificação final' {
        Mock Get-SpoolerJobRaw -ModuleName SpoolDoctor {
            throw 'Erro ao consultar fila após remoção.'
        }

        $result = Remove-SpoolerJob -PrinterName 'HP LaserJet' -Id 88 -Confirm:$false -LogPath $script:logPath

        $result.Outcome | Should -Be 'Failed'
        $result.Message | Should -Match 'Erro ao consultar fila após remoção\.'
        $result.Message | Should -Match 'HP LaserJet'
        $result.Message | Should -Match '\b88\b'

        Should -Invoke Remove-SpoolerJobRaw -ModuleName SpoolDoctor -Times 1 -Exactly
        Should -Invoke Get-SpoolerJobRaw -ModuleName SpoolDoctor -Times 1 -Exactly

        $logLines = @(Get-Content -LiteralPath $script:logPath -Encoding UTF8)
        $logLines.Count | Should -Be 1
        $logLines[0] | Should -Match 'Outcome=Failed'
        $logLines[0] | Should -Match 'HP LaserJet'
        $logLines[0] | Should -Match '\b88\b'
    }

    Context 'Execução remota (Operação 6)' {
        BeforeEach {
            $script:remoteAllowListPath = Join-Path -Path 'TestDrive:\' -ChildPath ("remove-job-allow-{0}.txt" -f [guid]::NewGuid().ToString('N'))
            @(
                'PC-REMOTO-01'
                'SRV-PRINT-01|PrintServer'
            ) | Set-Content -LiteralPath $script:remoteAllowListPath -Encoding UTF8

            $script:remoteSessionObj = [PSCustomObject]@{ ComputerName = 'PC-REMOTO-01'; Id = 2 }
            Mock New-SpoolerRemoteSession -ModuleName SpoolDoctor { return $script:remoteSessionObj }
            Mock Invoke-SpoolerRemoteScript -ModuleName SpoolDoctor {
                return [PSCustomObject]@{
                    PSTypeName   = 'Deserialized.SpoolDoctor.ActionResult'
                    ComputerName = 'PC-REMOTO-01'
                    Action       = 'Remove-SpoolerJob'
                    Outcome      = 'OK'
                    Message      = "Job 12 da impressora 'HP Remota' cancelado com sucesso na máquina 'PC-REMOTO-01'."
                    Timestamp    = Get-Date
                }
            }
            Mock Remove-SpoolerRemoteSession -ModuleName SpoolDoctor {}
        }

        It 'preserva execução local quando -ComputerName aponta para a máquina local' {
            Mock Get-SpoolerJobRaw -ModuleName SpoolDoctor { return @() }

            $result = Remove-SpoolerJob -PrinterName 'HP Local' -Id 5 -ComputerName $env:COMPUTERNAME -AllowedComputersPath $script:remoteAllowListPath -Confirm:$false -LogPath $script:logPath

            $result.Outcome | Should -Be 'OK'
            $result.ComputerName | Should -Be $env:COMPUTERNAME
            Should -Invoke New-SpoolerRemoteSession -ModuleName SpoolDoctor -Times 0 -Exactly
            Should -Invoke Remove-SpoolerJobRaw -ModuleName SpoolDoctor -Times 1 -Exactly
        }

        It 'executa fluxo remoto feliz sem exigir admin local, fecha sessão e grava log com hostname remoto' {
            Mock Test-IsAdministrator -ModuleName SpoolDoctor { return $false }

            $result = Remove-SpoolerJob -PrinterName 'HP Remota' -Id 12 -ComputerName 'pc-remoto-01' -AllowedComputersPath $script:remoteAllowListPath -Confirm:$false -LogPath $script:logPath

            $result.PSObject.TypeNames | Should -Contain 'SpoolDoctor.ActionResult'
            $result.ComputerName | Should -Be 'PC-REMOTO-01'
            $result.Action | Should -Be 'Remove-SpoolerJob'
            $result.Outcome | Should -Be 'OK'
            $result.Message | Should -Match 'PC-REMOTO-01'

            Should -Invoke New-SpoolerRemoteSession -ModuleName SpoolDoctor -Times 1 -Exactly
            Should -Invoke Invoke-SpoolerRemoteScript -ModuleName SpoolDoctor -Times 1 -Exactly
            Should -Invoke Remove-SpoolerRemoteSession -ModuleName SpoolDoctor -Times 1 -Exactly

            $logLines = @(Get-Content -LiteralPath $script:logPath -Encoding UTF8)
            $logLines.Count | Should -Be 1
            $logLines[0] | Should -Match 'Computer=PC-REMOTO-01'
            $logLines[0] | Should -Match 'Action=Remove-SpoolerJob'
            $logLines[0] | Should -Match 'Outcome=OK'
        }

        It 'em modo -WhatIf remoto retorna Simulated com hostname no log e não abre sessão WinRM' {
            $result = Remove-SpoolerJob -PrinterName 'HP Remota' -Id 12 -ComputerName 'PC-REMOTO-01' -AllowedComputersPath $script:remoteAllowListPath -WhatIf -LogPath $script:logPath

            $result.ComputerName | Should -Be 'PC-REMOTO-01'
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
            $childLogPath = Join-Path -Path $physicalTestDrive -ChildPath ("remove-remote-skipped-{0}.log" -f [guid]::NewGuid().ToString('N'))
            $childAllowPath = Join-Path -Path $physicalTestDrive -ChildPath ("remove-remote-allow-{0}.txt" -f [guid]::NewGuid().ToString('N'))
            Set-Content -LiteralPath $childAllowPath -Value 'PC-REMOTO-01' -Encoding UTF8

            $childScript = @"
`$ErrorActionPreference = 'Stop'
Import-Module -Name '$manifestPath' -Force
& (Get-Module -Name 'SpoolDoctor') {
    function script:New-SpoolerRemoteSession { [CmdletBinding(SupportsShouldProcess)] param([string]`$ComputerName, [PSCredential]`$Credential) throw 'Não deveria chamar New-SpoolerRemoteSession.' }
    function script:Invoke-SpoolerRemoteScript { param(`$Session, `$ScriptBlock, `$ArgumentList) throw 'Não deveria chamar Invoke-SpoolerRemoteScript.' }
    function script:Remove-SpoolerRemoteSession { [CmdletBinding(SupportsShouldProcess)] param(`$Session) throw 'Não deveria chamar Remove-SpoolerRemoteSession.' }
}
Remove-SpoolerJob -PrinterName 'HP Remota' -Id 44 -ComputerName 'PC-REMOTO-01' -AllowedComputersPath '$childAllowPath' -Confirm -LogPath '$childLogPath' | ConvertTo-Json -Compress
"@

            $rawOutput = @('N' | & powershell.exe -NoProfile -Command $childScript 2>&1 | ForEach-Object { $_.ToString() })
            $LASTEXITCODE | Should -Be 0

            ($rawOutput -join "`n") | Should -Match 'PC-REMOTO-01'
            $jsonLine = $rawOutput | Where-Object { $_ -match '^\s*\{.*\}\s*$' } | Select-Object -Last 1
            $jsonLine | Should -Not -BeNullOrEmpty

            $parsedResult = $jsonLine | ConvertFrom-Json
            $parsedResult.Outcome | Should -Be 'Skipped'
            $parsedResult.ComputerName | Should -Be 'PC-REMOTO-01'
            $parsedResult.Message | Should -Match 'PC-REMOTO-01'

            $logLines = @(Get-Content -LiteralPath $childLogPath -Encoding UTF8)
            $logLines.Count | Should -Be 1
            $logLines[0] | Should -Match 'Computer=PC-REMOTO-01'
            $logLines[0] | Should -Match 'Outcome=Skipped'
        }

        It 'recusa -ComputerName inválido ou fora da allow-list retornando Failed sem abrir sessão' {
            $invalidRes = Remove-SpoolerJob -PrinterName 'HP Remota' -Id 12 -ComputerName 'PC;bad' -AllowedComputersPath $script:remoteAllowListPath -Confirm:$false -LogPath $script:logPath
            $invalidRes.Outcome | Should -Be 'Failed'

            $unlistedLog = Join-Path -Path 'TestDrive:\' -ChildPath ("remove-unlisted-{0}.log" -f [guid]::NewGuid().ToString('N'))
            $unlistedRes = Remove-SpoolerJob -PrinterName 'HP Remota' -Id 12 -ComputerName 'PC-INTRUSO' -AllowedComputersPath $script:remoteAllowListPath -Confirm:$false -LogPath $unlistedLog
            $unlistedRes.Outcome | Should -Be 'Failed'
            $unlistedRes.ComputerName | Should -Be 'PC-INTRUSO'
            $unlistedRes.Message | Should -Match 'allow-list'

            Should -Invoke New-SpoolerRemoteSession -ModuleName SpoolDoctor -Times 0 -Exactly

            $logLines = @(Get-Content -LiteralPath $unlistedLog -Encoding UTF8)
            $logLines.Count | Should -Be 1
            $logLines[0] | Should -Match 'Computer=PC-INTRUSO'
            $logLines[0] | Should -Match 'Outcome=Failed'
        }

        It 'retorna Unreachable, fecha sessão no finally e grava log em falha de conectividade WinRM' {
            Mock Invoke-SpoolerRemoteScript -ModuleName SpoolDoctor {
                throw (New-Object -TypeName System.Management.Automation.Remoting.PSRemotingTransportException -ArgumentList 'WinRM unreachable.')
            }

            $result = Remove-SpoolerJob -PrinterName 'HP Remota' -Id 12 -ComputerName 'PC-REMOTO-01' -AllowedComputersPath $script:remoteAllowListPath -Confirm:$false -LogPath $script:logPath

            $result.Outcome | Should -Be 'Unreachable'
            $result.ComputerName | Should -Be 'PC-REMOTO-01'
            $result.Message | Should -Match 'PC-REMOTO-01'
            Should -Invoke Remove-SpoolerRemoteSession -ModuleName SpoolDoctor -Times 1 -Exactly

            $logLines = @(Get-Content -LiteralPath $script:logPath -Encoding UTF8)
            $logLines.Count | Should -Be 1
            $logLines[0] | Should -Match 'Computer=PC-REMOTO-01'
            $logLines[0] | Should -Match 'Outcome=Unreachable'
        }

        It 'retorna Failed e grava log quando falha autenticação ou permissão administrativa no destino' {
            Mock New-SpoolerRemoteSession -ModuleName SpoolDoctor {
                throw (New-Object -TypeName System.UnauthorizedAccessException -ArgumentList 'Access denied.')
            }

            $authResult = Remove-SpoolerJob -PrinterName 'HP Remota' -Id 12 -ComputerName 'PC-REMOTO-01' -AllowedComputersPath $script:remoteAllowListPath -Confirm:$false -LogPath $script:logPath
            $authResult.Outcome | Should -Be 'Failed'
            $authResult.ComputerName | Should -Be 'PC-REMOTO-01'
            Should -Invoke Remove-SpoolerRemoteSession -ModuleName SpoolDoctor -Times 0 -Exactly

            $noAdminLog = Join-Path -Path 'TestDrive:\' -ChildPath ("remove-noadmin-{0}.log" -f [guid]::NewGuid().ToString('N'))
            Mock New-SpoolerRemoteSession -ModuleName SpoolDoctor { return $script:remoteSessionObj }
            Mock Invoke-SpoolerRemoteScript -ModuleName SpoolDoctor {
                return [PSCustomObject]@{
                    PSTypeName   = 'Deserialized.SpoolDoctor.ActionResult'
                    ComputerName = 'PC-REMOTO-01'
                    Action       = 'Remove-SpoolerJob'
                    Outcome      = 'Failed'
                    Message      = "Permissão negada na máquina 'PC-REMOTO-01': execute como Administrador."
                    Timestamp    = Get-Date
                }
            }

            $noAdminResult = Remove-SpoolerJob -PrinterName 'HP Remota' -Id 12 -ComputerName 'PC-REMOTO-01' -AllowedComputersPath $script:remoteAllowListPath -Confirm:$false -LogPath $noAdminLog
            $noAdminResult.Outcome | Should -Be 'Failed'
            $noAdminResult.Message | Should -Match 'PC-REMOTO-01'
            Should -Invoke Remove-SpoolerRemoteSession -ModuleName SpoolDoctor -Times 1 -Exactly
        }
    }

    Context 'Execução remota em lote (Operação 7)' {
        BeforeEach {
            $script:batchAllowListPath = Join-Path -Path 'TestDrive:\' -ChildPath ("remove-batch-allow-{0}.txt" -f [guid]::NewGuid().ToString('N'))
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
                $opParams = $ArgumentList[2]
                return [PSCustomObject]@{
                    PSTypeName   = 'Deserialized.SpoolDoctor.ActionResult'
                    ComputerName = $targetHost
                    Action       = 'Remove-SpoolerJob'
                    Outcome      = 'OK'
                    Message      = "Job $($opParams['Id']) da impressora '$($opParams['PrinterName'])' cancelado com sucesso na máquina '$targetHost'."
                    Timestamp    = Get-Date
                }
            }
            Mock Remove-SpoolerRemoteSession -ModuleName SpoolDoctor {
                param($Session)
                $script:closedSessionTargets.Add([string]$Session.ComputerName)
            }
        }

        It 'executa lote 100% bem-sucedido em 3 máquinas com logs e encerramento de todas as sessões' {
            $results = @(Remove-SpoolerJob -PrinterName 'HP Rede' -Id 12 -ComputerName @('PC-REMOTO-01', 'pc-remoto-02', 'PC-REMOTO-03') -AllowedComputersPath $script:batchAllowListPath -Confirm:$false -LogPath $script:logPath)

            $results.Count | Should -Be 3
            $results[0].ComputerName | Should -Be 'PC-REMOTO-01'
            $results[1].ComputerName | Should -Be 'PC-REMOTO-02'
            $results[2].ComputerName | Should -Be 'PC-REMOTO-03'
            foreach ($res in $results) {
                $res.PSObject.TypeNames | Should -Contain 'SpoolDoctor.ActionResult'
                $res.Action | Should -Be 'Remove-SpoolerJob'
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

        It 'isola falhas Unreachable, allow-list, entrada vazia e auth no meio do lote fechando sessões abertas' {
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
                if ($targetHost -eq 'SRV-PRINT-01') {
                    throw (New-Object -TypeName System.Management.Automation.Remoting.PSRemotingTransportException -ArgumentList 'WinRM unreachable.')
                }
                return [PSCustomObject]@{
                    PSTypeName   = 'Deserialized.SpoolDoctor.ActionResult'
                    ComputerName = $targetHost
                    Action       = 'Remove-SpoolerJob'
                    Outcome      = 'OK'
                    Message      = "Job 12 cancelado na máquina '$targetHost'."
                    Timestamp    = Get-Date
                }
            }

            $targets = @('PC-REMOTO-01', 'SRV-PRINT-01', 'PC-INTRUSO', '', 'PC-REMOTO-02', 'PC-REMOTO-03')
            $results = @(Remove-SpoolerJob -PrinterName 'HP Rede' -Id 12 -ComputerName $targets -AllowedComputersPath $script:batchAllowListPath -Confirm:$false -LogPath $script:logPath)

            $results.Count | Should -Be 6
            $results[0].ComputerName | Should -Be 'PC-REMOTO-01'
            $results[0].Outcome | Should -Be 'OK'
            $results[1].ComputerName | Should -Be 'SRV-PRINT-01'
            $results[1].Outcome | Should -Be 'Unreachable'
            $results[2].ComputerName | Should -Be 'PC-INTRUSO'
            $results[2].Outcome | Should -Be 'Failed'
            $results[3].ComputerName | Should -Be '(inválido)'
            $results[3].Outcome | Should -Be 'Failed'
            $results[4].ComputerName | Should -Be 'PC-REMOTO-02'
            $results[4].Outcome | Should -Be 'Failed'
            $results[5].ComputerName | Should -Be 'PC-REMOTO-03'
            $results[5].Outcome | Should -Be 'OK'

            $script:openedSessionTargets.ToArray() | Should -Be @('PC-REMOTO-01', 'SRV-PRINT-01', 'PC-REMOTO-03')
            $script:closedSessionTargets.ToArray() | Should -Be @('PC-REMOTO-01', 'SRV-PRINT-01', 'PC-REMOTO-03')

            $logLines = @(Get-Content -LiteralPath $script:logPath -Encoding UTF8)
            $logLines.Count | Should -Be 6
            $logLines[1] | Should -Match 'Computer=SRV-PRINT-01.*Outcome=Unreachable'
            $logLines[2] | Should -Match 'Computer=PC-INTRUSO.*Outcome=Failed'
            $logLines[3] | Should -Match 'Computer=\(inválido\).*Outcome=Failed'
            $logLines[4] | Should -Match 'Computer=PC-REMOTO-02.*Outcome=Failed'
            $logLines[5] | Should -Match 'Computer=PC-REMOTO-03.*Outcome=OK'
        }

        It 'em modo -WhatIf no lote não abre sessão WinRM e retorna Simulated por máquina autorizada' {
            $results = @(Remove-SpoolerJob -PrinterName 'HP Rede' -Id 12 -ComputerName @('PC-REMOTO-01', 'PC-REMOTO-02') -AllowedComputersPath $script:batchAllowListPath -WhatIf -LogPath $script:logPath)

            $results.Count | Should -Be 2
            $results[0].ComputerName | Should -Be 'PC-REMOTO-01'
            $results[0].Outcome | Should -Be 'Simulated'
            $results[1].ComputerName | Should -Be 'PC-REMOTO-02'
            $results[1].Outcome | Should -Be 'Simulated'

            Should -Invoke New-SpoolerRemoteSession -ModuleName SpoolDoctor -Times 0 -Exactly
            Should -Invoke Invoke-SpoolerRemoteScript -ModuleName SpoolDoctor -Times 0 -Exactly

            $logLines = @(Get-Content -LiteralPath $script:logPath -Encoding UTF8)
            $logLines.Count | Should -Be 2
            $logLines[0] | Should -Match 'Computer=PC-REMOTO-01.*Outcome=Simulated'
            $logLines[1] | Should -Match 'Computer=PC-REMOTO-02.*Outcome=Simulated'
        }

        It 'avalia -Confirm individualmente por máquina exibindo o hostname correspondente' {
            if (-not ('SpoolDoctorBatchConfirmTestHost' -as [type])) {
                Add-Type -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Globalization;
using System.Management.Automation;
using System.Management.Automation.Host;
using System.Security;

public class SpoolDoctorBatchConfirmTestRawUI : PSHostRawUserInterface {
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

public class SpoolDoctorBatchConfirmTestHostUI : PSHostUserInterface {
    public Queue<int> Responses = new Queue<int>();
    public List<string> Prompts = new List<string>();
    private PSHostRawUserInterface _raw = new SpoolDoctorBatchConfirmTestRawUI();
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

public class SpoolDoctorBatchConfirmTestHost : PSHost {
    private Guid _id = Guid.NewGuid();
    private SpoolDoctorBatchConfirmTestHostUI _ui = new SpoolDoctorBatchConfirmTestHostUI();
    public SpoolDoctorBatchConfirmTestHostUI TestUI { get { return _ui; } }
    public override string Name { get { return "SpoolDoctorBatchConfirmTestHost"; } }
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
            $childLogPath = Join-Path -Path $physicalTestDrive -ChildPath ("remove-batch-confirm-{0}.log" -f [guid]::NewGuid().ToString('N'))
            $childAllowPath = Join-Path -Path $physicalTestDrive -ChildPath ("remove-batch-allow-{0}.txt" -f [guid]::NewGuid().ToString('N'))
            @('PC-REMOTO-01', 'PC-REMOTO-02') | Set-Content -LiteralPath $childAllowPath -Encoding UTF8

            $testHost = New-Object -TypeName SpoolDoctorBatchConfirmTestHost
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
            Action       = 'Remove-SpoolerJob'
            Outcome      = 'OK'
            Message      = "Job 44 cancelado na máquina '`$(`$ArgumentList[0])'."
            Timestamp    = Get-Date
        }
    }
    function script:Remove-SpoolerRemoteSession { [CmdletBinding(SupportsShouldProcess)] param(`$Session) }
}
Remove-SpoolerJob -PrinterName 'HP Rede' -Id 44 -ComputerName @('PC-REMOTO-01', 'PC-REMOTO-02') -AllowedComputersPath '$childAllowPath' -Confirm -LogPath '$childLogPath'
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

        It 'suporta lote misto local e remoto, deduplica alvos, recusa @() e preserva pipeline sem bind em ComputerName' {
            $command = Get-Command -Name 'Remove-SpoolerJob' -ErrorAction Stop
            $compAttr = $command.Parameters['ComputerName'].Attributes |
                Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] } |
                Select-Object -First 1
            $compAttr.ValueFromPipelineByPropertyName | Should -BeFalse

            $mixedResults = @(& {
                Set-StrictMode -Version Latest
                Remove-SpoolerJob -PrinterName 'HP Local' -Id 5 -ComputerName @($env:COMPUTERNAME, 'localhost', 'pc-remoto-01', 'PC-REMOTO-01') -AllowedComputersPath $script:batchAllowListPath -Confirm:$false -LogPath $script:logPath
            })

            $mixedResults.Count | Should -Be 2
            $mixedResults[0].ComputerName | Should -Be $env:COMPUTERNAME
            $mixedResults[0].Outcome | Should -Be 'OK'
            $mixedResults[1].ComputerName | Should -Be 'PC-REMOTO-01'
            $mixedResults[1].Outcome | Should -Be 'OK'

            Should -Invoke Remove-SpoolerJobRaw -ModuleName SpoolDoctor -Times 1 -Exactly
            Should -Invoke New-SpoolerRemoteSession -ModuleName SpoolDoctor -Times 1 -Exactly
            Should -Invoke Remove-SpoolerRemoteSession -ModuleName SpoolDoctor -Times 1 -Exactly

            $emptyLog = Join-Path -Path 'TestDrive:\' -ChildPath ("remove-empty-batch-{0}.log" -f [guid]::NewGuid().ToString('N'))
            $emptyResults = @(& {
                Set-StrictMode -Version Latest
                Remove-SpoolerJob -PrinterName 'HP Local' -Id 5 -ComputerName @() -AllowedComputersPath $script:batchAllowListPath -Confirm:$false -LogPath $emptyLog
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
