[CmdletBinding()]
param(
    [Parameter()]
    [switch]$NoShow,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$LogPath
)

Set-StrictMode -Version Latest

Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
Add-Type -AssemblyName System.Drawing -ErrorAction Stop

function Import-SpoolDoctorModule {
    [CmdletBinding()]
    param(
        [Parameter()]
        [switch]$Force
    )

    $repoRoot = Split-Path -Path $PSScriptRoot -Parent
    $manifestPath = Join-Path -Path $repoRoot -ChildPath 'src\SpoolDoctor.psd1'

    $importParams = @{
        Name        = $manifestPath
        ErrorAction = 'Stop'
    }
    if ($Force) {
        $importParams['Force'] = $true
    }

    Import-Module @importParams
}

function Get-SpoolDoctorPropertyValue {
    [CmdletBinding()]
    param(
        [Parameter()]
        $InputObject,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$PropertyName,

        [Parameter()]
        $DefaultValue = $null
    )

    if ($null -eq $InputObject) {
        return $DefaultValue
    }

    $property = $InputObject.PSObject.Properties[$PropertyName]
    if ($null -ne $property -and $null -ne $property.Value) {
        return $property.Value
    }

    return $DefaultValue
}

function Format-SpoolerJobSize {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()]
        $SizeBytes
    )

    if ($null -eq $SizeBytes) {
        return '-'
    }

    $bytes = [double]$SizeBytes
    $ptBr = [System.Globalization.CultureInfo]::GetCultureInfo('pt-BR')

    if ($bytes -lt 1024) {
        return ('{0} B' -f [long]$bytes)
    }

    if ($bytes -lt 1048576) {
        return [string]::Format($ptBr, '{0:0.0} KB', ($bytes / 1KB))
    }

    return [string]::Format($ptBr, '{0:0.0} MB', ($bytes / 1MB))
}

function Format-SpoolerJobAge {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()]
        $Age
    )

    if ($null -eq $Age -or -not ($Age -is [timespan])) {
        return '-'
    }

    $span = [timespan]$Age
    if ($span -lt [timespan]::Zero) {
        $span = [timespan]::Zero
    }

    if ($span.TotalMinutes -lt 1) {
        return ('{0}s' -f [int][Math]::Floor($span.TotalSeconds))
    }

    if ($span.TotalHours -lt 1) {
        return ('{0}m {1:00}s' -f [int][Math]::Floor($span.TotalMinutes), $span.Seconds)
    }

    if ($span.TotalDays -lt 1) {
        return ('{0}h {1:00}m' -f [int][Math]::Floor($span.TotalHours), $span.Minutes)
    }

    return ('{0}d {1:00}h' -f [int][Math]::Floor($span.TotalDays), $span.Hours)
}

function Format-SpoolerActionResult {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        $Result
    )

    $timestampRaw = Get-SpoolDoctorPropertyValue -InputObject $Result -PropertyName 'Timestamp'
    $timestampValue = if ($timestampRaw -is [datetime]) { [datetime]$timestampRaw } else { Get-Date }
    $timestampText = $timestampValue.ToString('dd/MM/yyyy HH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture)

    $actionText = [string](Get-SpoolDoctorPropertyValue -InputObject $Result -PropertyName 'Action' -DefaultValue 'Ação')
    $outcomeText = [string](Get-SpoolDoctorPropertyValue -InputObject $Result -PropertyName 'Outcome' -DefaultValue 'Unknown')
    $messageText = [string](Get-SpoolDoctorPropertyValue -InputObject $Result -PropertyName 'Message' -DefaultValue '')

    return ('[{0}] [{1}] ({2}) {3}' -f $timestampText, $outcomeText, $actionText, $messageText)
}

function Confirm-SpoolDoctorAction {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Title,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Message,

        [Parameter()]
        [ValidateSet('Warning', 'Question', 'Information', 'Error')]
        [string]$Icon = 'Warning'
    )

    $iconValue = [System.Windows.Forms.MessageBoxIcon]::$Icon
    $dialogResult = [System.Windows.Forms.MessageBox]::Show(
        $Message,
        $Title,
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        $iconValue,
        [System.Windows.Forms.MessageBoxDefaultButton]::Button2
    )

    return ($dialogResult -eq [System.Windows.Forms.DialogResult]::Yes)
}

