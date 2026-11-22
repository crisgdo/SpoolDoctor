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
        Mock Remove-OldSpoolBackup -ModuleName SpoolDoctor {
            return [PSCustomObject]@{
                RemovedCount = 0
                Warnings     = @()
            }
        }
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
        Should -Invoke Remove-OldSpoolBackup -ModuleName SpoolDoctor -Times 0 -Exactly

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
        Should -Invoke Remove-OldSpoolBackup -ModuleName SpoolDoctor -Times 0 -Exactly
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
    function script:Remove-OldSpoolBackup { [CmdletBinding(SupportsShouldProcess)] param([string]`$BackupRoot, [int]`$RetentionDays = 7) throw 'Não deveria chamar Remove-OldSpoolBackup.' }
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
        Should -Invoke Remove-OldSpoolBackup -ModuleName SpoolDoctor -Times 0 -Exactly
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
        Should -Invoke Remove-OldSpoolBackup -ModuleName SpoolDoctor -Times 0 -Exactly

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
        Should -Invoke Remove-OldSpoolBackup -ModuleName SpoolDoctor -Times 0 -Exactly

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
        Should -Invoke Remove-OldSpoolBackup -ModuleName SpoolDoctor -Times 0 -Exactly

        $logLines = @(Get-Content -LiteralPath $script:logPath -Encoding UTF8)
        $logLines.Count | Should -Be 1
        $logLines[0] | Should -Match 'Outcome=Failed'
    }

    It 'com backup padrão ativo chama Remove-OldSpoolBackup com RetentionDays 7 e registra contagem removida' {
        $script:capturedCleanupRoot = $null
        $script:capturedCleanupDays = $null

        Mock Remove-OldSpoolBackup -ModuleName SpoolDoctor {
            param([string]$BackupRoot, [int]$RetentionDays)
            $script:capturedCleanupRoot = $BackupRoot
            $script:capturedCleanupDays = $RetentionDays
            return [PSCustomObject]@{
                RemovedCount = 2
                Warnings     = @()
            }
        }

        $result = Reset-Spooler -Confirm:$false -LogPath $script:logPath

        $result.Outcome | Should -Be 'OK'
        $result.Message | Should -Match 'Backups antigos removidos:\s*2'

        Should -Invoke Remove-OldSpoolBackup -ModuleName SpoolDoctor -Times 1 -Exactly
        $script:capturedCleanupDays | Should -Be 7
        $script:capturedCleanupRoot | Should -Match 'SpoolDoctor\\backups$'

        $logLines = @(Get-Content -LiteralPath $script:logPath -Encoding UTF8)
        $logLines.Count | Should -Be 1
        $logLines[0] | Should -Match 'Outcome=OK'
        $logLines[0] | Should -Match 'Backups antigos removidos:\s*2'
    }

    It 'com -BackupRetentionDays 0 não chama Remove-OldSpoolBackup mesmo sem -BackupPath' {
        $result = Reset-Spooler -Confirm:$false -BackupRetentionDays 0 -LogPath $script:logPath

        $result.Outcome | Should -Be 'OK'
        Should -Invoke Remove-OldSpoolBackup -ModuleName SpoolDoctor -Times 0 -Exactly
    }

    It 'registra aviso na mensagem e no log sem alterar Outcome para Failed quando limpeza de backup antigo retorna aviso ou falha' {
        Mock Remove-OldSpoolBackup -ModuleName SpoolDoctor {
            return [PSCustomObject]@{
                RemovedCount = 1
                Warnings     = @("Não foi possível remover '20260101-010101': em uso.")
            }
        }

        $resultWarning = Reset-Spooler -Confirm:$false -LogPath $script:logPath

        $resultWarning.Outcome | Should -Be 'OK'
        $resultWarning.Message | Should -Match 'Backups antigos removidos:\s*1'
        $resultWarning.Message | Should -Match 'Aviso na limpeza de backups antigos'
        $resultWarning.Message | Should -Match 'em uso'

        $logLines = @(Get-Content -LiteralPath $script:logPath -Encoding UTF8)
        $logLines.Count | Should -Be 1
        $logLines[0] | Should -Match 'Outcome=OK'
        $logLines[0] | Should -Match 'Aviso na limpeza de backups antigos'

        $errorCleanupLogPath = Join-Path -Path 'TestDrive:\' -ChildPath ("reset-cleanup-err-{0}.log" -f [guid]::NewGuid().ToString('N'))
        Mock Remove-OldSpoolBackup -ModuleName SpoolDoctor {
            throw 'Falha inesperada na limpeza.'
        }

        $resultError = Reset-Spooler -Confirm:$false -LogPath $errorCleanupLogPath

        $resultError.Outcome | Should -Be 'OK'
        $resultError.Message | Should -Match 'Aviso na limpeza de backups antigos'
        $resultError.Message | Should -Match 'Falha inesperada na limpeza\.'

        $errLogLines = @(Get-Content -LiteralPath $errorCleanupLogPath -Encoding UTF8)
        $errLogLines.Count | Should -Be 1
        $errLogLines[0] | Should -Match 'Outcome=OK'
        $errLogLines[0] | Should -Match 'Falha inesperada na limpeza\.'
    }

    Context 'Execução remota (Operação 6)' {
        BeforeEach {
            $script:remoteAllowListPath = Join-Path -Path 'TestDrive:\' -ChildPath ("reset-allow-{0}.txt" -f [guid]::NewGuid().ToString('N'))
            @(
                'PC-REMOTO-01'
                'SRV-PRINT-01|PrintServer'
            ) | Set-Content -LiteralPath $script:remoteAllowListPath -Encoding UTF8

            $script:remoteSessionObj = [PSCustomObject]@{ ComputerName = 'PC-REMOTO-01'; Id = 3 }
            Mock New-SpoolerRemoteSession -ModuleName SpoolDoctor { return $script:remoteSessionObj }
            Mock Invoke-SpoolerRemoteScript -ModuleName SpoolDoctor {
                return [PSCustomObject]@{
                    PSTypeName   = 'Deserialized.SpoolDoctor.ActionResult'
                    ComputerName = 'PC-REMOTO-01'
                    Action       = 'Reset-Spooler'
                    Outcome      = 'OK'
                    Message      = "Spooler reiniciado com sucesso na máquina 'PC-REMOTO-01'. Arquivos removidos: 2."
                    Timestamp    = Get-Date
                }
            }
            Mock Remove-SpoolerRemoteSession -ModuleName SpoolDoctor {}
        }

        It 'preserva execução local quando -ComputerName aponta para a máquina local' {
            $result = Reset-Spooler -ComputerName $env:COMPUTERNAME -AllowedComputersPath $script:remoteAllowListPath -Confirm:$false -LogPath $script:logPath

            $result.Outcome | Should -Be 'OK'
            $result.ComputerName | Should -Be $env:COMPUTERNAME
            Should -Invoke New-SpoolerRemoteSession -ModuleName SpoolDoctor -Times 0 -Exactly
            Should -Invoke Stop-SpoolerService -ModuleName SpoolDoctor -Times 1 -Exactly
        }

        It 'executa fluxo remoto feliz (com backup padrão e -SkipBackup) sem exigir admin local e fecha sessão' {
            Mock Test-IsAdministrator -ModuleName SpoolDoctor { return $false }
            $script:capturedRemoteArgs = $null
            $script:capturedRemoteScriptText = $null

            Mock Invoke-SpoolerRemoteScript -ModuleName SpoolDoctor {
                param($Session, $ScriptBlock, $ArgumentList)
                $script:capturedRemoteArgs = $ArgumentList
                $script:capturedRemoteScriptText = $ScriptBlock.ToString()
                return [PSCustomObject]@{
                    PSTypeName   = 'Deserialized.SpoolDoctor.ActionResult'
                    ComputerName = 'PC-REMOTO-01'
                    Action       = 'Reset-Spooler'
                    Outcome      = 'OK'
                    Message      = "Spooler reiniciado com sucesso na máquina 'PC-REMOTO-01'."
                    Timestamp    = Get-Date
                }
            }

            $resDefault = Reset-Spooler -ComputerName 'pc-remoto-01' -AllowedComputersPath $script:remoteAllowListPath -Confirm:$false -LogPath $script:logPath
            $resDefault.PSObject.TypeNames | Should -Contain 'SpoolDoctor.ActionResult'
            $resDefault.Outcome | Should -Be 'OK'
            $resDefault.ComputerName | Should -Be 'PC-REMOTO-01'
            $script:capturedRemoteArgs[3].Keys | Should -Contain 'Test-SpoolerPrintServer'
            $script:capturedRemoteScriptText | Should -Match 'Confirm\s*=\s*\$false'

            $skipLog = Join-Path -Path 'TestDrive:\' -ChildPath ("reset-remote-skip-{0}.log" -f [guid]::NewGuid().ToString('N'))
            $resSkip = Reset-Spooler -ComputerName 'PC-REMOTO-01' -AllowedComputersPath $script:remoteAllowListPath -SkipBackup -Confirm:$false -LogPath $skipLog
            $resSkip.Outcome | Should -Be 'OK'
            ([bool]$script:capturedRemoteArgs[2]['SkipBackup']) | Should -BeTrue

            Should -Invoke New-SpoolerRemoteSession -ModuleName SpoolDoctor -Times 2 -Exactly
            Should -Invoke Remove-SpoolerRemoteSession -ModuleName SpoolDoctor -Times 2 -Exactly

            $logLines = @(Get-Content -LiteralPath $script:logPath -Encoding UTF8)
            $logLines.Count | Should -Be 1
            $logLines[0] | Should -Match 'Computer=PC-REMOTO-01'
            $logLines[0] | Should -Match 'Outcome=OK'
        }

        It 'em modo -WhatIf remoto retorna Simulated com hostname no log e não abre sessão WinRM' {
            $result = Reset-Spooler -ComputerName 'PC-REMOTO-01' -AllowedComputersPath $script:remoteAllowListPath -WhatIf -LogPath $script:logPath

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
            $childLogPath = Join-Path -Path $physicalTestDrive -ChildPath ("reset-remote-skipped-{0}.log" -f [guid]::NewGuid().ToString('N'))
            $childAllowPath = Join-Path -Path $physicalTestDrive -ChildPath ("reset-remote-allow-{0}.txt" -f [guid]::NewGuid().ToString('N'))
            Set-Content -LiteralPath $childAllowPath -Value 'PC-REMOTO-01' -Encoding UTF8

            $childScript = @"
`$ErrorActionPreference = 'Stop'
Import-Module -Name '$manifestPath' -Force
& (Get-Module -Name 'SpoolDoctor') {
    function script:New-SpoolerRemoteSession { [CmdletBinding(SupportsShouldProcess)] param([string]`$ComputerName, [PSCredential]`$Credential) throw 'Não deveria chamar New-SpoolerRemoteSession.' }
    function script:Invoke-SpoolerRemoteScript { param(`$Session, `$ScriptBlock, `$ArgumentList) throw 'Não deveria chamar Invoke-SpoolerRemoteScript.' }
    function script:Remove-SpoolerRemoteSession { [CmdletBinding(SupportsShouldProcess)] param(`$Session) throw 'Não deveria chamar Remove-SpoolerRemoteSession.' }
}
Reset-Spooler -ComputerName 'PC-REMOTO-01' -AllowedComputersPath '$childAllowPath' -LogPath '$childLogPath' | ConvertTo-Json -Compress
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
            $invalidRes = Reset-Spooler -ComputerName '   ' -AllowedComputersPath $script:remoteAllowListPath -Confirm:$false -LogPath $script:logPath
            $invalidRes.Outcome | Should -Be 'Failed'

            $unlistedLog = Join-Path -Path 'TestDrive:\' -ChildPath ("reset-unlisted-{0}.log" -f [guid]::NewGuid().ToString('N'))
            $unlistedRes = Reset-Spooler -ComputerName 'PC-INTRUSO' -AllowedComputersPath $script:remoteAllowListPath -Confirm:$false -LogPath $unlistedLog
            $unlistedRes.Outcome | Should -Be 'Failed'
            $unlistedRes.ComputerName | Should -Be 'PC-INTRUSO'
            $unlistedRes.Message | Should -Match 'allow-list'

            Should -Invoke New-SpoolerRemoteSession -ModuleName SpoolDoctor -Times 0 -Exactly

            $logLines = @(Get-Content -LiteralPath $unlistedLog -Encoding UTF8)
            $logLines.Count | Should -Be 1
            $logLines[0] | Should -Match 'Computer=PC-INTRUSO'
            $logLines[0] | Should -Match 'Outcome=Failed'
        }

        It 'bloqueia servidor de impressão marcado na allow-list sem -AllowPrintServer antes de abrir sessão' {
            $result = Reset-Spooler -ComputerName 'SRV-PRINT-01' -AllowedComputersPath $script:remoteAllowListPath -Confirm:$false -LogPath $script:logPath

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

        It 'bloqueia servidor de impressão detectado dinamicamente no destino sem -AllowPrintServer com motivo explícito' {
            Mock Invoke-SpoolerRemoteScript -ModuleName SpoolDoctor {
                return [PSCustomObject]@{
                    PSTypeName   = 'Deserialized.SpoolDoctor.ActionResult'
                    ComputerName = 'PC-REMOTO-01'
                    Action       = 'Reset-Spooler'
                    Outcome      = 'Failed'
                    Message      = "Reset bloqueado na máquina 'PC-REMOTO-01' (servidor de impressão detectado: sistema operacional Windows Server (ProductType=3)). Informe -AllowPrintServer para confirmar a execução."
                    Timestamp    = Get-Date
                }
            }

            $result = Reset-Spooler -ComputerName 'PC-REMOTO-01' -AllowedComputersPath $script:remoteAllowListPath -Confirm:$false -LogPath $script:logPath

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
            $simResult = Reset-Spooler -ComputerName 'SRV-PRINT-01' -AllowedComputersPath $script:remoteAllowListPath -AllowPrintServer -WhatIf -LogPath $script:logPath
            $simResult.Outcome | Should -Be 'Simulated'
            $simResult.ComputerName | Should -Be 'SRV-PRINT-01'
            Should -Invoke New-SpoolerRemoteSession -ModuleName SpoolDoctor -Times 0 -Exactly

            $execLog = Join-Path -Path 'TestDrive:\' -ChildPath ("reset-printserver-ok-{0}.log" -f [guid]::NewGuid().ToString('N'))
            $script:capturedPrintArg = $null
            Mock Invoke-SpoolerRemoteScript -ModuleName SpoolDoctor {
                param($Session, $ScriptBlock, $ArgumentList)
                $script:capturedPrintArg = $ArgumentList[2]
                return [PSCustomObject]@{
                    PSTypeName   = 'Deserialized.SpoolDoctor.ActionResult'
                    ComputerName = 'SRV-PRINT-01'
                    Action       = 'Reset-Spooler'
                    Outcome      = 'OK'
                    Message      = "Spooler reiniciado com sucesso na máquina 'SRV-PRINT-01'."
                    Timestamp    = Get-Date
                }
            }

            $okResult = Reset-Spooler -ComputerName 'SRV-PRINT-01' -AllowedComputersPath $script:remoteAllowListPath -AllowPrintServer -Confirm:$false -LogPath $execLog
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

            $result = Reset-Spooler -ComputerName 'PC-REMOTO-01' -AllowedComputersPath $script:remoteAllowListPath -Confirm:$false -LogPath $script:logPath

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

            $result = Reset-Spooler -ComputerName 'PC-REMOTO-01' -AllowedComputersPath $script:remoteAllowListPath -Confirm:$false -LogPath $script:logPath

            $result.Outcome | Should -Be 'Failed'
            $result.ComputerName | Should -Be 'PC-REMOTO-01'
            Should -Invoke Remove-SpoolerRemoteSession -ModuleName SpoolDoctor -Times 0 -Exactly

            $logLines = @(Get-Content -LiteralPath $script:logPath -Encoding UTF8)
            $logLines.Count | Should -Be 1
            $logLines[0] | Should -Match 'Computer=PC-REMOTO-01'
            $logLines[0] | Should -Match 'Outcome=Failed'
        }
    }

    Context 'Execução remota em lote (Operação 7)' {
        BeforeEach {
            $script:batchAllowListPath = Join-Path -Path 'TestDrive:\' -ChildPath ("reset-batch-allow-{0}.txt" -f [guid]::NewGuid().ToString('N'))
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
                    Action       = 'Reset-Spooler'
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
            $results = @(Reset-Spooler -ComputerName @('PC-REMOTO-01', 'pc-remoto-02', 'PC-REMOTO-03') -AllowedComputersPath $script:batchAllowListPath -Confirm:$false -LogPath $script:logPath)

            $results.Count | Should -Be 3
            $results[0].ComputerName | Should -Be 'PC-REMOTO-01'
            $results[1].ComputerName | Should -Be 'PC-REMOTO-02'
            $results[2].ComputerName | Should -Be 'PC-REMOTO-03'
            foreach ($res in $results) {
                $res.PSObject.TypeNames | Should -Contain 'SpoolDoctor.ActionResult'
                $res.Action | Should -Be 'Reset-Spooler'
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

        It 'isola falha Unreachable no meio do lote, fecha a sessão no finally e continua para a próxima máquina' {
            Mock Invoke-SpoolerRemoteScript -ModuleName SpoolDoctor {
                param($Session, $ScriptBlock, $ArgumentList)
                $targetHost = [string]$ArgumentList[0]
                if ($targetHost -eq 'PC-REMOTO-02') {
                    throw (New-Object -TypeName System.Management.Automation.Remoting.PSRemotingTransportException -ArgumentList 'WinRM unreachable on PC-REMOTO-02.')
                }
                return [PSCustomObject]@{
                    PSTypeName   = 'Deserialized.SpoolDoctor.ActionResult'
                    ComputerName = $targetHost
                    Action       = 'Reset-Spooler'
                    Outcome      = 'OK'
                    Message      = "Spooler reiniciado com sucesso na máquina '$targetHost'."
                    Timestamp    = Get-Date
                }
            }

            $results = @(Reset-Spooler -ComputerName @('PC-REMOTO-01', 'PC-REMOTO-02', 'PC-REMOTO-03') -AllowedComputersPath $script:batchAllowListPath -Confirm:$false -LogPath $script:logPath)

            $results.Count | Should -Be 3
            $results[0].ComputerName | Should -Be 'PC-REMOTO-01'
            $results[0].Outcome | Should -Be 'OK'
            $results[1].ComputerName | Should -Be 'PC-REMOTO-02'
            $results[1].Outcome | Should -Be 'Unreachable'
            $results[2].ComputerName | Should -Be 'PC-REMOTO-03'
            $results[2].Outcome | Should -Be 'OK'

            $script:closedSessionTargets.ToArray() | Should -Be @('PC-REMOTO-01', 'PC-REMOTO-02', 'PC-REMOTO-03')

            $logLines = @(Get-Content -LiteralPath $script:logPath -Encoding UTF8)
            $logLines.Count | Should -Be 3
            $logLines[0] | Should -Match 'Computer=PC-REMOTO-01.*Outcome=OK'
            $logLines[1] | Should -Match 'Computer=PC-REMOTO-02.*Outcome=Unreachable'
            $logLines[2] | Should -Match 'Computer=PC-REMOTO-03.*Outcome=OK'
        }

        It 'isola máquina fora da allow-list, servidor de impressão bloqueado, entrada vazia e erro de autenticação no lote' {
            Mock New-SpoolerRemoteSession -ModuleName SpoolDoctor {
                param([string]$ComputerName, [PSCredential]$Credential)
                if ($ComputerName -eq 'PC-REMOTO-02') {
                    throw (New-Object -TypeName System.UnauthorizedAccessException -ArgumentList 'Access is denied.')
                }
                $script:openedSessionTargets.Add($ComputerName)
                return [PSCustomObject]@{ ComputerName = $ComputerName; Id = $script:openedSessionTargets.Count }
            }

            $targets = @('PC-REMOTO-01', 'PC-INTRUSO', 'SRV-PRINT-01', '', 'PC-REMOTO-02', 'PC-REMOTO-03')
            $results = @(Reset-Spooler -ComputerName $targets -AllowedComputersPath $script:batchAllowListPath -Confirm:$false -LogPath $script:logPath)

            $results.Count | Should -Be 6
            $results[0].ComputerName | Should -Be 'PC-REMOTO-01'
            $results[0].Outcome | Should -Be 'OK'
            $results[1].ComputerName | Should -Be 'PC-INTRUSO'
            $results[1].Outcome | Should -Be 'Failed'
            $results[1].Message | Should -Match 'allow-list'
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
            $logLines[1] | Should -Match 'Computer=PC-INTRUSO.*Outcome=Failed'
            $logLines[2] | Should -Match 'Computer=SRV-PRINT-01.*Outcome=Failed'
            $logLines[3] | Should -Match 'Computer=\(inválido\).*Outcome=Failed'
            $logLines[4] | Should -Match 'Computer=PC-REMOTO-02.*Outcome=Failed'
            $logLines[5] | Should -Match 'Computer=PC-REMOTO-03.*Outcome=OK'
        }

        It 'em modo -WhatIf no lote não abre sessão WinRM e retorna Simulated por máquina autorizada' {
            $results = @(Reset-Spooler -ComputerName @('PC-REMOTO-01', 'SRV-PRINT-01', 'PC-REMOTO-02') -AllowedComputersPath $script:batchAllowListPath -WhatIf -LogPath $script:logPath)

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

            $logLines = @(Get-Content -LiteralPath $script:logPath -Encoding UTF8)
            $logLines.Count | Should -Be 3
            $logLines[0] | Should -Match 'Computer=PC-REMOTO-01.*Outcome=Simulated'
            $logLines[1] | Should -Match 'Computer=SRV-PRINT-01.*Outcome=Failed'
            $logLines[2] | Should -Match 'Computer=PC-REMOTO-02.*Outcome=Simulated'
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
            $childLogPath = Join-Path -Path $physicalTestDrive -ChildPath ("reset-batch-confirm-{0}.log" -f [guid]::NewGuid().ToString('N'))
            $childAllowPath = Join-Path -Path $physicalTestDrive -ChildPath ("reset-batch-allow-{0}.txt" -f [guid]::NewGuid().ToString('N'))
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
            Action       = 'Reset-Spooler'
            Outcome      = 'OK'
            Message      = "Spooler reiniciado com sucesso na máquina '`$(`$ArgumentList[0])'."
            Timestamp    = Get-Date
        }
    }
    function script:Remove-SpoolerRemoteSession { [CmdletBinding(SupportsShouldProcess)] param(`$Session) }
}
Reset-Spooler -ComputerName @('PC-REMOTO-01', 'PC-REMOTO-02') -AllowedComputersPath '$childAllowPath' -LogPath '$childLogPath'
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
                Reset-Spooler -ComputerName @('localhost', $env:COMPUTERNAME, 'pc-remoto-01', 'PC-REMOTO-01') -AllowedComputersPath $script:batchAllowListPath -Confirm:$false -LogPath $script:logPath
            })

            $mixedResults.Count | Should -Be 2
            $mixedResults[0].ComputerName | Should -Be $env:COMPUTERNAME
            $mixedResults[0].Outcome | Should -Be 'OK'
            $mixedResults[1].ComputerName | Should -Be 'PC-REMOTO-01'
            $mixedResults[1].Outcome | Should -Be 'OK'

            Should -Invoke Stop-SpoolerService -ModuleName SpoolDoctor -Times 1 -Exactly
            Should -Invoke New-SpoolerRemoteSession -ModuleName SpoolDoctor -Times 1 -Exactly
            Should -Invoke Remove-SpoolerRemoteSession -ModuleName SpoolDoctor -Times 1 -Exactly

            $emptyLog = Join-Path -Path 'TestDrive:\' -ChildPath ("reset-empty-batch-{0}.log" -f [guid]::NewGuid().ToString('N'))
            $emptyResults = @(& {
                Set-StrictMode -Version Latest
                Reset-Spooler -ComputerName @() -AllowedComputersPath $script:batchAllowListPath -Confirm:$false -LogPath $emptyLog
            })

            $emptyResults.Count | Should -Be 1
            $emptyResults[0].ComputerName | Should -Be '(inválido)'
            $emptyResults[0].Outcome | Should -Be 'Failed'
            Should -Invoke Stop-SpoolerService -ModuleName SpoolDoctor -Times 1 -Exactly
            Should -Invoke New-SpoolerRemoteSession -ModuleName SpoolDoctor -Times 1 -Exactly

            $emptyLogs = @(Get-Content -LiteralPath $emptyLog -Encoding UTF8)
            $emptyLogs.Count | Should -Be 1
            $emptyLogs[0] | Should -Match 'Computer=\(inválido\).*Outcome=Failed'
        }
    }
}
