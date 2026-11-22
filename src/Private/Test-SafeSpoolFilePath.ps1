function Test-SafeSpoolFilePath {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $false
    }

    if ($Path.Trim() -ne $Path) {
        return $false
    }

    if ($Path -match '[\*\?]') {
        return $false
    }

    # Exige caminho absoluto local com letra de drive (bloqueia relativos e UNC).
    if ($Path -notmatch '^[a-zA-Z]:[\\/]') {
        return $false
    }

    # Bloqueia explicitamente qualquer segmento de path traversal antes da normalização.
    $segments = @($Path -split '[\\/]')
    if ($segments -contains '..') {
        return $false
    }

    try {
        $fullPath = [System.IO.Path]::GetFullPath($Path)
    }
    catch {
        return $false
    }

    $directoryPath = [System.IO.Path]::GetDirectoryName($fullPath)
    if ([string]::IsNullOrEmpty($directoryPath)) {
        return $false
    }

    $expectedDirectory = (Get-SpoolDirectoryPath).TrimEnd('\', '/')
    $normalizedDirectory = $directoryPath.TrimEnd('\', '/')
    if (-not [string]::Equals($normalizedDirectory, $expectedDirectory, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $false
    }

    $fileName = [System.IO.Path]::GetFileName($fullPath)
    if ([string]::IsNullOrWhiteSpace($fileName) -or ($fileName.IndexOf(':') -ge 0)) {
        return $false
    }

    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($fullPath)
    if ([string]::IsNullOrWhiteSpace($baseName)) {
        return $false
    }

    $extension = [System.IO.Path]::GetExtension($fullPath)
    if ($extension -notin @('.SPL', '.SHD')) {
        return $false
    }

    return $true
}
