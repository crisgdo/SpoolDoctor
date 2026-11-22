Describe 'SpoolDoctor - Validação segura de caminhos do spooler' {
    BeforeAll {
        $repoRoot = Split-Path -Path $PSScriptRoot -Parent
        $manifestPath = Join-Path -Path $repoRoot -ChildPath 'src\SpoolDoctor.psd1'

        if (Get-Module -Name 'SpoolDoctor') {
            Remove-Module -Name 'SpoolDoctor' -Force -ErrorAction Stop
        }

        Import-Module -Name $manifestPath -Force -ErrorAction Stop

        $spoolDir = [System.IO.Path]::GetFullPath((Join-Path -Path $env:SystemRoot -ChildPath 'System32\spool\PRINTERS'))
        $spoolParent = Split-Path -Path $spoolDir -Parent
    }

    AfterAll {
        if (Get-Module -Name 'SpoolDoctor') {
            Remove-Module -Name 'SpoolDoctor' -Force -ErrorAction Stop
        }
    }

    Context 'Test-SafeSpoolFilePath' {
        It 'aceita arquivos .SPL e .SHD (maiúsculas e minúsculas) diretamente em PRINTERS' {
            $validPaths = @(
                (Join-Path -Path $spoolDir -ChildPath '00001.SPL'),
                (Join-Path -Path $spoolDir -ChildPath '00001.SHD'),
                (Join-Path -Path $spoolDir -ChildPath '00002.spl'),
                (Join-Path -Path $spoolDir -ChildPath '00002.shd')
            )

            foreach ($targetPath in $validPaths) {
                $isValid = InModuleScope 'SpoolDoctor' -Parameters @{ FilePath = $targetPath } {
                    param($FilePath)
                    Test-SafeSpoolFilePath -Path $FilePath
                }
                $isValid | Should -BeTrue -Because "o caminho válido '$targetPath' deve ser aceito"
            }
        }

        It 'recusa caminhos fora da pasta PRINTERS' {
            $outsidePaths = @(
                'C:\Temp\00001.SPL',
                (Join-Path -Path $env:SystemRoot -ChildPath 'System32\cmd.exe'),
                (Join-Path -Path $spoolParent -ChildPath '00001.SPL')
            )

            foreach ($targetPath in $outsidePaths) {
                $isValid = InModuleScope 'SpoolDoctor' -Parameters @{ FilePath = $targetPath } {
                    param($FilePath)
                    Test-SafeSpoolFilePath -Path $FilePath
                }
                $isValid | Should -BeFalse -Because "o caminho externo '$targetPath' não pode ser aceito"
            }
        }

        It 'recusa pasta com prefixo parecido (PRINTERS2) e subpasta dentro de PRINTERS' {
            $trickyPaths = @(
                (Join-Path -Path $spoolParent -ChildPath 'PRINTERS2\00001.SPL'),
                (Join-Path -Path $spoolDir -ChildPath 'sub\00001.SPL')
            )

            foreach ($targetPath in $trickyPaths) {
                $isValid = InModuleScope 'SpoolDoctor' -Parameters @{ FilePath = $targetPath } {
                    param($FilePath)
                    Test-SafeSpoolFilePath -Path $FilePath
                }
                $isValid | Should -BeFalse -Because "o caminho '$targetPath' não está diretamente na pasta PRINTERS"
            }
        }

        It 'recusa tentativas de path traversal (..\)' {
            $traversalPaths = @(
                (Join-Path -Path $spoolDir -ChildPath '..\drivers\00001.SPL'),
                (Join-Path -Path $spoolDir -ChildPath '..\..\win.ini'),
                (Join-Path -Path $spoolDir -ChildPath '..\PRINTERS\00001.SPL')
            )

            foreach ($targetPath in $traversalPaths) {
                $isValid = InModuleScope 'SpoolDoctor' -Parameters @{ FilePath = $targetPath } {
                    param($FilePath)
                    Test-SafeSpoolFilePath -Path $FilePath
                }
                $isValid | Should -BeFalse -Because "tentativa de path traversal '$targetPath' deve ser bloqueada"
            }
        }

        It 'recusa extensões diferentes de .SPL e .SHD mesmo dentro de PRINTERS' {
            $invalidExtPaths = @(
                (Join-Path -Path $spoolDir -ChildPath '00001.TXT'),
                (Join-Path -Path $spoolDir -ChildPath '00001.TMP'),
                (Join-Path -Path $spoolDir -ChildPath '00001.EXE'),
                (Join-Path -Path $spoolDir -ChildPath '00001.SPL.bak'),
                (Join-Path -Path $spoolDir -ChildPath '00001')
            )

            foreach ($targetPath in $invalidExtPaths) {
                $isValid = InModuleScope 'SpoolDoctor' -Parameters @{ FilePath = $targetPath } {
                    param($FilePath)
                    Test-SafeSpoolFilePath -Path $FilePath
                }
                $isValid | Should -BeFalse -Because "a extensão de '$targetPath' não é permitida"
            }
        }

        It 'recusa entradas inválidas (vazia, espaços, relativa, UNC, curinga, pasta raiz e nome sem base)' {
            $invalidInputs = @(
                '',
                '   ',
                '00001.SPL',
                '\\server\share\00001.SPL',
                (Join-Path -Path $spoolDir -ChildPath '*.SPL'),
                "$spoolDir\",
                (Join-Path -Path $spoolDir -ChildPath '.SPL'),
                (Join-Path -Path $spoolDir -ChildPath '00001.SPL:ads')
            )

            foreach ($targetPath in $invalidInputs) {
                $isValid = InModuleScope 'SpoolDoctor' -Parameters @{ FilePath = $targetPath } {
                    param($FilePath)
                    Test-SafeSpoolFilePath -Path $FilePath
                }
                $isValid | Should -BeFalse -Because "a entrada inválida '$targetPath' deve ser recusada"
            }
        }
    }

    Context 'Remove-SpoolFile' {
        BeforeEach {
            Mock Remove-Item -ModuleName SpoolDoctor {}
        }

        It 'lança exceção e não chama Remove-Item para caminho fora de PRINTERS' {
            $unsafePath = 'C:\Temp\00001.SPL'

            {
                InModuleScope 'SpoolDoctor' -Parameters @{ FilePath = $unsafePath } {
                    param($FilePath)
                    Remove-SpoolFile -Path $FilePath -Confirm:$false
                }
            } | Should -Throw

            Should -Invoke Remove-Item -ModuleName SpoolDoctor -Times 0 -Exactly
        }

        It 'lança exceção e não chama Remove-Item para path traversal (..\)' {
            $traversalPath = Join-Path -Path $spoolDir -ChildPath '..\drivers\00001.SPL'

            {
                InModuleScope 'SpoolDoctor' -Parameters @{ FilePath = $traversalPath } {
                    param($FilePath)
                    Remove-SpoolFile -Path $FilePath -Confirm:$false
                }
            } | Should -Throw

            Should -Invoke Remove-Item -ModuleName SpoolDoctor -Times 0 -Exactly
        }

        It 'lança exceção e não chama Remove-Item para extensão inválida' {
            $badExtensionPath = Join-Path -Path $spoolDir -ChildPath '00001.TXT'

            {
                InModuleScope 'SpoolDoctor' -Parameters @{ FilePath = $badExtensionPath } {
                    param($FilePath)
                    Remove-SpoolFile -Path $FilePath -Confirm:$false
                }
            } | Should -Throw

            Should -Invoke Remove-Item -ModuleName SpoolDoctor -Times 0 -Exactly
        }

        It 'chama Remove-Item exatamente uma vez para arquivo .SPL válido em PRINTERS' {
            $validPath = Join-Path -Path $spoolDir -ChildPath '00001.SPL'

            InModuleScope 'SpoolDoctor' -Parameters @{ FilePath = $validPath } {
                param($FilePath)
                Remove-SpoolFile -Path $FilePath -Confirm:$false
            }

            Should -Invoke Remove-Item -ModuleName SpoolDoctor -Times 1 -Exactly -ParameterFilter {
                $LiteralPath -eq $validPath
            }
        }
    }
}
