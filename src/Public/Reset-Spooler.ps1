function Reset-Spooler {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([PSCustomObject])]
    param(
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$LogPath
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
    else {
        $actionDescription = "Parar o serviço Spooler, apagar arquivos .SPL e .SHD de PRINTERS e reiniciar o serviço na máquina '$computerName'"
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
            $removedCount = 0
            $failureMessage = $null

            try {
                Stop-SpoolerService -Confirm:$false
                $serviceStopped = $true

                $spoolFiles = @(Get-SpoolFile)
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
                        $message = "Spooler reiniciado com sucesso na máquina '$computerName'. Arquivos removidos: $removedCount. Serviço em execução e fila vazia."
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
