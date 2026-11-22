function New-SpoolerRemoteSession {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ComputerName,

        [Parameter()]
        [PSCredential]$Credential
    )

    if ($PSCmdlet.ShouldProcess($ComputerName, 'Abrir sessão remota WinRM')) {
        $sessionParams = @{
            ComputerName = $ComputerName
            ErrorAction  = 'Stop'
        }
        if ($PSBoundParameters.ContainsKey('Credential') -and $null -ne $Credential) {
            $sessionParams['Credential'] = $Credential
        }

        return (New-PSSession @sessionParams)
    }
}
