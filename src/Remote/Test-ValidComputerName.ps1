function Test-ValidComputerName {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$ComputerName
    )

    if ([string]::IsNullOrWhiteSpace($ComputerName)) {
        return $false
    }

    if ($ComputerName.Trim() -ne $ComputerName) {
        return $false
    }

    if ($ComputerName.Length -gt 255) {
        return $false
    }

    if ($ComputerName -notmatch '^[A-Za-z0-9\-\.]+$') {
        return $false
    }

    if ($ComputerName.StartsWith('.') -or $ComputerName.EndsWith('.') -or $ComputerName.Contains('..')) {
        return $false
    }

    # Exige ao menos uma letra para bloquear IPs literais (ex.: 192.168.1.10 ou 127.0.0.1).
    if ($ComputerName -notmatch '[A-Za-z]') {
        return $false
    }

    $labels = $ComputerName.Split('.')
    foreach ($label in $labels) {
        if ([string]::IsNullOrEmpty($label) -or $label.Length -gt 63) {
            return $false
        }

        if ($label.StartsWith('-') -or $label.EndsWith('-')) {
            return $false
        }
    }

    return $true
}
