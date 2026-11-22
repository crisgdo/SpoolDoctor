function Get-SpoolerPrinterRaw {
    [CmdletBinding()]
    [OutputType([object[]])]
    param()

    $printers = @(Get-Printer -ErrorAction Stop)
    return $printers
}
