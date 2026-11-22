function Remove-SpoolerRemoteSession {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [object]$Session
    )

    $computerProp = $Session.PSObject.Properties['ComputerName']
    $target = if ($null -ne $computerProp -and -not [string]::IsNullOrWhiteSpace([string]$computerProp.Value)) {
        [string]$computerProp.Value
    }
    else {
        'Sessão WinRM'
    }

    if ($PSCmdlet.ShouldProcess($target, 'Encerrar sessão remota WinRM')) {
        Remove-PSSession -Session $Session -ErrorAction Stop
    }
}
