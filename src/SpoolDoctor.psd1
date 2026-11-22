@{
    RootModule        = 'SpoolDoctor.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = 'a8c4e2b1-7d3f-4c9a-9e52-1b6f0d8a3c4e'
    Author            = 'SpoolDoctor'
    CompanyName       = 'SpoolDoctor'
    Copyright         = '(c) SpoolDoctor. Todos os direitos reservados.'
    Description       = 'SpoolDoctor — ferramenta em PowerShell para diagnosticar e limpar a fila de impressão do Windows, local e remotamente.'
    PowerShellVersion = '5.1'

    # Preencher explicitamente com os nomes das funções de src/Public conforme forem criadas.
    FunctionsToExport = @('Get-SpoolerJob', 'Remove-SpoolerJob', 'Reset-Spooler')
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()

    PrivateData       = @{
        PSData = @{
            Tags = @('SpoolDoctor', 'Spooler', 'PrintQueue', 'Windows', 'PowerShell')
        }
    }
}
