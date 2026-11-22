function Remove-OldSpoolBackup {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$BackupRoot,

        [Parameter()]
        [ValidateRange(0, 365)]
        [int]$RetentionDays = 7
    )

    if ([string]::IsNullOrWhiteSpace($BackupRoot)) {
        throw 'O diretório raiz de backups não pode conter apenas espaços em branco.'
    }

    $trimmedRoot = $BackupRoot.Trim()
    if ($trimmedRoot -match '^[a-zA-Z]:[\\/]?$') {
        throw "Diretório raiz de backups inválido (raiz de unidade não é permitida): '$BackupRoot'."
    }

    $removedCount = 0
    $warnings = New-Object -TypeName 'System.Collections.Generic.List[string]'

    if ($RetentionDays -eq 0 -or -not (Test-Path -LiteralPath $trimmedRoot -PathType Container)) {
        return [PSCustomObject]@{
            RemovedCount = 0
            Warnings     = @()
        }
    }

    $rootItem = Get-Item -LiteralPath $trimmedRoot -ErrorAction Stop
    $resolvedRoot = [System.IO.Path]::GetFullPath($rootItem.FullName).TrimEnd('\', '/')
    $driveRoot = ([System.IO.Path]::GetPathRoot("$resolvedRoot\")).TrimEnd('\', '/')
    if ([string]::Equals($resolvedRoot, $driveRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Diretório raiz de backups inválido (raiz de unidade não é permitida): '$BackupRoot'."
    }

    $cutoff = (Get-Date).AddDays(-$RetentionDays)
    $subDirectories = @(Get-ChildItem -LiteralPath $resolvedRoot -Directory -ErrorAction Stop)

    foreach ($dir in $subDirectories) {
        if ($null -eq $dir) {
            continue
        }

        if ($dir.Name -notmatch '^\d{8}-\d{6}$') {
            continue
        }

        if (($dir.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            continue
        }

        $parsedDate = [datetime]::MinValue
        $parsedOk = [datetime]::TryParseExact(
            $dir.Name,
            'yyyyMMdd-HHmmss',
            [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::None,
            [ref]$parsedDate
        )
        if (-not $parsedOk -or $parsedDate -ge $cutoff) {
            continue
        }

        $fullChildPath = [System.IO.Path]::GetFullPath($dir.FullName)
        $parentPath = ([System.IO.Path]::GetDirectoryName($fullChildPath)).TrimEnd('\', '/')
        if (-not [string]::Equals($parentPath, $resolvedRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
            continue
        }

        if ($PSCmdlet.ShouldProcess($fullChildPath, 'Remover backup antigo do SpoolDoctor')) {
            try {
                Remove-Item -LiteralPath $fullChildPath -Recurse -Force -ErrorAction Stop
                $removedCount++
            }
            catch {
                $warnings.Add("Não foi possível remover o backup antigo '$($dir.Name)': $($_.Exception.Message)")
            }
        }
    }

    return [PSCustomObject]@{
        RemovedCount = $removedCount
        Warnings     = @($warnings)
    }
}
