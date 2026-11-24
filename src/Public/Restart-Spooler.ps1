function Restart-Spooler {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([PSCustomObject])]
    param(
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$LogPath,

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

    $actionName = 'Restart-Spooler'
    $hasCredential = ($PSBoundParameters.ContainsKey('Credential') -and $null -ne $Credential)
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
            if ($target.IsPrintServerListed -and -not $AllowPrintServer) {
                $outcome = 'Failed'
                $message = "Reinício bloqueado na máquina '$targetComputerName' (marcada como servidor de impressão na allow-list com '|PrintServer'). Informe -AllowPrintServer para confirmar a execução."
            }
            else {
                $printServerNotice = if ($AllowPrintServer) { ' [SERVIDOR DE IMPRESSÃO]' } else { '' }
                $actionDescription = "Reiniciar ou iniciar o serviço Spooler preservando os arquivos da fila na máquina remota '$targetComputerName'$printServerNotice"

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
                    $remoteParams = @{
                        ComputerName = $targetComputerName
                        Operation    = $actionName
                        Parameters   = @{
                            AllowPrintServer = [bool]$AllowPrintServer
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
                        $message = "Resposta inválida ou vazia ao reiniciar o serviço Spooler na máquina '$targetComputerName'."
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
                            "Resultado remoto recebido sem mensagem detalhada ao reiniciar o serviço Spooler na máquina '$targetComputerName'."
                        }
                    }
                }
            }
        }
        elseif (-not (Test-IsAdministrator)) {
            $outcome = 'Failed'
            $message = "Permissão negada na máquina '$targetComputerName': execute o PowerShell como Administrador para reiniciar o serviço Spooler."
        }
        else {
            $actionDescription = "Reiniciar ou iniciar o serviço Spooler preservando os arquivos da fila na máquina '$targetComputerName'"
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
                $wasAlreadyStopped = $false
                $failureMessage = $null

                try {
                    $initialStatus = [string](Get-SpoolerServiceStatus)
                    if ($initialStatus -eq 'Stopped') {
                        $wasAlreadyStopped = $true
                    }
                    else {
                        Stop-SpoolerService -Confirm:$false
                        $serviceStopped = $true
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
                    $message = "Falha ao reiniciar o serviço Spooler na máquina '$targetComputerName': $failureMessage"
                }
                else {
                    try {
                        $finalStatus = [string](Get-SpoolerServiceStatus)
                        if ($finalStatus -ne 'Running') {
                            $outcome = 'Failed'
                            $message = "Verificação final falhou na máquina '$targetComputerName': status do serviço='$finalStatus' (esperado 'Running')."
                        }
                        else {
                            $outcome = 'OK'
                            if ($wasAlreadyStopped) {
                                $message = "Serviço Spooler iniciado com sucesso na máquina '$targetComputerName'. Arquivos da fila preservados e serviço em execução."
                            }
                            else {
                                $message = "Serviço Spooler reiniciado com sucesso na máquina '$targetComputerName'. Arquivos da fila preservados e serviço em execução."
                            }
                        }
                    }
                    catch {
                        $outcome = 'Failed'
                        $message = "Falha na verificação final do serviço Spooler na máquina '$targetComputerName': $($_.Exception.Message)"
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
