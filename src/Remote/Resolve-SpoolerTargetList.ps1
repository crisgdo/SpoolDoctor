function Resolve-SpoolerTargetList {
    [CmdletBinding()]
    [OutputType([PSCustomObject[]])]
    param(
        [Parameter()]
        [AllowNull()]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]]$ComputerName,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$AllowedComputersPath,

        [Parameter()]
        [switch]$HasCredential
    )

    $baseParams = @{
        HasCredential = [bool]$HasCredential
    }
    if ($PSBoundParameters.ContainsKey('AllowedComputersPath')) {
        $baseParams['AllowedComputersPath'] = $AllowedComputersPath
    }

    if (-not $PSBoundParameters.ContainsKey('ComputerName')) {
        $localTarget = Resolve-SpoolerTarget @baseParams
        return @($localTarget)
    }

    if ($null -eq $ComputerName -or $ComputerName.Count -eq 0) {
        return @(
            [PSCustomObject]@{
                IsValid             = $false
                IsLocal             = $false
                ComputerName        = '(inválido)'
                IsPrintServerListed = $false
                FailureOutcome      = 'Failed'
                ErrorMessage        = 'Lista de máquinas inválida em -ComputerName: informe ao menos um hostname ou FQDN válido.'
            }
        )
    }

    $targets = New-Object -TypeName 'System.Collections.Generic.List[PSCustomObject]'
    $seenValidTargets = New-Object -TypeName 'System.Collections.Generic.HashSet[string]' -ArgumentList ([System.StringComparer]::OrdinalIgnoreCase)
    $seenInvalidNamedTargets = New-Object -TypeName 'System.Collections.Generic.HashSet[string]' -ArgumentList ([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($rawComputerName in $ComputerName) {
        $targetParams = @{} + $baseParams
        $targetParams['ComputerName'] = $rawComputerName

        $resolved = Resolve-SpoolerTarget @targetParams
        $resolvedName = [string]$resolved.ComputerName

        if ([string]::Equals($resolvedName, '(inválido)', [System.StringComparison]::OrdinalIgnoreCase)) {
            $targets.Add($resolved)
            continue
        }

        if ($resolved.IsValid) {
            if ($seenValidTargets.Add($resolvedName)) {
                $targets.Add($resolved)
            }
        }
        elseif ($seenInvalidNamedTargets.Add($resolvedName)) {
            $targets.Add($resolved)
        }
    }

    return $targets.ToArray()
}
