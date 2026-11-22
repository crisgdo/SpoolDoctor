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
        [string]$BackupPath
    )

    $computerName = if (-not [string]::IsNullOrWhiteSpace($env:COMPUTERNAME)) {
        $env:COMPUTERNAME
    }
    else {
        [System.Environment]::MachineName
    }

    $actionName = 'Reset-Spooler'
    $timestamp = Get-Date
    $outcome = 'Failed'
    $message = ''

    if (-not (Test-IsAdministrator)) {
        $outcome = 'Failed'
        $message = "Permissão negada na máquina '$computerName': execute o PowerShell como Administrador para resetar o spooler."
    }
    elseif (-not $SkipBackup -and $PSBoundParameters.ContainsKey('BackupPath') -and [string]::IsNullOrWhiteSpace($BackupPath)) {
        $outcome = 'Failed'
        $message = "Parâmetro -BackupPath inválido na máquina '$computerName': o caminho de backup não pode conter apenas espaços em branco."
    }
    else {
        $backupDescription = if ($SkipBackup) { 'sem backup (-SkipBackup)' } else { 'com backup prévio' }
        $actionDescription = "Parar o serviço Spooler, apagar arquivos .SPL e .SHD de PRINTERS ($backupDescription) e reiniciar o serviço na máquina '$computerName'"
        if (-not $PSCmdlet.ShouldProcess($computerName, $actionDescription)) {
            if ($WhatIfPreference) {
                $outcome = 'Simulated'
                $message = "Simulação (-WhatIf): nenhuma alteração foi realizada na máquina '$computerName'."
            }
            else {
                $outcome = 'Skipped'
                $message = "Operação cancelada pelo usuário na confirmação para a máquina '$computerName'."
            }
        }
        else {
            $serviceStopped = $false
            $startAttempted = $false
            $backedUpCount = 0
            $removedCount = 0
            $effectiveBackupDirectory = $null
            $failureMessage = $null

            try {
                if (-not $SkipBackup) {
                    if ($PSBoundParameters.ContainsKey('BackupPath')) {
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

                        $effectiveBackupDirectory = Join-Path -Path $programDataRoot -ChildPath ("SpoolDoctor\backups\{0}" -f $timestamp.ToString('yyyyMMdd-HHmmss'))
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
                $message = "Falha ao resetar o spooler na máquina '$computerName': $failureMessage"
            }
            else {
                try {
                    $serviceStatus = Get-SpoolerServiceStatus
                    $remainingFiles = @(Get-SpoolFile)

                    if ($serviceStatus -ne 'Running' -or $remainingFiles.Count -gt 0) {
                        $outcome = 'Failed'
                        $message = "Verificação final falhou na máquina '$computerName': status do serviço='$serviceStatus', arquivos remanescentes=$($remainingFiles.Count)."
                    }
                    else {
                        $outcome = 'OK'
                        if ($SkipBackup) {
                            $message = "Spooler reiniciado com sucesso na máquina '$computerName'. Arquivos removidos: $removedCount. Backup ignorado (-SkipBackup). Serviço em execução e fila vazia."
                        }
                        elseif ($backedUpCount -gt 0) {
                            $message = "Spooler reiniciado com sucesso na máquina '$computerName'. Backup realizado: $backedUpCount arquivo(s) em '$effectiveBackupDirectory'. Arquivos removidos: $removedCount. Serviço em execução e fila vazia."
                        }
                        else {
                            $message = "Spooler reiniciado com sucesso na máquina '$computerName'. Arquivos removidos: 0 (fila já vazia; nenhum backup necessário). Serviço em execução e fila vazia."
                        }
                    }
                }
                catch {
                    $outcome = 'Failed'
                    $message = "Falha na verificação final do spooler na máquina '$computerName': $($_.Exception.Message)"
                }
            }
        }
    }

    $result = [PSCustomObject]@{
        PSTypeName   = 'SpoolDoctor.ActionResult'
        ComputerName = $computerName
        Action       = $actionName
        Outcome      = $outcome
        Message      = $message
        Timestamp    = $timestamp
    }

    $logParams = @{
        ComputerName = $computerName
        Action       = $actionName
        Outcome      = $outcome
        Message      = $message
        Timestamp    = $timestamp
    }
    if ($PSBoundParameters.ContainsKey('LogPath')) {
        $logParams['LogPath'] = $LogPath
    }

    Write-SpoolDoctorLog @logParams

    return $result
}
