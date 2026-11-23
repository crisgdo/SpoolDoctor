function Get-SpoolerAllowedComputer {
    [CmdletBinding()]
    [OutputType([PSCustomObject[]])]
    param(
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$AllowedComputersPath
    )

    $params = @{}
    if ($PSBoundParameters.ContainsKey('AllowedComputersPath')) {
        $params['Path'] = $AllowedComputersPath
    }

    return @(Get-AllowedComputer @params)
}
