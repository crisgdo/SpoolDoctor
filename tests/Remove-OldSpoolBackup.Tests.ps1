Describe 'SpoolDoctor - Limpeza de backups antigos (Remove-OldSpoolBackup)' {
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
        $script:backupRoot = Join-Path -Path 'TestDrive:\' -ChildPath ("backups-{0}" -f [guid]::NewGuid().ToString('N'))
    }

    It 'apaga pasta yyyyMMdd-HHmmss vencida, preserva recente e preserva pastas antigas com nome fora do padrão' {
        $null = New-Item -Path $script:backupRoot -ItemType Directory -Force

        $expiredName = (Get-Date).AddDays(-10).ToString('yyyyMMdd-HHmmss')
        $recentName = (Get-Date).AddDays(-2).ToString('yyyyMMdd-HHmmss')
        $otherNames = @('manual-backup', '2020-01-01', '99999999-999999')

        $expiredPath = Join-Path -Path $script:backupRoot -ChildPath $expiredName
        $recentPath = Join-Path -Path $script:backupRoot -ChildPath $recentName

        $null = New-Item -Path $expiredPath -ItemType Directory -Force
        $null = New-Item -Path (Join-Path -Path $expiredPath -ChildPath '00001.SPL') -ItemType File -Force

        $null = New-Item -Path $recentPath -ItemType Directory -Force
        $null = New-Item -Path (Join-Path -Path $recentPath -ChildPath '00002.SPL') -ItemType File -Force

        $oldTime = (Get-Date).AddDays(-30)
        $preservedOtherPaths = foreach ($name in $otherNames) {
            $dirPath = Join-Path -Path $script:backupRoot -ChildPath $name
            $null = New-Item -Path $dirPath -ItemType Directory -Force
            (Get-Item -LiteralPath $dirPath).LastWriteTime = $oldTime
            $dirPath
        }

        $result = InModuleScope 'SpoolDoctor' -Parameters @{ Root = $script:backupRoot } {
            param($Root)
            Remove-OldSpoolBackup -BackupRoot $Root -RetentionDays 7 -Confirm:$false
        }

        $result.RemovedCount | Should -Be 1
        $result.Warnings.Count | Should -Be 0

        Test-Path -LiteralPath $expiredPath | Should -BeFalse
        Test-Path -LiteralPath $recentPath -PathType Container | Should -BeTrue
        foreach ($otherPath in $preservedOtherPaths) {
            Test-Path -LiteralPath $otherPath -PathType Container | Should -BeTrue
        }
    }

    It 'respeita -RetentionDays 0 e não remove nenhuma pasta' {
        $null = New-Item -Path $script:backupRoot -ItemType Directory -Force
        $expiredPath = Join-Path -Path $script:backupRoot -ChildPath ((Get-Date).AddDays(-30).ToString('yyyyMMdd-HHmmss'))
        $null = New-Item -Path $expiredPath -ItemType Directory -Force

        $result = InModuleScope 'SpoolDoctor' -Parameters @{ Root = $script:backupRoot } {
            param($Root)
            Remove-OldSpoolBackup -BackupRoot $Root -RetentionDays 0 -Confirm:$false
        }

        $result.RemovedCount | Should -Be 0
        $result.Warnings.Count | Should -Be 0
        Test-Path -LiteralPath $expiredPath -PathType Container | Should -BeTrue
    }

    It 'em modo -WhatIf não remove pasta vencida' {
        $null = New-Item -Path $script:backupRoot -ItemType Directory -Force
        $expiredPath = Join-Path -Path $script:backupRoot -ChildPath ((Get-Date).AddDays(-15).ToString('yyyyMMdd-HHmmss'))
        $null = New-Item -Path $expiredPath -ItemType Directory -Force

        $result = InModuleScope 'SpoolDoctor' -Parameters @{ Root = $script:backupRoot } {
            param($Root)
            Remove-OldSpoolBackup -BackupRoot $Root -RetentionDays 7 -WhatIf
        }

        $result.RemovedCount | Should -Be 0
        Test-Path -LiteralPath $expiredPath -PathType Container | Should -BeTrue
    }

    It 'retorna RemovedCount 0 sem erro quando BackupRoot não existe' {
        $result = InModuleScope 'SpoolDoctor' -Parameters @{ Root = $script:backupRoot } {
            param($Root)
            Remove-OldSpoolBackup -BackupRoot $Root -RetentionDays 7 -Confirm:$false
        }

        $result.RemovedCount | Should -Be 0
        $result.Warnings.Count | Should -Be 0
    }

    It 'recusa BackupRoot inválido (<Label>) lançando exceção' -ForEach @(
        @{ Label = 'apenas espaços'; BadRoot = '   ' }
        @{ Label = 'raiz de unidade'; BadRoot = 'C:\' }
    ) {
        param($BadRoot)

        {
            InModuleScope 'SpoolDoctor' -Parameters @{ TargetRoot = $BadRoot } {
                param($TargetRoot)
                Remove-OldSpoolBackup -BackupRoot $TargetRoot -RetentionDays 7 -Confirm:$false
            }
        } | Should -Throw
    }

    It 'gera aviso em Warnings e continua removendo demais pastas quando Remove-Item falha em uma pasta' {
        $null = New-Item -Path $script:backupRoot -ItemType Directory -Force
        $lockedName = (Get-Date).AddDays(-12).ToString('yyyyMMdd-HHmmss')
        $removableName = (Get-Date).AddDays(-10).ToString('yyyyMMdd-HHmmss')

        $null = New-Item -Path (Join-Path -Path $script:backupRoot -ChildPath $lockedName) -ItemType Directory -Force
        $null = New-Item -Path (Join-Path -Path $script:backupRoot -ChildPath $removableName) -ItemType Directory -Force

        $script:lockedBackupName = $lockedName
        Mock Remove-Item -ModuleName SpoolDoctor {
            param([string]$LiteralPath)
            if ($LiteralPath -like "*$script:lockedBackupName*") {
                throw 'Pasta em uso.'
            }
        }

        $result = InModuleScope 'SpoolDoctor' -Parameters @{ Root = $script:backupRoot } {
            param($Root)
            Remove-OldSpoolBackup -BackupRoot $Root -RetentionDays 7 -Confirm:$false
        }

        $result.RemovedCount | Should -Be 1
        $result.Warnings.Count | Should -Be 1
        $result.Warnings[0] | Should -Match 'Pasta em uso\.'
        Should -Invoke Remove-Item -ModuleName SpoolDoctor -Times 2 -Exactly
    }
}
