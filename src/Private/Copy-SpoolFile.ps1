function Copy-SpoolFile {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Path,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$DestinationDirectory
    )

    if (-not (Test-SafeSpoolFilePath -Path $Path)) {
        throw "Caminho recusado por segurança para backup (permitidos apenas arquivos .SPL e .SHD na pasta PRINTERS): '$Path'."
    }

    if ([string]::IsNullOrWhiteSpace($DestinationDirectory)) {
        throw 'O diretório de destino do backup não pode conter apenas espaços em branco.'
    }

    if ($PSCmdlet.ShouldProcess($Path, "Copiar arquivo da fila de impressão para '$DestinationDirectory'")) {
        if (-not (Test-Path -LiteralPath $DestinationDirectory -PathType Container)) {
            $null = New-Item -Path $DestinationDirectory -ItemType Directory -Force -ErrorAction Stop
        }

        Copy-Item -LiteralPath $Path -Destination $DestinationDirectory -Force -ErrorAction Stop
    }
}
