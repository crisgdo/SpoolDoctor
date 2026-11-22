Set-StrictMode -Version Latest

# Carrega os scripts internos (Private e Remote) antes das funções públicas (Public).
$scriptFolders = @('Private', 'Remote', 'Public')
$publicFunctions = @()

foreach ($folder in $scriptFolders) {
    $folderPath = Join-Path -Path $PSScriptRoot -ChildPath $folder
    if (-not (Test-Path -Path $folderPath -PathType Container)) {
        continue
    }

    $scriptFiles = @(
        Get-ChildItem -Path $folderPath -Filter '*.ps1' -File -ErrorAction Stop |
            Sort-Object -Property Name
    )

    foreach ($file in $scriptFiles) {
        try {
            . $file.FullName
        }
        catch {
            throw "Falha ao carregar o arquivo '$($file.FullName)': $($_.Exception.Message)"
        }

        if ($folder -eq 'Public') {
            $publicFunctions += $file.BaseName
        }
    }
}

# Exporta explicitamente apenas as funções encontradas em Public (ou nenhuma se a pasta estiver vazia).
if ($publicFunctions.Count -gt 0) {
    Export-ModuleMember -Function $publicFunctions
}
else {
    Export-ModuleMember
}
