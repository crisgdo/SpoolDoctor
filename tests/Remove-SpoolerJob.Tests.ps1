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
}
