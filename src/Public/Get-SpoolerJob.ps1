function Get-SpoolerJob {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$PrinterName,

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
        [string]$AllowedComputersPath
    )

    $actionName = 'Get-SpoolerJob'
    $hasPrinterFilter = $PSBoundParameters.ContainsKey('PrinterName')
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
    $isBatchMode = ($resolvedTargets.Count -gt 1)

    foreach ($target in $resolvedTargets) {
        $now = Get-Date
        $targetComputerName = [string]$target.ComputerName

        $jobs = New-Object -TypeName 'System.Collections.Generic.List[PSCustomObject]'
        $targetPrinters = New-Object -TypeName 'System.Collections.Generic.List[string]'
        $outcome = 'OK'
        $message = ''
        $failureMessage = $null

        if (-not $target.IsValid) {
            $outcome = [string]$target.FailureOutcome
            $failureMessage = [string]$target.ErrorMessage
            $message = $failureMessage
        }
        elseif (-not $target.IsLocal) {
            try {
                if ($hasPrinterFilter -and [string]::IsNullOrWhiteSpace($PrinterName)) {
                    throw 'O parâmetro -PrinterName não pode conter apenas espaços em branco.'
                }

                $opParams = @{}
                if ($hasPrinterFilter) {
                    $opParams['PrinterName'] = $PrinterName
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
                    $failureMessage = [string]$remoteResult.Message
                    $message = $failureMessage
                }
                else {
                    $remoteJobs = @($remoteResult.Data)
                    foreach ($remoteJob in $remoteJobs) {
                        if ($null -eq $remoteJob) {
                            continue
                        }

                        $idProp = $remoteJob.PSObject.Properties['Id']
                        $jobId = if ($null -ne $idProp -and $null -ne $idProp.Value) { $idProp.Value } else { $null }

                        $printerProp = $remoteJob.PSObject.Properties['PrinterName']
                        $jobPrinterName = if ($null -ne $printerProp -and $null -ne $printerProp.Value) { [string]$printerProp.Value } else { $null }

                        $docProp = $remoteJob.PSObject.Properties['Document']
                        $document = if ($null -ne $docProp -and $null -ne $docProp.Value) { [string]$docProp.Value } else { $null }

                        $sizeProp = $remoteJob.PSObject.Properties['SizeBytes']
                        $sizeBytes = if ($null -ne $sizeProp -and $null -ne $sizeProp.Value) { [long]$sizeProp.Value } else { $null }

                        $submittedProp = $remoteJob.PSObject.Properties['SubmittedAt']
                        $submittedAt = $null
                        if ($null -ne $submittedProp -and $null -ne $submittedProp.Value) {
                            if ($submittedProp.Value -is [datetime]) {
                                $submittedAt = [datetime]$submittedProp.Value
                            }
                            elseif (-not [string]::IsNullOrWhiteSpace([string]$submittedProp.Value)) {
                                $submittedAt = [datetime]$submittedProp.Value
                            }
                        }

                        $ageProp = $remoteJob.PSObject.Properties['Age']
                        $age = $null
                        if ($null -ne $ageProp -and $null -ne $ageProp.Value) {
                            if ($ageProp.Value -is [timespan]) {
                                $age = [timespan]$ageProp.Value
                            }
                            elseif (-not [string]::IsNullOrWhiteSpace([string]$ageProp.Value)) {
                                $age = [timespan]::Parse([string]$ageProp.Value)
                            }
                        }

                        $statusProp = $remoteJob.PSObject.Properties['Status']
                        $status = if (
                            $null -ne $statusProp -and
                            $null -ne $statusProp.Value -and
                            -not [string]::IsNullOrWhiteSpace([string]$statusProp.Value)
                        ) {
                            [string]$statusProp.Value
                        }
                        else {
                            'Unknown'
                        }

                        $jobs.Add([PSCustomObject]@{
                            PSTypeName   = 'SpoolDoctor.PrintJob'
                            Id           = $jobId
                            PrinterName  = $jobPrinterName
                            Document     = $document
                            SizeBytes    = $sizeBytes
                            SubmittedAt  = $submittedAt
                            Age          = $age
                            Status       = $status
                            ComputerName = $targetComputerName
                        })
                    }

                    $message = if ($hasPrinterFilter) {
                        "Consulta remota de jobs concluída na máquina '$targetComputerName' para a impressora '$PrinterName'. Jobs encontrados: $($jobs.Count)."
                    }
                    else {
                        "Consulta remota de jobs concluída na máquina '$targetComputerName'. Jobs encontrados: $($jobs.Count)."
                    }
                }
            }
            catch {
                $outcome = 'Failed'
                $failureMessage = if ($hasPrinterFilter -and -not [string]::IsNullOrWhiteSpace($PrinterName)) {
                    "Falha ao listar jobs de impressão na máquina '$targetComputerName' para a impressora '$PrinterName': $($_.Exception.Message)"
                }
                else {
                    "Falha ao listar jobs de impressão na máquina '$targetComputerName': $($_.Exception.Message)"
                }
                $message = $failureMessage
            }
        }
        else {
            try {
                if ($hasPrinterFilter) {
                    if ([string]::IsNullOrWhiteSpace($PrinterName)) {
                        throw 'O parâmetro -PrinterName não pode conter apenas espaços em branco.'
                    }

                    $targetPrinters.Add($PrinterName)
                }
                else {
                    $rawPrinters = @(Get-SpoolerPrinterRaw)
                    foreach ($rawPrinter in $rawPrinters) {
                        if ($null -eq $rawPrinter) {
                            continue
                        }

                        $resolvedPrinterName = $null
                        if ($rawPrinter -is [string]) {
                            $resolvedPrinterName = $rawPrinter
                        }
                        else {
                            $nameProperty = $rawPrinter.PSObject.Properties['Name']
                            if ($null -ne $nameProperty -and $null -ne $nameProperty.Value) {
                                $resolvedPrinterName = [string]$nameProperty.Value
                            }
                        }

                        if (-not [string]::IsNullOrWhiteSpace($resolvedPrinterName)) {
                            $targetPrinters.Add($resolvedPrinterName)
                        }
                    }
                }

                foreach ($targetPrinter in $targetPrinters) {
                    $rawJobs = @(Get-SpoolerJobRaw -PrinterName $targetPrinter)
                    foreach ($rawJob in $rawJobs) {
                        if ($null -eq $rawJob) {
                            continue
                        }

                        $idProperty = $rawJob.PSObject.Properties['Id']
                        $jobId = if ($null -ne $idProperty -and $null -ne $idProperty.Value) {
                            $idProperty.Value
                        }
                        else {
                            $null
                        }

                        $printerProperty = $rawJob.PSObject.Properties['PrinterName']
                        $jobPrinterName = if (
                            $null -ne $printerProperty -and
                            $null -ne $printerProperty.Value -and
                            -not [string]::IsNullOrWhiteSpace([string]$printerProperty.Value)
                        ) {
                            [string]$printerProperty.Value
                        }
                        else {
                            $targetPrinter
                        }

                        $documentProperty = $rawJob.PSObject.Properties['DocumentName']
                        $document = if ($null -ne $documentProperty -and $null -ne $documentProperty.Value) {
                            [string]$documentProperty.Value
                        }
                        else {
                            $null
                        }

                        $sizeProperty = $rawJob.PSObject.Properties['Size']
                        $sizeBytes = if ($null -ne $sizeProperty -and $null -ne $sizeProperty.Value) {
                            [long]$sizeProperty.Value
                        }
                        else {
                            $null
                        }

                        $submittedProperty = $rawJob.PSObject.Properties['SubmittedTime']
                        $submittedAt = $null
                        if ($null -ne $submittedProperty -and $null -ne $submittedProperty.Value) {
                            if ($submittedProperty.Value -is [datetime]) {
                                $submittedAt = $submittedProperty.Value
                            }
                            elseif ($submittedProperty.Value -is [string] -and -not [string]::IsNullOrWhiteSpace($submittedProperty.Value)) {
                                $submittedAt = [datetime]$submittedProperty.Value
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

                        $statusProperty = $rawJob.PSObject.Properties['JobStatus']
                        $status = if (
                            $null -ne $statusProperty -and
                            $null -ne $statusProperty.Value -and
                            -not [string]::IsNullOrWhiteSpace($statusProperty.Value.ToString())
                        ) {
                            $statusProperty.Value.ToString()
                        }
                        else {
                            'Unknown'
                        }

                        $computerProperty = $rawJob.PSObject.Properties['ComputerName']
                        $jobComputerName = if (
                            $null -ne $computerProperty -and
                            $null -ne $computerProperty.Value -and
                            -not [string]::IsNullOrWhiteSpace([string]$computerProperty.Value)
                        ) {
                            [string]$computerProperty.Value
                        }
                        else {
                            $targetComputerName
                        }

                        $jobObject = [PSCustomObject]@{
                            PSTypeName   = 'SpoolDoctor.PrintJob'
                            Id           = $jobId
                            PrinterName  = $jobPrinterName
                            Document     = $document
                            SizeBytes    = $sizeBytes
                            SubmittedAt  = $submittedAt
                            Age          = $age
                            Status       = $status
                            ComputerName = $jobComputerName
                        }
                        $jobs.Add($jobObject)
                    }
                }

                $message = if ($hasPrinterFilter) {
                    "Consulta de jobs concluída na máquina '$targetComputerName' para a impressora '$PrinterName'. Jobs encontrados: $($jobs.Count)."
                }
                else {
                    "Consulta de jobs concluída na máquina '$targetComputerName'. Impressoras consultadas: $($targetPrinters.Count). Jobs encontrados: $($jobs.Count)."
                }
            }
            catch {
                $outcome = 'Failed'
                $failureMessage = if ($hasPrinterFilter -and -not [string]::IsNullOrWhiteSpace($PrinterName)) {
                    "Falha ao listar jobs de impressão na máquina '$targetComputerName' para a impressora '$PrinterName': $($_.Exception.Message)"
                }
                else {
                    "Falha ao listar jobs de impressão na máquina '$targetComputerName': $($_.Exception.Message)"
                }
                $message = $failureMessage
            }
        }

        $logParams = @{
            ComputerName = $targetComputerName
            Action       = $actionName
            Outcome      = $outcome
            Message      = $message
            Timestamp    = $now
        }
        if ($hasLogPath) {
            $logParams['LogPath'] = $LogPath
        }
        Write-SpoolDoctorLog @logParams

        if ($null -ne $failureMessage) {
            if ($isBatchMode) {
                $errorCategory = if ($outcome -eq 'Unreachable') {
                    [System.Management.Automation.ErrorCategory]::ConnectionError
                }
                else {
                    [System.Management.Automation.ErrorCategory]::NotSpecified
                }
                $exception = New-Object -TypeName 'System.InvalidOperationException' -ArgumentList $failureMessage
                $errorRecord = New-Object -TypeName 'System.Management.Automation.ErrorRecord' -ArgumentList @(
                    $exception,
                    "SpoolDoctor.$outcome",
                    $errorCategory,
                    $targetComputerName
                )
                $PSCmdlet.WriteError($errorRecord)
                continue
            }

            throw $failureMessage
        }

        foreach ($job in $jobs) {
            $job
        }
    }
}
