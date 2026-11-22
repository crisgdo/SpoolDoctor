Describe 'SpoolDoctor - Interface WinForms e launcher (Operação 4)' {
    BeforeAll {
        $repoRoot = Split-Path -Path $PSScriptRoot -Parent
        $script:uiScriptPath = Join-Path -Path $repoRoot -ChildPath 'ui\SpoolDoctorUI.ps1'
        $script:launcherPath = Join-Path -Path $repoRoot -ChildPath 'Iniciar.bat'

        if (Get-Module -Name 'SpoolDoctor') {
            Remove-Module -Name 'SpoolDoctor' -Force -ErrorAction Stop
        }

        if (Test-Path -LiteralPath $script:uiScriptPath -PathType Leaf) {
            . $script:uiScriptPath -NoShow
        }

        function Get-SpoolDoctorControlVisibleFlag {
            param(
                [Parameter(Mandatory)]
                [System.Windows.Forms.Control]$Control
            )

            $parent = $Control.Parent
            if ($null -eq $parent) {
                return [bool]$Control.Visible
            }

            $parent.Controls.Remove($Control)
            try {
                return [bool]$Control.Visible
            }
            finally {
                $parent.Controls.Add($Control)
            }
        }
    }

    AfterAll {
        if (Get-Module -Name 'SpoolDoctor') {
            Remove-Module -Name 'SpoolDoctor' -Force -ErrorAction Stop
        }
    }

    BeforeEach {
        $script:logPath = Join-Path -Path 'TestDrive:\' -ChildPath ("ui-{0}.log" -f [guid]::NewGuid().ToString('N'))

        if (Get-Command -Name 'Get-SpoolerJob' -ErrorAction SilentlyContinue) {
            Mock Get-SpoolerJob { return @() }
        }
        if (Get-Command -Name 'Remove-SpoolerJob' -ErrorAction SilentlyContinue) {
            Mock Remove-SpoolerJob {
                return [PSCustomObject]@{
                    PSTypeName   = 'SpoolDoctor.ActionResult'
                    ComputerName = $env:COMPUTERNAME
                    Action       = 'Remove-SpoolerJob'
                    Outcome      = 'OK'
                    Message      = 'Job cancelado.'
                    Timestamp    = Get-Date
                }
            }
        }
        if (Get-Command -Name 'Reset-Spooler' -ErrorAction SilentlyContinue) {
            Mock Reset-Spooler {
                return [PSCustomObject]@{
                    PSTypeName   = 'SpoolDoctor.ActionResult'
                    ComputerName = $env:COMPUTERNAME
                    Action       = 'Reset-Spooler'
                    Outcome      = 'OK'
                    Message      = 'Spooler reiniciado.'
                    Timestamp    = Get-Date
                }
            }
        }
        if (Get-Command -Name 'Confirm-SpoolDoctorAction' -ErrorAction SilentlyContinue) {
            Mock Confirm-SpoolDoctorAction { return $false }
        }
        if (Get-Command -Name 'Test-SpoolDoctorElevated' -ErrorAction SilentlyContinue) {
            Mock Test-SpoolDoctorElevated { return $true }
        }
        if (Get-Command -Name 'Start-SpoolDoctorElevatedProcess' -ErrorAction SilentlyContinue) {
            Mock Start-SpoolDoctorElevatedProcess {}
        }
        if (Get-Command -Name 'Show-SpoolDoctorFormDialog' -ErrorAction SilentlyContinue) {
            Mock Show-SpoolDoctorFormDialog {}
        }
        if (Get-Command -Name 'Close-SpoolDoctorForm' -ErrorAction SilentlyContinue) {
            Mock Close-SpoolDoctorForm {}
        }
        if (Get-Command -Name 'Test-Spooler' -ErrorAction SilentlyContinue) {
            Mock Test-Spooler {
                return [PSCustomObject]@{
                    PSTypeName          = 'SpoolDoctor.Diagnostic'
                    ComputerName        = $env:COMPUTERNAME
                    ServiceStatus       = 'Running'
                    PrinterCount        = 1
                    UnhealthyPrinters   = @()
                    JobCount            = 0
                    StuckJobs           = @()
                    SpoolFileCount      = 0
                    HasOrphanSpoolFiles = $false
                    Health              = 'Healthy'
                    IsHealthy           = $true
                    Issues              = @()
                    Recommendation      = 'Spooler saudável. Nenhuma ação corretiva necessária.'
                    Timestamp           = Get-Date
                }
            }
        }
    }

    It 'possui ui/SpoolDoctorUI.ps1 válido no parser AST sem erros de sintaxe' {
        Test-Path -LiteralPath $script:uiScriptPath -PathType Leaf | Should -BeTrue

        $tokens = $null
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:uiScriptPath, [ref]$tokens, [ref]$parseErrors)

        $ast | Should -Not -BeNullOrEmpty
        $parseErrors.Count | Should -Be 0
    }

    It 'possui Iniciar.bat de uma linha com -STA, -ExecutionPolicy Bypass, caminho entre aspas e sem BOM ou UAC' {
        Test-Path -LiteralPath $script:launcherPath -PathType Leaf | Should -BeTrue

        $bytes = [System.IO.File]::ReadAllBytes($script:launcherPath)
        $hasUtf8Bom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
        $hasUtf8Bom | Should -BeFalse

        $lines = @(
            Get-Content -LiteralPath $script:launcherPath -Encoding UTF8 |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        )
        $lines.Count | Should -Be 1

        $line = $lines[0]
        $line | Should -Match 'powershell\.exe'
        $line | Should -Match '-NoProfile'
        $line | Should -Match '-ExecutionPolicy\s+Bypass'
        $line | Should -Match '-STA'
        $line | Should -Match '-WindowStyle\s+Hidden'
        $line | Should -Match '-File\s+"%~dp0ui\\SpoolDoctorUI\.ps1"'
        $line | Should -Not -Match 'RunAs|runas'
    }

    It 'mantém ui/SpoolDoctorUI.ps1 como camada fina sem cmdlets nativos proibidos nem Write-Host' {
        Test-Path -LiteralPath $script:uiScriptPath -PathType Leaf | Should -BeTrue

        $tokens = $null
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:uiScriptPath, [ref]$tokens, [ref]$parseErrors)
        $parseErrors.Count | Should -Be 0

        $commandNames = @(
            $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true) |
                ForEach-Object { $_.GetCommandName() } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                Select-Object -Unique
        )

        $forbiddenCommands = @(
            'Stop-Service',
            'Start-Service',
            'Remove-Item',
            'Copy-Item',
            'Get-PrintJob',
            'Remove-PrintJob',
            'Get-Printer',
            'Get-Service',
            'Write-Host'
        )
        foreach ($forbidden in $forbiddenCommands) {
            $commandNames | Should -Not -Contain $forbidden
        }

        $commandNames | Should -Contain 'Get-SpoolerJob'
        $commandNames | Should -Contain 'Remove-SpoolerJob'
        $commandNames | Should -Contain 'Reset-Spooler'
        $commandNames | Should -Contain 'Test-Spooler'
    }

    It 'formata tamanho, idade e ActionResult corretamente incluindo valores nulos' {
        (Format-SpoolerJobSize -SizeBytes $null) | Should -Be '-'
        (Format-SpoolerJobSize -SizeBytes 512) | Should -Be '512 B'
        (Format-SpoolerJobSize -SizeBytes 204800) | Should -Be '200,0 KB'
        (Format-SpoolerJobSize -SizeBytes 1572864) | Should -Be '1,5 MB'

        (Format-SpoolerJobAge -Age $null) | Should -Be '-'
        (Format-SpoolerJobAge -Age ([timespan]::FromSeconds(45))) | Should -Be '45s'
        (Format-SpoolerJobAge -Age ([timespan]::new(0, 15, 5))) | Should -Be '15m 05s'
        (Format-SpoolerJobAge -Age ([timespan]::new(2, 5, 0))) | Should -Be '2h 05m'
        (Format-SpoolerJobAge -Age ([timespan]::new(1, 3, 0, 0))) | Should -Be '1d 03h'

        $sampleResult = [PSCustomObject]@{
            Timestamp = [datetime]'2026-11-22T15:30:45'
            Action    = 'Remove-SpoolerJob'
            Outcome   = 'OK'
            Message   = 'Job 42 cancelado com sucesso.'
        }
        $formattedResult = Format-SpoolerActionResult -Result $sampleResult
        $formattedResult | Should -Be '[22/11/2026 15:30:45] [OK] (Remove-SpoolerJob) Job 42 cancelado com sucesso.'
    }

    It 'cria o formulário com controles principais e botão de cancelar desabilitado no estado inicial' {
        $form = Initialize-SpoolDoctorForm -LogPath $script:logPath
        try {
            $form | Should -BeOfType [System.Windows.Forms.Form]
            $ui = $form.Tag
            $ui | Should -Not -BeNullOrEmpty

            $ui.ComputerLabel.Text | Should -Match ([regex]::Escape($env:COMPUTERNAME))
            $form.Text | Should -Match 'Administrador'
            $ui.PrivilegeLabel | Should -BeOfType [System.Windows.Forms.Label]
            $ui.PrivilegeLabel.Text | Should -Match 'Administrador'
            $ui.ElevateButton | Should -BeOfType [System.Windows.Forms.Button]
            (Get-SpoolDoctorControlVisibleFlag -Control $ui.ElevateButton) | Should -BeFalse
            $ui.FilterTextBox | Should -BeOfType [System.Windows.Forms.TextBox]
            $ui.RefreshButton | Should -BeOfType [System.Windows.Forms.Button]
            $ui.Grid | Should -BeOfType [System.Windows.Forms.DataGridView]
            $ui.WhatIfCheckBox | Should -BeOfType [System.Windows.Forms.CheckBox]
            $ui.BackupCheckBox | Should -BeOfType [System.Windows.Forms.CheckBox]
            $ui.DiagnoseButton | Should -BeOfType [System.Windows.Forms.Button]
            $ui.CancelButton | Should -BeOfType [System.Windows.Forms.Button]
            $ui.ResetButton | Should -BeOfType [System.Windows.Forms.Button]
            $ui.StatusTextBox | Should -BeOfType [System.Windows.Forms.TextBox]

            $ui.Grid.ReadOnly | Should -BeTrue
            $ui.Grid.MultiSelect | Should -BeFalse
            $ui.Grid.SelectionMode | Should -Be ([System.Windows.Forms.DataGridViewSelectionMode]::FullRowSelect)
            $ui.Grid.AllowUserToAddRows | Should -BeFalse
            $ui.Grid.AllowUserToDeleteRows | Should -BeFalse
            $ui.Grid.Columns.Count | Should -Be 7

            $ui.StatusTextBox.ReadOnly | Should -BeTrue
            $ui.StatusTextBox.Multiline | Should -BeTrue

            $ui.CancelButton.Enabled | Should -BeFalse
            $ui.RefreshButton.Enabled | Should -BeTrue
            $ui.DiagnoseButton.Enabled | Should -BeTrue
            $ui.DiagnoseButton.Text | Should -Match 'Diagnosticar'
            $ui.ResetButton.Enabled | Should -BeTrue
            $ui.WhatIfCheckBox.Checked | Should -BeFalse
            $ui.BackupCheckBox.Checked | Should -BeTrue
            $ui.BackupCheckBox.Text | Should -Match 'backup'
            $form.UseWaitCursor | Should -BeFalse
        }
        finally {
            $form.Dispose()
        }
    }

    It 'popula a grade com jobs (incluindo campos nulos), aplica filtro e limpa seleção após atualizar' {
        $script:capturedPrinterFilter = $null
        $script:capturedRefreshLogPath = $null
        $script:mockJobs = @(
            [PSCustomObject]@{
                PSTypeName   = 'SpoolDoctor.PrintJob'
                Id           = 101
                PrinterName  = 'HP LaserJet'
                Document     = 'Relatorio.pdf'
                SizeBytes    = 204800L
                SubmittedAt  = [datetime]'2026-11-22T15:30:00'
                Age          = [timespan]::new(0, 15, 5)
                Status       = 'Printing'
                ComputerName = $env:COMPUTERNAME
            },
            [PSCustomObject]@{
                PSTypeName   = 'SpoolDoctor.PrintJob'
                Id           = 102
                PrinterName  = 'HP LaserJet'
                Document     = $null
                SizeBytes    = $null
                SubmittedAt  = $null
                Age          = $null
                Status       = 'Error'
                ComputerName = $env:COMPUTERNAME
            }
        )

        Mock Get-SpoolerJob {
            param([string]$PrinterName, [string]$LogPath)
            $script:capturedPrinterFilter = $PrinterName
            $script:capturedRefreshLogPath = $LogPath
            return $script:mockJobs
        }

        $form = Initialize-SpoolDoctorForm -LogPath $script:logPath
        try {
            $ui = $form.Tag
            $ui.FilterTextBox.Text = 'HP LaserJet'

            Invoke-SpoolDoctorRefresh -Form $form

            $script:capturedPrinterFilter | Should -Be 'HP LaserJet'
            $script:capturedRefreshLogPath | Should -Be $script:logPath

            $ui.Grid.Rows.Count | Should -Be 2
            $ui.Grid.Rows[0].Cells['Id'].Value | Should -Be 101
            $ui.Grid.Rows[0].Cells['PrinterName'].Value | Should -Be 'HP LaserJet'
            $ui.Grid.Rows[0].Cells['Document'].Value | Should -Be 'Relatorio.pdf'
            $ui.Grid.Rows[0].Cells['Status'].Value | Should -Be 'Printing'
            $ui.Grid.Rows[0].Cells['Size'].Value | Should -Be '200,0 KB'
            $ui.Grid.Rows[0].Cells['Age'].Value | Should -Be '15m 05s'
            $ui.Grid.Rows[0].Cells['SubmittedAt'].Value | Should -Be '22/11/2026 15:30:00'

            $ui.Grid.Rows[1].Cells['Id'].Value | Should -Be 102
            $ui.Grid.Rows[1].Cells['Document'].Value | Should -Be '-'
            $ui.Grid.Rows[1].Cells['Size'].Value | Should -Be '-'
            $ui.Grid.Rows[1].Cells['Age'].Value | Should -Be '-'
            $ui.Grid.Rows[1].Cells['SubmittedAt'].Value | Should -Be '-'

            $ui.Grid.SelectedRows.Count | Should -Be 0
            $ui.CancelButton.Enabled | Should -BeFalse
            $ui.RefreshButton.Enabled | Should -BeTrue
            $ui.ResetButton.Enabled | Should -BeTrue
            $form.UseWaitCursor | Should -BeFalse
            $ui.StatusTextBox.Text | Should -Match '2'
        }
        finally {
            $form.Dispose()
        }
    }

    It 'atualiza grade vazia sem erro e mantém botão de cancelar desabilitado' {
        $form = Initialize-SpoolDoctorForm -LogPath $script:logPath
        try {
            $ui = $form.Tag

            { Invoke-SpoolDoctorRefresh -Form $form } | Should -Not -Throw

            $ui.Grid.Rows.Count | Should -Be 0
            $ui.CancelButton.Enabled | Should -BeFalse
            $ui.RefreshButton.Enabled | Should -BeTrue
            $ui.ResetButton.Enabled | Should -BeTrue
            $form.UseWaitCursor | Should -BeFalse
            $ui.StatusTextBox.Text | Should -Match '0'
        }
        finally {
            $form.Dispose()
        }
    }

    It 'trata erro de Get-SpoolerJob sem quebrar a janela e exibe falha clara no status' {
        Mock Get-SpoolerJob {
            throw 'Falha simulada ao consultar o spooler.'
        }

        $form = Initialize-SpoolDoctorForm -LogPath $script:logPath
        try {
            $ui = $form.Tag

            { Invoke-SpoolDoctorRefresh -Form $form } | Should -Not -Throw

            $ui.Grid.Rows.Count | Should -Be 0
            $ui.StatusTextBox.Text | Should -Match 'Falha simulada ao consultar o spooler\.'
            $ui.CancelButton.Enabled | Should -BeFalse
            $ui.RefreshButton.Enabled | Should -BeTrue
            $ui.ResetButton.Enabled | Should -BeTrue
            $form.UseWaitCursor | Should -BeFalse
        }
        finally {
            $form.Dispose()
        }
    }

    It 'não chama Remove-SpoolerJob quando usuário recusa a confirmação de cancelamento' {
        $script:capturedConfirmMessage = $null
        Mock Get-SpoolerJob {
            return @(
                [PSCustomObject]@{
                    PSTypeName   = 'SpoolDoctor.PrintJob'
                    Id           = 42
                    PrinterName  = 'HP LaserJet'
                    Document     = 'Relatorio.pdf'
                    SizeBytes    = 1024L
                    SubmittedAt  = [datetime]'2026-11-22T15:00:00'
                    Age          = [timespan]::FromMinutes(3)
                    Status       = 'Paused'
                    ComputerName = $env:COMPUTERNAME
                }
            )
        }
        Mock Confirm-SpoolDoctorAction {
            param([string]$Title, [string]$Message, [string]$Icon)
            $script:capturedConfirmMessage = $Message
            return $false
        }

        $form = Initialize-SpoolDoctorForm -LogPath $script:logPath
        try {
            $ui = $form.Tag
            Invoke-SpoolDoctorRefresh -Form $form
            $ui.Grid.Rows[0].Selected = $true
            Sync-SpoolDoctorSelectionState -Form $form

            $ui.CancelButton.Enabled | Should -BeTrue

            Invoke-SpoolDoctorCancelJob -Form $form

            Should -Invoke Remove-SpoolerJob -Times 0 -Exactly
            $script:capturedConfirmMessage | Should -Match 'HP LaserJet'
            $script:capturedConfirmMessage | Should -Match '\b42\b'
            $script:capturedConfirmMessage | Should -Match 'Relatorio\.pdf'
            $ui.StatusTextBox.Text | Should -Match 'cancelad'
            $ui.RefreshButton.Enabled | Should -BeTrue
            $ui.ResetButton.Enabled | Should -BeTrue
            $form.UseWaitCursor | Should -BeFalse
        }
        finally {
            $form.Dispose()
        }
    }

    It 'chama Remove-SpoolerJob -WhatIf quando confirmação é aceita em modo simulação' {
        $script:capturedCancelConfirmMsg = $null
        $script:capturedCancelArgs = $null
        $script:capturedCancelWhatIfPref = $false

        Mock Get-SpoolerJob {
            return @(
                [PSCustomObject]@{
                    PSTypeName   = 'SpoolDoctor.PrintJob'
                    Id           = 42
                    PrinterName  = 'HP LaserJet'
                    Document     = 'Relatorio.pdf'
                    SizeBytes    = 1024L
                    SubmittedAt  = [datetime]'2026-11-22T15:00:00'
                    Age          = [timespan]::FromMinutes(3)
                    Status       = 'Paused'
                    ComputerName = $env:COMPUTERNAME
                }
            )
        }
        Mock Confirm-SpoolDoctorAction {
            param([string]$Title, [string]$Message, [string]$Icon)
            $script:capturedCancelConfirmMsg = $Message
            return $true
        }
        Mock Remove-SpoolerJob {
            param([string]$PrinterName, [int]$Id, [string]$LogPath)
            $script:capturedCancelArgs = @{} + $PSBoundParameters
            $script:capturedCancelWhatIfPref = [bool]$WhatIfPreference
            return [PSCustomObject]@{
                PSTypeName   = 'SpoolDoctor.ActionResult'
                ComputerName = $env:COMPUTERNAME
                Action       = 'Remove-SpoolerJob'
                Outcome      = 'Simulated'
                Message      = "Simulação (-WhatIf): job $Id simulado."
                Timestamp    = Get-Date
            }
        }

        $form = Initialize-SpoolDoctorForm -LogPath $script:logPath
        try {
            $ui = $form.Tag
            Invoke-SpoolDoctorRefresh -Form $form
            $ui.Grid.Rows[0].Selected = $true
            Sync-SpoolDoctorSelectionState -Form $form
            $ui.WhatIfCheckBox.Checked = $true

            Invoke-SpoolDoctorCancelJob -Form $form

            Should -Invoke Remove-SpoolerJob -Times 1 -Exactly
            $script:capturedCancelConfirmMsg | Should -Match 'simula|-WhatIf'
            $script:capturedCancelArgs['PrinterName'] | Should -Be 'HP LaserJet'
            $script:capturedCancelArgs['Id'] | Should -Be 42
            $script:capturedCancelArgs['LogPath'] | Should -Be $script:logPath
            $script:capturedCancelWhatIfPref | Should -BeTrue
            $ui.StatusTextBox.Text | Should -Match '\[Simulated\]'
            $ui.RefreshButton.Enabled | Should -BeTrue
            $ui.ResetButton.Enabled | Should -BeTrue
            $form.UseWaitCursor | Should -BeFalse
        }
        finally {
            $form.Dispose()
        }
    }

    It 'chama Remove-SpoolerJob -Confirm:$false quando confirmação é aceita em modo normal e atualiza grade' {
        $script:capturedNormalCancelConfirmPref = $null
        $script:capturedNormalCancelWhatIf = $false
        $script:getJobsCalls = 0

        Mock Get-SpoolerJob {
            $script:getJobsCalls++
            if ($script:getJobsCalls -eq 1) {
                return @(
                    [PSCustomObject]@{
                        PSTypeName   = 'SpoolDoctor.PrintJob'
                        Id           = 42
                        PrinterName  = 'HP LaserJet'
                        Document     = 'Relatorio.pdf'
                        SizeBytes    = 1024L
                        SubmittedAt  = [datetime]'2026-11-22T15:00:00'
                        Age          = [timespan]::FromMinutes(3)
                        Status       = 'Paused'
                        ComputerName = $env:COMPUTERNAME
                    }
                )
            }
            return @()
        }
        Mock Confirm-SpoolDoctorAction { return $true }
        Mock Remove-SpoolerJob {
            param([string]$PrinterName, [int]$Id, [string]$LogPath)
            $script:capturedNormalCancelConfirmPref = "$ConfirmPreference"
            $script:capturedNormalCancelWhatIf = [bool]$WhatIfPreference
            return [PSCustomObject]@{
                PSTypeName   = 'SpoolDoctor.ActionResult'
                ComputerName = $env:COMPUTERNAME
                Action       = 'Remove-SpoolerJob'
                Outcome      = 'OK'
                Message      = 'Job 42 cancelado com sucesso.'
                Timestamp    = Get-Date
            }
        }

        $form = Initialize-SpoolDoctorForm -LogPath $script:logPath
        try {
            $ui = $form.Tag
            Invoke-SpoolDoctorRefresh -Form $form
            $ui.Grid.Rows[0].Selected = $true
            Sync-SpoolDoctorSelectionState -Form $form
            $ui.WhatIfCheckBox.Checked = $false

            Invoke-SpoolDoctorCancelJob -Form $form

            Should -Invoke Remove-SpoolerJob -Times 1 -Exactly
            $script:capturedNormalCancelWhatIf | Should -BeFalse
            $script:capturedNormalCancelConfirmPref | Should -Be 'None'
            $ui.StatusTextBox.Text | Should -Match '\[OK\]'
            $ui.Grid.Rows.Count | Should -Be 0
            $ui.CancelButton.Enabled | Should -BeFalse
            $ui.RefreshButton.Enabled | Should -BeTrue
            $ui.ResetButton.Enabled | Should -BeTrue
            $form.UseWaitCursor | Should -BeFalse
        }
        finally {
            $form.Dispose()
        }
    }

    It 'não chama Reset-Spooler quando usuário recusa a confirmação mostrando a máquina de destino' {
        $script:capturedResetConfirmMsg = $null
        Mock Confirm-SpoolDoctorAction {
            param([string]$Title, [string]$Message, [string]$Icon)
            $script:capturedResetConfirmMsg = $Message
            return $false
        }

        $form = Initialize-SpoolDoctorForm -LogPath $script:logPath
        try {
            $ui = $form.Tag

            Invoke-SpoolDoctorReset -Form $form

            Should -Invoke Reset-Spooler -Times 0 -Exactly
            $script:capturedResetConfirmMsg | Should -Match ([regex]::Escape($env:COMPUTERNAME))
            $ui.StatusTextBox.Text | Should -Match 'cancelad'
            $ui.RefreshButton.Enabled | Should -BeTrue
            $ui.ResetButton.Enabled | Should -BeTrue
            $form.UseWaitCursor | Should -BeFalse
        }
        finally {
            $form.Dispose()
        }
    }

    It 'chama Reset-Spooler -WhatIf quando confirmação é aceita em modo simulação' {
        $script:capturedResetSimConfirmMsg = $null
        $script:capturedResetSimArgs = $null
        $script:capturedResetSimWhatIf = $false

        Mock Confirm-SpoolDoctorAction {
            param([string]$Title, [string]$Message, [string]$Icon)
            $script:capturedResetSimConfirmMsg = $Message
            return $true
        }
        Mock Reset-Spooler {
            param([string]$LogPath)
            $script:capturedResetSimArgs = @{} + $PSBoundParameters
            $script:capturedResetSimWhatIf = [bool]$WhatIfPreference
            return [PSCustomObject]@{
                PSTypeName   = 'SpoolDoctor.ActionResult'
                ComputerName = $env:COMPUTERNAME
                Action       = 'Reset-Spooler'
                Outcome      = 'Simulated'
                Message      = 'Simulação (-WhatIf): reset simulado.'
                Timestamp    = Get-Date
            }
        }

        $form = Initialize-SpoolDoctorForm -LogPath $script:logPath
        try {
            $ui = $form.Tag
            $ui.WhatIfCheckBox.Checked = $true

            Invoke-SpoolDoctorReset -Form $form

            Should -Invoke Reset-Spooler -Times 1 -Exactly
            $script:capturedResetSimConfirmMsg | Should -Match ([regex]::Escape($env:COMPUTERNAME))
            $script:capturedResetSimConfirmMsg | Should -Match 'simula|-WhatIf'
            $script:capturedResetSimArgs['LogPath'] | Should -Be $script:logPath
            $script:capturedResetSimWhatIf | Should -BeTrue
            $ui.StatusTextBox.Text | Should -Match '\[Simulated\]'
            $ui.RefreshButton.Enabled | Should -BeTrue
            $ui.ResetButton.Enabled | Should -BeTrue
            $form.UseWaitCursor | Should -BeFalse
        }
        finally {
            $form.Dispose()
        }
    }

    It 'chama Reset-Spooler -Confirm:$false quando confirmação é aceita sem simulação' {
        $script:capturedResetRealConfirmMsg = $null
        $script:capturedResetRealArgs = $null
        $script:capturedResetRealConfirmPref = $null
        $script:capturedResetRealWhatIf = $false

        Mock Confirm-SpoolDoctorAction {
            param([string]$Title, [string]$Message, [string]$Icon)
            $script:capturedResetRealConfirmMsg = $Message
            return $true
        }
        Mock Reset-Spooler {
            param([string]$LogPath)
            $script:capturedResetRealArgs = @{} + $PSBoundParameters
            $script:capturedResetRealConfirmPref = "$ConfirmPreference"
            $script:capturedResetRealWhatIf = [bool]$WhatIfPreference
            return [PSCustomObject]@{
                PSTypeName   = 'SpoolDoctor.ActionResult'
                ComputerName = $env:COMPUTERNAME
                Action       = 'Reset-Spooler'
                Outcome      = 'OK'
                Message      = 'Spooler reiniciado com sucesso.'
                Timestamp    = Get-Date
            }
        }

        $form = Initialize-SpoolDoctorForm -LogPath $script:logPath
        try {
            $ui = $form.Tag
            $ui.WhatIfCheckBox.Checked = $false
            $ui.BackupCheckBox.Checked = $true

            Invoke-SpoolDoctorReset -Form $form

            Should -Invoke Reset-Spooler -Times 1 -Exactly
            $script:capturedResetRealConfirmMsg | Should -Match 'SIM'
            $script:capturedResetRealWhatIf | Should -BeFalse
            $script:capturedResetRealConfirmPref | Should -Be 'None'
            $script:capturedResetRealArgs.ContainsKey('SkipBackup') | Should -BeFalse
            $script:capturedResetRealArgs['LogPath'] | Should -Be $script:logPath
            $ui.StatusTextBox.Text | Should -Match '\[OK\]'
            $ui.CancelButton.Enabled | Should -BeFalse
            $ui.RefreshButton.Enabled | Should -BeTrue
            $ui.ResetButton.Enabled | Should -BeTrue
            $form.UseWaitCursor | Should -BeFalse
        }
        finally {
            $form.Dispose()
        }
    }

    It 'chama Reset-Spooler com -SkipBackup quando BackupCheckBox está desmarcado' {
        $script:capturedSkipBackupConfirmMsg = $null
        $script:capturedSkipBackupArgs = $null

        Mock Confirm-SpoolDoctorAction {
            param([string]$Title, [string]$Message, [string]$Icon)
            $script:capturedSkipBackupConfirmMsg = $Message
            return $true
        }
        Mock Reset-Spooler {
            param([string]$LogPath, [switch]$SkipBackup)
            $script:capturedSkipBackupArgs = @{} + $PSBoundParameters
            return [PSCustomObject]@{
                PSTypeName   = 'SpoolDoctor.ActionResult'
                ComputerName = $env:COMPUTERNAME
                Action       = 'Reset-Spooler'
                Outcome      = 'OK'
                Message      = 'Spooler reiniciado sem backup (-SkipBackup).'
                Timestamp    = Get-Date
            }
        }

        $form = Initialize-SpoolDoctorForm -LogPath $script:logPath
        try {
            $ui = $form.Tag
            $ui.WhatIfCheckBox.Checked = $false
            $ui.BackupCheckBox.Checked = $false

            Invoke-SpoolDoctorReset -Form $form

            Should -Invoke Reset-Spooler -Times 1 -Exactly
            $script:capturedSkipBackupConfirmMsg | Should -Match 'SkipBackup|NÃO'
            $script:capturedSkipBackupArgs.ContainsKey('SkipBackup') | Should -BeTrue
            ([bool]$script:capturedSkipBackupArgs['SkipBackup']) | Should -BeTrue
            $ui.StatusTextBox.Text | Should -Match '\[OK\]'
            $ui.RefreshButton.Enabled | Should -BeTrue
            $ui.ResetButton.Enabled | Should -BeTrue
            $form.UseWaitCursor | Should -BeFalse
        }
        finally {
            $form.Dispose()
        }
    }

    It 'executa Invoke-SpoolDoctorDiagnose chamando Test-Spooler e exibe diagnóstico completo no painel de status' {
        $script:capturedDiagnoseLogPath = $null

        Mock Test-Spooler {
            param([string]$LogPath)
            $script:capturedDiagnoseLogPath = $LogPath
            return [PSCustomObject]@{
                PSTypeName          = 'SpoolDoctor.Diagnostic'
                ComputerName        = $env:COMPUTERNAME
                ServiceStatus       = 'Running'
                PrinterCount        = 2
                UnhealthyPrinters   = @()
                JobCount            = 1
                StuckJobs           = @(
                    [PSCustomObject]@{
                        Id          = 501
                        PrinterName = 'HP LaserJet'
                        Document    = 'Contrato.pdf'
                        Status      = 'Error'
                        Age         = [timespan]::FromMinutes(22)
                        Reason      = 'Status=Error; Idade=22m'
                    }
                )
                SpoolFileCount      = $null
                HasOrphanSpoolFiles = $false
                Health              = 'Warning'
                IsHealthy           = $false
                Issues              = @(
                    "Job 501 na impressora 'HP LaserJet' possivelmente travado.",
                    'Sem permissão para ler PRINTERS (execute como Administrador).'
                )
                Recommendation      = 'Tente cancelar os jobs travados com Remove-SpoolerJob antes de executar Reset-Spooler.'
                Timestamp           = [datetime]'2026-11-22T18:10:00'
            }
        }

        $form = Initialize-SpoolDoctorForm -LogPath $script:logPath
        try {
            $ui = $form.Tag

            Invoke-SpoolDoctorDiagnose -Form $form

            Should -Invoke Test-Spooler -Times 1 -Exactly
            $script:capturedDiagnoseLogPath | Should -Be $script:logPath
            $ui.StatusTextBox.Text | Should -Match 'Warning'
            $ui.StatusTextBox.Text | Should -Match 'sem permissão/indisponível'
            $ui.StatusTextBox.Text | Should -Match 'Job 501'
            $ui.StatusTextBox.Text | Should -Match 'Remove-SpoolerJob'
            $ui.DiagnoseButton.Enabled | Should -BeTrue
            $ui.RefreshButton.Enabled | Should -BeTrue
            $ui.ResetButton.Enabled | Should -BeTrue
            $form.UseWaitCursor | Should -BeFalse
        }
        finally {
            $form.Dispose()
        }
    }

    It 'trata erro de Test-Spooler em Invoke-SpoolDoctorDiagnose sem quebrar a janela' {
        Mock Test-Spooler {
            throw 'Falha simulada durante diagnóstico.'
        }

        $form = Initialize-SpoolDoctorForm -LogPath $script:logPath
        try {
            $ui = $form.Tag

            { Invoke-SpoolDoctorDiagnose -Form $form } | Should -Not -Throw

            $ui.StatusTextBox.Text | Should -Match 'Falha simulada durante diagnóstico\.'
            $ui.DiagnoseButton.Enabled | Should -BeTrue
            $ui.RefreshButton.Enabled | Should -BeTrue
            $ui.ResetButton.Enabled | Should -BeTrue
            $form.UseWaitCursor | Should -BeFalse
        }
        finally {
            $form.Dispose()
        }
    }

    It 'declara parâmetros de elevação na UI e SupportsShouldProcess no wrapper de RunAs' {
        $uiCommand = Get-Command -Name $script:uiScriptPath -ErrorAction Stop
        $uiCommand.Parameters.Keys | Should -Contain 'NoShow'
        $uiCommand.Parameters.Keys | Should -Contain 'NoElevate'
        $uiCommand.Parameters.Keys | Should -Contain 'ElevationAttempted'
        $uiCommand.Parameters.Keys | Should -Contain 'LogPath'

        $tokens = $null
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:uiScriptPath, [ref]$tokens, [ref]$parseErrors)
        $parseErrors.Count | Should -Be 0

        $elevateFnAst = $ast.Find({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'Start-SpoolDoctorElevatedProcess'
        }, $true)
        $elevateFnAst | Should -Not -BeNullOrEmpty

        $cmdletBindingAst = $elevateFnAst.Body.ParamBlock.Attributes |
            Where-Object { $_.TypeName.Name -eq 'CmdletBinding' } |
            Select-Object -First 1
        $cmdletBindingAst | Should -Not -BeNullOrEmpty

        $supportsArg = $cmdletBindingAst.NamedArguments |
            Where-Object { $_.ArgumentName -eq 'SupportsShouldProcess' } |
            Select-Object -First 1
        $supportsArg | Should -Not -BeNullOrEmpty
        ($supportsArg.ExpressionOmitted -or $supportsArg.Argument.ToString() -match 'true') | Should -BeTrue
    }

    It 'monta argumentos de elevação com caminho entre aspas, -STA, -ElevationAttempted e -LogPath opcional' {
        $spaceScriptPath = 'D:\Pasta Com Espaços\ui\SpoolDoctorUI.ps1'
        $argsWithoutLog = @(Get-SpoolDoctorElevationArgumentList -ScriptPath $spaceScriptPath)

        $argsWithoutLog | Should -Contain '-NoProfile'
        $argsWithoutLog | Should -Contain '-ExecutionPolicy'
        $argsWithoutLog | Should -Contain 'Bypass'
        $argsWithoutLog | Should -Contain '-STA'
        $argsWithoutLog | Should -Contain '-WindowStyle'
        $argsWithoutLog | Should -Contain 'Hidden'
        $argsWithoutLog | Should -Contain '-File'
        $argsWithoutLog | Should -Contain ('"{0}"' -f $spaceScriptPath)
        $argsWithoutLog | Should -Contain '-ElevationAttempted'
        $argsWithoutLog | Should -Not -Contain '-LogPath'

        $staIndex = [Array]::IndexOf($argsWithoutLog, '-STA')
        $fileIndex = [Array]::IndexOf($argsWithoutLog, '-File')
        $attemptIndex = [Array]::IndexOf($argsWithoutLog, '-ElevationAttempted')
        $staIndex | Should -BeLessThan $fileIndex
        $argsWithoutLog[$fileIndex + 1] | Should -Be ('"{0}"' -f $spaceScriptPath)
        $attemptIndex | Should -BeGreaterThan $fileIndex

        $spaceLogPath = 'C:\Logs Com Espaço\spooldoctor.log'
        $argsWithLog = @(Get-SpoolDoctorElevationArgumentList -ScriptPath $spaceScriptPath -LogPath $spaceLogPath)

        $logFlagIndex = [Array]::IndexOf($argsWithLog, '-LogPath')
        $logFlagIndex | Should -BeGreaterThan $fileIndex
        $argsWithLog[$logFlagIndex + 1] | Should -Be ('"{0}"' -f $spaceLogPath)
    }

    It 'não tenta relançar quando sessão já está elevada como Administrador' {
        $script:capturedElevatedUiState = $null

        Mock Import-SpoolDoctorModule {}
        Mock Show-SpoolDoctorFormDialog {
            param([System.Windows.Forms.Form]$Form)
            $script:capturedElevatedUiState = [PSCustomObject]@{
                Title          = $Form.Text
                PrivilegeText  = $Form.Tag.PrivilegeLabel.Text
                ElevateVisible = Get-SpoolDoctorControlVisibleFlag -Control $Form.Tag.ElevateButton
                ResetEnabled   = $Form.Tag.ResetButton.Enabled
            }
        }

        $elevationResult = Request-SpoolDoctorElevation -ScriptPath $script:uiScriptPath
        $elevationResult.Outcome | Should -Be 'AlreadyElevated'
        $elevationResult.ShouldExitCurrentProcess | Should -BeFalse

        Show-SpoolDoctorUI -ScriptPath $script:uiScriptPath -LogPath $script:logPath

        Should -Invoke Start-SpoolDoctorElevatedProcess -Times 0 -Exactly
        Should -Invoke Show-SpoolDoctorFormDialog -Times 1 -Exactly
        $script:capturedElevatedUiState | Should -Not -BeNullOrEmpty
        $script:capturedElevatedUiState.Title | Should -Match 'Administrador'
        $script:capturedElevatedUiState.PrivilegeText | Should -Match 'Administrador'
        $script:capturedElevatedUiState.ElevateVisible | Should -BeFalse
        $script:capturedElevatedUiState.ResetEnabled | Should -BeTrue
    }

    It 'dispara elevação UAC na inicialização quando não é Administrador e encerra instância atual sem abrir janela duplicada' {
        $script:capturedLaunchArgs = $null

        Mock Test-SpoolDoctorElevated { return $false }
        Mock Import-SpoolDoctorModule {}
        Mock Initialize-SpoolDoctorForm { throw 'Não deveria criar a janela quando o relançamento UAC ocorre.' }
        Mock Start-SpoolDoctorElevatedProcess {
            param([string[]]$ArgumentList)
            $script:capturedLaunchArgs = @($ArgumentList)
        }

        { Show-SpoolDoctorUI -ScriptPath $script:uiScriptPath -LogPath $script:logPath } | Should -Not -Throw

        Should -Invoke Start-SpoolDoctorElevatedProcess -Times 1 -Exactly
        Should -Invoke Initialize-SpoolDoctorForm -Times 0 -Exactly
        Should -Invoke Show-SpoolDoctorFormDialog -Times 0 -Exactly

        $script:capturedLaunchArgs | Should -Not -BeNullOrEmpty
        $script:capturedLaunchArgs | Should -Contain '-NoProfile'
        $script:capturedLaunchArgs | Should -Contain '-ExecutionPolicy'
        $script:capturedLaunchArgs | Should -Contain 'Bypass'
        $script:capturedLaunchArgs | Should -Contain '-STA'
        $script:capturedLaunchArgs | Should -Contain '-WindowStyle'
        $script:capturedLaunchArgs | Should -Contain 'Hidden'
        $script:capturedLaunchArgs | Should -Contain '-File'
        $script:capturedLaunchArgs | Should -Contain ('"{0}"' -f $script:uiScriptPath)
        $script:capturedLaunchArgs | Should -Contain '-ElevationAttempted'
        $script:capturedLaunchArgs | Should -Contain '-LogPath'
        $script:capturedLaunchArgs | Should -Contain ('"{0}"' -f $script:logPath)

        $staIdx = [Array]::IndexOf($script:capturedLaunchArgs, '-STA')
        $fileIdx = [Array]::IndexOf($script:capturedLaunchArgs, '-File')
        $attemptIdx = [Array]::IndexOf($script:capturedLaunchArgs, '-ElevationAttempted')
        $logIdx = [Array]::IndexOf($script:capturedLaunchArgs, '-LogPath')
        $staIdx | Should -BeLessThan $fileIdx
        $script:capturedLaunchArgs[$fileIdx + 1] | Should -Be ('"{0}"' -f $script:uiScriptPath)
        $attemptIdx | Should -BeGreaterThan $fileIdx
        $script:capturedLaunchArgs[$logIdx + 1] | Should -Be ('"{0}"' -f $script:logPath)
    }

    It 'trata cancelamento do UAC (Win32Exception 1223 direto, cadeia InnerException e OperationCanceledException) e abre em modo somente leitura' {
        $script:uacAttemptCounter = 0
        $script:cancelScenario = 'DirectWin32'
        $script:capturedCanceledUiState = $null

        Mock Test-SpoolDoctorElevated { return $false }
        Mock Import-SpoolDoctorModule {}
        Mock Start-SpoolDoctorElevatedProcess {
            $script:uacAttemptCounter++
            switch ($script:cancelScenario) {
                'DirectWin32' {
                    throw (New-Object -TypeName System.ComponentModel.Win32Exception -ArgumentList 1223)
                }
                'NestedInnerWin32' {
                    $rootWin32 = New-Object -TypeName System.ComponentModel.Win32Exception -ArgumentList 1223
                    $midEx = New-Object -TypeName System.Exception -ArgumentList @('Camada intermediária', $rootWin32)
                    throw (New-Object -TypeName System.InvalidOperationException -ArgumentList @('Falha externa ao iniciar processo', $midEx))
                }
                'OperationCanceled' {
                    throw (New-Object -TypeName System.OperationCanceledException -ArgumentList 'Elevação cancelada.')
                }
            }
        }
        Mock Show-SpoolDoctorFormDialog {
            param([System.Windows.Forms.Form]$Form)
            $script:capturedCanceledUiState = [PSCustomObject]@{
                Title           = $Form.Text
                PrivilegeText   = $Form.Tag.PrivilegeLabel.Text
                ElevateVisible  = Get-SpoolDoctorControlVisibleFlag -Control $Form.Tag.ElevateButton
                ElevateEnabled  = $Form.Tag.ElevateButton.Enabled
                RefreshEnabled  = $Form.Tag.RefreshButton.Enabled
                DiagnoseEnabled = $Form.Tag.DiagnoseButton.Enabled
                ResetEnabled    = $Form.Tag.ResetButton.Enabled
                CancelEnabled   = $Form.Tag.CancelButton.Enabled
                StatusText      = $Form.Tag.StatusTextBox.Text
            }
        }

        foreach ($scenario in @('DirectWin32', 'NestedInnerWin32', 'OperationCanceled')) {
            $script:cancelScenario = $scenario
            $script:uacAttemptCounter = 0

            $res = Request-SpoolDoctorElevation -ScriptPath $script:uiScriptPath
            $script:uacAttemptCounter | Should -Be 1
            $res.Outcome | Should -Be 'Canceled'
            $res.ShouldExitCurrentProcess | Should -BeFalse
            $res.Message | Should -Match 'cancelad|recusad'
            $res.Message | Should -Match 'somente leitura'
        }

        $script:cancelScenario = 'NestedInnerWin32'
        $script:uacAttemptCounter = 0

        { Show-SpoolDoctorUI -ScriptPath $script:uiScriptPath -LogPath $script:logPath } | Should -Not -Throw

        $script:uacAttemptCounter | Should -Be 1
        Should -Invoke Start-SpoolDoctorElevatedProcess -Times 4 -Exactly
        Should -Invoke Show-SpoolDoctorFormDialog -Times 1 -Exactly

        $script:capturedCanceledUiState | Should -Not -BeNullOrEmpty
        $script:capturedCanceledUiState.Title | Should -Match 'Usuário padrão'
        $script:capturedCanceledUiState.PrivilegeText | Should -Match 'Usuário padrão'
        $script:capturedCanceledUiState.ElevateVisible | Should -BeTrue
        $script:capturedCanceledUiState.ElevateEnabled | Should -BeTrue
        $script:capturedCanceledUiState.RefreshEnabled | Should -BeTrue
        $script:capturedCanceledUiState.DiagnoseEnabled | Should -BeTrue
        $script:capturedCanceledUiState.ResetEnabled | Should -BeFalse
        $script:capturedCanceledUiState.CancelEnabled | Should -BeFalse
        $script:capturedCanceledUiState.StatusText | Should -Match 'cancelad|recusad'
    }

    It 'trata falha inesperada ao relançar sem entrar em loop e abre em modo somente leitura com detalhe do erro' {
        $script:capturedFailedUiState = $null

        Mock Test-SpoolDoctorElevated { return $false }
        Mock Import-SpoolDoctorModule {}
        Mock Start-SpoolDoctorElevatedProcess {
            throw (New-Object -TypeName System.ComponentModel.Win32Exception -ArgumentList 5)
        }
        Mock Show-SpoolDoctorFormDialog {
            param([System.Windows.Forms.Form]$Form)
            $script:capturedFailedUiState = [PSCustomObject]@{
                ResetEnabled   = $Form.Tag.ResetButton.Enabled
                ElevateVisible = Get-SpoolDoctorControlVisibleFlag -Control $Form.Tag.ElevateButton
                StatusText     = $Form.Tag.StatusTextBox.Text
            }
        }

        $res = Request-SpoolDoctorElevation -ScriptPath $script:uiScriptPath
        $res.Outcome | Should -Be 'Failed'
        $res.ShouldExitCurrentProcess | Should -BeFalse

        { Show-SpoolDoctorUI -ScriptPath $script:uiScriptPath -LogPath $script:logPath } | Should -Not -Throw

        Should -Invoke Start-SpoolDoctorElevatedProcess -Times 2 -Exactly
        Should -Invoke Show-SpoolDoctorFormDialog -Times 1 -Exactly
        $script:capturedFailedUiState.ResetEnabled | Should -BeFalse
        $script:capturedFailedUiState.ElevateVisible | Should -BeTrue
        $script:capturedFailedUiState.StatusText | Should -Match 'Falha|Não foi possível'
    }

    It 'respeita trava anti-loop (-ElevationAttempted) e -NoElevate sem tentar relançar' {
        $script:capturedAntiLoopUiState = $null

        Mock Test-SpoolDoctorElevated { return $false }
        Mock Import-SpoolDoctorModule {}
        Mock Show-SpoolDoctorFormDialog {
            param([System.Windows.Forms.Form]$Form)
            $script:capturedAntiLoopUiState = [PSCustomObject]@{
                Title          = $Form.Text
                ResetEnabled   = $Form.Tag.ResetButton.Enabled
                ElevateVisible = Get-SpoolDoctorControlVisibleFlag -Control $Form.Tag.ElevateButton
                StatusText     = $Form.Tag.StatusTextBox.Text
            }
        }

        $antiLoopResult = Request-SpoolDoctorElevation -ScriptPath $script:uiScriptPath -ElevationAttempted
        $antiLoopResult.Outcome | Should -Be 'Skipped'
        $antiLoopResult.ShouldExitCurrentProcess | Should -BeFalse

        $noElevateResult = Request-SpoolDoctorElevation -ScriptPath $script:uiScriptPath -NoElevate
        $noElevateResult.Outcome | Should -Be 'Skipped'
        $noElevateResult.ShouldExitCurrentProcess | Should -BeFalse

        { Show-SpoolDoctorUI -ScriptPath $script:uiScriptPath -ElevationAttempted -LogPath $script:logPath } | Should -Not -Throw
        $script:capturedAntiLoopUiState.Title | Should -Match 'Usuário padrão'
        $script:capturedAntiLoopUiState.ResetEnabled | Should -BeFalse
        $script:capturedAntiLoopUiState.ElevateVisible | Should -BeTrue
        $script:capturedAntiLoopUiState.StatusText | Should -Match 'elevação|Administrador|somente leitura'

        { Show-SpoolDoctorUI -ScriptPath $script:uiScriptPath -NoElevate -LogPath $script:logPath } | Should -Not -Throw

        Should -Invoke Start-SpoolDoctorElevatedProcess -Times 0 -Exactly
        Should -Invoke Show-SpoolDoctorFormDialog -Times 2 -Exactly
    }

    It 'executa com -NoShow em processo filho sem tentar elevar nem abrir janela' {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File $script:uiScriptPath -NoShow
        $LASTEXITCODE | Should -Be 0
    }

    It 'mantém Cancelar e Resetar desabilitados em modo somente leitura mesmo após atualizar grade, selecionar job e diagnosticar' {
        Mock Test-SpoolDoctorElevated { return $false }
        Mock Get-SpoolerJob {
            return @(
                [PSCustomObject]@{
                    PSTypeName   = 'SpoolDoctor.PrintJob'
                    Id           = 77
                    PrinterName  = 'HP LaserJet'
                    Document     = 'NotaFiscal.pdf'
                    SizeBytes    = 4096L
                    SubmittedAt  = [datetime]'2026-11-22T18:00:00'
                    Age          = [timespan]::FromMinutes(5)
                    Status       = 'Printing'
                    ComputerName = $env:COMPUTERNAME
                }
            )
        }

        $form = Initialize-SpoolDoctorForm -ScriptPath $script:uiScriptPath -LogPath $script:logPath -StartupNotice 'Sessão em modo somente leitura.'
        try {
            $ui = $form.Tag
            $form.Text | Should -Match 'Usuário padrão'
            $ui.PrivilegeLabel.Text | Should -Match 'Usuário padrão'
            (Get-SpoolDoctorControlVisibleFlag -Control $ui.ElevateButton) | Should -BeTrue
            $ui.ElevateButton.Enabled | Should -BeTrue
            $ui.ResetButton.Enabled | Should -BeFalse
            $ui.CancelButton.Enabled | Should -BeFalse
            $ui.StatusTextBox.Text | Should -Match 'Sessão em modo somente leitura\.'

            Invoke-SpoolDoctorRefresh -Form $form -PreserveStatus:(-not [string]::IsNullOrWhiteSpace([string]$ui.StartupNotice))
            $ui.StatusTextBox.Text | Should -Match 'Sessão em modo somente leitura\.'
            $ui.Grid.Rows.Count | Should -Be 1

            $ui.Grid.Rows[0].Selected = $true
            Sync-SpoolDoctorSelectionState -Form $form

            $ui.CancelButton.Enabled | Should -BeFalse
            $ui.ResetButton.Enabled | Should -BeFalse
            $ui.RefreshButton.Enabled | Should -BeTrue
            $ui.DiagnoseButton.Enabled | Should -BeTrue
            $ui.ElevateButton.Enabled | Should -BeTrue

            Invoke-SpoolDoctorDiagnose -Form $form
            Should -Invoke Test-Spooler -Times 1 -Exactly
            $ui.CancelButton.Enabled | Should -BeFalse
            $ui.ResetButton.Enabled | Should -BeFalse
            $ui.RefreshButton.Enabled | Should -BeTrue
            $ui.DiagnoseButton.Enabled | Should -BeTrue
            $ui.ElevateButton.Enabled | Should -BeTrue
        }
        finally {
            $form.Dispose()
        }
    }

    It 'permite elevação manual via Invoke-SpoolDoctorElevate quando aceita e trata recusa ou sessão já elevada' {
        $script:manualElevateArgs = $null

        Mock Test-SpoolDoctorElevated { return $false }
        Mock Start-SpoolDoctorElevatedProcess {
            param([string[]]$ArgumentList)
            $script:manualElevateArgs = @($ArgumentList)
        }

        $form = Initialize-SpoolDoctorForm -ScriptPath $script:uiScriptPath -LogPath $script:logPath
        try {
            Invoke-SpoolDoctorElevate -Form $form

            Should -Invoke Start-SpoolDoctorElevatedProcess -Times 1 -Exactly
            Should -Invoke Close-SpoolDoctorForm -Times 1 -Exactly
            $script:manualElevateArgs | Should -Contain '-ElevationAttempted'
            $script:manualElevateArgs | Should -Contain '-LogPath'
            $script:manualElevateArgs | Should -Contain ('"{0}"' -f $script:logPath)
        }
        finally {
            $form.Dispose()
        }

        Mock Start-SpoolDoctorElevatedProcess {
            $innerWin32 = New-Object -TypeName System.ComponentModel.Win32Exception -ArgumentList 1223
            throw (New-Object -TypeName System.Exception -ArgumentList @('Recusado pelo UAC', $innerWin32))
        }

        $formCanceled = Initialize-SpoolDoctorForm -ScriptPath $script:uiScriptPath -LogPath $script:logPath
        try {
            $uiCanceled = $formCanceled.Tag
            { Invoke-SpoolDoctorElevate -Form $formCanceled } | Should -Not -Throw

            Should -Invoke Close-SpoolDoctorForm -Times 1 -Exactly
            $uiCanceled.StatusTextBox.Text | Should -Match 'cancelad|recusad'
            $uiCanceled.RefreshButton.Enabled | Should -BeTrue
            $uiCanceled.DiagnoseButton.Enabled | Should -BeTrue
            $uiCanceled.ElevateButton.Enabled | Should -BeTrue
            $uiCanceled.CancelButton.Enabled | Should -BeFalse
            $uiCanceled.ResetButton.Enabled | Should -BeFalse
            $formCanceled.UseWaitCursor | Should -BeFalse
        }
        finally {
            $formCanceled.Dispose()
        }

        Mock Test-SpoolDoctorElevated { return $true }
        $formAlreadyAdmin = Initialize-SpoolDoctorForm -ScriptPath $script:uiScriptPath -LogPath $script:logPath
        try {
            $uiAdmin = $formAlreadyAdmin.Tag
            Invoke-SpoolDoctorElevate -Form $formAlreadyAdmin

            Should -Invoke Close-SpoolDoctorForm -Times 1 -Exactly
            Should -Invoke Start-SpoolDoctorElevatedProcess -Times 2 -Exactly
            $uiAdmin.StatusTextBox.Text | Should -Match 'Administrador'
        }
        finally {
            $formAlreadyAdmin.Dispose()
        }
    }
}
