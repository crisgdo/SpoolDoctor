function Reset-Spooler {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([PSCustomObject])]
    param(
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$LogPath,

        [Parameter()]
        [switch]$SkipBackup,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$BackupPath,

        [Parameter()]
        [ValidateRange(0, 365)]
        [int]$BackupRetentionDays = 7,

        [Parameter()]
        [AllowNull()]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]]$ComputerName,

        [Parameter()]
        [PSCredential]$Credential,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$AllowedComputersPath,

        [Parameter()]
        [switch]$AllowPrintServer
    )

    $actionName = 'Reset-Spooler'
    $hasCredential = ($PSBoundParameters.ContainsKey('Credential') -and $null -ne $Credential)
    $hasBackupPath = $PSBoundParameters.ContainsKey('BackupPath')
    $hasLogPath = $PSBoundParameters.ContainsKey('LogPath')

    $targetParams = @{
        HasCredential = $hasCredential
    }
    if ($PSBoundParameters.ContainsKey('ComputerName')) {
        $targetParams['ComputerName'] = $ComputerName
    }
    if ($PSBoundParameters.ContainsKey('AllowedComputersPath')) {
        $targetParams['AllowedComputersPath'] = $AllowedComputersPath
    }

    $resolvedTargets = @(Resolve-SpoolerTargetList @targetParams)

    foreach ($target in $resolvedTargets) {
        $targetComputerName = [string]$target.ComputerName
        $timestamp = Get-Date
        $outcome = 'Failed'
        $message = ''

        if (-not $target.IsValid) {
            $outcome = [string]$target.FailureOutcome
            $message = [string]$target.ErrorMessage
        }
        elseif (-not $target.IsLocal) {
            if (-not $SkipBackup -and $hasBackupPath -and [string]::IsNullOrWhiteSpace($BackupPath)) {
                $outcome = 'Failed'
                $message = "Parâmetro -BackupPath inválido na máquina '$targetComputerName': o caminho de backup não pode conter apenas espaços em branco."
            }
            elseif ($target.IsPrintServerListed -and -not $AllowPrintServer) {
                $outcome = 'Failed'
                $message = "Reset bloqueado na máquina '$targetComputerName' (marcada como servidor de impressão na allow-list com '|PrintServer'). Informe -AllowPrintServer para confirmar a execução."
            }
            else {
                $backupDescription = if ($SkipBackup) { 'sem backup (-SkipBackup)' } else { 'com backup prévio' }
                $printServerNotice = if ($AllowPrintServer) { ' [SERVIDOR DE IMPRESSÃO]' } else { '' }
                $actionDescription = "Parar o serviço Spooler, apagar arquivos .SPL e .SHD de PRINTERS ($backupDescription) e reiniciar o serviço na máquina remota '$targetComputerName'$printServerNotice"

                if (-not $PSCmdlet.ShouldProcess($targetComputerName, $actionDescription)) {
                    if ($WhatIfPreference) {
                        $outcome = 'Simulated'
                        $message = "Simulação (-WhatIf): nenhuma alteração foi realizada na máquina remota '$targetComputerName'."
                    }
                    else {
                        $outcome = 'Skipped'
                        $message = "Operação cancelada pelo usuário na confirmação para a máquina '$targetComputerName'."
                    }
                }
                else {
                    $opParams = @{
                        AllowPrintServer    = [bool]$AllowPrintServer
                        BackupRetentionDays = $BackupRetentionDays
                    }
                    if ($SkipBackup) {
                        $opParams['SkipBackup'] = $true
                    }
                    if ($hasBackupPath) {
                        $opParams['BackupPath'] = $BackupPath
                    }

                    $remoteParams = @{
                        ComputerName = $targetComputerName
                        Operation    = $actionName
                        Parameters   = $opParams
                    }
                    if ($hasCredential) {
                        $remoteParams['Credential'] = $Credential
                    }

                    $remoteResult = Invoke-SpoolerRemoteOperation @remoteParams
                    if (-not $remoteResult.Success) {
                        $outcome = [string]$remoteResult.Outcome
                        $message = [string]$remoteResult.Message
                    }
                    elseif ($null -eq $remoteResult.Data) {
                        $outcome = 'Failed'
                        $message = "Resposta inválida ou vazia ao resetar o spooler na máquina '$targetComputerName'."
                    }
                    else {
                        $remoteData = $remoteResult.Data
                        $outcomeProp = $remoteData.PSObject.Properties['Outcome']
                        $messageProp = $remoteData.PSObject.Properties['Message']

                        $outcome = if ($null -ne $outcomeProp -and -not [string]::IsNullOrWhiteSpace([string]$outcomeProp.Value)) {
                            [string]$outcomeProp.Value
                        }
                        else {
                            'Failed'
                        }
                        $message = if ($null -ne $messageProp -and -not [string]::IsNullOrWhiteSpace([string]$messageProp.Value)) {
                            [string]$messageProp.Value
                        }
                        else {
                            "Resultado remoto recebido sem mensagem detalhada ao resetar o spooler na máquina '$targetComputerName'."
                        }
                    }
                }
            }
        }
        elseif (-not (Test-IsAdministrator)) {
            $outcome = 'Failed'
            $message = "Permissão negada na máquina '$targetComputerName': execute o PowerShell como Administrador para resetar o spooler."
        }
        elseif (-not $SkipBackup -and $hasBackupPath -and [string]::IsNullOrWhiteSpace($BackupPath)) {
            $outcome = 'Failed'
            $message = "Parâmetro -BackupPath inválido na máquina '$targetComputerName': o caminho de backup não pode conter apenas espaços em branco."
        }
        else {
            $backupDescription = if ($SkipBackup) { 'sem backup (-SkipBackup)' } else { 'com backup prévio' }
            $actionDescription = "Parar o serviço Spooler, apagar arquivos .SPL e .SHD de PRINTERS ($backupDescription) e reiniciar o serviço na máquina '$targetComputerName'"
            if (-not $PSCmdlet.ShouldProcess($targetComputerName, $actionDescription)) {
                if ($WhatIfPreference) {
                    $outcome = 'Simulated'
                    $message = "Simulação (-WhatIf): nenhuma alteração foi realizada na máquina '$targetComputerName'."
                }
                else {
                    $outcome = 'Skipped'
                    $message = "Operação cancelada pelo usuário na confirmação para a máquina '$targetComputerName'."
                }
            }
            else {
                $serviceStopped = $false
                $startAttempted = $false
                $backedUpCount = 0
                $removedCount = 0
                $defaultBackupRoot = $null
                $effectiveBackupDirectory = $null
                $failureMessage = $null

                try {
                    if (-not $SkipBackup) {
                        if ($hasBackupPath) {
                            $effectiveBackupDirectory = $BackupPath
                        }
                        else {
                            $programDataRoot = $env:ProgramData
                            if ([string]::IsNullOrWhiteSpace($programDataRoot)) {
                                $programDataRoot = [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::CommonApplicationData)
                            }
                            if ([string]::IsNullOrWhiteSpace($programDataRoot)) {
                                throw 'A variável de ambiente ProgramData não está definida para gravar o backup.'
                            }

                            $defaultBackupRoot = Join-Path -Path $programDataRoot -ChildPath 'SpoolDoctor\backups'
                            $effectiveBackupDirectory = Join-Path -Path $defaultBackupRoot -ChildPath $timestamp.ToString('yyyyMMdd-HHmmss')
                        }
                    }

                    Stop-SpoolerService -Confirm:$false
                    $serviceStopped = $true

                    $spoolFiles = @(Get-SpoolFile)
                    $validatedPaths = New-Object -TypeName 'System.Collections.Generic.List[string]'
                    foreach ($file in $spoolFiles) {
                        $filePath = if ($null -eq $file) {
                            ''
                        }
                        elseif ($file -is [string]) {
                            $file
                        }
                        else {
                            $file.FullName
                        }

                        if (-not (Test-SafeSpoolFilePath -Path $filePath)) {
                            throw "Caminho inseguro detectado e recusado durante o reset: '$filePath'."
                        }

                        $validatedPaths.Add($filePath)
                    }

                    if (-not $SkipBackup -and $validatedPaths.Count -gt 0) {
                        foreach ($filePath in $validatedPaths) {
                            Copy-SpoolFile -Path $filePath -DestinationDirectory $effectiveBackupDirectory -Confirm:$false
                            $backedUpCount++
                        }
                    }

                    foreach ($filePath in $validatedPaths) {
                        Remove-SpoolFile -Path $filePath -Confirm:$false
                        $removedCount++
                    }

                    $startAttempted = $true
                    Start-SpoolerService -Confirm:$false
                }
                catch {
                    $failureMessage = $_.Exception.Message
                }
                finally {
                    if ($serviceStopped -and -not $startAttempted) {
                        try {
                            Start-SpoolerService -Confirm:$false
                        }
                        catch {
                            $failureMessage = "$failureMessage Falha também ao tentar reiniciar o serviço Spooler: $($_.Exception.Message)"
                        }
                    }
                }

                if ($null -ne $failureMessage) {
                    $outcome = 'Failed'
                    $message = "Falha ao resetar o spooler na máquina '$targetComputerName': $failureMessage"
                }
                else {
                    try {
                        $serviceStatus = Get-SpoolerServiceStatus
                        $remainingFiles = @(Get-SpoolFile)

                        if ($serviceStatus -ne 'Running' -or $remainingFiles.Count -gt 0) {
                            $outcome = 'Failed'
                            $message = "Verificação final falhou na máquina '$targetComputerName': status do serviço='$serviceStatus', arquivos remanescentes=$($remainingFiles.Count)."
                        }
                        else {
                            $outcome = 'OK'
                            if ($SkipBackup) {
                                $message = "Spooler reiniciado com sucesso na máquina '$targetComputerName'. Arquivos removidos: $removedCount. Backup ignorado (-SkipBackup). Serviço em execução e fila vazia."
                            }
                            elseif ($backedUpCount -gt 0) {
                                $message = "Spooler reiniciado com sucesso na máquina '$targetComputerName'. Backup realizado: $backedUpCount arquivo(s) em '$effectiveBackupDirectory'. Arquivos removidos: $removedCount. Serviço em execução e fila vazia."
                            }
                            else {
                                $message = "Spooler reiniciado com sucesso na máquina '$targetComputerName'. Arquivos removidos: 0 (fila já vazia; nenhum backup necessário). Serviço em execução e fila vazia."
                            }

                            if (-not $SkipBackup -and $BackupRetentionDays -gt 0 -and -not [string]::IsNullOrWhiteSpace($defaultBackupRoot)) {
                                try {
                                    $cleanupResult = Remove-OldSpoolBackup -BackupRoot $defaultBackupRoot -RetentionDays $BackupRetentionDays -Confirm:$false
                                    if ($null -ne $cleanupResult) {
                                        $removedProp = $cleanupResult.PSObject.Properties['RemovedCount']
                                        if ($null -ne $removedProp -and [int]$removedProp.Value -gt 0) {
                                            $message = "$message Backups antigos removidos: $([int]$removedProp.Value)."
                                        }

                                        $warningsProp = $cleanupResult.PSObject.Properties['Warnings']
                                        if ($null -ne $warningsProp -and $null -ne $warningsProp.Value) {
                                            $cleanupWarnings = @($warningsProp.Value | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
                                            if ($cleanupWarnings.Count -gt 0) {
                                                $message = "$message Aviso na limpeza de backups antigos: $($cleanupWarnings -join ' ')"
                                            }
                                        }
                                    }
                                }
                                catch {
                                    $message = "$message Aviso na limpeza de backups antigos: $($_.Exception.Message)"
                                }
                            }
                        }
                    }
                    catch {
                        $outcome = 'Failed'
                        $message = "Falha na verificação final do spooler na máquina '$targetComputerName': $($_.Exception.Message)"
                    }
                }
            }
        }

        $result = [PSCustomObject]@{
            PSTypeName   = 'SpoolDoctor.ActionResult'
            ComputerName = $targetComputerName
            Action       = $actionName
            Outcome      = $outcome
            Message      = $message
            Timestamp    = $timestamp
        }

        $logParams = @{
            ComputerName = $targetComputerName
            Action       = $actionName
            Outcome      = $outcome
            Message      = $message
            Timestamp    = $timestamp
        }
        if ($hasLogPath) {
            $logParams['LogPath'] = $LogPath
        }

        Write-SpoolDoctorLog @logParams

        $result
    }
}
