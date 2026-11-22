function Get-AllowedComputer {
    [CmdletBinding()]
    [OutputType([PSCustomObject[]])]
    param(
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$Path
    )

    if ($PSBoundParameters.ContainsKey('Path')) {
        if ([string]::IsNullOrWhiteSpace($Path)) {
            throw 'O caminho da allow-list não pode conter apenas espaços em branco.'
        }
        $resolvedPath = $Path.Trim()
    }
    else {
        $repoRoot = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent
        $resolvedPath = Join-Path -Path $repoRoot -ChildPath 'config\allowed-computers.txt'
    }

    if (-not (Test-Path -LiteralPath $resolvedPath -PathType Leaf)) {
        throw "Arquivo de allow-list não encontrado: '$resolvedPath'."
    }

    $lines = @(Get-Content -LiteralPath $resolvedPath -Encoding UTF8 -ErrorAction Stop)
    $lookup = @{}
    $entries = New-Object -TypeName 'System.Collections.Generic.List[PSCustomObject]'

    $lineNumber = 0
    foreach ($rawLine in $lines) {
        $lineNumber++
        if ($null -eq $rawLine) {
            continue
        }

        $trimmed = $rawLine.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed) -or $trimmed.StartsWith('#')) {
            continue
        }

        $parts = $trimmed.Split('|')
        if ($parts.Count -gt 2) {
            throw "Entrada malformada na allow-list '$resolvedPath' (linha $lineNumber): '$trimmed'."
        }

        $hostCandidate = $parts[0].Trim()
        if (-not (Test-ValidComputerName -ComputerName $hostCandidate)) {
            throw "Nome de computador inválido na allow-list '$resolvedPath' (linha $lineNumber): '$hostCandidate'."
        }

        $isPrintServer = $false
        if ($parts.Count -eq 2) {
            $tag = $parts[1].Trim()
            if (-not [string]::Equals($tag, 'PrintServer', [System.StringComparison]::OrdinalIgnoreCase)) {
                throw "Marcação desconhecida '$tag' na allow-list '$resolvedPath' (linha $lineNumber). Permitido apenas '|PrintServer'."
            }
            $isPrintServer = $true
        }

        if ($lookup.ContainsKey($hostCandidate)) {
            if ($isPrintServer) {
                $lookup[$hostCandidate].IsPrintServer = $true
            }
        }
        else {
            $entry = [PSCustomObject]@{
                PSTypeName    = 'SpoolDoctor.AllowedComputer'
                ComputerName  = $hostCandidate
                IsPrintServer = $isPrintServer
            }
            $lookup[$hostCandidate] = $entry
            $entries.Add($entry)
        }
    }

    return $entries.ToArray()
}
