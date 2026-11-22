Describe 'SpoolDoctor - Get-SpoolerJob' {
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
        $script:logPath = Join-Path -Path 'TestDrive:\' -ChildPath ("get-jobs-{0}.log" -f [guid]::NewGuid().ToString('N'))

        Mock Get-SpoolerPrinterRaw -ModuleName SpoolDoctor { return @() }
        Mock Get-SpoolerJobRaw -ModuleName SpoolDoctor { return @() }
        Mock Test-IsAdministrator -ModuleName SpoolDoctor { return $false }
    }

    It 'declara CmdletBinding sem SupportsShouldProcess e não exige privilégio de administrador' {
        $command = Get-Command -Name 'Get-SpoolerJob' -ErrorAction Stop
        $cmdletBinding = $command.ScriptBlock.Attributes |
            Where-Object { $_ -is [System.Management.Automation.CmdletBindingAttribute] } |
            Select-Object -First 1

        $cmdletBinding | Should -Not -BeNullOrEmpty
        $cmdletBinding.SupportsShouldProcess | Should -BeFalse

        $jobs = @(Get-SpoolerJob -LogPath $script:logPath)
        $jobs.Count | Should -Be 0

        Should -Invoke Test-IsAdministrator -ModuleName SpoolDoctor -Times 0 -Exactly
    }

    It 'lista jobs de múltiplas impressoras no pipeline, valida contrato PrintJob, calcula Age e registra log' {
        $now = Get-Date
        $script:printers = @(
            [PSCustomObject]@{ Name = 'HP LaserJet' },
            [PSCustomObject]@{ Name = 'Canon Financeiro' }
        )
        $script:jobsByPrinter = @{
            'HP LaserJet'      = @(
                [PSCustomObject]@{
                    Id            = 101
                    PrinterName   = 'HP LaserJet'
                    DocumentName  = 'Relatorio.pdf'
                    Size          = 204800
                    SubmittedTime = $now.AddMinutes(-15)
                    JobStatus     = 'Printing'
                    ComputerName  = 'PC-MATRIZ'
                },
                [PSCustomObject]@{
                    Id            = 102
                    PrinterName   = 'HP LaserJet'
                    DocumentName  = 'Planilha.xlsx'
                    Size          = 51200
                    SubmittedTime = $now.AddMinutes(-5)
                    JobStatus     = 'Spooling'
                    ComputerName  = 'PC-MATRIZ'
                }
            )
            'Canon Financeiro' = @(
                [PSCustomObject]@{
                    Id            = 201
                    PrinterName   = 'Canon Financeiro'
                    DocumentName  = 'Contrato.docx'
                    Size          = 1024000
                    SubmittedTime = $now.AddMinutes(-30)
                    JobStatus     = 'Error'
                    ComputerName  = 'PC-MATRIZ'
                }
            )
        }

        Mock Get-SpoolerPrinterRaw -ModuleName SpoolDoctor {
            return $script:printers
        }
        Mock Get-SpoolerJobRaw -ModuleName SpoolDoctor {
            param([string]$PrinterName)
            return $script:jobsByPrinter[$PrinterName]
        }

        $jobs = @(Get-SpoolerJob -LogPath $script:logPath)

        $jobs.Count | Should -Be 3
        foreach ($job in $jobs) {
            $job.PSObject.TypeNames | Should -Contain 'SpoolDoctor.PrintJob'
        }

        $jobs[0].Id | Should -Be 101
        $jobs[0].PrinterName | Should -Be 'HP LaserJet'
        $jobs[0].Document | Should -Be 'Relatorio.pdf'
        $jobs[0].SizeBytes | Should -BeOfType [long]
        $jobs[0].SizeBytes | Should -Be 204800L
        $jobs[0].SubmittedAt | Should -BeOfType [datetime]
        $jobs[0].Age | Should -BeOfType [timespan]
        $jobs[0].Age.TotalMinutes | Should -BeGreaterOrEqual 14.9
        $jobs[0].Age.TotalMinutes | Should -BeLessThan 17
        $jobs[0].Status | Should -Be 'Printing'
        $jobs[0].ComputerName | Should -Be 'PC-MATRIZ'

        $jobs[1].Id | Should -Be 102
        $jobs[1].Age | Should -BeOfType [timespan]
        $jobs[1].Age.TotalMinutes | Should -BeGreaterOrEqual 4.9
        $jobs[1].Age.TotalMinutes | Should -BeLessThan 7

        $jobs[2].Id | Should -Be 201
        $jobs[2].PrinterName | Should -Be 'Canon Financeiro'
        $jobs[2].Document | Should -Be 'Contrato.docx'
        $jobs[2].SizeBytes | Should -Be 1024000L
        $jobs[2].Age.TotalMinutes | Should -BeGreaterOrEqual 29.9
        $jobs[2].Age.TotalMinutes | Should -BeLessThan 32
        $jobs[2].Status | Should -Be 'Error'

        Test-Path -LiteralPath $script:logPath -PathType Leaf | Should -BeTrue
        $logLines = @(Get-Content -LiteralPath $script:logPath -Encoding UTF8)
        $logLines.Count | Should -Be 1
        $logLines[0] | Should -Match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}'
        $logLines[0] | Should -Match "Computer=$([regex]::Escape($env:COMPUTERNAME))"
        $logLines[0] | Should -Match 'Action=Get-SpoolerJob'
        $logLines[0] | Should -Match 'Outcome=OK'
        $logLines[0] | Should -Match 'Jobs encontrados:\s*3'

        $pipedIds = @(Get-SpoolerJob -LogPath $script:logPath | Select-Object -ExpandProperty Id)
        $pipedIds | Should -Be @(101, 102, 201)
    }

    It 'filtra por -PrinterName consultando apenas a impressora solicitada e registra filtro no log' {
        $now = Get-Date
        $script:filteredJobs = @(
            [PSCustomObject]@{
                Id            = 11
                PrinterName   = 'HP LaserJet'
                DocumentName  = 'Etiqueta.pdf'
                Size          = 4096
                SubmittedTime = $now.AddMinutes(-2)
                JobStatus     = 'Printing'
                ComputerName  = 'PC-MATRIZ'
            },
            [PSCustomObject]@{
                Id            = 12
                PrinterName   = 'HP LaserJet'
                DocumentName  = 'Boleto.pdf'
                Size          = 8192
                SubmittedTime = $now.AddMinutes(-1)
                JobStatus     = 'Normal'
                ComputerName  = 'PC-MATRIZ'
            }
        )

        Mock Get-SpoolerJobRaw -ModuleName SpoolDoctor {
            param([string]$PrinterName)
            if ($PrinterName -eq 'HP LaserJet') {
                return $script:filteredJobs
            }
            return @()
        }

        $jobs = @(Get-SpoolerJob -PrinterName 'HP LaserJet' -LogPath $script:logPath)

        Should -Invoke Get-SpoolerPrinterRaw -ModuleName SpoolDoctor -Times 0 -Exactly
        Should -Invoke Get-SpoolerJobRaw -ModuleName SpoolDoctor -Times 1 -Exactly -ParameterFilter { $PrinterName -eq 'HP LaserJet' }

        $jobs.Count | Should -Be 2
        ($jobs | Select-Object -ExpandProperty PrinterName -Unique) | Should -Be @('HP LaserJet')

        $logLines = @(Get-Content -LiteralPath $script:logPath -Encoding UTF8)
        $logLines.Count | Should -Be 1
        $logLines[0] | Should -Match 'Action=Get-SpoolerJob'
        $logLines[0] | Should -Match 'Outcome=OK'
        $logLines[0] | Should -Match 'HP LaserJet'
        $logLines[0] | Should -Match 'Jobs encontrados:\s*2'
    }

    It 'retorna coleção vazia sem erro em StrictMode quando impressora não possui jobs ou wrapper retorna nulo' {
        Mock Get-SpoolerPrinterRaw -ModuleName SpoolDoctor {
            return @([PSCustomObject]@{ Name = 'HP LaserJet' })
        }
        Mock Get-SpoolerJobRaw -ModuleName SpoolDoctor { return @() }

        $jobsEmpty = @(& {
            Set-StrictMode -Version Latest
            Get-SpoolerJob -LogPath $script:logPath
        })
        $jobsEmpty.Count | Should -Be 0

        $logLines = @(Get-Content -LiteralPath $script:logPath -Encoding UTF8)
        $logLines.Count | Should -Be 1
        $logLines[0] | Should -Match 'Action=Get-SpoolerJob'
        $logLines[0] | Should -Match 'Outcome=OK'
        $logLines[0] | Should -Match 'Jobs encontrados:\s*0'

        $nullLogPath = Join-Path -Path 'TestDrive:\' -ChildPath ("get-jobs-null-{0}.log" -f [guid]::NewGuid().ToString('N'))
        Mock Get-SpoolerJobRaw -ModuleName SpoolDoctor { return $null }

        $jobsNull = @(& {
            Set-StrictMode -Version Latest
            Get-SpoolerJob -LogPath $nullLogPath
        })
        $jobsNull.Count | Should -Be 0

        $nullLogLines = @(Get-Content -LiteralPath $nullLogPath -Encoding UTF8)
        $nullLogLines.Count | Should -Be 1
        $nullLogLines[0] | Should -Match 'Outcome=OK'
        $nullLogLines[0] | Should -Match 'Jobs encontrados:\s*0'
    }

    It 'retorna coleção vazia sem erro em StrictMode quando não há impressoras locais' {
        Mock Get-SpoolerPrinterRaw -ModuleName SpoolDoctor { return @() }

        $jobs = @(& {
            Set-StrictMode -Version Latest
            Get-SpoolerJob -LogPath $script:logPath
        })

        $jobs.Count | Should -Be 0
        Should -Invoke Get-SpoolerJobRaw -ModuleName SpoolDoctor -Times 0 -Exactly

        $logLines = @(Get-Content -LiteralPath $script:logPath -Encoding UTF8)
        $logLines.Count | Should -Be 1
        $logLines[0] | Should -Match 'Action=Get-SpoolerJob'
        $logLines[0] | Should -Match 'Outcome=OK'
        $logLines[0] | Should -Match 'Jobs encontrados:\s*0'
    }

    It 'trata SubmittedTime nulo, propriedade ausente, timestamp futuro e fallbacks sem quebrar em StrictMode' {
        $futureTime = (Get-Date).AddMinutes(10)
        $script:edgeJobs = @(
            [PSCustomObject]@{
                Id            = 301
                PrinterName   = 'Printer-Edge'
                DocumentName  = 'Nulo.pdf'
                Size          = 100
                SubmittedTime = $null
                JobStatus     = 'Paused'
                ComputerName  = 'PC-EDGE'
            },
            [PSCustomObject]@{
                Id           = 302
                DocumentName = 'SemCampos.txt'
            },
            [PSCustomObject]@{
                Id            = 303
                PrinterName   = 'Printer-Edge'
                DocumentName  = 'Futuro.pdf'
                Size          = 500
                SubmittedTime = $futureTime
                JobStatus     = 'Spooling'
                ComputerName  = 'PC-EDGE'
            }
        )

        Mock Get-SpoolerPrinterRaw -ModuleName SpoolDoctor {
            return @([PSCustomObject]@{ Name = 'Printer-Edge' })
        }
        Mock Get-SpoolerJobRaw -ModuleName SpoolDoctor {
            return $script:edgeJobs
        }

        $jobs = @(& {
            Set-StrictMode -Version Latest
            Get-SpoolerJob -LogPath $script:logPath
        })

        $jobs.Count | Should -Be 3

        ($null -eq $jobs[0].SubmittedAt) | Should -BeTrue
        ($null -eq $jobs[0].Age) | Should -BeTrue
        $jobs[0].SizeBytes | Should -Be 100L
        $jobs[0].Status | Should -Be 'Paused'

        ($null -eq $jobs[1].SubmittedAt) | Should -BeTrue
        ($null -eq $jobs[1].Age) | Should -BeTrue
        ($null -eq $jobs[1].SizeBytes) | Should -BeTrue
        $jobs[1].Status | Should -Be 'Unknown'
        $jobs[1].PrinterName | Should -Be 'Printer-Edge'
        $jobs[1].ComputerName | Should -Be $env:COMPUTERNAME

        $jobs[2].Age | Should -BeOfType [timespan]
        $jobs[2].Age | Should -Be ([timespan]::Zero)
    }

    It 'recusa -PrinterName apenas com espaços, grava log Failed e não chama wrappers' {
        { Get-SpoolerJob -PrinterName '   ' -LogPath $script:logPath } | Should -Throw

        Should -Invoke Get-SpoolerPrinterRaw -ModuleName SpoolDoctor -Times 0 -Exactly
        Should -Invoke Get-SpoolerJobRaw -ModuleName SpoolDoctor -Times 0 -Exactly

        Test-Path -LiteralPath $script:logPath -PathType Leaf | Should -BeTrue
        $logLines = @(Get-Content -LiteralPath $script:logPath -Encoding UTF8)
        $logLines.Count | Should -Be 1
        $logLines[0] | Should -Match 'Action=Get-SpoolerJob'
        $logLines[0] | Should -Match 'Outcome=Failed'
    }

    It 'propaga erro explícito e grava log Failed quando Get-SpoolerPrinterRaw falha' {
        Mock Get-SpoolerPrinterRaw -ModuleName SpoolDoctor {
            throw 'Falha simulada ao listar impressoras.'
        }

        { Get-SpoolerJob -LogPath $script:logPath } | Should -Throw '*Falha simulada ao listar impressoras.*'

        Test-Path -LiteralPath $script:logPath -PathType Leaf | Should -BeTrue
        $logLines = @(Get-Content -LiteralPath $script:logPath -Encoding UTF8)
        $logLines.Count | Should -Be 1
        $logLines[0] | Should -Match 'Action=Get-SpoolerJob'
        $logLines[0] | Should -Match 'Outcome=Failed'
        $logLines[0] | Should -Match 'Falha simulada ao listar impressoras\.'
    }

    It 'propaga erro explícito sem emissão parcial e grava log Failed quando Get-SpoolerJobRaw falha na segunda impressora' {
        $script:firstPrinterJob = [PSCustomObject]@{
            Id            = 1
            PrinterName   = 'Printer-1'
            DocumentName  = 'Doc1.pdf'
            Size          = 1024
            SubmittedTime = (Get-Date).AddMinutes(-3)
            JobStatus     = 'Printing'
            ComputerName  = 'PC-MATRIZ'
        }

        Mock Get-SpoolerPrinterRaw -ModuleName SpoolDoctor {
            return @(
                [PSCustomObject]@{ Name = 'Printer-1' },
                [PSCustomObject]@{ Name = 'Printer-2' }
            )
        }
        Mock Get-SpoolerJobRaw -ModuleName SpoolDoctor {
            param([string]$PrinterName)
            if ($PrinterName -eq 'Printer-1') {
                return @($script:firstPrinterJob)
            }
            throw 'Erro simulado na fila da Printer-2.'
        }

        $emitted = @()
        $caught = $null
        try {
            $emitted = @(Get-SpoolerJob -LogPath $script:logPath)
        }
        catch {
            $caught = $_
        }

        $caught | Should -Not -BeNullOrEmpty
        $caught.Exception.Message | Should -Match 'Erro simulado na fila da Printer-2\.'
        $emitted.Count | Should -Be 0

        Test-Path -LiteralPath $script:logPath -PathType Leaf | Should -BeTrue
        $logLines = @(Get-Content -LiteralPath $script:logPath -Encoding UTF8)
        $logLines.Count | Should -Be 1
        $logLines[0] | Should -Match 'Action=Get-SpoolerJob'
        $logLines[0] | Should -Match 'Outcome=Failed'
        $logLines[0] | Should -Match 'Erro simulado na fila da Printer-2\.'
    }

    It 'propaga erro explícito e grava log Failed com nome da impressora quando Get-SpoolerJobRaw falha com -PrinterName' {
        Mock Get-SpoolerJobRaw -ModuleName SpoolDoctor {
            throw 'Impressora não encontrada.'
        }

        { Get-SpoolerJob -PrinterName 'ImpressoraInexistente' -LogPath $script:logPath } | Should -Throw '*Impressora não encontrada.*'

        $logLines = @(Get-Content -LiteralPath $script:logPath -Encoding UTF8)
        $logLines.Count | Should -Be 1
        $logLines[0] | Should -Match 'Action=Get-SpoolerJob'
        $logLines[0] | Should -Match 'Outcome=Failed'
        $logLines[0] | Should -Match 'ImpressoraInexistente'
        $logLines[0] | Should -Match 'Impressora não encontrada\.'
    }
}
