function Get-RemoteFailureOutcome {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [System.Management.Automation.ErrorRecord]$ErrorRecord
    )

    $messages = New-Object -TypeName 'System.Collections.Generic.List[string]'
    $hasUnauthorizedException = $false
    $hasTransportException = $false
    $hasAccessDeniedErrorCode = $false

    $current = $ErrorRecord.Exception
    while ($null -ne $current) {
        if (-not [string]::IsNullOrWhiteSpace($current.Message)) {
            $messages.Add($current.Message)
        }

        if ($current -is [System.UnauthorizedAccessException] -or $current -is [System.Security.SecurityException]) {
            $hasUnauthorizedException = $true
        }

        if ($current -is [System.Management.Automation.Remoting.PSRemotingTransportException] -or $current -is [System.TimeoutException]) {
            $hasTransportException = $true
        }

        $errorCodeProp = $current.PSObject.Properties['ErrorCode']
        if ($null -ne $errorCodeProp -and $null -ne $errorCodeProp.Value) {
            $codeInt = [int]$errorCodeProp.Value
            if ($codeInt -in @(5, -2147024891, -2146893042)) {
                $hasAccessDeniedErrorCode = $true
            }
        }

        $current = $current.InnerException
    }

    $combinedMessage = $messages -join ' '
    $errorId = if ($null -ne $ErrorRecord.FullyQualifiedErrorId) { [string]$ErrorRecord.FullyQualifiedErrorId } else { '' }
    $category = if ($null -ne $ErrorRecord.CategoryInfo) { $ErrorRecord.CategoryInfo.Category } else { [System.Management.Automation.ErrorCategory]::NotSpecified }

    # Prioriza autenticação/permissão antes de transporte para que acesso negado no WinRM retorne Failed.
    if (
        $hasUnauthorizedException -or
        $hasAccessDeniedErrorCode -or
        $category -eq [System.Management.Automation.ErrorCategory]::PermissionDenied -or
        $category -eq [System.Management.Automation.ErrorCategory]::AuthenticationError -or
        $errorId -match 'AccessDenied|Unauthorized|Authentication' -or
        $combinedMessage -match 'access\s+is\s+denied|access.*denied|acesso\s+negado|unauthorized|logon\s+failure|erro\s+de\s+logon|authentication|credencial|permiss[aã]o\s+negada'
    ) {
        return 'Failed'
    }

    if (
        $hasTransportException -or
        $category -eq [System.Management.Automation.ErrorCategory]::OpenError -or
        $category -eq [System.Management.Automation.ErrorCategory]::ConnectionError -or
        $category -eq [System.Management.Automation.ErrorCategory]::OperationTimeout -or
        $errorId -match 'PSSessionOpenFailed|WinRM|WSMan|Timeout' -or
        $combinedMessage -match 'WinRM|WS-Management|WSMan|cannot\s+connect|n[aã]o\s+pode\s+concluir\s+a\s+opera[çc][aã]o|timed\s+out|tempo\s+limite|network\s+path|host.*not\s+found|inacess[ií]vel|Connecting\s+to\s+remote\s+server'
    ) {
        return 'Unreachable'
    }

    return 'Failed'
}
