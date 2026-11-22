function Get-SpoolerJob {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$PrinterName,

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

    $actionName = 'Get-SpoolerJob'
    $now = Get-Date
    $hasPrinterFilter = $PSBoundParameters.ContainsKey('PrinterName')
    $jobs = New-Object -TypeName 'System.Collections.Generic.List[PSCustomObject]'
    $targetPrinters = New-Object -TypeName 'System.Collections.Generic.List[string]'
    $outcome = 'OK'
    $message = ''
    $failureMessage = $null

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
                    $computerName
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
            "Consulta de jobs concluída na máquina '$computerName' para a impressora '$PrinterName'. Jobs encontrados: $($jobs.Count)."
        }
        else {
            "Consulta de jobs concluída na máquina '$computerName'. Impressoras consultadas: $($targetPrinters.Count). Jobs encontrados: $($jobs.Count)."
        }
    }
    catch {
        $outcome = 'Failed'
        $failureMessage = if ($hasPrinterFilter -and -not [string]::IsNullOrWhiteSpace($PrinterName)) {
            "Falha ao listar jobs de impressão na máquina '$computerName' para a impressora '$PrinterName': $($_.Exception.Message)"
        }
        else {
            "Falha ao listar jobs de impressão na máquina '$computerName': $($_.Exception.Message)"
        }
        $message = $failureMessage
    }

    $logParams = @{
        ComputerName = $computerName
        Action       = $actionName
        Outcome      = $outcome
        Message      = $message
        Timestamp    = $now
    }
    if ($PSBoundParameters.ContainsKey('LogPath')) {
        $logParams['LogPath'] = $LogPath
    }
    Write-SpoolDoctorLog @logParams

    if ($null -ne $failureMessage) {
        throw $failureMessage
    }

    foreach ($job in $jobs) {
        $job
    }
}
