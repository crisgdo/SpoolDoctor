function Get-SpoolDirectoryPath {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    if ([string]::IsNullOrWhiteSpace($env:SystemRoot)) {
        throw 'A variável de ambiente SystemRoot não está definida.'
    }

    $rawPath = Join-Path -Path $env:SystemRoot -ChildPath 'System32\spool\PRINTERS'
    return [System.IO.Path]::GetFullPath($rawPath)
}
