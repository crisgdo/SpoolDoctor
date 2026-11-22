function Get-SpoolerJobRaw {
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$PrinterName
    )

    $jobs = @(Get-PrintJob -PrinterName $PrinterName -ErrorAction Stop)
    return $jobs
}
