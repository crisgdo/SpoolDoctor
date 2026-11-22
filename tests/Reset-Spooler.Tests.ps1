Describe 'SpoolDoctor - Reset-Spooler' {
    BeforeAll {
        $repoRoot = Split-Path -Path $PSScriptRoot -Parent
        $manifestPath = Join-Path -Path $repoRoot -ChildPath 'src\SpoolDoctor.psd1'
        $spoolDir = [System.IO.Path]::GetFullPath((Join-Path -Path $env:SystemRoot -ChildPath 'System32\spool\PRINTERS'))

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
        $script:logPath = Join-Path -Path 'TestDrive:\' -ChildPath ("reset-{0}.log" -f [guid]::NewGuid().ToString('N'))
        $script:backupPath = Join-Path -Path 'TestDrive:\' -ChildPath ("backup-{0}" -f [guid]::NewGuid().ToString('N'))

        Mock Test-IsAdministrator -ModuleName SpoolDoctor { return $true }
        Mock Stop-SpoolerService -ModuleName SpoolDoctor {}
        Mock Start-SpoolerService -ModuleName SpoolDoctor {}
        Mock Get-SpoolerServiceStatus -ModuleName SpoolDoctor { return 'Running' }
        Mock Get-SpoolFile -ModuleName SpoolDoctor { return @() }
        Mock Copy-SpoolFile -ModuleName SpoolDoctor {}
        Mock Remove-SpoolFile -ModuleName SpoolDoctor {}
    }

    It 'declara SupportsShouldProcess e ConfirmImpact = High' {
        $command = Get-Command -Name 'Reset-Spooler' -ErrorAction Stop
        $cmdletBinding = $command.ScriptBlock.Attributes |
            Where-Object { $_ -is [System.Management.Automation.CmdletBindingAttribute] } |
            Select-Object -First 1

        $cmdletBinding | Should -Not -BeNullOrEmpty
        $cmdletBinding.SupportsShouldProcess | Should -BeTrue
        $cmdletBinding.ConfirmImpact | Should -Be ([System.Management.Automation.ConfirmImpact]::High)
    }

    It 'recusa execução sem privilégio de administrador, registra log e não toca no sistema' {
        Mock Test-IsAdministrator -ModuleName SpoolDoctor { return $false }

        $result = Reset-Spooler -Confirm:$false -LogPath $script:logPath

        $result.ComputerName | Should -Be $env:COMPUTERNAME
        $result.Action | Should -Be 'Reset-Spooler'
        $result.Outcome | Should -Be 'Failed'
        $result.Message | Should -Match 'Administrador'
        $result.Timestamp | Should -BeOfType [datetime]

        Should -Invoke Stop-SpoolerService -ModuleName SpoolDoctor -Times 0 -Exactly
        Should -Invoke Get-SpoolFile -ModuleName SpoolDoctor -Times 0 -Exactly
        Should -Invoke Copy-SpoolFile -ModuleName SpoolDoctor -Times 0 -Exactly
        Should -Invoke Remove-SpoolFile -ModuleName SpoolDoctor -Times 0 -Exactly
        Should -Invoke Start-SpoolerService -ModuleName SpoolDoctor -Times 0 -Exactly
        Should -Invoke Get-SpoolerServiceStatus -ModuleName SpoolDoctor -Times 0 -Exactly

        Test-Path -LiteralPath $script:logPath -PathType Leaf | Should -BeTrue
        $logLines = @(Get-Content -LiteralPath $script:logPath -Encoding UTF8)
        $logLines.Count | Should -Be 1
        $logLines[0] | Should -Match 'Outcome=Failed'
    }

    It 'em modo -WhatIf não chama wrappers destrutivos, grava log e retorna Simulated' {
        $result = Reset-Spooler -WhatIf -LogPath $script:logPath -BackupPath $script:backupPath

        $result.ComputerName | Should -Be $env:COMPUTERNAME
        $result.Action | Should -Be 'Reset-Spooler'
        $result.Outcome | Should -Be 'Simulated'
        $result.Timestamp | Should -BeOfType [datetime]

        Should -Invoke Stop-SpoolerService -ModuleName SpoolDoctor -Times 0 -Exactly
        Should -Invoke Get-SpoolFile -ModuleName SpoolDoctor -Times 0 -Exactly
        Should -Invoke Copy-SpoolFile -ModuleName SpoolDoctor -Times 0 -Exactly
        Should -Invoke Remove-SpoolFile -ModuleName SpoolDoctor -Times 0 -Exactly
        Should -Invoke Start-SpoolerService -ModuleName SpoolDoctor -Times 0 -Exactly
        Should -Invoke Get-SpoolerServiceStatus -ModuleName SpoolDoctor -Times 0 -Exactly
        Test-Path -LiteralPath $script:backupPath | Should -BeFalse

        Test-Path -LiteralPath $script:logPath -PathType Leaf | Should -BeTrue
        $logLines = @(Get-Content -LiteralPath $script:logPath -Encoding UTF8)
        $logLines.Count | Should -Be 1
        $logLines[0] | Should -Match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}'
        $logLines[0] | Should -Match 'Outcome=Simulated'
    }

    It 'retorna Skipped e registra log quando o usuário recusa a confirmação' {
        $physicalTestDrive = (Get-PSDrive -Name 'TestDrive').Root
        $childLogPath = Join-Path -Path $physicalTestDrive -ChildPath ("skipped-{0}.log" -f [guid]::NewGuid().ToString('N'))

        $childScript = @"
`$ErrorActionPreference = 'Stop'
Import-Module -Name '$manifestPath' -Force
& (Get-Module -Name 'SpoolDoctor') {
    function script:Test-IsAdministrator { return `$true }
    function script:Stop-SpoolerService { [CmdletBinding(SupportsShouldProcess)] param() throw 'Não deveria chamar Stop-SpoolerService.' }
    function script:Get-SpoolFile { throw 'Não deveria chamar Get-SpoolFile.' }
    function script:Copy-SpoolFile { [CmdletBinding(SupportsShouldProcess)] param([string]`$Path, [string]`$DestinationDirectory) throw 'Não deveria chamar Copy-SpoolFile.' }
    function script:Remove-SpoolFile { [CmdletBinding(SupportsShouldProcess)] param([string]`$Path) throw 'Não deveria chamar Remove-SpoolFile.' }
    function script:Start-SpoolerService { [CmdletBinding(SupportsShouldProcess)] param() throw 'Não deveria chamar Start-SpoolerService.' }
    function script:Get-SpoolerServiceStatus { throw 'Não deveria chamar Get-SpoolerServiceStatus.' }
}
Reset-Spooler -LogPath '$childLogPath' | ConvertTo-Json -Compress
"@

        $rawOutput = @('N' | & powershell.exe -NoProfile -Command $childScript)
        $LASTEXITCODE | Should -Be 0

        $jsonLine = $rawOutput | Where-Object { $_ -match '^\s*\{.*\}\s*$' } | Select-Object -Last 1
        $jsonLine | Should -Not -BeNullOrEmpty

        $parsedResult = $jsonLine | ConvertFrom-Json
        $parsedResult.Outcome | Should -Be 'Skipped'
        $parsedResult.Action | Should -Be 'Reset-Spooler'
        $parsedResult.ComputerName | Should -Be $env:COMPUTERNAME

        Test-Path -LiteralPath $childLogPath -PathType Leaf | Should -BeTrue
        $logLines = @(Get-Content -LiteralPath $childLogPath -Encoding UTF8)
        $logLines.Count | Should -Be 1
        $logLines[0] | Should -Match 'Outcome=Skipped'
    }

    It 'recusa caminho inseguro (<Kind>) durante o reset, tenta reiniciar o serviço no finally e retorna Failed' -ForEach @(
        @{ Kind = 'fora de PRINTERS' }
        @{ Kind = 'path traversal' }
        @{ Kind = 'extensão inválida' }
    ) {
        param($Kind)

        $unsafeTarget = switch ($Kind) {
            'fora de PRINTERS'  { 'C:\Temp\00001.SPL' }
            'path traversal'    { Join-Path -Path $spoolDir -ChildPath '..\drivers\00001.SPL' }
            'extensão inválida' { Join-Path -Path $spoolDir -ChildPath '00001.TXT' }
        }
        $script:unsafeCandidate = $unsafeTarget

        Mock Get-SpoolFile -ModuleName SpoolDoctor {
            return @([PSCustomObject]@{ FullName = $script:unsafeCandidate })
        }

        $result = Reset-Spooler -Confirm:$false -LogPath $script:logPath -BackupPath $script:backupPath

        $result.Outcome | Should -Be 'Failed' -Because "caminho inseguro '$unsafeTarget' deve falhar"
        Should -Invoke Copy-SpoolFile -ModuleName SpoolDoctor -Times 0 -Exactly
        Should -Invoke Remove-SpoolFile -ModuleName SpoolDoctor -Times 0 -Exactly
        Should -Invoke Start-SpoolerService -ModuleName SpoolDoctor -Times 1 -Exactly

        Test-Path -LiteralPath $script:logPath -PathType Leaf | Should -BeTrue
        $logLines = @(Get-Content -LiteralPath $script:logPath -Encoding UTF8)
        $logLines.Count | Should -Be 1
        $logLines[0] | Should -Match 'Outcome=Failed'
    }

    It 'retorna Failed e grava log quando Stop-SpoolerService falha' {
        Mock Stop-SpoolerService -ModuleName SpoolDoctor { throw 'Falha simulada ao parar o serviço.' }

        $result = Reset-Spooler -Confirm:$false -LogPath $script:logPath

        $result.Outcome | Should -Be 'Failed'
        $result.Message | Should -Match 'Falha simulada ao parar o serviço\.'

        Should -Invoke Remove-SpoolFile -ModuleName SpoolDoctor -Times 0 -Exactly
        Should -Invoke Start-SpoolerService -ModuleName SpoolDoctor -Times 0 -Exactly

        $logLines = @(Get-Content -LiteralPath $script:logPath -Encoding UTF8)
        $logLines.Count | Should -Be 1
        $logLines[0] | Should -Match 'Outcome=Failed'
    }

    It 'tenta reiniciar o serviço no finally quando Remove-SpoolFile falha e retorna Failed' {
        $validFile = Join-Path -Path $spoolDir -ChildPath '00001.SPL'
        $script:removeFailTarget = $validFile

        Mock Get-SpoolFile -ModuleName SpoolDoctor {
            return @([PSCustomObject]@{ FullName = $script:removeFailTarget })
        }
        Mock Remove-SpoolFile -ModuleName SpoolDoctor { throw 'Arquivo bloqueado em uso.' }

        $result = Reset-Spooler -Confirm:$false -LogPath $script:logPath

        $result.Outcome | Should -Be 'Failed'
        $result.Message | Should -Match 'Arquivo bloqueado em uso\.'

        Should -Invoke Stop-SpoolerService -ModuleName SpoolDoctor -Times 1 -Exactly
        Should -Invoke Start-SpoolerService -ModuleName SpoolDoctor -Times 1 -Exactly

        $logLines = @(Get-Content -LiteralPath $script:logPath -Encoding UTF8)
        $logLines.Count | Should -Be 1
        $logLines[0] | Should -Match 'Outcome=Failed'
    }

    It 'registra ambos os erros e retorna Failed se Remove-SpoolFile e a recuperação no finally falharem' {
        $validFile = Join-Path -Path $spoolDir -ChildPath '00001.SPL'
        $script:doubleFailTarget = $validFile

        Mock Get-SpoolFile -ModuleName SpoolDoctor {
            return @([PSCustomObject]@{ FullName = $script:doubleFailTarget })
        }
        Mock Remove-SpoolFile -ModuleName SpoolDoctor { throw 'Erro na remoção do arquivo.' }
        Mock Start-SpoolerService -ModuleName SpoolDoctor { throw 'Erro ao reiniciar o spooler.' }

        $result = Reset-Spooler -Confirm:$false -LogPath $script:logPath

        $result.Outcome | Should -Be 'Failed'
        $result.Message | Should -Match 'Erro na remoção do arquivo\.'
        $result.Message | Should -Match 'Erro ao reiniciar o spooler\.'

        Should -Invoke Start-SpoolerService -ModuleName SpoolDoctor -Times 1 -Exactly

        $logLines = @(Get-Content -LiteralPath $script:logPath -Encoding UTF8)
        $logLines.Count | Should -Be 1
        $logLines[0] | Should -Match 'Outcome=Failed'
    }

    It 'retorna Failed e chama Start-SpoolerService apenas uma vez quando Start-SpoolerService falha' {
        $validFile = Join-Path -Path $spoolDir -ChildPath '00001.SPL'
        $script:startFailTarget = $validFile

        Mock Get-SpoolFile -ModuleName SpoolDoctor {
            return @([PSCustomObject]@{ FullName = $script:startFailTarget })
        }
        Mock Start-SpoolerService -ModuleName SpoolDoctor { throw 'Serviço não respondeu ao iniciar.' }

        $result = Reset-Spooler -Confirm:$false -LogPath $script:logPath

        $result.Outcome | Should -Be 'Failed'
        $result.Message | Should -Match 'Serviço não respondeu ao iniciar\.'

        Should -Invoke Remove-SpoolFile -ModuleName SpoolDoctor -Times 1 -Exactly
        Should -Invoke Start-SpoolerService -ModuleName SpoolDoctor -Times 1 -Exactly

        $logLines = @(Get-Content -LiteralPath $script:logPath -Encoding UTF8)
        $logLines.Count | Should -Be 1
        $logLines[0] | Should -Match 'Outcome=Failed'
    }

    It 'retorna Failed na verificação final se o serviço não estiver Running' {
        Mock Get-SpoolerServiceStatus -ModuleName SpoolDoctor { return 'Stopped' }

        $result = Reset-Spooler -Confirm:$false -LogPath $script:logPath

        $result.Outcome | Should -Be 'Failed'
        $result.Message | Should -Match 'Stopped'

        $logLines = @(Get-Content -LiteralPath $script:logPath -Encoding UTF8)
        $logLines.Count | Should -Be 1
        $logLines[0] | Should -Match 'Outcome=Failed'
    }

    It 'retorna Failed na verificação final se ainda restar arquivo .SPL ou .SHD na pasta' {
        $script:leftoverFile = Join-Path -Path $spoolDir -ChildPath '00099.SHD'

        Mock Get-SpoolFile -ModuleName SpoolDoctor {
            return @([PSCustomObject]@{ FullName = $script:leftoverFile })
        }

        $result = Reset-Spooler -Confirm:$false -LogPath $script:logPath

        $result.Outcome | Should -Be 'Failed'
        $result.Message | Should -Match 'remanescente'

        $logLines = @(Get-Content -LiteralPath $script:logPath -Encoding UTF8)
        $logLines.Count | Should -Be 1
        $logLines[0] | Should -Match 'Outcome=Failed'
    }

    It 'retorna Failed na verificação final se ocorrer erro ao consultar o status do serviço' {
        Mock Get-SpoolerServiceStatus -ModuleName SpoolDoctor { throw 'Erro ao consultar serviço Spooler.' }

        $result = Reset-Spooler -Confirm:$false -LogPath $script:logPath

        $result.Outcome | Should -Be 'Failed'
        $result.Message | Should -Match 'Erro ao consultar serviço Spooler\.'

        $logLines = @(Get-Content -LiteralPath $script:logPath -Encoding UTF8)
        $logLines.Count | Should -Be 1
        $logLines[0] | Should -Match 'Outcome=Failed'
    }

    It 'executa o fluxo feliz completo removendo arquivos .SPL e .SHD, verificando estado e gravando log' {
        $script:happyFiles = @(
            [PSCustomObject]@{ FullName = (Join-Path -Path $spoolDir -ChildPath '00001.SPL') },
            [PSCustomObject]@{ FullName = (Join-Path -Path $spoolDir -ChildPath '00001.SHD') }
        )
        $script:getSpoolFileCalls = 0

        Mock Get-SpoolFile -ModuleName SpoolDoctor {
            $script:getSpoolFileCalls++
            if ($script:getSpoolFileCalls -eq 1) {
                return $script:happyFiles
            }
            return @()
        }

        $result = Reset-Spooler -Confirm:$false -LogPath $script:logPath -BackupPath $script:backupPath

        $result.ComputerName | Should -Be $env:COMPUTERNAME
        $result.Action | Should -Be 'Reset-Spooler'
        $result.Outcome | Should -Be 'OK'
        $result.Timestamp | Should -BeOfType [datetime]
        $result.Message | Should -Match '2'

        Should -Invoke Stop-SpoolerService -ModuleName SpoolDoctor -Times 1 -Exactly
        Should -Invoke Copy-SpoolFile -ModuleName SpoolDoctor -Times 2 -Exactly
        Should -Invoke Remove-SpoolFile -ModuleName SpoolDoctor -Times 2 -Exactly
        Should -Invoke Start-SpoolerService -ModuleName SpoolDoctor -Times 1 -Exactly
        Should -Invoke Get-SpoolerServiceStatus -ModuleName SpoolDoctor -Times 1 -Exactly

        Test-Path -LiteralPath $script:logPath -PathType Leaf | Should -BeTrue
        $logLines = @(Get-Content -LiteralPath $script:logPath -Encoding UTF8)
        $logLines.Count | Should -Be 1
        $logLines[0] | Should -Match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}'
        $logLines[0] | Should -Match "Computer=$([regex]::Escape($env:COMPUTERNAME))"
        $logLines[0] | Should -Match 'Action=Reset-Spooler'
        $logLines[0] | Should -Match 'Outcome=OK'
    }

    It 'executa o fluxo feliz quando a fila já está vazia sem chamar Remove-SpoolFile nem Copy-SpoolFile' {
        $result = Reset-Spooler -Confirm:$false -LogPath $script:logPath -BackupPath $script:backupPath

        $result.Outcome | Should -Be 'OK'
        $result.Action | Should -Be 'Reset-Spooler'
        $result.Message | Should -Match '0'

        Should -Invoke Stop-SpoolerService -ModuleName SpoolDoctor -Times 1 -Exactly
        Should -Invoke Copy-SpoolFile -ModuleName SpoolDoctor -Times 0 -Exactly
        Should -Invoke Remove-SpoolFile -ModuleName SpoolDoctor -Times 0 -Exactly
        Should -Invoke Start-SpoolerService -ModuleName SpoolDoctor -Times 1 -Exactly
        Should -Invoke Get-SpoolerServiceStatus -ModuleName SpoolDoctor -Times 1 -Exactly
        Test-Path -LiteralPath $script:backupPath | Should -BeFalse

        $logLines = @(Get-Content -LiteralPath $script:logPath -Encoding UTF8)
        $logLines.Count | Should -Be 1
        $logLines[0] | Should -Match 'Outcome=OK'
    }

    It 'copia todos os arquivos de spool para o backup antes de remover qualquer arquivo e registra destino no log' {
        $script:orderedFiles = @(
            [PSCustomObject]@{ FullName = (Join-Path -Path $spoolDir -ChildPath '00001.SPL') },
            [PSCustomObject]@{ FullName = (Join-Path -Path $spoolDir -ChildPath '00001.SHD') }
        )
        $script:orderList = New-Object -TypeName 'System.Collections.Generic.List[string]'
        $script:capturedBackupDestinations = New-Object -TypeName 'System.Collections.Generic.List[string]'
        $script:getOrderCalls = 0

        Mock Get-SpoolFile -ModuleName SpoolDoctor {
            $script:getOrderCalls++
            if ($script:getOrderCalls -eq 1) {
                return $script:orderedFiles
            }
            return @()
        }
        Mock Copy-SpoolFile -ModuleName SpoolDoctor {
            param([string]$Path, [string]$DestinationDirectory)
            $script:orderList.Add("Copy:$([System.IO.Path]::GetFileName($Path))")
            $script:capturedBackupDestinations.Add($DestinationDirectory)
        }
        Mock Remove-SpoolFile -ModuleName SpoolDoctor {
            param([string]$Path)
            $script:orderList.Add("Remove:$([System.IO.Path]::GetFileName($Path))")
        }

        $result = Reset-Spooler -Confirm:$false -LogPath $script:logPath -BackupPath $script:backupPath

        $result.Outcome | Should -Be 'OK'
        $result.Message | Should -Match 'Backup'
        $result.Message | Should -Match '2'
        $result.Message | Should -Match ([regex]::Escape($script:backupPath))

        $script:orderList.Count | Should -Be 4
        $script:orderList[0] | Should -Be 'Copy:00001.SPL'
        $script:orderList[1] | Should -Be 'Copy:00001.SHD'
        $script:orderList[2] | Should -Be 'Remove:00001.SPL'
        $script:orderList[3] | Should -Be 'Remove:00001.SHD'

        $script:capturedBackupDestinations.Count | Should -Be 2
        ($script:capturedBackupDestinations | Select-Object -Unique) | Should -Be @($script:backupPath)

        $logLines = @(Get-Content -LiteralPath $script:logPath -Encoding UTF8)
        $logLines.Count | Should -Be 1
        $logLines[0] | Should -Match 'Outcome=OK'
        $logLines[0] | Should -Match 'Backup'
        $logLines[0] | Should -Match ([regex]::Escape($script:backupPath))
    }

    It 'com -SkipBackup não chama Copy-SpoolFile e registra backup ignorado no resultado e log' {
        $script:skipFiles = @(
            [PSCustomObject]@{ FullName = (Join-Path -Path $spoolDir -ChildPath '00010.SPL') },
            [PSCustomObject]@{ FullName = (Join-Path -Path $spoolDir -ChildPath '00010.SHD') }
        )
        $script:getSkipCalls = 0

        Mock Get-SpoolFile -ModuleName SpoolDoctor {
            $script:getSkipCalls++
            if ($script:getSkipCalls -eq 1) {
                return $script:skipFiles
            }
            return @()
        }

        $result = Reset-Spooler -Confirm:$false -SkipBackup -LogPath $script:logPath

        $result.Outcome | Should -Be 'OK'
        $result.Message | Should -Match '-SkipBackup'

        Should -Invoke Copy-SpoolFile -ModuleName SpoolDoctor -Times 0 -Exactly
        Should -Invoke Remove-SpoolFile -ModuleName SpoolDoctor -Times 2 -Exactly

        $logLines = @(Get-Content -LiteralPath $script:logPath -Encoding UTF8)
        $logLines.Count | Should -Be 1
        $logLines[0] | Should -Match 'Outcome=OK'
        $logLines[0] | Should -Match '-SkipBackup'
    }

    It 'aborta remoção e reinicia o serviço no finally se Copy-SpoolFile falhar' {
        $script:failBackupFiles = @(
            [PSCustomObject]@{ FullName = (Join-Path -Path $spoolDir -ChildPath '00001.SPL') },
            [PSCustomObject]@{ FullName = (Join-Path -Path $spoolDir -ChildPath '00002.SHD') }
        )

        Mock Get-SpoolFile -ModuleName SpoolDoctor {
            return $script:failBackupFiles
        }
        Mock Copy-SpoolFile -ModuleName SpoolDoctor {
            param([string]$Path, [string]$DestinationDirectory)
            if ($Path -like '*00002.SHD') {
                throw 'Disco de backup cheio.'
            }
        }

        $result = Reset-Spooler -Confirm:$false -LogPath $script:logPath -BackupPath $script:backupPath

        $result.Outcome | Should -Be 'Failed'
        $result.Message | Should -Match 'Disco de backup cheio\.'

        Should -Invoke Remove-SpoolFile -ModuleName SpoolDoctor -Times 0 -Exactly
        Should -Invoke Start-SpoolerService -ModuleName SpoolDoctor -Times 1 -Exactly

        $logLines = @(Get-Content -LiteralPath $script:logPath -Encoding UTF8)
        $logLines.Count | Should -Be 1
        $logLines[0] | Should -Match 'Outcome=Failed'
        $logLines[0] | Should -Match 'Disco de backup cheio\.'
    }

    It 'recusa -BackupPath apenas com espaços quando backup está ativo e não toca no sistema' {
        $result = Reset-Spooler -Confirm:$false -LogPath $script:logPath -BackupPath '   '

        $result.Outcome | Should -Be 'Failed'
        $result.Message | Should -Match 'BackupPath'

        Should -Invoke Stop-SpoolerService -ModuleName SpoolDoctor -Times 0 -Exactly
        Should -Invoke Copy-SpoolFile -ModuleName SpoolDoctor -Times 0 -Exactly
        Should -Invoke Remove-SpoolFile -ModuleName SpoolDoctor -Times 0 -Exactly
        Should -Invoke Start-SpoolerService -ModuleName SpoolDoctor -Times 0 -Exactly

        $logLines = @(Get-Content -LiteralPath $script:logPath -Encoding UTF8)
        $logLines.Count | Should -Be 1
        $logLines[0] | Should -Match 'Outcome=Failed'
    }
}
