function Remove-SpoolerJobRaw {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$PrinterName,

        [Parameter(Mandatory)]
        [ValidateRange(1, [int]::MaxValue)]
        [int]$Id
    )

    if ($PSCmdlet.ShouldProcess("$PrinterName (Job $Id)", 'Cancelar job de impressão')) {
        Remove-PrintJob -PrinterName $PrinterName -ID $Id -ErrorAction Stop
    }
}
