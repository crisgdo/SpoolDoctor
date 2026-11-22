function Write-SpoolDoctorLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ComputerName,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Action,

        [Parameter(Mandatory)]
        [ValidateSet('OK', 'Failed', 'Unreachable', 'Skipped', 'Simulated')]
        [string]$Outcome,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Message,

        [Parameter()]
        [datetime]$Timestamp = (Get-Date),

        [Parameter()]
        [string]$UserName,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$LogPath
    )

    if ([string]::IsNullOrWhiteSpace($UserName)) {
        if (-not [string]::IsNullOrWhiteSpace($env:USERDOMAIN)) {
            $UserName = "$($env:USERDOMAIN)\$($env:USERNAME)"
        }
        else {
            $UserName = $env:USERNAME
        }
    }

    if (-not $PSBoundParameters.ContainsKey('LogPath')) {
        if ([string]::IsNullOrWhiteSpace($env:ProgramData)) {
            throw 'A variável de ambiente ProgramData não está definida para gravar o log.'
        }
        $LogPath = Join-Path -Path $env:ProgramData -ChildPath 'SpoolDoctor\logs\spooldoctor.log'
    }

    $logDirectory = Split-Path -Path $LogPath -Parent
    if (-not [string]::IsNullOrWhiteSpace($logDirectory)) {
        if (-not (Test-Path -LiteralPath $logDirectory -PathType Container)) {
            $null = New-Item -Path $logDirectory -ItemType Directory -Force -WhatIf:$false -Confirm:$false -ErrorAction Stop
        }
    }

    $isoTimestamp = $Timestamp.ToString('o')
    $singleLineMessage = ($Message -replace '[\r\n]+', ' ').Trim()
    $logEntry = '{0} | Computer={1} | User={2} | Action={3} | Outcome={4} | Message={5}' -f `
        $isoTimestamp, $ComputerName, $UserName, $Action, $Outcome, $singleLineMessage

    # Passa -WhatIf:$false -Confirm:$false para registrar simulações e explicita -Encoding UTF8 no PS 5.1.
    Add-Content -LiteralPath $LogPath -Value $logEntry -Encoding UTF8 -WhatIf:$false -Confirm:$false -ErrorAction Stop
}
