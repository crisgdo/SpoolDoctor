function Get-SpoolFile {
    [CmdletBinding()]
    [OutputType([System.IO.FileInfo[]])]
    param()

    $spoolDirectory = Get-SpoolDirectoryPath
    $files = @(
        Get-ChildItem -LiteralPath $spoolDirectory -File -ErrorAction Stop |
            Where-Object -FilterScript { $_.Extension -in @('.SPL', '.SHD') }
    )

    return $files
}
