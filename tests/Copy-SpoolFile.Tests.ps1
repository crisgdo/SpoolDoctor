Describe 'SpoolDoctor - Backup seguro de arquivos do spooler (Copy-SpoolFile)' {
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
        $script:backupDir = Join-Path -Path 'TestDrive:\' -ChildPath ("copy-backup-{0}\sub" -f [guid]::NewGuid().ToString('N'))
        Mock Copy-Item -ModuleName SpoolDoctor {}
    }

    It 'lança exceção, não cria destino e não chama Copy-Item para caminho fora de PRINTERS' {
        $unsafePath = 'C:\Temp\00001.SPL'

        {
            InModuleScope 'SpoolDoctor' -Parameters @{ FilePath = $unsafePath; DestDir = $script:backupDir } {
                param($FilePath, $DestDir)
                Copy-SpoolFile -Path $FilePath -DestinationDirectory $DestDir -Confirm:$false
            }
        } | Should -Throw

        Should -Invoke Copy-Item -ModuleName SpoolDoctor -Times 0 -Exactly
        Test-Path -LiteralPath $script:backupDir | Should -BeFalse
    }

    It 'lança exceção, não cria destino e não chama Copy-Item para path traversal (..\)' {
        $traversalPath = Join-Path -Path $spoolDir -ChildPath '..\drivers\00001.SPL'

        {
            InModuleScope 'SpoolDoctor' -Parameters @{ FilePath = $traversalPath; DestDir = $script:backupDir } {
                param($FilePath, $DestDir)
                Copy-SpoolFile -Path $FilePath -DestinationDirectory $DestDir -Confirm:$false
            }
        } | Should -Throw

        Should -Invoke Copy-Item -ModuleName SpoolDoctor -Times 0 -Exactly
        Test-Path -LiteralPath $script:backupDir | Should -BeFalse
    }

    It 'lança exceção, não cria destino e não chama Copy-Item para extensão inválida' {
        $badExtensionPath = Join-Path -Path $spoolDir -ChildPath '00001.TXT'

        {
            InModuleScope 'SpoolDoctor' -Parameters @{ FilePath = $badExtensionPath; DestDir = $script:backupDir } {
                param($FilePath, $DestDir)
                Copy-SpoolFile -Path $FilePath -DestinationDirectory $DestDir -Confirm:$false
            }
        } | Should -Throw

        Should -Invoke Copy-Item -ModuleName SpoolDoctor -Times 0 -Exactly
        Test-Path -LiteralPath $script:backupDir | Should -BeFalse
    }

    It 'lança exceção e não chama Copy-Item quando -DestinationDirectory contém apenas espaços' {
        $validPath = Join-Path -Path $spoolDir -ChildPath '00001.SPL'

        {
            InModuleScope 'SpoolDoctor' -Parameters @{ FilePath = $validPath } {
                param($FilePath)
                Copy-SpoolFile -Path $FilePath -DestinationDirectory '   ' -Confirm:$false
            }
        } | Should -Throw

        Should -Invoke Copy-Item -ModuleName SpoolDoctor -Times 0 -Exactly
    }

    It 'em modo -WhatIf não cria diretório de destino nem chama Copy-Item' {
        $validPath = Join-Path -Path $spoolDir -ChildPath '00001.SPL'

        InModuleScope 'SpoolDoctor' -Parameters @{ FilePath = $validPath; DestDir = $script:backupDir } {
            param($FilePath, $DestDir)
            Copy-SpoolFile -Path $FilePath -DestinationDirectory $DestDir -WhatIf
        }

        Should -Invoke Copy-Item -ModuleName SpoolDoctor -Times 0 -Exactly
        Test-Path -LiteralPath $script:backupDir | Should -BeFalse
    }

    It 'cria diretório de destino em TestDrive e chama Copy-Item para arquivo válido (<FileName>)' -ForEach @(
        @{ FileName = '00001.SPL' }
        @{ FileName = '00002.SHD' }
    ) {
        param($FileName)

        $validPath = Join-Path -Path $spoolDir -ChildPath $FileName
        $destDir = $script:backupDir

        InModuleScope 'SpoolDoctor' -Parameters @{ FilePath = $validPath; TargetDir = $destDir } {
            param($FilePath, $TargetDir)
            Copy-SpoolFile -Path $FilePath -DestinationDirectory $TargetDir -Confirm:$false
        }

        Test-Path -LiteralPath $destDir -PathType Container | Should -BeTrue
        Should -Invoke Copy-Item -ModuleName SpoolDoctor -Times 1 -Exactly -ParameterFilter {
            $LiteralPath -eq $validPath -and $Destination -eq $destDir
        }
    }
}
