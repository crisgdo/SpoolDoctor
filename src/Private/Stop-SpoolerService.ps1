function Stop-SpoolerService {
    [CmdletBinding(SupportsShouldProcess)]
    param()

    if ($PSCmdlet.ShouldProcess('Spooler', 'Parar o serviço de Spooler de Impressão')) {
        Stop-Service -Name 'Spooler' -ErrorAction Stop
    }
}
