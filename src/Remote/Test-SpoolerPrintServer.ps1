function Test-SpoolerPrintServer {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param()

    $reasons = New-Object -TypeName 'System.Collections.Generic.List[string]'

    $os = Get-CimInstance -ClassName 'Win32_OperatingSystem' -ErrorAction Stop
    if ($null -ne $os) {
        $productTypeProp = $os.PSObject.Properties['ProductType']
        if ($null -ne $productTypeProp -and $null -ne $productTypeProp.Value) {
            $productType = [int]$productTypeProp.Value
            if ($productType -in @(2, 3)) {
                $reasons.Add("sistema operacional Windows Server (ProductType=$productType)")
            }
        }
    }

    $serviceStatus = [string](Get-SpoolerServiceStatus)
    if ($serviceStatus -eq 'Running') {
        $printers = @(Get-SpoolerPrinterRaw)
        $sharedNames = New-Object -TypeName 'System.Collections.Generic.List[string]'

        foreach ($printer in $printers) {
            if ($null -eq $printer) {
                continue
            }

            $sharedProp = $printer.PSObject.Properties['Shared']
            if ($null -ne $sharedProp -and $null -ne $sharedProp.Value -and [bool]$sharedProp.Value) {
                $nameProp = $printer.PSObject.Properties['Name']
                $printerName = if ($null -ne $nameProp -and -not [string]::IsNullOrWhiteSpace([string]$nameProp.Value)) {
                    [string]$nameProp.Value
                }
                else {
                    '(sem nome)'
                }
                $sharedNames.Add($printerName)
            }
        }

        if ($sharedNames.Count -gt 0) {
            $reasons.Add("impressora(s) compartilhada(s): $($sharedNames -join ', ')")
        }
    }

    return [PSCustomObject]@{
        IsPrintServer = ($reasons.Count -gt 0)
        Reasons       = @($reasons)
    }
}
