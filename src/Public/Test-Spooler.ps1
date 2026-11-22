function Test-Spooler {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter()]
        [ValidateRange(1, 1440)]
        [int]$StuckThresholdMinutes = 15,

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

    $actionName = 'Test-Spooler'
    $now = Get-Date
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

    $target = Resolve-SpoolerTarget @targetParams
    $computerName = [string]$target.ComputerName

    $outcome = 'OK'
    $failureMessage = $null
    $diagnostic = $null
    $logMessage = ''

    $problematicPrinterStatuses = @(
        'Error',
        'Offline',
        'PaperOut',
        'PaperJam',
        'NotAvailable',
        'DoorOpen',
        'NoToner',
        'OutputBinFull',
        'ServerUnknown',
        'UserIntervention'
    )
    $problematicJobStatuses = @(
        'Error',
        'Blocked',
        'Deleting',
        'Offline',
        'PaperOut',
        'UserIntervention'
    )

    $splitStatusTokens = {
        param([object]$RawStatus)

        if ($null -eq $RawStatus) {
            return @()
        }

        $statusText = $RawStatus.ToString()
        if ([string]::IsNullOrWhiteSpace($statusText)) {
            return @()
        }

        return @(
            $statusText -split ',' |
                ForEach-Object { $_.Trim() } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        )
    }

    if (-not $target.IsValid) {
        $outcome = [string]$target.FailureOutcome
        $failureMessage = [string]$target.ErrorMessage
        $logMessage = $failureMessage
    }
    elseif (-not $target.IsLocal) {
        try {
            $remoteParams = @{
                ComputerName = $computerName
                Operation    = $actionName
                Parameters   = @{
                    StuckThresholdMinutes = $StuckThresholdMinutes
                }
            }
            if ($hasCredential) {
                $remoteParams['Credential'] = $Credential
            }

            $remoteResult = Invoke-SpoolerRemoteOperation @remoteParams
            if (-not $remoteResult.Success) {
                $outcome = [string]$remoteResult.Outcome
                $failureMessage = [string]$remoteResult.Message
                $logMessage = $failureMessage
            }
            elseif ($null -eq $remoteResult.Data) {
                throw "Resposta inválida ou vazia ao diagnosticar o spooler na máquina '$computerName'."
            }
            else {
                $rawDiag = $remoteResult.Data
                $serviceStatus = [string]$rawDiag.PSObject.Properties['ServiceStatus'].Value
                $printerCount = [int]$rawDiag.PSObject.Properties['PrinterCount'].Value
                $unhealthyPrinters = @($rawDiag.PSObject.Properties['UnhealthyPrinters'].Value | Where-Object { $null -ne $_ })
                $jobCount = [int]$rawDiag.PSObject.Properties['JobCount'].Value
                $stuckJobs = @($rawDiag.PSObject.Properties['StuckJobs'].Value | Where-Object { $null -ne $_ })
                $spoolFileProp = $rawDiag.PSObject.Properties['SpoolFileCount']
                $spoolFileCount = if ($null -ne $spoolFileProp -and $null -ne $spoolFileProp.Value) { [int]$spoolFileProp.Value } else { $null }
                $hasOrphan = [bool]$rawDiag.PSObject.Properties['HasOrphanSpoolFiles'].Value
                $health = [string]$rawDiag.PSObject.Properties['Health'].Value
                $isHealthy = [bool]$rawDiag.PSObject.Properties['IsHealthy'].Value
                $issues = @($rawDiag.PSObject.Properties['Issues'].Value | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_ })
                $recommendation = [string]$rawDiag.PSObject.Properties['Recommendation'].Value
                $tsProp = $rawDiag.PSObject.Properties['Timestamp']
                $diagTimestamp = if ($null -ne $tsProp -and $tsProp.Value -is [datetime]) { [datetime]$tsProp.Value } else { $now }

                $diagnostic = [PSCustomObject]@{
                    PSTypeName          = 'SpoolDoctor.Diagnostic'
                    ComputerName        = $computerName
                    ServiceStatus       = $serviceStatus
                    PrinterCount        = $printerCount
                    UnhealthyPrinters   = @($unhealthyPrinters)
                    JobCount            = $jobCount
                    StuckJobs           = @($stuckJobs)
                    SpoolFileCount      = $spoolFileCount
                    HasOrphanSpoolFiles = $hasOrphan
                    Health              = $health
                    IsHealthy           = $isHealthy
                    Issues              = @($issues)
                    Recommendation      = $recommendation
                    Timestamp           = $diagTimestamp
                }

                $spoolCountText = if ($null -ne $spoolFileCount) { [string]$spoolFileCount } else { 'N/D' }
                $logMessage = "Diagnóstico remoto concluído na máquina '$computerName': Health=$health, Serviço=$serviceStatus, Impressoras=$printerCount, Jobs=$jobCount, Travados=$($stuckJobs.Count), ArquivosPRINTERS=$spoolCountText."
            }
        }
        catch {
            $outcome = 'Failed'
            $failureMessage = "Falha ao diagnosticar o spooler na máquina '$computerName': $($_.Exception.Message)"
            $logMessage = $failureMessage
        }
    }
    else {
        try {
        $serviceStatus = [string](Get-SpoolerServiceStatus)
        if ([string]::IsNullOrWhiteSpace($serviceStatus)) {
            $serviceStatus = 'Unknown'
        }

        $issues = New-Object -TypeName 'System.Collections.Generic.List[string]'
        $unhealthyPrinters = New-Object -TypeName 'System.Collections.Generic.List[PSCustomObject]'
        $stuckJobs = New-Object -TypeName 'System.Collections.Generic.List[PSCustomObject]'
        $printerCount = 0
        $jobCount = 0

        if ($serviceStatus -ne 'Running') {
            $issues.Add("Serviço Spooler não está em execução (status='$serviceStatus').")
        }
        else {
            $rawPrinters = @(Get-SpoolerPrinterRaw)
            $printerNames = New-Object -TypeName 'System.Collections.Generic.List[string]'

            foreach ($rawPrinter in $rawPrinters) {
                if ($null -eq $rawPrinter) {
                    continue
                }

                $printerName = $null
                if ($rawPrinter -is [string]) {
                    $printerName = $rawPrinter
                }
                else {
                    $nameProp = $rawPrinter.PSObject.Properties['Name']
                    if ($null -ne $nameProp -and $null -ne $nameProp.Value) {
                        $printerName = [string]$nameProp.Value
                    }
                }

                if ([string]::IsNullOrWhiteSpace($printerName)) {
                    continue
                }

                $printerCount++
                $printerNames.Add($printerName)

                if (-not ($rawPrinter -is [string])) {
                    $printerStatusProp = $rawPrinter.PSObject.Properties['PrinterStatus']
                    if ($null -ne $printerStatusProp -and $null -ne $printerStatusProp.Value) {
                        $printerStatusText = $printerStatusProp.Value.ToString()
                        $printerTokens = @(& $splitStatusTokens $printerStatusText)
                        $matchedPrinterFlags = @($printerTokens | Where-Object { $_ -in $problematicPrinterStatuses })
                        if ($matchedPrinterFlags.Count -gt 0) {
                            $unhealthyPrinters.Add([PSCustomObject]@{
                                Name   = $printerName
                                Status = $printerStatusText
                            })
                            $issues.Add("Impressora '$printerName' com status de alerta ('$printerStatusText').")
                        }
                    }
                }
            }

            foreach ($targetPrinter in $printerNames) {
                $rawJobs = @(Get-SpoolerJobRaw -PrinterName $targetPrinter)
                foreach ($rawJob in $rawJobs) {
                    if ($null -eq $rawJob) {
                        continue
                    }

                    $jobCount++

                    $idProp = $rawJob.PSObject.Properties['Id']
                    $jobId = if ($null -ne $idProp -and $null -ne $idProp.Value) { $idProp.Value } else { $null }

                    $jobPrinterProp = $rawJob.PSObject.Properties['PrinterName']
                    $jobPrinterName = if (
                        $null -ne $jobPrinterProp -and
                        $null -ne $jobPrinterProp.Value -and
                        -not [string]::IsNullOrWhiteSpace([string]$jobPrinterProp.Value)
                    ) {
                        [string]$jobPrinterProp.Value
                    }
                    else {
                        $targetPrinter
                    }

                    $docProp = $rawJob.PSObject.Properties['DocumentName']
                    $jobDocument = if ($null -ne $docProp -and $null -ne $docProp.Value) { [string]$docProp.Value } else { $null }

                    $submittedProp = $rawJob.PSObject.Properties['SubmittedTime']
                    $submittedAt = $null
                    if ($null -ne $submittedProp -and $null -ne $submittedProp.Value) {
                        if ($submittedProp.Value -is [datetime]) {
                            $submittedAt = $submittedProp.Value
                        }
                        elseif ($submittedProp.Value -is [string] -and -not [string]::IsNullOrWhiteSpace($submittedProp.Value)) {
                            $submittedAt = [datetime]$submittedProp.Value
                        }
                    }

                    $age = $null
                    if ($null -ne $submittedAt) {
                        $referenceNow = if ($submittedAt.Kind -eq [System.DateTimeKind]::Utc) {
                            $now.ToUniversalTime()
                        }
                        else {
                            $now
                        }

                        $elapsed = $referenceNow - $submittedAt
                        if ($elapsed -lt [timespan]::Zero) {
                            $elapsed = [timespan]::Zero
                        }
                        $age = $elapsed
                    }

                    $jobStatusProp = $rawJob.PSObject.Properties['JobStatus']
                    $jobStatusText = if (
                        $null -ne $jobStatusProp -and
                        $null -ne $jobStatusProp.Value -and
                        -not [string]::IsNullOrWhiteSpace($jobStatusProp.Value.ToString())
                    ) {
                        $jobStatusProp.Value.ToString()
                    }
                    else {
                        'Unknown'
                    }

                    $jobTokens = @(& $splitStatusTokens $jobStatusText)
                    $matchedJobFlags = @($jobTokens | Where-Object { $_ -in $problematicJobStatuses })

                    $stuckReasons = New-Object -TypeName 'System.Collections.Generic.List[string]'
                    if ($null -ne $age -and $age.TotalMinutes -ge $StuckThresholdMinutes) {
                        $stuckReasons.Add("Idade $([int][Math]::Floor($age.TotalMinutes))m >= $($StuckThresholdMinutes)m")
                    }
                    if ($matchedJobFlags.Count -gt 0) {
                        $stuckReasons.Add("Status=$jobStatusText")
                    }

                    if ($stuckReasons.Count -gt 0) {
                        $reasonText = $stuckReasons -join '; '
                        $stuckJobs.Add([PSCustomObject]@{
                            Id          = $jobId
                            PrinterName = $jobPrinterName
                            Document    = $jobDocument
                            Status      = $jobStatusText
                            Age         = $age
                            Reason      = $reasonText
                        })
                        $issues.Add("Job $jobId na impressora '$jobPrinterName' possivelmente travado ($reasonText).")
                    }
                }
            }
        }

        $spoolFileCount = $null
        $hasOrphanSpoolFiles = $false
        $spoolFilesAccessDenied = $false
        $spoolFilesReadError = $false

        try {
            $spoolFiles = @(Get-SpoolFile)
            $spoolFileCount = $spoolFiles.Count
            if ($serviceStatus -eq 'Running' -and $jobCount -eq 0 -and $spoolFileCount -gt 0) {
                $hasOrphanSpoolFiles = $true
                $issues.Add("Detectado(s) $spoolFileCount arquivo(s) órfão(s) (.SPL/.SHD) em PRINTERS com 0 jobs na fila.")
            }
        }
        catch {
            $ex = $_.Exception
            $isUnauthorized = ($ex -is [System.UnauthorizedAccessException]) -or
                ($null -ne $ex.InnerException -and $ex.InnerException -is [System.UnauthorizedAccessException]) -or
                ($_.CategoryInfo.Category -eq [System.Management.Automation.ErrorCategory]::PermissionDenied) -or
                ($ex.Message -match 'acesso negado|access.*denied|unauthorized')

            if ($isUnauthorized) {
                $spoolFilesAccessDenied = $true
                $issues.Add('Sem permissão para ler a pasta PRINTERS: execute o PowerShell como Administrador para verificar arquivos órfãos (.SPL/.SHD).')
            }
            else {
                $spoolFilesReadError = $true
                $issues.Add("Não foi possível ler a pasta PRINTERS: $($ex.Message)")
            }
        }

        $health = 'Healthy'
        $recommendation = 'Spooler saudável. Nenhuma ação corretiva necessária.'

        if ($serviceStatus -ne 'Running' -or $hasOrphanSpoolFiles) {
            $health = 'Critical'
            if ($serviceStatus -ne 'Running') {
                $recommendation = "O serviço Spooler está '$serviceStatus'. Execute Reset-Spooler para reiniciar o serviço e limpar a fila."
            }
            else {
                $recommendation = 'Há arquivos órfãos (.SPL/.SHD) na pasta PRINTERS sem jobs na fila. Execute Reset-Spooler para limpar a fila com segurança.'
            }
        }
        elseif ($stuckJobs.Count -gt 0 -or $unhealthyPrinters.Count -gt 0 -or $spoolFilesAccessDenied -or $spoolFilesReadError) {
            $health = 'Warning'
            if ($stuckJobs.Count -gt 0) {
                $recommendation = "Foram identificados $($stuckJobs.Count) job(s) possivelmente travado(s). Tente cancelar primeiro com Remove-SpoolerJob; se o job permanecer preso, execute Reset-Spooler."
            }
            elseif ($unhealthyPrinters.Count -gt 0) {
                $recommendation = 'Há impressora(s) com status de erro ou offline. Verifique a impressora física/rede e, se necessário, use Remove-SpoolerJob ou Reset-Spooler.'
            }
            else {
                $recommendation = 'Execute o diagnóstico como Administrador para verificar os arquivos da pasta PRINTERS.'
            }
        }

        $diagnostic = [PSCustomObject]@{
            PSTypeName          = 'SpoolDoctor.Diagnostic'
            ComputerName        = $computerName
            ServiceStatus       = $serviceStatus
            PrinterCount        = $printerCount
            UnhealthyPrinters   = @($unhealthyPrinters)
            JobCount            = $jobCount
            StuckJobs           = @($stuckJobs)
            SpoolFileCount      = $spoolFileCount
            HasOrphanSpoolFiles = $hasOrphanSpoolFiles
            Health              = $health
            IsHealthy           = ($health -eq 'Healthy')
            Issues              = @($issues)
            Recommendation      = $recommendation
            Timestamp           = $now
        }

        $spoolCountText = if ($null -ne $spoolFileCount) { [string]$spoolFileCount } else { 'N/D' }
        $logMessage = "Diagnóstico concluído na máquina '$computerName': Health=$health, Serviço=$serviceStatus, Impressoras=$printerCount, Jobs=$jobCount, Travados=$($stuckJobs.Count), ArquivosPRINTERS=$spoolCountText."
    }
        catch {
            $outcome = 'Failed'
            $failureMessage = "Falha ao diagnosticar o spooler na máquina '$computerName': $($_.Exception.Message)"
            $logMessage = $failureMessage
        }
    }

    $logParams = @{
        ComputerName = $computerName
        Action       = $actionName
        Outcome      = $outcome
        Message      = $logMessage
        Timestamp    = $now
    }
    if ($PSBoundParameters.ContainsKey('LogPath')) {
        $logParams['LogPath'] = $LogPath
    }

    Write-SpoolDoctorLog @logParams

    if ($null -ne $failureMessage) {
        throw $failureMessage
    }

    return $diagnostic
}
