Describe 'SpoolDoctor - Camada remota (src/Remote)' {
    BeforeAll {
        $repoRoot = Split-Path -Path $PSScriptRoot -Parent
        $manifestPath = Join-Path -Path $repoRoot -ChildPath 'src\SpoolDoctor.psd1'
        $script:remoteFolderPath = Join-Path -Path $repoRoot -ChildPath 'src\Remote'

        if (Get-Module -Name 'SpoolDoctor') {
            Remove-Module -Name 'SpoolDoctor' -Force -ErrorAction Stop
        }

        Import-Module -Name $manifestPath -Force -ErrorAction Stop

        function New-DummyPSSession {
            return [System.Runtime.Serialization.FormatterServices]::GetUninitializedObject(
                [System.Management.Automation.Runspaces.PSSession]
            )
        }

        function New-DummyErrorRecord {
            param(
                [Parameter(Mandatory)]
                [System.Exception]$Exception,

                [Parameter()]
                [string]$ErrorId = 'RemoteError',

                [Parameter()]
                [System.Management.Automation.ErrorCategory]$Category = [System.Management.Automation.ErrorCategory]::NotSpecified
            )

            return New-Object -TypeName System.Management.Automation.ErrorRecord -ArgumentList @(
                $Exception,
                $ErrorId,
                $Category,
                $null
            )
        }
    }

    AfterAll {
        if (Get-Module -Name 'SpoolDoctor') {
            Remove-Module -Name 'SpoolDoctor' -Force -ErrorAction Stop
        }
    }

    Context 'Test-ValidComputerName' {
        It 'aceita hostname ou FQDN válido (<Name>)' -ForEach @(
            @{ Name = 'PC-01' }
            @{ Name = 'ESTACAO-ATENDIMENTO-02.empresa.local' }
            @{ Name = 'localhost' }
            @{ Name = 'a1' }
            @{ Name = 'SRV01.corp.contoso.com' }
        ) {
            param($Name)

            $isValid = InModuleScope 'SpoolDoctor' -Parameters @{ Target = $Name } {
                param($Target)
                Test-ValidComputerName -ComputerName $Target
            }

            $isValid | Should -BeTrue
        }

        It 'recusa entrada inválida ou IP literal (<Kind>)' -ForEach @(
            @{ Kind = 'nulo'; Value = $null }
            @{ Kind = 'vazio'; Value = '' }
            @{ Kind = 'espaços'; Value = '   ' }
            @{ Kind = 'espaço no início'; Value = ' PC-01' }
            @{ Kind = 'espaço no fim'; Value = 'PC-01 ' }
            @{ Kind = 'espaço interno'; Value = 'PC 01' }
            @{ Kind = 'hífen inicial'; Value = '-PC01' }
            @{ Kind = 'hífen final'; Value = 'PC01-' }
            @{ Kind = 'ponto inicial'; Value = '.PC01' }
            @{ Kind = 'ponto final'; Value = 'PC01.' }
            @{ Kind = 'dois pontos seguidos'; Value = 'PC..LOCAL' }
            @{ Kind = 'injeção de comando'; Value = 'PC;whoami' }
            @{ Kind = 'UNC'; Value = '\\PC01' }
            @{ Kind = 'path traversal'; Value = '../PC01' }
            @{ Kind = 'barra'; Value = 'PC01/share' }
            @{ Kind = 'curinga'; Value = 'PC01*' }
            @{ Kind = 'IPv4 literal'; Value = '192.168.1.10' }
            @{ Kind = 'loopback IPv4'; Value = '127.0.0.1' }
            @{ Kind = 'label acima de 63 chars'; Value = ('a' * 64) }
            @{ Kind = 'FQDN acima de 255 chars'; Value = ((('a' * 60) + '.') * 4 + 'domain.local') }
        ) {
            param($Kind, $Value)

            $isValid = InModuleScope 'SpoolDoctor' -Parameters @{ Target = $Value } {
                param($Target)
                Test-ValidComputerName -ComputerName $Target
            }

            $isValid | Should -BeFalse -Because "o caso '$Kind' deve ser recusado"
        }
    }

    Context 'Get-AllowedComputer' {
        It 'lê config/allowed-computers.txt padrão sem erro retornando vazio quando só há comentários' {
            $entries = @(InModuleScope 'SpoolDoctor' {
                Get-AllowedComputer
            })

            $entries.Count | Should -Be 0
        }

        It 'ignora comentários e linhas vazias, reconhece |PrintServer e deduplica preservando PrintServer' {
            $allowListPath = Join-Path -Path 'TestDrive:\' -ChildPath ("allowed-{0}.txt" -f [guid]::NewGuid().ToString('N'))
            $content = @(
                '# Comentário inicial'
                ''
                '   PC-FIN-01   '
                '  # Comentário indentado'
                'SRV-PRINT-01|PrintServer'
                'pc-fin-01|printserver'
                'ESTACAO-02.empresa.local'
            ) -join "`r`n"
            Set-Content -LiteralPath $allowListPath -Value $content -Encoding UTF8

            $entries = @(InModuleScope 'SpoolDoctor' -Parameters @{ FilePath = $allowListPath } {
                param($FilePath)
                Get-AllowedComputer -Path $FilePath
            })

            $entries.Count | Should -Be 3
            $entries[0].PSObject.TypeNames | Should -Contain 'SpoolDoctor.AllowedComputer'
            $entries[0].ComputerName | Should -Be 'PC-FIN-01'
            $entries[0].IsPrintServer | Should -BeTrue
            $entries[1].ComputerName | Should -Be 'SRV-PRINT-01'
            $entries[1].IsPrintServer | Should -BeTrue
            $entries[2].ComputerName | Should -Be 'ESTACAO-02.empresa.local'
            $entries[2].IsPrintServer | Should -BeFalse
        }

        It 'lança erro explícito quando o arquivo não existe' {
            $missingPath = Join-Path -Path 'TestDrive:\' -ChildPath 'nao-existe-allowed.txt'

            {
                InModuleScope 'SpoolDoctor' -Parameters @{ FilePath = $missingPath } {
                    param($FilePath)
                    Get-AllowedComputer -Path $FilePath
                }
            } | Should -Throw '*não encontrado*'
        }

        It 'lança erro explícito para entrada malformada ou hostname inválido (<Line>)' -ForEach @(
            @{ Line = 'PC-01|OutraTag' }
            @{ Line = 'PC-01|PrintServer|Extra' }
            @{ Line = 'PC;bad' }
            @{ Line = '192.168.1.10' }
        ) {
            param($Line)

            $badListPath = Join-Path -Path 'TestDrive:\' -ChildPath ("allowed-bad-{0}.txt" -f [guid]::NewGuid().ToString('N'))
            Set-Content -LiteralPath $badListPath -Value $Line -Encoding UTF8

            {
                InModuleScope 'SpoolDoctor' -Parameters @{ FilePath = $badListPath } {
                    param($FilePath)
                    Get-AllowedComputer -Path $FilePath
                }
            } | Should -Throw
        }
    }

    Context 'Resolve-SpoolerTarget' {
        BeforeEach {
            $script:allowListPath = Join-Path -Path 'TestDrive:\' -ChildPath ("resolve-{0}.txt" -f [guid]::NewGuid().ToString('N'))
            @(
                'PC-REMOTO-01'
                'SRV-PRINT-01|PrintServer'
            ) | Set-Content -LiteralPath $script:allowListPath -Encoding UTF8
        }

        It 'resolve como local quando -ComputerName é omitido e não lê a allow-list' {
            Mock Get-AllowedComputer -ModuleName SpoolDoctor { throw 'Não deveria ler allow-list.' }

            $target = InModuleScope 'SpoolDoctor' -Parameters @{ ListPath = $script:allowListPath } {
                param($ListPath)
                Resolve-SpoolerTarget -AllowedComputersPath $ListPath
            }

            $target.IsValid | Should -BeTrue
            $target.IsLocal | Should -BeTrue
            $target.ComputerName | Should -Be $env:COMPUTERNAME
            $target.IsPrintServerListed | Should -BeFalse
            Should -Invoke Get-AllowedComputer -ModuleName SpoolDoctor -Times 0 -Exactly
        }

        It 'recusa -HasCredential quando o alvo é local (omitido ou localhost)' {
            Mock Get-AllowedComputer -ModuleName SpoolDoctor { throw 'Não deveria ler allow-list.' }

            $targetOmitted = InModuleScope 'SpoolDoctor' -Parameters @{ ListPath = $script:allowListPath } {
                param($ListPath)
                Resolve-SpoolerTarget -AllowedComputersPath $ListPath -HasCredential
            }
            $targetLocalhost = InModuleScope 'SpoolDoctor' -Parameters @{ ListPath = $script:allowListPath } {
                param($ListPath)
                Resolve-SpoolerTarget -ComputerName 'localhost' -AllowedComputersPath $ListPath -HasCredential
            }

            $targetOmitted.IsValid | Should -BeFalse
            $targetOmitted.FailureOutcome | Should -Be 'Failed'
            $targetOmitted.ErrorMessage | Should -Match 'Credential'

            $targetLocalhost.IsValid | Should -BeFalse
            $targetLocalhost.FailureOutcome | Should -Be 'Failed'
            $targetLocalhost.ErrorMessage | Should -Match 'Credential'
            Should -Invoke Get-AllowedComputer -ModuleName SpoolDoctor -Times 0 -Exactly
        }

        It 'resolve como local quando -ComputerName aponta para localhost ou $env:COMPUTERNAME sem consultar allow-list' {
            Mock Get-AllowedComputer -ModuleName SpoolDoctor { throw 'Não deveria ler allow-list.' }

            foreach ($localAlias in @('localhost', 'LOCALHOST', $env:COMPUTERNAME)) {
                $target = InModuleScope 'SpoolDoctor' -Parameters @{ Name = $localAlias; ListPath = $script:allowListPath } {
                    param($Name, $ListPath)
                    Resolve-SpoolerTarget -ComputerName $Name -AllowedComputersPath $ListPath
                }

                $target.IsValid | Should -BeTrue
                $target.IsLocal | Should -BeTrue
                $target.ComputerName | Should -Be $env:COMPUTERNAME
            }

            Should -Invoke Get-AllowedComputer -ModuleName SpoolDoctor -Times 0 -Exactly
        }

        It 'recusa entrada inválida em -ComputerName antes de consultar allow-list (<BadName>)' -ForEach @(
            @{ BadName = '' }
            @{ BadName = '   ' }
            @{ BadName = 'PC;calc' }
            @{ BadName = '10.0.0.5' }
        ) {
            param($BadName)

            Mock Get-AllowedComputer -ModuleName SpoolDoctor { throw 'Não deveria ler allow-list.' }

            $target = InModuleScope 'SpoolDoctor' -Parameters @{ Name = $BadName; ListPath = $script:allowListPath } {
                param($Name, $ListPath)
                Resolve-SpoolerTarget -ComputerName $Name -AllowedComputersPath $ListPath
            }

            $target.IsValid | Should -BeFalse
            $target.IsLocal | Should -BeFalse
            $target.FailureOutcome | Should -Be 'Failed'
            $target.ErrorMessage | Should -Not -BeNullOrEmpty
            Should -Invoke Get-AllowedComputer -ModuleName SpoolDoctor -Times 0 -Exactly
        }

        It 'recusa máquina fora da allow-list com FailureOutcome Failed e nome do host na mensagem' {
            $target = InModuleScope 'SpoolDoctor' -Parameters @{ ListPath = $script:allowListPath } {
                param($ListPath)
                Resolve-SpoolerTarget -ComputerName 'PC-NAO-AUTORIZADO' -AllowedComputersPath $ListPath
            }

            $target.IsValid | Should -BeFalse
            $target.IsLocal | Should -BeFalse
            $target.ComputerName | Should -Be 'PC-NAO-AUTORIZADO'
            $target.FailureOutcome | Should -Be 'Failed'
            $target.ErrorMessage | Should -Match 'PC-NAO-AUTORIZADO'
            $target.ErrorMessage | Should -Match 'allow-list'
        }

        It 'autoriza máquina presente na allow-list (case-insensitive) preservando flag PrintServer' {
            $normalTarget = InModuleScope 'SpoolDoctor' -Parameters @{ ListPath = $script:allowListPath } {
                param($ListPath)
                Resolve-SpoolerTarget -ComputerName 'pc-remoto-01' -AllowedComputersPath $ListPath
            }
            $printTarget = InModuleScope 'SpoolDoctor' -Parameters @{ ListPath = $script:allowListPath } {
                param($ListPath)
                Resolve-SpoolerTarget -ComputerName 'srv-print-01' -AllowedComputersPath $ListPath
            }

            $normalTarget.IsValid | Should -BeTrue
            $normalTarget.IsLocal | Should -BeFalse
            $normalTarget.ComputerName | Should -Be 'PC-REMOTO-01'
            $normalTarget.IsPrintServerListed | Should -BeFalse

            $printTarget.IsValid | Should -BeTrue
            $printTarget.IsLocal | Should -BeFalse
            $printTarget.ComputerName | Should -Be 'SRV-PRINT-01'
            $printTarget.IsPrintServerListed | Should -BeTrue
        }

        It 'retorna inválido Failed quando leitura da allow-list falha' {
            $missingList = Join-Path -Path 'TestDrive:\' -ChildPath 'missing-allow.txt'

            $target = InModuleScope 'SpoolDoctor' -Parameters @{ ListPath = $missingList } {
                param($ListPath)
                Resolve-SpoolerTarget -ComputerName 'PC-REMOTO-01' -AllowedComputersPath $ListPath
            }

            $target.IsValid | Should -BeFalse
            $target.FailureOutcome | Should -Be 'Failed'
            $target.ErrorMessage | Should -Match 'não encontrado'
        }
    }

    Context 'Get-RemoteFailureOutcome' {
        It 'classifica falhas de transporte WinRM, conectividade e timeout como Unreachable' {
            $transportEx = New-Object -TypeName System.Management.Automation.Remoting.PSRemotingTransportException -ArgumentList 'Connecting to remote server PC-REMOTO-01 failed: WinRM cannot process the request.'
            $transportErr = New-DummyErrorRecord -Exception $transportEx -ErrorId 'WinRMOperationTimeout' -Category ([System.Management.Automation.ErrorCategory]::OpenError)

            $timeoutEx = New-Object -TypeName System.TimeoutException -ArgumentList 'A operação atingiu o tempo limite.'
            $timeoutErr = New-DummyErrorRecord -Exception $timeoutEx -ErrorId 'OperationTimeout' -Category ([System.Management.Automation.ErrorCategory]::OperationTimeout)

            $outcome1 = InModuleScope 'SpoolDoctor' -Parameters @{ Record = $transportErr } {
                param($Record)
                Get-RemoteFailureOutcome -ErrorRecord $Record
            }
            $outcome2 = InModuleScope 'SpoolDoctor' -Parameters @{ Record = $timeoutErr } {
                param($Record)
                Get-RemoteFailureOutcome -ErrorRecord $Record
            }

            $outcome1 | Should -Be 'Unreachable'
            $outcome2 | Should -Be 'Unreachable'
        }

        It 'classifica acesso negado, autenticação e exceção genérica como Failed' {
            $authEx = New-Object -TypeName System.UnauthorizedAccessException -ArgumentList 'Acesso negado ao autenticar na máquina remota.'
            $authErr = New-DummyErrorRecord -Exception $authEx -ErrorId 'AccessDenied' -Category ([System.Management.Automation.ErrorCategory]::PermissionDenied)

            $wrappedAuthEx = New-Object -TypeName System.Management.Automation.Remoting.PSRemotingTransportException -ArgumentList 'Connecting to remote server failed with the following error message : Access is denied.'
            $wrappedAuthErr = New-DummyErrorRecord -Exception $wrappedAuthEx -ErrorId 'AccessDenied,PSSessionOpenFailed' -Category ([System.Management.Automation.ErrorCategory]::AuthenticationError)

            $genericEx = New-Object -TypeName System.InvalidOperationException -ArgumentList 'Erro inesperado ao consultar serviço.'
            $genericErr = New-DummyErrorRecord -Exception $genericEx

            foreach ($record in @($authErr, $wrappedAuthErr, $genericErr)) {
                $outcome = InModuleScope 'SpoolDoctor' -Parameters @{ Record = $record } {
                    param($Record)
                    Get-RemoteFailureOutcome -ErrorRecord $Record
                }
                $outcome | Should -Be 'Failed'
            }
        }
    }

    Context 'Test-SpoolerPrintServer' {
        BeforeEach {
            Mock Get-CimInstance -ModuleName SpoolDoctor {
                return [PSCustomObject]@{ ProductType = [uint32]1 }
            }
            Mock Get-SpoolerServiceStatus -ModuleName SpoolDoctor { return 'Running' }
            Mock Get-SpoolerPrinterRaw -ModuleName SpoolDoctor {
                return @([PSCustomObject]@{ Name = 'HP LaserJet'; Shared = $false })
            }
        }

        It 'retorna IsPrintServer falso em workstation sem impressoras compartilhadas' {
            $check = InModuleScope 'SpoolDoctor' { Test-SpoolerPrintServer }

            $check.IsPrintServer | Should -BeFalse
            $check.Reasons.Count | Should -Be 0
        }

        It 'detecta Windows Server (ProductType 2 e 3) como servidor de impressão' -ForEach @(
            @{ ProductType = [uint32]2 }
            @{ ProductType = [uint32]3 }
        ) {
            param($ProductType)

            $script:capturedType = $ProductType
            Mock Get-CimInstance -ModuleName SpoolDoctor {
                return [PSCustomObject]@{ ProductType = $script:capturedType }
            }

            $check = InModuleScope 'SpoolDoctor' { Test-SpoolerPrintServer }

            $check.IsPrintServer | Should -BeTrue
            ($check.Reasons -join ' ') | Should -Match 'Windows Server'
        }

        It 'detecta impressora compartilhada como servidor de impressão mesmo em workstation' {
            Mock Get-SpoolerPrinterRaw -ModuleName SpoolDoctor {
                return @(
                    [PSCustomObject]@{ Name = 'PDF Printer'; Shared = $false },
                    [PSCustomObject]@{ Name = 'HP Compartilhada'; Shared = $true }
                )
            }

            $check = InModuleScope 'SpoolDoctor' { Test-SpoolerPrintServer }

            $check.IsPrintServer | Should -BeTrue
            ($check.Reasons -join ' ') | Should -Match 'HP Compartilhada'
        }

        It 'não consulta impressoras quando Spooler está Stopped' {
            Mock Get-SpoolerServiceStatus -ModuleName SpoolDoctor { return 'Stopped' }

            $check = InModuleScope 'SpoolDoctor' { Test-SpoolerPrintServer }

            $check.IsPrintServer | Should -BeFalse
            Should -Invoke Get-SpoolerPrinterRaw -ModuleName SpoolDoctor -Times 0 -Exactly
        }

        It 'propaga erro explícito se Get-CimInstance falhar' {
            Mock Get-CimInstance -ModuleName SpoolDoctor { throw 'Erro CIM.' }

            { InModuleScope 'SpoolDoctor' { Test-SpoolerPrintServer } } | Should -Throw '*Erro CIM.*'
        }
    }

    Context 'Wrappers WinRM (New/Invoke/Remove)' {
        BeforeEach {
            $script:fakeSession = New-DummyPSSession
            Mock New-PSSession -ModuleName SpoolDoctor { return $script:fakeSession }
            Mock Invoke-Command -ModuleName SpoolDoctor { return 'ok' }
            Mock Remove-PSSession -ModuleName SpoolDoctor {}
        }

        It 'declara SupportsShouldProcess em New-SpoolerRemoteSession e Remove-SpoolerRemoteSession' {
            foreach ($fnName in @('New-SpoolerRemoteSession', 'Remove-SpoolerRemoteSession')) {
                $attr = InModuleScope 'SpoolDoctor' -Parameters @{ Name = $fnName } {
                    param($Name)
                    (Get-Command -Name $Name -ErrorAction Stop).ScriptBlock.Attributes |
                        Where-Object { $_ -is [System.Management.Automation.CmdletBindingAttribute] } |
                        Select-Object -First 1
                }
                $attr | Should -Not -BeNullOrEmpty
                $attr.SupportsShouldProcess | Should -BeTrue
            }
        }

        It 'respeita -WhatIf em New-SpoolerRemoteSession e Remove-SpoolerRemoteSession' {
            InModuleScope 'SpoolDoctor' -Parameters @{ Sess = $script:fakeSession } {
                param($Sess)
                $null = New-SpoolerRemoteSession -ComputerName 'PC-REMOTO-01' -WhatIf
                Remove-SpoolerRemoteSession -Session $Sess -WhatIf
            }

            Should -Invoke New-PSSession -ModuleName SpoolDoctor -Times 0 -Exactly
            Should -Invoke Remove-PSSession -ModuleName SpoolDoctor -Times 0 -Exactly
        }

        It 'repassa parâmetros para New-PSSession, Invoke-Command e Remove-PSSession' {
            $cred = New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList @(
                'DOMINIO\operador',
                (New-Object -TypeName System.Security.SecureString)
            )
            $sb = { param($x) $x }

            $output = InModuleScope 'SpoolDoctor' -Parameters @{ Cred = $cred; Block = $sb } {
                param($Cred, $Block)
                $s = New-SpoolerRemoteSession -ComputerName 'PC-REMOTO-01' -Credential $Cred -Confirm:$false
                $res = Invoke-SpoolerRemoteScript -Session $s -ScriptBlock $Block -ArgumentList @('abc')
                Remove-SpoolerRemoteSession -Session $s -Confirm:$false
                return $res
            }

            $output | Should -Be 'ok'
            Should -Invoke New-PSSession -ModuleName SpoolDoctor -Times 1 -Exactly -ParameterFilter {
                $ComputerName -eq 'PC-REMOTO-01' -and $null -ne $Credential
            }
            Should -Invoke Invoke-Command -ModuleName SpoolDoctor -Times 1 -Exactly
            Should -Invoke Remove-PSSession -ModuleName SpoolDoctor -Times 1 -Exactly
        }
    }

    Context 'Invoke-SpoolerRemoteOperation' {
        BeforeEach {
            $script:opSession = [PSCustomObject]@{ ComputerName = 'PC-REMOTO-01'; Id = 99 }
            Mock New-SpoolerRemoteSession -ModuleName SpoolDoctor { return $script:opSession }
            Mock Invoke-SpoolerRemoteScript -ModuleName SpoolDoctor { return @() }
            Mock Remove-SpoolerRemoteSession -ModuleName SpoolDoctor {}
        }

        It 'executa fluxo feliz abrindo, injetando funções em memória e fechando a sessão com Credential' {
            $script:capturedArgs = $null
            $script:capturedScriptBlockText = $null
            $cred = New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList @(
                'DOMINIO\operador',
                (New-Object -TypeName System.Security.SecureString)
            )

            Mock Invoke-SpoolerRemoteScript -ModuleName SpoolDoctor {
                param($Session, $ScriptBlock, $ArgumentList)
                $script:capturedArgs = $ArgumentList
                $script:capturedScriptBlockText = $ScriptBlock.ToString()
                return @([PSCustomObject]@{ Id = 1; PrinterName = 'HP'; ComputerName = 'PC-REMOTO-01' })
            }

            $result = InModuleScope 'SpoolDoctor' -Parameters @{ Cred = $cred } {
                param($Cred)
                Invoke-SpoolerRemoteOperation -ComputerName 'PC-REMOTO-01' -Operation 'Get-SpoolerJob' -Parameters @{ PrinterName = 'HP' } -Credential $Cred
            }

            $result.Success | Should -BeTrue
            $result.Outcome | Should -Be 'OK'
            @($result.Data).Count | Should -Be 1

            Should -Invoke New-SpoolerRemoteSession -ModuleName SpoolDoctor -Times 1 -Exactly -ParameterFilter {
                $ComputerName -eq 'PC-REMOTO-01' -and $null -ne $Credential
            }
            Should -Invoke Invoke-SpoolerRemoteScript -ModuleName SpoolDoctor -Times 1 -Exactly
            Should -Invoke Remove-SpoolerRemoteSession -ModuleName SpoolDoctor -Times 1 -Exactly

            $script:capturedArgs[0] | Should -Be 'PC-REMOTO-01'
            $script:capturedArgs[1] | Should -Be 'Get-SpoolerJob'
            $script:capturedArgs[3].Keys | Should -Contain 'Get-SpoolerJob'
            $script:capturedArgs[3].Keys | Should -Contain 'Get-SpoolerJobRaw'
            $script:capturedScriptBlockText | Should -Not -Match 'Invoke-Expression'
            $script:capturedScriptBlockText | Should -Match 'Write-SpoolDoctorLog'
        }

        It 'encerra sessão no finally e retorna Unreachable quando Invoke-SpoolerRemoteScript falha por transporte WinRM' {
            Mock Invoke-SpoolerRemoteScript -ModuleName SpoolDoctor {
                throw (New-Object -TypeName System.Management.Automation.Remoting.PSRemotingTransportException -ArgumentList 'WinRM cannot process the request.')
            }

            $result = InModuleScope 'SpoolDoctor' {
                Invoke-SpoolerRemoteOperation -ComputerName 'PC-OFFLINE' -Operation 'Test-Spooler' -Parameters @{}
            }

            $result.Success | Should -BeFalse
            $result.Outcome | Should -Be 'Unreachable'
            $result.Message | Should -Match 'PC-OFFLINE'
            Should -Invoke Remove-SpoolerRemoteSession -ModuleName SpoolDoctor -Times 1 -Exactly
        }

        It 'não chama Remove-SpoolerRemoteSession se New-SpoolerRemoteSession falhar (Unreachable e Failed)' {
            Mock New-SpoolerRemoteSession -ModuleName SpoolDoctor {
                throw (New-Object -TypeName System.Management.Automation.Remoting.PSRemotingTransportException -ArgumentList 'WinRM disabled on destination.')
            }

            $unreachable = InModuleScope 'SpoolDoctor' {
                Invoke-SpoolerRemoteOperation -ComputerName 'PC-SEM-WINRM' -Operation 'Test-Spooler' -Parameters @{}
            }
            $unreachable.Success | Should -BeFalse
            $unreachable.Outcome | Should -Be 'Unreachable'
            Should -Invoke Remove-SpoolerRemoteSession -ModuleName SpoolDoctor -Times 0 -Exactly

            Mock New-SpoolerRemoteSession -ModuleName SpoolDoctor {
                throw (New-Object -TypeName System.UnauthorizedAccessException -ArgumentList 'Access is denied.')
            }

            $failed = InModuleScope 'SpoolDoctor' {
                Invoke-SpoolerRemoteOperation -ComputerName 'PC-NEGADO' -Operation 'Reset-Spooler' -Parameters @{}
            }
            $failed.Success | Should -BeFalse
            $failed.Outcome | Should -Be 'Failed'
            $failed.Message | Should -Match 'PC-NEGADO'
            Should -Invoke Remove-SpoolerRemoteSession -ModuleName SpoolDoctor -Times 0 -Exactly
        }

        It 'preserva erro principal e registra aviso quando Remove-SpoolerRemoteSession também falha no finally' {
            Mock Invoke-SpoolerRemoteScript -ModuleName SpoolDoctor {
                throw 'Erro principal na execução remota.'
            }
            Mock Remove-SpoolerRemoteSession -ModuleName SpoolDoctor {
                throw 'Erro ao fechar sessão.'
            }

            $result = InModuleScope 'SpoolDoctor' {
                Invoke-SpoolerRemoteOperation -ComputerName 'PC-REMOTO-01' -Operation 'Test-Spooler' -Parameters @{}
            }

            $result.Success | Should -BeFalse
            $result.Outcome | Should -Be 'Failed'
            $result.Message | Should -Match 'Erro principal na execução remota\.'
            $result.Message | Should -Match 'Erro ao fechar sessão\.'
            Should -Invoke Remove-SpoolerRemoteSession -ModuleName SpoolDoctor -Times 1 -Exactly
        }
    }

    Context 'Auditoria AST de src/Remote' {
        It 'mantém arquivos válidos no parser, sem Invoke-Expression ou Write-Host e com WinRM isolado nos wrappers' {
            $remoteFiles = @(Get-ChildItem -Path $script:remoteFolderPath -Filter '*.ps1' -File -ErrorAction Stop)
            $remoteFiles.Count | Should -Be 9

            foreach ($file in $remoteFiles) {
                $tokens = $null
                $parseErrors = $null
                $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$parseErrors)
                $ast | Should -Not -BeNullOrEmpty
                $parseErrors.Count | Should -Be 0 -Because "o arquivo '$($file.Name)' não pode ter erro de sintaxe"

                $commandNames = @(
                    $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true) |
                        ForEach-Object { $_.GetCommandName() } |
                        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                        Select-Object -Unique
                )

                $commandNames | Should -Not -Contain 'Invoke-Expression'
                $commandNames | Should -Not -Contain 'iex'
                $commandNames | Should -Not -Contain 'Write-Host'

                if ($file.BaseName -ne 'New-SpoolerRemoteSession') {
                    $commandNames | Should -Not -Contain 'New-PSSession'
                }
                if ($file.BaseName -ne 'Invoke-SpoolerRemoteScript') {
                    $commandNames | Should -Not -Contain 'Invoke-Command'
                }
                if ($file.BaseName -ne 'Remove-SpoolerRemoteSession') {
                    $commandNames | Should -Not -Contain 'Remove-PSSession'
                }
            }
        }
    }
}
