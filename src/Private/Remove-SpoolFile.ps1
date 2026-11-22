function Remove-SpoolFile {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Path
    )

    if (-not (Test-SafeSpoolFilePath -Path $Path)) {
        throw "Caminho recusado por segurança (permitidos apenas arquivos .SPL e .SHD na pasta PRINTERS): '$Path'."
    }

    if ($PSCmdlet.ShouldProcess($Path, 'Remover arquivo da fila de impressão')) {
        Remove-Item -LiteralPath $Path -Force -ErrorAction Stop
    }
}
