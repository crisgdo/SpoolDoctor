function Get-SpoolerServiceStatus {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $service = Get-Service -Name 'Spooler' -ErrorAction Stop
    return $service.Status.ToString()
}
