function Start-SpoolerService {
    [CmdletBinding(SupportsShouldProcess)]
    param()

    if ($PSCmdlet.ShouldProcess('Spooler', 'Iniciar o serviço de Spooler de Impressão')) {
        Start-Service -Name 'Spooler' -ErrorAction Stop
    }
}
