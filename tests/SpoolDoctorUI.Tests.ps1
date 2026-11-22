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
            $ui.FilterTextBox | Should -BeOfType [System.Windows.Forms.TextBox]
            $ui.RefreshButton | Should -BeOfType [System.Windows.Forms.Button]
            $ui.Grid | Should -BeOfType [System.Windows.Forms.DataGridView]
            $ui.WhatIfCheckBox | Should -BeOfType [System.Windows.Forms.CheckBox]
            $ui.BackupCheckBox | Should -BeOfType [System.Windows.Forms.CheckBox]
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
}
