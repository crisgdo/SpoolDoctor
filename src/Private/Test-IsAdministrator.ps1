function Test-IsAdministrator {
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    if ($null -eq $identity) {
        return $false
    }

    $principal = New-Object -TypeName System.Security.Principal.WindowsPrincipal -ArgumentList $identity
    return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}