function Sync-SpoolDoctorSelectionState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [System.Windows.Forms.Form]$Form
    )

    $ui = $Form.Tag
    if ($null -eq $ui) {
        return
    }

    $hasValidSelection = (
        $ui.Grid.SelectedRows.Count -gt 0 -and
        $null -ne $ui.Grid.SelectedRows[0].Tag
    )
    $ui.CancelButton.Enabled = [bool]$hasValidSelection
}

function Sync-SpoolDoctorBusyState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [System.Windows.Forms.Form]$Form,

        [Parameter(Mandatory)]
        [bool]$IsBusy
    )

    $ui = $Form.Tag
    if ($null -eq $ui) {
        return
    }

    if ($IsBusy) {
        $ui.RefreshButton.Enabled = $false
        $ui.CancelButton.Enabled = $false
        $ui.ResetButton.Enabled = $false
        $Form.UseWaitCursor = $true
    }
    else {
        $ui.RefreshButton.Enabled = $true
        $ui.ResetButton.Enabled = $true
        Sync-SpoolDoctorSelectionState -Form $Form
        $Form.UseWaitCursor = $false
    }
}

function Write-SpoolDoctorStatusText {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [System.Windows.Forms.Form]$Form,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Text,

        [Parameter()]
        [switch]$Append
    )

    $ui = $Form.Tag
    if ($null -eq $ui) {
        return
    }

    if ($Append -and -not [string]::IsNullOrWhiteSpace($ui.StatusTextBox.Text)) {
        $ui.StatusTextBox.Text = "$($ui.StatusTextBox.Text)`r`n$Text"
    }
    else {
        $ui.StatusTextBox.Text = $Text
    }
}

