function Invoke-SpoolerRemoteScript {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [object]$Session,

        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [scriptblock]$ScriptBlock,

        [Parameter()]
        [object[]]$ArgumentList
    )

    $invokeParams = @{
        Session     = $Session
        ScriptBlock = $ScriptBlock
        ErrorAction = 'Stop'
    }
    if ($PSBoundParameters.ContainsKey('ArgumentList') -and $null -ne $ArgumentList -and $ArgumentList.Count -gt 0) {
        $invokeParams['ArgumentList'] = $ArgumentList
    }

    return (Invoke-Command @invokeParams)
}
