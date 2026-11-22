function Remove-SpoolerJob {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory, ValueFromPipelineByPropertyName)]
        [ValidateNotNullOrEmpty()]
        [string]$PrinterName,

        [Parameter(Mandatory, ValueFromPipelineByPropertyName)]
        [ValidateRange(1, [int]::MaxValue)]
        [int]$Id,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$LogPath
    )

    begin {
        $computerName = if (-not [string]::IsNullOrWhiteSpace($env:COMPUTERNAME)) {
            $env:COMPUTERNAME
        }
        else {
            [System.Environment]::MachineName
        }

        $actionName = 'Remove-SpoolerJob'
        $hasLogPath = $PSBoundParameters.ContainsKey('LogPath')
    }

    process {
        $timestamp = Get-Date
        $outcome = 'Failed'
        $message = ''

        if (-not (Test-IsAdministrator)) {
            $outcome = 'Failed'
            $message = "Permissão negada na máquina '$computerName' para cancelar o job $Id da impressora '$PrinterName': execute o PowerShell como Administrador."
        }
        elseif ([string]::IsNullOrWhiteSpace($PrinterName)) {
            $outcome = 'Failed'
            $message = "Parâmetro -PrinterName inválido na máquina '$computerName' para o job ${Id}: o nome da impressora não pode conter apenas espaços em branco."
        }
        else {
            $target = "$computerName - $PrinterName (Job $Id)"
            $actionDescription = "Cancelar o job de impressão $Id na impressora '$PrinterName'"

            if (-not $PSCmdlet.ShouldProcess($target, $actionDescription)) {
                if ($WhatIfPreference) {
                    $outcome = 'Simulated'
                    $message = "Simulação (-WhatIf): cancelamento do job $Id da impressora '$PrinterName' simulado na máquina '$computerName'; nenhuma alteração foi realizada."
                }
                else {
                    $outcome = 'Skipped'
                    $message = "Operação cancelada pelo usuário na confirmação para o job $Id da impressora '$PrinterName' na máquina '$computerName'."
                }
            }
            else {
                $removalFailed = $false

                try {
                    Remove-SpoolerJobRaw -PrinterName $PrinterName -Id $Id -Confirm:$false
                }
                catch {
                    $removalFailed = $true
                    $outcome = 'Failed'
                    $message = "Falha ao cancelar o job $Id da impressora '$PrinterName' na máquina '$computerName': $($_.Exception.Message)"
                }

                if (-not $removalFailed) {
                    try {
                        $remainingJobs = @(Get-SpoolerJobRaw -PrinterName $PrinterName)
                        $jobStillPresent = $false
                        $remainingStatus = $null

                        foreach ($remainingJob in $remainingJobs) {
                            if ($null -eq $remainingJob) {
                                continue
                            }

                            $idProperty = $remainingJob.PSObject.Properties['Id']
                            if ($null -ne $idProperty -and $null -ne $idProperty.Value) {
                                $parsedId = 0
                                if ([int]::TryParse([string]$idProperty.Value, [ref]$parsedId) -and $parsedId -eq $Id) {
                                    $jobStillPresent = $true
                                    $statusProperty = $remainingJob.PSObject.Properties['JobStatus']
                                    if (
                                        $null -ne $statusProperty -and
                                        $null -ne $statusProperty.Value -and
                                        -not [string]::IsNullOrWhiteSpace($statusProperty.Value.ToString())
                                    ) {
                                        $remainingStatus = $statusProperty.Value.ToString()
                                    }
                                    break
                                }
                            }
                        }

                        if ($jobStillPresent) {
                            $outcome = 'Failed'
                            if (-not [string]::IsNullOrWhiteSpace($remainingStatus)) {
                                $message = "Verificação final falhou na máquina '$computerName': o job $Id da impressora '$PrinterName' permaneceu na fila (status='$remainingStatus'). Considere executar Reset-Spooler."
                            }
                            else {
                                $message = "Verificação final falhou na máquina '$computerName': o job $Id da impressora '$PrinterName' permaneceu na fila. Considere executar Reset-Spooler."
                            }
                        }
                        else {
                            $outcome = 'OK'
                            $message = "Job $Id da impressora '$PrinterName' cancelado com sucesso na máquina '$computerName'. Ausência confirmada na fila."
                        }
                    }
                    catch {
                        $outcome = 'Failed'
                        $message = "Falha na verificação final após cancelar o job $Id da impressora '$PrinterName' na máquina '$computerName': $($_.Exception.Message)"
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
        if ($hasLogPath) {
            $logParams['LogPath'] = $LogPath
        }

        Write-SpoolDoctorLog @logParams

        $result
    }

    end {
    }
}
