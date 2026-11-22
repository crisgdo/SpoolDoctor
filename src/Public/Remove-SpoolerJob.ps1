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
        [string]$LogPath,

        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$ComputerName,

        [Parameter()]
        [PSCredential]$Credential,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$AllowedComputersPath
    )

    begin {
        $hasCredential = ($PSBoundParameters.ContainsKey('Credential') -and $null -ne $Credential)
        $targetParams = @{
            HasCredential = $hasCredential
        }
        if ($PSBoundParameters.ContainsKey('ComputerName')) {
            $targetParams['ComputerName'] = $ComputerName
        }
        if ($PSBoundParameters.ContainsKey('AllowedComputersPath')) {
            $targetParams['AllowedComputersPath'] = $AllowedComputersPath
        }

        $resolvedTarget = Resolve-SpoolerTarget @targetParams
        $computerName = [string]$resolvedTarget.ComputerName

        $actionName = 'Remove-SpoolerJob'
        $hasLogPath = $PSBoundParameters.ContainsKey('LogPath')
    }

    process {
        $timestamp = Get-Date
        $outcome = 'Failed'
        $message = ''

        if (-not $resolvedTarget.IsValid) {
            $outcome = [string]$resolvedTarget.FailureOutcome
            $message = [string]$resolvedTarget.ErrorMessage
        }
        elseif (-not $resolvedTarget.IsLocal) {
            if ([string]::IsNullOrWhiteSpace($PrinterName)) {
                $outcome = 'Failed'
                $message = "Parâmetro -PrinterName inválido na máquina '$computerName' para o job ${Id}: o nome da impressora não pode conter apenas espaços em branco."
            }
            else {
                $targetDescription = "$computerName - $PrinterName (Job $Id)"
                $actionDescription = "Cancelar o job de impressão $Id na impressora '$PrinterName' na máquina remota '$computerName'"

                if (-not $PSCmdlet.ShouldProcess($targetDescription, $actionDescription)) {
                    if ($WhatIfPreference) {
                        $outcome = 'Simulated'
                        $message = "Simulação (-WhatIf): cancelamento do job $Id da impressora '$PrinterName' simulado na máquina remota '$computerName'; nenhuma alteração foi realizada."
                    }
                    else {
                        $outcome = 'Skipped'
                        $message = "Operação cancelada pelo usuário na confirmação para o job $Id da impressora '$PrinterName' na máquina '$computerName'."
                    }
                }
                else {
                    $remoteParams = @{
                        ComputerName = $computerName
                        Operation    = $actionName
                        Parameters   = @{
                            PrinterName = $PrinterName
                            Id          = $Id
                        }
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
                        $message = "Resposta inválida ou vazia ao cancelar o job $Id da impressora '$PrinterName' na máquina '$computerName'."
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
                            "Resultado remoto recebido sem mensagem detalhada para o job $Id na máquina '$computerName'."
                        }
                    }
                }
            }
        }
        elseif (-not (Test-IsAdministrator)) {
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