function Invoke-SpoolDoctorRefresh {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [System.Windows.Forms.Form]$Form,

        [Parameter()]
        [switch]$PreserveStatus
    )

    $ui = $Form.Tag
    Sync-SpoolDoctorBusyState -Form $Form -IsBusy $true

    try {
        $queryParams = @{ ErrorAction = 'Stop' }
        $filterText = $ui.FilterTextBox.Text.Trim()
        if (-not [string]::IsNullOrWhiteSpace($filterText)) {
            $queryParams['PrinterName'] = $filterText
        }
        if (-not [string]::IsNullOrWhiteSpace($ui.LogPath)) {
            $queryParams['LogPath'] = $ui.LogPath
        }

        $jobs = @(Get-SpoolerJob @queryParams)
        $ui.Grid.Rows.Clear()

        foreach ($job in $jobs) {
            if ($null -eq $job) {
                continue
            }

            $idVal = Get-SpoolDoctorPropertyValue -InputObject $job -PropertyName 'Id' -DefaultValue '-'
            $printerVal = [string](Get-SpoolDoctorPropertyValue -InputObject $job -PropertyName 'PrinterName' -DefaultValue '-')
            $docVal = [string](Get-SpoolDoctorPropertyValue -InputObject $job -PropertyName 'Document' -DefaultValue '-')
            if ([string]::IsNullOrWhiteSpace($docVal)) {
                $docVal = '-'
            }

            $statusVal = [string](Get-SpoolDoctorPropertyValue -InputObject $job -PropertyName 'Status' -DefaultValue '-')
            if ([string]::IsNullOrWhiteSpace($statusVal)) {
                $statusVal = '-'
            }

            $sizeVal = Format-SpoolerJobSize -SizeBytes (Get-SpoolDoctorPropertyValue -InputObject $job -PropertyName 'SizeBytes')
            $ageVal = Format-SpoolerJobAge -Age (Get-SpoolDoctorPropertyValue -InputObject $job -PropertyName 'Age')

            $submittedRaw = Get-SpoolDoctorPropertyValue -InputObject $job -PropertyName 'SubmittedAt'
            $submittedVal = if ($submittedRaw -is [datetime]) {
                ([datetime]$submittedRaw).ToString('dd/MM/yyyy HH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture)
            }
            else {
                '-'
            }

            $rowIndex = $ui.Grid.Rows.Add($idVal, $printerVal, $docVal, $statusVal, $sizeVal, $ageVal, $submittedVal)
            $ui.Grid.Rows[$rowIndex].Tag = $job
        }

        $ui.Grid.ClearSelection()

        if (-not $PreserveStatus) {
            $nowText = (Get-Date).ToString('dd/MM/yyyy HH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture)
            $filterNote = if ([string]::IsNullOrWhiteSpace($filterText)) { '' } else { " (filtro: '$filterText')" }
            $statusMessage = "[$nowText] Fila atualizada$filterNote. Jobs encontrados: $($ui.Grid.Rows.Count)."
            Write-SpoolDoctorStatusText -Form $Form -Text $statusMessage
        }
    }
    catch {
        $ui.Grid.Rows.Clear()
        $ui.Grid.ClearSelection()
        $nowText = (Get-Date).ToString('dd/MM/yyyy HH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture)
        $errorMessage = "[$nowText] [ERRO] Falha ao consultar a fila de impressão: $($_.Exception.Message)"
        Write-SpoolDoctorStatusText -Form $Form -Text $errorMessage -Append:$PreserveStatus
    }
    finally {
        Sync-SpoolDoctorBusyState -Form $Form -IsBusy $false
    }
}

function Invoke-SpoolDoctorCancelJob {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [System.Windows.Forms.Form]$Form
    )

    $ui = $Form.Tag
    if ($ui.Grid.SelectedRows.Count -eq 0 -or $null -eq $ui.Grid.SelectedRows[0].Tag) {
        $nowText = (Get-Date).ToString('dd/MM/yyyy HH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture)
        Write-SpoolDoctorStatusText -Form $Form -Text "[$nowText] Selecione um job na tabela antes de cancelar."
        Sync-SpoolDoctorSelectionState -Form $Form
        return
    }

    $selectedJob = $ui.Grid.SelectedRows[0].Tag
    $jobId = Get-SpoolDoctorPropertyValue -InputObject $selectedJob -PropertyName 'Id'
    $printerName = [string](Get-SpoolDoctorPropertyValue -InputObject $selectedJob -PropertyName 'PrinterName' -DefaultValue '')
    $documentName = [string](Get-SpoolDoctorPropertyValue -InputObject $selectedJob -PropertyName 'Document' -DefaultValue '')
    if ([string]::IsNullOrWhiteSpace($documentName)) {
        $documentName = '(sem nome)'
    }

    $isWhatIf = [bool]$ui.WhatIfCheckBox.Checked
    $whatIfNotice = if ($isWhatIf) {
        "`r`n`r`nMODO SIMULAÇÃO (-WhatIf) ATIVO: nenhuma alteração real será feita."
    }
    else {
        ''
    }

    $confirmMessage = (
        "Deseja cancelar o job abaixo na máquina '$($ui.ComputerName)'?`r`n`r`n" +
        "Impressora: $printerName`r`n" +
        "Job ID: $jobId`r`n" +
        "Documento: $documentName" +
        $whatIfNotice
    )

    $confirmed = Confirm-SpoolDoctorAction -Title 'Confirmar cancelamento de job' -Message $confirmMessage -Icon 'Warning'
    if (-not $confirmed) {
        $nowText = (Get-Date).ToString('dd/MM/yyyy HH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture)
        Write-SpoolDoctorStatusText -Form $Form -Text "[$nowText] Cancelamento do job $jobId ($printerName) cancelado pelo usuário."
        return
    }

    Sync-SpoolDoctorBusyState -Form $Form -IsBusy $true

    try {
        $actionParams = @{
            PrinterName = $printerName
            Id          = [int]$jobId
            ErrorAction = 'Stop'
        }
        if (-not [string]::IsNullOrWhiteSpace($ui.LogPath)) {
            $actionParams['LogPath'] = $ui.LogPath
        }
        if ($isWhatIf) {
            $actionParams['WhatIf'] = $true
        }
        else {
            $actionParams['Confirm'] = $false
        }

        $result = Remove-SpoolerJob @actionParams
        if ($null -ne $result) {
            Write-SpoolDoctorStatusText -Form $Form -Text (Format-SpoolerActionResult -Result $result)
            $outcome = [string](Get-SpoolDoctorPropertyValue -InputObject $result -PropertyName 'Outcome' -DefaultValue '')
            if (-not $isWhatIf -and $outcome -eq 'OK') {
                Invoke-SpoolDoctorRefresh -Form $Form -PreserveStatus
            }
        }
    }
    catch {
        $nowText = (Get-Date).ToString('dd/MM/yyyy HH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture)
        Write-SpoolDoctorStatusText -Form $Form -Text "[$nowText] [ERRO] Falha ao cancelar o job ${jobId}: $($_.Exception.Message)"
    }
    finally {
        Sync-SpoolDoctorBusyState -Form $Form -IsBusy $false
    }
}

function Invoke-SpoolDoctorReset {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [System.Windows.Forms.Form]$Form
    )

    $ui = $Form.Tag
    $isWhatIf = [bool]$ui.WhatIfCheckBox.Checked
    $whatIfNotice = if ($isWhatIf) {
        "`r`n`r`nMODO SIMULAÇÃO (-WhatIf) ATIVO: nenhuma alteração real será feita."
    }
    else {
        ''
    }

    $confirmMessage = (
        "ATENÇÃO: esta ação irá parar o serviço Spooler, apagar todos os arquivos .SPL e .SHD da fila e reiniciar o serviço na máquina '$($ui.ComputerName)'.`r`n`r`n" +
        "Deseja continuar?" +
        $whatIfNotice
    )

    $confirmed = Confirm-SpoolDoctorAction -Title 'Confirmar reset do Spooler' -Message $confirmMessage -Icon 'Warning'
    if (-not $confirmed) {
        $nowText = (Get-Date).ToString('dd/MM/yyyy HH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture)
        Write-SpoolDoctorStatusText -Form $Form -Text "[$nowText] Reset do spooler cancelado pelo usuário na máquina '$($ui.ComputerName)'."
        return
    }

    Sync-SpoolDoctorBusyState -Form $Form -IsBusy $true

    try {
        $actionParams = @{
            ErrorAction = 'Stop'
        }
        if (-not [string]::IsNullOrWhiteSpace($ui.LogPath)) {
            $actionParams['LogPath'] = $ui.LogPath
        }
        if ($isWhatIf) {
            $actionParams['WhatIf'] = $true
        }
        else {
            $actionParams['Confirm'] = $false
        }

        $result = Reset-Spooler @actionParams
        if ($null -ne $result) {
            Write-SpoolDoctorStatusText -Form $Form -Text (Format-SpoolerActionResult -Result $result)
            $outcome = [string](Get-SpoolDoctorPropertyValue -InputObject $result -PropertyName 'Outcome' -DefaultValue '')
            if (-not $isWhatIf -and $outcome -eq 'OK') {
                Invoke-SpoolDoctorRefresh -Form $Form -PreserveStatus
            }
        }
    }
    catch {
        $nowText = (Get-Date).ToString('dd/MM/yyyy HH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture)
        Write-SpoolDoctorStatusText -Form $Form -Text "[$nowText] [ERRO] Falha ao resetar o spooler: $($_.Exception.Message)"
    }
    finally {
        Sync-SpoolDoctorBusyState -Form $Form -IsBusy $false
    }
}

function Initialize-SpoolDoctorForm {
    [CmdletBinding()]
    [OutputType([System.Windows.Forms.Form])]
    param(
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$LogPath
    )

    $computerName = if (-not [string]::IsNullOrWhiteSpace($env:COMPUTERNAME)) {
        $env:COMPUTERNAME
    }
    else {
        [System.Environment]::MachineName
    }

    $form = New-Object -TypeName System.Windows.Forms.Form
    $form.Text = 'SpoolDoctor - Fila de Impressão'
    $form.Size = New-Object -TypeName System.Drawing.Size(920, 560)
    $form.MinimumSize = New-Object -TypeName System.Drawing.Size(780, 480)
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $form.Font = New-Object -TypeName System.Drawing.Font('Segoe UI', 9)

    $layout = New-Object -TypeName System.Windows.Forms.TableLayoutPanel
    $layout.Dock = [System.Windows.Forms.DockStyle]::Fill
    $layout.Padding = New-Object -TypeName System.Windows.Forms.Padding(10)
    $layout.ColumnCount = 1
    $layout.RowCount = 4
    $null = $layout.ColumnStyles.Add((New-Object -TypeName System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    $null = $layout.RowStyles.Add((New-Object -TypeName System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
    $null = $layout.RowStyles.Add((New-Object -TypeName System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 65)))
    $null = $layout.RowStyles.Add((New-Object -TypeName System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
    $null = $layout.RowStyles.Add((New-Object -TypeName System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 35)))

    $topPanel = New-Object -TypeName System.Windows.Forms.FlowLayoutPanel
    $topPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
    $topPanel.AutoSize = $true
    $topPanel.WrapContents = $true
    $topPanel.Padding = New-Object -TypeName System.Windows.Forms.Padding(0, 0, 0, 6)

    $computerLabel = New-Object -TypeName System.Windows.Forms.Label
    $computerLabel.Text = "Máquina: $computerName"
    $computerLabel.AutoSize = $true
    $computerLabel.Font = New-Object -TypeName System.Drawing.Font('Segoe UI', 9.5, [System.Drawing.FontStyle]::Bold)
    $computerLabel.Margin = New-Object -TypeName System.Windows.Forms.Padding(0, 6, 16, 4)

    $filterLabel = New-Object -TypeName System.Windows.Forms.Label
    $filterLabel.Text = 'Impressora (opcional):'
    $filterLabel.AutoSize = $true
    $filterLabel.Margin = New-Object -TypeName System.Windows.Forms.Padding(0, 6, 6, 4)

    $filterTextBox = New-Object -TypeName System.Windows.Forms.TextBox
    $filterTextBox.Width = 220
    $filterTextBox.Margin = New-Object -TypeName System.Windows.Forms.Padding(0, 3, 10, 4)

    $refreshButton = New-Object -TypeName System.Windows.Forms.Button
    $refreshButton.Text = 'Atualizar'
    $refreshButton.AutoSize = $true
    $refreshButton.Padding = New-Object -TypeName System.Windows.Forms.Padding(10, 2, 10, 2)
    $refreshButton.Margin = New-Object -TypeName System.Windows.Forms.Padding(0, 1, 0, 4)

    $topPanel.Controls.AddRange(@($computerLabel, $filterLabel, $filterTextBox, $refreshButton))

    $grid = New-Object -TypeName System.Windows.Forms.DataGridView
    $grid.Dock = [System.Windows.Forms.DockStyle]::Fill
    $grid.ReadOnly = $true
    $grid.MultiSelect = $false
    $grid.SelectionMode = [System.Windows.Forms.DataGridViewSelectionMode]::FullRowSelect
    $grid.AllowUserToAddRows = $false
    $grid.AllowUserToDeleteRows = $false
    $grid.AllowUserToResizeRows = $false
    $grid.RowHeadersVisible = $false
    $grid.AutoSizeColumnsMode = [System.Windows.Forms.DataGridViewAutoSizeColumnsMode]::Fill
    $grid.BackgroundColor = [System.Drawing.SystemColors]::Window

    $columns = @(
        @{ Name = 'Id'; Header = 'ID'; Weight = 10 },
        @{ Name = 'PrinterName'; Header = 'Impressora'; Weight = 22 },
        @{ Name = 'Document'; Header = 'Documento'; Weight = 24 },
        @{ Name = 'Status'; Header = 'Status'; Weight = 14 },
        @{ Name = 'Size'; Header = 'Tamanho'; Weight = 10 },
        @{ Name = 'Age'; Header = 'Idade'; Weight = 10 },
        @{ Name = 'SubmittedAt'; Header = 'Enviado em'; Weight = 18 }
    )
    foreach ($colDef in $columns) {
        $colIndex = $grid.Columns.Add($colDef.Name, $colDef.Header)
        $grid.Columns[$colIndex].FillWeight = $colDef.Weight
    }

    $actionPanel = New-Object -TypeName System.Windows.Forms.FlowLayoutPanel
    $actionPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
    $actionPanel.AutoSize = $true
    $actionPanel.Padding = New-Object -TypeName System.Windows.Forms.Padding(0, 6, 0, 6)

    $whatIfCheckBox = New-Object -TypeName System.Windows.Forms.CheckBox
    $whatIfCheckBox.Text = 'Modo simulação (-WhatIf)'
    $whatIfCheckBox.AutoSize = $true
    $whatIfCheckBox.Margin = New-Object -TypeName System.Windows.Forms.Padding(0, 6, 16, 4)

    $cancelButton = New-Object -TypeName System.Windows.Forms.Button
    $cancelButton.Text = 'Cancelar job selecionado'
    $cancelButton.AutoSize = $true
    $cancelButton.Enabled = $false
    $cancelButton.Padding = New-Object -TypeName System.Windows.Forms.Padding(10, 2, 10, 2)
    $cancelButton.Margin = New-Object -TypeName System.Windows.Forms.Padding(0, 2, 10, 4)

    $resetButton = New-Object -TypeName System.Windows.Forms.Button
    $resetButton.Text = 'Resetar Spooler'
    $resetButton.AutoSize = $true
    $resetButton.Padding = New-Object -TypeName System.Windows.Forms.Padding(10, 2, 10, 2)
    $resetButton.Margin = New-Object -TypeName System.Windows.Forms.Padding(0, 2, 0, 4)

    $actionPanel.Controls.AddRange(@($whatIfCheckBox, $cancelButton, $resetButton))

    $statusGroup = New-Object -TypeName System.Windows.Forms.GroupBox
    $statusGroup.Text = 'Status e retorno das ações'
    $statusGroup.Dock = [System.Windows.Forms.DockStyle]::Fill
    $statusGroup.Padding = New-Object -TypeName System.Windows.Forms.Padding(8)

    $statusTextBox = New-Object -TypeName System.Windows.Forms.TextBox
    $statusTextBox.Multiline = $true
    $statusTextBox.ReadOnly = $true
    $statusTextBox.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
    $statusTextBox.Dock = [System.Windows.Forms.DockStyle]::Fill
    $statusTextBox.BackColor = [System.Drawing.SystemColors]::Window

    $statusGroup.Controls.Add($statusTextBox)

    $layout.Controls.Add($topPanel, 0, 0)
    $layout.Controls.Add($grid, 0, 1)
    $layout.Controls.Add($actionPanel, 0, 2)
    $layout.Controls.Add($statusGroup, 0, 3)

    $form.Controls.Add($layout)

    $resolvedLogPath = if ($PSBoundParameters.ContainsKey('LogPath')) { $LogPath } else { $null }
    $form.Tag = @{
        ComputerName  = $computerName
        LogPath       = $resolvedLogPath
        ComputerLabel = $computerLabel
        FilterTextBox = $filterTextBox
        RefreshButton = $refreshButton
        Grid          = $grid
        WhatIfCheckBox = $whatIfCheckBox
        CancelButton  = $cancelButton
        ResetButton   = $resetButton
        StatusTextBox = $statusTextBox
    }

    $refreshButton.Add_Click({
        $owner = $this.FindForm()
        if ($null -ne $owner) {
            Invoke-SpoolDoctorRefresh -Form $owner
        }
    })
    $cancelButton.Add_Click({
        $owner = $this.FindForm()
        if ($null -ne $owner) {
            Invoke-SpoolDoctorCancelJob -Form $owner
        }
    })
    $resetButton.Add_Click({
        $owner = $this.FindForm()
        if ($null -ne $owner) {
            Invoke-SpoolDoctorReset -Form $owner
        }
    })
    $grid.Add_SelectionChanged({
        $owner = $this.FindForm()
        if ($null -ne $owner) {
            Sync-SpoolDoctorSelectionState -Form $owner
        }
    })

    return $form
}

function Show-SpoolDoctorUI {
    [CmdletBinding()]
    param(
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$LogPath
    )

    Import-SpoolDoctorModule -Force
    [System.Windows.Forms.Application]::EnableVisualStyles()

    $formParams = @{}
    if ($PSBoundParameters.ContainsKey('LogPath')) {
        $formParams['LogPath'] = $LogPath
    }

    $form = Initialize-SpoolDoctorForm @formParams
    try {
        $form.Add_Shown({
            Invoke-SpoolDoctorRefresh -Form $this
        })
        $null = $form.ShowDialog()
    }
    finally {
        $form.Dispose()
    }
}

Import-SpoolDoctorModule

if (-not $NoShow -and $MyInvocation.InvocationName -ne '.') {
    $showParams = @{}
    if ($PSBoundParameters.ContainsKey('LogPath')) {
        $showParams['LogPath'] = $LogPath
    }
    Show-SpoolDoctorUI @showParams
}
