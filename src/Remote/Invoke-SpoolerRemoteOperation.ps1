function Invoke-SpoolerRemoteOperation {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ComputerName,

        [Parameter(Mandatory)]
        [ValidateSet('Get-SpoolerJob', 'Remove-SpoolerJob', 'Reset-Spooler', 'Test-Spooler')]
        [string]$Operation,

        [Parameter()]
        [hashtable]$Parameters = @{},

        [Parameter()]
        [PSCredential]$Credential
    )

    $requiredFunctionNames = switch ($Operation) {
        'Get-SpoolerJob' {
            @(
                'Test-ValidComputerName',
                'Resolve-SpoolerTarget',
                'Get-SpoolerPrinterRaw',
                'Get-SpoolerJobRaw',
                'Get-SpoolerJob'
            )
        }
        'Remove-SpoolerJob' {
            @(
                'Test-ValidComputerName',
                'Resolve-SpoolerTarget',
                'Test-IsAdministrator',
                'Remove-SpoolerJobRaw',
                'Get-SpoolerJobRaw',
                'Remove-SpoolerJob'
            )
        }
        'Reset-Spooler' {
            @(
                'Test-ValidComputerName',
                'Resolve-SpoolerTarget',
                'Test-IsAdministrator',
                'Get-SpoolDirectoryPath',
                'Test-SafeSpoolFilePath',
                'Get-SpoolerServiceStatus',
                'Stop-SpoolerService',
                'Start-SpoolerService',
                'Get-SpoolFile',
                'Copy-SpoolFile',
                'Remove-SpoolFile',
                'Remove-OldSpoolBackup',
                'Get-SpoolerPrinterRaw',
                'Test-SpoolerPrintServer',
                'Reset-Spooler'
            )
        }
        'Test-Spooler' {
            @(
                'Test-ValidComputerName',
                'Resolve-SpoolerTarget',
                'Get-SpoolerServiceStatus',
                'Get-SpoolerPrinterRaw',
                'Get-SpoolerJobRaw',
                'Get-SpoolDirectoryPath',
                'Get-SpoolFile',
                'Test-Spooler'
            )
        }
    }

    $functionDefinitions = @{}
    foreach ($fnName in $requiredFunctionNames) {
        $fnItem = Get-Item -Path "Function:\$fnName" -ErrorAction Stop
        $functionDefinitions[$fnName] = $fnItem.ScriptBlock.ToString()
    }

    $remoteScriptBlock = {
        param(
            [string]$TargetComputerName,
            [string]$OperationName,
            [hashtable]$OperationParameters,
            [hashtable]$FunctionDefinitions
        )

        Set-StrictMode -Version Latest

        # O log oficial é gravado localmente após o retorno para preservar -LogPath e centralizar a auditoria.
        $null = New-Item -Path 'Function:' -Name 'Write-SpoolDoctorLog' -Value ([scriptblock]::Create('$null = $args')) -Force -ErrorAction Stop

        foreach ($entry in $FunctionDefinitions.GetEnumerator()) {
            $scriptBlock = [scriptblock]::Create([string]$entry.Value)
            $null = New-Item -Path 'Function:' -Name ([string]$entry.Key) -Value $scriptBlock -Force -ErrorAction Stop
        }

        switch ($OperationName) {
            'Get-SpoolerJob' {
                $callParams = @{}
                if ($OperationParameters.ContainsKey('PrinterName') -and -not [string]::IsNullOrWhiteSpace([string]$OperationParameters['PrinterName'])) {
                    $callParams['PrinterName'] = [string]$OperationParameters['PrinterName']
                }
                return @(Get-SpoolerJob @callParams)
            }
            'Remove-SpoolerJob' {
                $callParams = @{
                    PrinterName = [string]$OperationParameters['PrinterName']
                    Id          = [int]$OperationParameters['Id']
                    Confirm     = $false
                }
                return (Remove-SpoolerJob @callParams)
            }
            'Reset-Spooler' {
                if (-not (Test-IsAdministrator)) {
                    return [PSCustomObject]@{
                        PSTypeName   = 'SpoolDoctor.ActionResult'
                        ComputerName = $TargetComputerName
                        Action       = 'Reset-Spooler'
                        Outcome      = 'Failed'
                        Message      = "Permissão negada na máquina '$TargetComputerName': execute com credencial de Administrador no destino para resetar o spooler."
                        Timestamp    = (Get-Date)
                    }
                }

                $allowPrintServer = $OperationParameters.ContainsKey('AllowPrintServer') -and [bool]$OperationParameters['AllowPrintServer']
                if (-not $allowPrintServer) {
                    try {
                        $printServerCheck = Test-SpoolerPrintServer
                    }
                    catch {
                        return [PSCustomObject]@{
                            PSTypeName   = 'SpoolDoctor.ActionResult'
                            ComputerName = $TargetComputerName
                            Action       = 'Reset-Spooler'
                            Outcome      = 'Failed'
                            Message      = "Reset bloqueado na máquina '$TargetComputerName': não foi possível verificar se a máquina é servidor de impressão ($($_.Exception.Message))."
                            Timestamp    = (Get-Date)
                        }
                    }

                    if ($null -ne $printServerCheck -and [bool]$printServerCheck.IsPrintServer) {
                        $reasonsText = @($printServerCheck.Reasons) -join '; '
                        return [PSCustomObject]@{
                            PSTypeName   = 'SpoolDoctor.ActionResult'
                            ComputerName = $TargetComputerName
                            Action       = 'Reset-Spooler'
                            Outcome      = 'Failed'
                            Message      = "Reset bloqueado na máquina '$TargetComputerName' (servidor de impressão detectado: $reasonsText). Informe -AllowPrintServer para confirmar a execução."
                            Timestamp    = (Get-Date)
                        }
                    }
                }

                $callParams = @{
                    Confirm = $false
                }
                if ($OperationParameters.ContainsKey('SkipBackup') -and [bool]$OperationParameters['SkipBackup']) {
                    $callParams['SkipBackup'] = $true
                }
                if ($OperationParameters.ContainsKey('BackupPath') -and -not [string]::IsNullOrWhiteSpace([string]$OperationParameters['BackupPath'])) {
                    $callParams['BackupPath'] = [string]$OperationParameters['BackupPath']
                }
                if ($OperationParameters.ContainsKey('BackupRetentionDays')) {
                    $callParams['BackupRetentionDays'] = [int]$OperationParameters['BackupRetentionDays']
                }

                return (Reset-Spooler @callParams)
            }
            'Test-Spooler' {
                $callParams = @{}
                if ($OperationParameters.ContainsKey('StuckThresholdMinutes')) {
                    $callParams['StuckThresholdMinutes'] = [int]$OperationParameters['StuckThresholdMinutes']
                }
                return (Test-Spooler @callParams)
            }
        }
    }

    $session = $null
    $success = $false
    $outcome = 'Failed'
    $message = ''
    $data = $null

    try {
        $sessionParams = @{
            ComputerName = $ComputerName
            Confirm      = $false
            WhatIf       = $false
        }
        if ($PSBoundParameters.ContainsKey('Credential') -and $null -ne $Credential) {
            $sessionParams['Credential'] = $Credential
        }

        $session = New-SpoolerRemoteSession @sessionParams
        $data = Invoke-SpoolerRemoteScript -Session $session -ScriptBlock $remoteScriptBlock -ArgumentList @(
            $ComputerName,
            $Operation,
            $Parameters,
            $functionDefinitions
        )
        $success = $true
        $outcome = 'OK'
        $message = "Execução remota da ação '$Operation' concluída na máquina '$ComputerName'."
    }
    catch {
        $success = $false
        $outcome = Get-RemoteFailureOutcome -ErrorRecord $_
        $message = "Falha na execução remota em '$ComputerName': $($_.Exception.Message)"
    }
    finally {
        if ($null -ne $session) {
            try {
                Remove-SpoolerRemoteSession -Session $session -Confirm:$false -WhatIf:$false
            }
            catch {
                $cleanupNote = "Aviso ao encerrar a sessão remota em '$ComputerName': $($_.Exception.Message)"
                if ([string]::IsNullOrWhiteSpace($message)) {
                    $message = $cleanupNote
                }
                else {
                    $message = "$message $cleanupNote"
                }
            }
        }
    }

    return [PSCustomObject]@{
        Success = $success
        Outcome = $outcome
        Message = $message
        Data    = $data
    }
}
