[CmdletBinding()]
param(
    [Parameter()]
    [switch]$NoShow,

    [Parameter()]
    [switch]$NoElevate,

    [Parameter()]
    [switch]$ElevationAttempted,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$LogPath,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$AllowedComputersPath
)

Set-StrictMode -Version Latest

$script:SpoolDoctorUIScriptPath = $PSCommandPath

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

function Format-SpoolerDiagnostic {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        $Diagnostic
    )

    $timestampRaw = Get-SpoolDoctorPropertyValue -InputObject $Diagnostic -PropertyName 'Timestamp'
    $timestampValue = if ($timestampRaw -is [datetime]) { [datetime]$timestampRaw } else { Get-Date }
    $timestampText = $timestampValue.ToString('dd/MM/yyyy HH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture)

    $computerText = [string](Get-SpoolDoctorPropertyValue -InputObject $Diagnostic -PropertyName 'ComputerName' -DefaultValue '-')
    $healthText = [string](Get-SpoolDoctorPropertyValue -InputObject $Diagnostic -PropertyName 'Health' -DefaultValue 'Unknown')
    $serviceText = [string](Get-SpoolDoctorPropertyValue -InputObject $Diagnostic -PropertyName 'ServiceStatus' -DefaultValue 'Unknown')
    $printerCountRaw = Get-SpoolDoctorPropertyValue -InputObject $Diagnostic -PropertyName 'PrinterCount'
    $printerCountText = if ($null -eq $printerCountRaw) { 'N/D' } else { [string]$printerCountRaw }
    $jobCountRaw = Get-SpoolDoctorPropertyValue -InputObject $Diagnostic -PropertyName 'JobCount'
    $jobCountText = if ($null -eq $jobCountRaw) { 'N/D' } else { [string]$jobCountRaw }
    $stuckJobs = @(Get-SpoolDoctorPropertyValue -InputObject $Diagnostic -PropertyName 'StuckJobs' -DefaultValue @())
    $spoolFileCount = Get-SpoolDoctorPropertyValue -InputObject $Diagnostic -PropertyName 'SpoolFileCount'
    $spoolFileText = if ($null -eq $spoolFileCount) { 'sem permissão/indisponível' } else { [string]$spoolFileCount }
    $recommendationText = [string](Get-SpoolDoctorPropertyValue -InputObject $Diagnostic -PropertyName 'Recommendation' -DefaultValue '')
    $issues = @(Get-SpoolDoctorPropertyValue -InputObject $Diagnostic -PropertyName 'Issues' -DefaultValue @() | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })

    $lines = New-Object -TypeName 'System.Collections.Generic.List[string]'
    $lines.Add("[$timestampText] [$healthText] Diagnóstico em '$computerText' — Serviço: $serviceText | Impressoras: $printerCountText | Jobs: $jobCountText | Travados: $($stuckJobs.Count) | Arquivos PRINTERS: $spoolFileText")
    if (-not [string]::IsNullOrWhiteSpace($recommendationText)) {
        $lines.Add("Recomendação: $recommendationText")
    }
    foreach ($issue in $issues) {
        $lines.Add("- $issue")
    }

    return ($lines -join "`r`n")
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

function Test-SpoolDoctorElevated {
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    if ($null -eq $identity) {
        return $false
    }

    $principal = New-Object -TypeName System.Security.Principal.WindowsPrincipal -ArgumentList $identity
    return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Format-SpoolDoctorProcessArgument {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Value
    )

    $escaped = $Value -replace '(\\*)"', '$1$1\"'
    $escaped = $escaped -replace '(\\+)$', '$1$1'
    return ('"{0}"' -f $escaped)
}

function Get-SpoolDoctorElevationArgumentList {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter()]
        [string]$ScriptPath = $script:SpoolDoctorUIScriptPath,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$LogPath,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$AllowedComputersPath
    )

    if ([string]::IsNullOrWhiteSpace($ScriptPath)) {
        throw 'Não foi possível determinar o caminho do script ui/SpoolDoctorUI.ps1 para relançamento.'
    }

    $argumentList = New-Object -TypeName 'System.Collections.Generic.List[string]'
    $argumentList.Add('-NoProfile')
    $argumentList.Add('-ExecutionPolicy')
    $argumentList.Add('Bypass')
    $argumentList.Add('-STA')
    $argumentList.Add('-WindowStyle')
    $argumentList.Add('Hidden')
    $argumentList.Add('-File')
    $argumentList.Add((Format-SpoolDoctorProcessArgument -Value $ScriptPath))
    $argumentList.Add('-ElevationAttempted')

    if ($PSBoundParameters.ContainsKey('LogPath') -and -not [string]::IsNullOrWhiteSpace($LogPath)) {
        $argumentList.Add('-LogPath')
        $argumentList.Add((Format-SpoolDoctorProcessArgument -Value $LogPath))
    }
    if ($PSBoundParameters.ContainsKey('AllowedComputersPath') -and -not [string]::IsNullOrWhiteSpace($AllowedComputersPath)) {
        $argumentList.Add('-AllowedComputersPath')
        $argumentList.Add((Format-SpoolDoctorProcessArgument -Value $AllowedComputersPath))
    }

    return $argumentList.ToArray()
}

function Test-SpoolDoctorElevationCanceled {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter()]
        [System.Exception]$Exception
    )

    $current = $Exception
    while ($null -ne $current) {
        if ($current -is [System.ComponentModel.Win32Exception] -and $current.NativeErrorCode -eq 1223) {
            return $true
        }
        if ($current -is [System.OperationCanceledException]) {
            return $true
        }
        $current = $current.InnerException
    }

    return $false
}

function Start-SpoolDoctorElevatedProcess {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string[]]$ArgumentList
    )

    if ($PSCmdlet.ShouldProcess('powershell.exe', 'Iniciar SpoolDoctor com elevação UAC (Administrador)')) {
        Start-Process -FilePath 'powershell.exe' -Verb 'RunAs' -WindowStyle 'Hidden' -ArgumentList $ArgumentList -ErrorAction Stop
    }
}

function Request-SpoolDoctorElevation {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter()]
        [string]$ScriptPath = $script:SpoolDoctorUIScriptPath,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$LogPath,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$AllowedComputersPath,

        [Parameter()]
        [switch]$ElevationAttempted,

        [Parameter()]
        [switch]$NoElevate,

        [Parameter()]
        [switch]$Force
    )

    if (Test-SpoolDoctorElevated) {
        return [PSCustomObject]@{
            PSTypeName               = 'SpoolDoctor.ElevationResult'
            Outcome                  = 'AlreadyElevated'
            ShouldExitCurrentProcess = $false
            Message                  = ''
        }
    }

    if (-not $Force -and ($ElevationAttempted -or $NoElevate)) {
        $reasonText = if ($ElevationAttempted) {
            'A tentativa anterior de elevação não resultou em privilégio de Administrador (trava anti-loop ativada).'
        }
        else {
            'Elevação automática desabilitada (-NoElevate).'
        }

        return [PSCustomObject]@{
            PSTypeName               = 'SpoolDoctor.ElevationResult'
            Outcome                  = 'Skipped'
            ShouldExitCurrentProcess = $false
            Message                  = "$reasonText Janela aberta em modo somente leitura. Use 'Reiniciar como Administrador' para habilitar cancelamento e reset."
        }
    }

    $argParams = @{
        ScriptPath = $ScriptPath
    }
    if ($PSBoundParameters.ContainsKey('LogPath') -and -not [string]::IsNullOrWhiteSpace($LogPath)) {
        $argParams['LogPath'] = $LogPath
    }
    if ($PSBoundParameters.ContainsKey('AllowedComputersPath') -and -not [string]::IsNullOrWhiteSpace($AllowedComputersPath)) {
        $argParams['AllowedComputersPath'] = $AllowedComputersPath
    }

    try {
        $elevationArgs = @(Get-SpoolDoctorElevationArgumentList @argParams)
        Start-SpoolDoctorElevatedProcess -ArgumentList $elevationArgs -Confirm:$false

        return [PSCustomObject]@{
            PSTypeName               = 'SpoolDoctor.ElevationResult'
            Outcome                  = 'Relaunched'
            ShouldExitCurrentProcess = $true
            Message                  = 'Nova instância do SpoolDoctor iniciada com privilégios de Administrador.'
        }
    }
    catch {
        if (Test-SpoolDoctorElevationCanceled -Exception $_.Exception) {
            return [PSCustomObject]@{
                PSTypeName               = 'SpoolDoctor.ElevationResult'
                Outcome                  = 'Canceled'
                ShouldExitCurrentProcess = $false
                Message                  = "Elevação UAC recusada ou cancelada pelo usuário. Janela aberta em modo somente leitura. Use 'Reiniciar como Administrador' quando desejar alterar a fila."
            }
        }

        return [PSCustomObject]@{
            PSTypeName               = 'SpoolDoctor.ElevationResult'
            Outcome                  = 'Failed'
            ShouldExitCurrentProcess = $false
            Message                  = "Não foi possível iniciar o SpoolDoctor como Administrador: $($_.Exception.Message) Janela mantida em modo somente leitura."
        }
    }
}

function Request-SpoolDoctorCredential {
    [CmdletBinding()]
    [OutputType([PSCredential])]
    param(
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$Message = 'Informe as credenciais de administrador para execução remota no SpoolDoctor:'
    )

    try {
        $credential = Get-Credential -Message $Message -ErrorAction Stop
        if ($credential -is [PSCredential]) {
            return $credential
        }
        return $null
    }
    catch {
        # Cancelamento do prompt de credencial pelo usuário retorna nulo sem interromper a interface.
        return $null
    }
}

function Test-SpoolDoctorIsLocalComputer {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$ComputerName,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$LocalComputerName
    )

    if ([string]::IsNullOrWhiteSpace($ComputerName)) {
        return $true
    }

    $candidate = $ComputerName.Trim()
    $localTrimmed = $LocalComputerName.Trim()

    if ([string]::Equals($candidate, 'localhost', [System.StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }
    if ([string]::Equals($candidate, $localTrimmed, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }
    if (-not [string]::IsNullOrWhiteSpace($env:USERDNSDOMAIN)) {
        $localFqdn = "$localTrimmed.$($env:USERDNSDOMAIN.Trim())"
        if ([string]::Equals($candidate, $localFqdn, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }

    return $false
}

function Get-SpoolDoctorSelectedTarget {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [System.Windows.Forms.Form]$Form
    )

    $ui = $Form.Tag
    if ($null -eq $ui -or $null -eq $ui.TargetOptions -or $ui.TargetOptions.Count -eq 0) {
        return [PSCustomObject]@{
            Mode             = 'Local'
            DisplayText      = "Local ($($env:COMPUTERNAME))"
            ComputerNames    = @()
            IsRemote         = $false
            IsBatch          = $false
            IsPrintServer    = $false
            PrintServerNames = @()
        }
    }

    $index = $ui.TargetComboBox.SelectedIndex
    if ($index -lt 0 -or $index -ge $ui.TargetOptions.Count) {
        $index = 0
    }

    return $ui.TargetOptions[$index]
}

function Get-SpoolDoctorRemoteParameter {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [System.Windows.Forms.Form]$Form,

        [Parameter()]
        [string[]]$ComputerNames = @()
    )

    $params = @{}
    if ($null -eq $ComputerNames -or $ComputerNames.Count -eq 0) {
        return $params
    }

    $ui = $Form.Tag
    $params['ComputerName'] = @($ComputerNames)
    if ($null -ne $ui) {
        if (-not [string]::IsNullOrWhiteSpace([string]$ui.AllowedComputersPath)) {
            $params['AllowedComputersPath'] = [string]$ui.AllowedComputersPath
        }
        if ($ui.CredentialCheckBox.Checked -and $null -ne $ui.Credential) {
            $params['Credential'] = $ui.Credential
        }
    }

    return $params
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

    $isElevated = [bool]$ui.IsElevated
    $hasValidSelection = (
        $ui.Grid.SelectedRows.Count -gt 0 -and
        $null -ne $ui.Grid.SelectedRows[0].Tag
    )
    if (-not $hasValidSelection) {
        $ui.CancelButton.Enabled = $false
        return
    }

    if ($isElevated) {
        $ui.CancelButton.Enabled = $true
        return
    }

    $selectedJob = $ui.Grid.SelectedRows[0].Tag
    $jobComputerName = [string](Get-SpoolDoctorPropertyValue -InputObject $selectedJob -PropertyName 'ComputerName' -DefaultValue '')
    if ([string]::IsNullOrWhiteSpace($jobComputerName)) {
        $selectedTarget = Get-SpoolDoctorSelectedTarget -Form $Form
        $ui.CancelButton.Enabled = [bool]$selectedTarget.IsRemote
    }
    else {
        $isJobLocal = Test-SpoolDoctorIsLocalComputer -ComputerName $jobComputerName -LocalComputerName $ui.ComputerName
        $ui.CancelButton.Enabled = (-not $isJobLocal)
    }
}

function Sync-SpoolDoctorTargetState {
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

    $isElevated = [bool]$ui.IsElevated
    $selectedTarget = Get-SpoolDoctorSelectedTarget -Form $Form
    $isRemote = [bool]$selectedTarget.IsRemote

    $ui.CredentialCheckBox.Enabled = $isRemote
    $ui.ResetButton.Enabled = ($isElevated -or $isRemote)

    if ($isElevated) {
        $ui.PrivilegeLabel.Text = 'Privilégio: Administrador'
        $ui.PrivilegeLabel.ForeColor = [System.Drawing.Color]::DarkGreen
    }
    elseif ($isRemote) {
        $ui.PrivilegeLabel.Text = 'Privilégio: Usuário padrão (admin validado no destino)'
        $ui.PrivilegeLabel.ForeColor = [System.Drawing.Color]::DarkBlue
    }
    else {
        $ui.PrivilegeLabel.Text = 'Privilégio: Usuário padrão (somente leitura)'
        $ui.PrivilegeLabel.ForeColor = [System.Drawing.Color]::DarkRed
    }

    Sync-SpoolDoctorSelectionState -Form $Form
}

function Invoke-SpoolDoctorCredentialChange {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [System.Windows.Forms.Form]$Form
    )

    $ui = $Form.Tag
    if ($null -eq $ui -or [bool]$ui.UpdatingCredentialCheckBox) {
        return
    }

    if (-not $ui.CredentialCheckBox.Checked) {
        $ui.Credential = $null
        return
    }

    $cred = Request-SpoolDoctorCredential
    if ($null -eq $cred) {
        $ui.UpdatingCredentialCheckBox = $true
        try {
            $ui.CredentialCheckBox.Checked = $false
            $ui.Credential = $null
        }
        finally {
            $ui.UpdatingCredentialCheckBox = $false
        }
        return
    }

    $ui.Credential = $cred
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
    if ($Form.IsDisposed -or $null -eq $ui) {
        return
    }

    $isElevated = [bool]$ui.IsElevated

    if ($IsBusy) {
        $ui.TargetComboBox.Enabled = $false
        $ui.CredentialCheckBox.Enabled = $false
        $ui.RefreshButton.Enabled = $false
        $ui.DiagnoseButton.Enabled = $false
        $ui.CancelButton.Enabled = $false
        $ui.ResetButton.Enabled = $false
        $ui.ElevateButton.Enabled = $false
        $Form.UseWaitCursor = $true
    }
    else {
        $ui.TargetComboBox.Enabled = $true
        $ui.RefreshButton.Enabled = $true
        $ui.DiagnoseButton.Enabled = $true
        $ui.ElevateButton.Enabled = (-not $isElevated)
        Sync-SpoolDoctorTargetState -Form $Form
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
        $selectedTarget = Get-SpoolDoctorSelectedTarget -Form $Form
        $queryParams = Get-SpoolDoctorRemoteParameter -Form $Form -ComputerNames $selectedTarget.ComputerNames
        $filterText = $ui.FilterTextBox.Text.Trim()
        if (-not [string]::IsNullOrWhiteSpace($filterText)) {
            $queryParams['PrinterName'] = $filterText
        }
        if (-not [string]::IsNullOrWhiteSpace($ui.LogPath)) {
            $queryParams['LogPath'] = $ui.LogPath
        }

        $batchErrors = @()
        if ($selectedTarget.IsBatch) {
            $queryParams['ErrorAction'] = 'Continue'
            $jobs = @(Get-SpoolerJob @queryParams -ErrorVariable batchErrors)
        }
        else {
            $queryParams['ErrorAction'] = 'Stop'
            $jobs = @(Get-SpoolerJob @queryParams)
        }

        $ui.Grid.Rows.Clear()

        foreach ($job in $jobs) {
            if ($null -eq $job) {
                continue
            }

            $computerVal = [string](Get-SpoolDoctorPropertyValue -InputObject $job -PropertyName 'ComputerName' -DefaultValue '')
            if ([string]::IsNullOrWhiteSpace($computerVal)) {
                $computerVal = if (-not $selectedTarget.IsBatch -and $selectedTarget.ComputerNames.Count -eq 1) {
                    [string]$selectedTarget.ComputerNames[0]
                }
                else {
                    [string]$ui.ComputerName
                }
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

            $rowIndex = $ui.Grid.Rows.Add($computerVal, $idVal, $printerVal, $docVal, $statusVal, $sizeVal, $ageVal, $submittedVal)
            $ui.Grid.Rows[$rowIndex].Tag = $job
        }

        $ui.Grid.ClearSelection()

        $partialErrorLines = New-Object -TypeName 'System.Collections.Generic.List[string]'
        foreach ($err in @($batchErrors)) {
            if ($null -eq $err) {
                continue
            }
            $errMsg = [string]$err.Exception.Message
            if ([string]::IsNullOrWhiteSpace($errMsg)) {
                continue
            }
            $errTarget = if ($null -ne $err.TargetObject -and -not [string]::IsNullOrWhiteSpace([string]$err.TargetObject)) {
                [string]$err.TargetObject
            }
            else {
                'desconhecida'
            }
            $errKind = if ([string]$err.FullyQualifiedErrorId -match 'SpoolDoctor\.([A-Za-z]+)') {
                $Matches[1]
            }
            else {
                'Failed'
            }
            $partialErrorLines.Add("- [$errKind] ${errTarget}: $errMsg")
        }

        if (-not $PreserveStatus) {
            $nowText = (Get-Date).ToString('dd/MM/yyyy HH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture)
            $filterNote = if ([string]::IsNullOrWhiteSpace($filterText)) { '' } else { " (filtro: '$filterText')" }
            $targetNote = if ($selectedTarget.IsRemote) { " [$($selectedTarget.DisplayText)]" } else { '' }
            $statusMessage = "[$nowText] Fila atualizada$targetNote$filterNote. Jobs encontrados: $($ui.Grid.Rows.Count)."
            if ($partialErrorLines.Count -gt 0) {
                $statusMessage = "$statusMessage`r`nFalhas/máquinas indisponíveis ($($partialErrorLines.Count)):`r`n$($partialErrorLines -join "`r`n")"
            }
            Write-SpoolDoctorStatusText -Form $Form -Text $statusMessage
        }
        elseif ($partialErrorLines.Count -gt 0) {
            $nowText = (Get-Date).ToString('dd/MM/yyyy HH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture)
            $partialNotice = "[$nowText] Falhas na atualização em lote ($($partialErrorLines.Count)):`r`n$($partialErrorLines -join "`r`n")"
            Write-SpoolDoctorStatusText -Form $Form -Text $partialNotice -Append
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
    $selectedTarget = Get-SpoolDoctorSelectedTarget -Form $Form
    $jobId = Get-SpoolDoctorPropertyValue -InputObject $selectedJob -PropertyName 'Id'
    $printerName = [string](Get-SpoolDoctorPropertyValue -InputObject $selectedJob -PropertyName 'PrinterName' -DefaultValue '')
    $documentName = [string](Get-SpoolDoctorPropertyValue -InputObject $selectedJob -PropertyName 'Document' -DefaultValue '')
    if ([string]::IsNullOrWhiteSpace($documentName)) {
        $documentName = '(sem nome)'
    }

    $jobComputerName = [string](Get-SpoolDoctorPropertyValue -InputObject $selectedJob -PropertyName 'ComputerName' -DefaultValue '')
    if ([string]::IsNullOrWhiteSpace($jobComputerName)) {
        $jobComputerName = if (-not $selectedTarget.IsBatch -and $selectedTarget.ComputerNames.Count -eq 1) {
            [string]$selectedTarget.ComputerNames[0]
        }
        else {
            [string]$ui.ComputerName
        }
    }
    $isJobRemote = (-not (Test-SpoolDoctorIsLocalComputer -ComputerName $jobComputerName -LocalComputerName $ui.ComputerName))

    $isWhatIf = [bool]$ui.WhatIfCheckBox.Checked
    $whatIfNotice = if ($isWhatIf) {
        "`r`n`r`nMODO SIMULAÇÃO (-WhatIf) ATIVO: nenhuma alteração real será feita."
    }
    else {
        ''
    }

    $confirmMessage = (
        "Deseja cancelar o job abaixo na máquina '$jobComputerName'?`r`n`r`n" +
        "Impressora: $printerName`r`n" +
        "Job ID: $jobId`r`n" +
        "Documento: $documentName" +
        $whatIfNotice
    )

    $confirmed = Confirm-SpoolDoctorAction -Title 'Confirmar cancelamento de job' -Message $confirmMessage -Icon 'Warning'
    if (-not $confirmed) {
        $nowText = (Get-Date).ToString('dd/MM/yyyy HH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture)
        Write-SpoolDoctorStatusText -Form $Form -Text "[$nowText] Cancelamento do job $jobId ($printerName) na máquina '$jobComputerName' cancelado pelo usuário."
        return
    }

    Sync-SpoolDoctorBusyState -Form $Form -IsBusy $true

    try {
        $targetComputers = if ($isJobRemote) { @($jobComputerName) } else { @() }
        $actionParams = Get-SpoolDoctorRemoteParameter -Form $Form -ComputerNames $targetComputers
        $actionParams['PrinterName'] = $printerName
        $actionParams['Id'] = [int]$jobId
        $actionParams['ErrorAction'] = 'Stop'
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
    $selectedTarget = Get-SpoolDoctorSelectedTarget -Form $Form
    $isWhatIf = [bool]$ui.WhatIfCheckBox.Checked
    $shouldBackup = [bool]$ui.BackupCheckBox.Checked
    $backupNotice = if ($shouldBackup) {
        "`r`nBackup antes de apagar: SIM (arquivos .SPL e .SHD serão copiados antes da remoção)."
    }
    else {
        "`r`nBackup antes de apagar: NÃO (-SkipBackup; arquivos serão removidos sem cópia prévia)."
    }
    $whatIfNotice = if ($isWhatIf) {
        "`r`n`r`nMODO SIMULAÇÃO (-WhatIf) ATIVO: nenhuma alteração real será feita."
    }
    else {
        ''
    }

    $allowPrintServer = $false
    if (-not $selectedTarget.IsBatch -and $selectedTarget.IsPrintServer) {
        $printServerHost = [string]$selectedTarget.ComputerNames[0]
        $firstMessage = (
            "ATENÇÃO [SERVIDOR DE IMPRESSÃO]: a máquina '$printServerHost' está marcada como servidor de impressão (|PrintServer).`r`n" +
            "Resetar o serviço Spooler irá interromper a fila e a impressão de TODOS os usuários conectados a este servidor.`r`n" +
            $backupNotice +
            "`r`n`r`nDeseja prosseguir para a confirmação final?" +
            $whatIfNotice
        )
        $firstConfirmed = Confirm-SpoolDoctorAction -Title 'Confirmar reset em Servidor de Impressão' -Message $firstMessage -Icon 'Warning'
        if (-not $firstConfirmed) {
            $nowText = (Get-Date).ToString('dd/MM/yyyy HH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture)
            Write-SpoolDoctorStatusText -Form $Form -Text "[$nowText] Reset do spooler cancelado pelo usuário na máquina '$printServerHost'."
            return
        }

        $secondMessage = (
            "CONFIRMAÇÃO REFORÇADA (-AllowPrintServer):`r`n`r`n" +
            "Confirma a execução do reset completo do serviço Spooler no servidor de impressão '$printServerHost'?" +
            $whatIfNotice
        )
        $secondConfirmed = Confirm-SpoolDoctorAction -Title 'Confirmação reforçada - Servidor de Impressão' -Message $secondMessage -Icon 'Error'
        if (-not $secondConfirmed) {
            $nowText = (Get-Date).ToString('dd/MM/yyyy HH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture)
            Write-SpoolDoctorStatusText -Form $Form -Text "[$nowText] Confirmação reforçada recusada pelo usuário para o servidor de impressão '$printServerHost'."
            return
        }

        $allowPrintServer = $true
    }
    else {
        $targetDescription = if ($selectedTarget.IsBatch) {
            "nas $($selectedTarget.ComputerNames.Count) máquinas autorizadas ($($selectedTarget.ComputerNames -join ', '))"
        }
        elseif ($selectedTarget.IsRemote) {
            "na máquina '$($selectedTarget.ComputerNames[0])'"
        }
        else {
            "na máquina '$($ui.ComputerName)'"
        }

        $batchPrintServerNotice = ''
        if ($selectedTarget.IsBatch -and $selectedTarget.PrintServerNames.Count -gt 0) {
            $batchPrintServerNotice = "`r`nObservação: servidor(es) de impressão marcado(s) com |PrintServer ($($selectedTarget.PrintServerNames -join ', ')) serão bloqueados automaticamente no modo lote (selecione-os individualmente caso deseje resetar)."
        }

        $confirmMessage = (
            "ATENÇÃO: esta ação irá parar o serviço Spooler, apagar todos os arquivos .SPL e .SHD da fila e reiniciar o serviço $targetDescription.`r`n" +
            $backupNotice +
            $batchPrintServerNotice +
            "`r`n`r`nDeseja continuar?" +
            $whatIfNotice
        )

        $confirmed = Confirm-SpoolDoctorAction -Title 'Confirmar reset do Spooler' -Message $confirmMessage -Icon 'Warning'
        if (-not $confirmed) {
            $nowText = (Get-Date).ToString('dd/MM/yyyy HH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture)
            Write-SpoolDoctorStatusText -Form $Form -Text "[$nowText] Reset do spooler cancelado pelo usuário ($($selectedTarget.DisplayText))."
            return
        }
    }

    Sync-SpoolDoctorBusyState -Form $Form -IsBusy $true

    try {
        $actionParams = Get-SpoolDoctorRemoteParameter -Form $Form -ComputerNames $selectedTarget.ComputerNames
        $actionParams['ErrorAction'] = 'Stop'
        if (-not [string]::IsNullOrWhiteSpace($ui.LogPath)) {
            $actionParams['LogPath'] = $ui.LogPath
        }
        if (-not $shouldBackup) {
            $actionParams['SkipBackup'] = $true
        }
        if ($allowPrintServer) {
            $actionParams['AllowPrintServer'] = $true
        }
        if ($isWhatIf) {
            $actionParams['WhatIf'] = $true
        }
        else {
            $actionParams['Confirm'] = $false
        }

        $results = @(Reset-Spooler @actionParams | Where-Object { $null -ne $_ })
        if ($results.Count -gt 0) {
            $formattedLines = @(
                foreach ($res in $results) {
                    Format-SpoolerActionResult -Result $res
                }
            )
            Write-SpoolDoctorStatusText -Form $Form -Text ($formattedLines -join "`r`n")

            $hasSuccessOutcome = $false
            foreach ($res in $results) {
                $outcome = [string](Get-SpoolDoctorPropertyValue -InputObject $res -PropertyName 'Outcome' -DefaultValue '')
                if ($outcome -eq 'OK') {
                    $hasSuccessOutcome = $true
                    break
                }
            }

            if (-not $isWhatIf -and $hasSuccessOutcome) {
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

function Invoke-SpoolDoctorDiagnose {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [System.Windows.Forms.Form]$Form
    )

    $ui = $Form.Tag
    Sync-SpoolDoctorBusyState -Form $Form -IsBusy $true

    try {
        $selectedTarget = Get-SpoolDoctorSelectedTarget -Form $Form
        $diagnoseParams = Get-SpoolDoctorRemoteParameter -Form $Form -ComputerNames $selectedTarget.ComputerNames
        $diagnoseParams['ErrorAction'] = 'Stop'
        if (-not [string]::IsNullOrWhiteSpace($ui.LogPath)) {
            $diagnoseParams['LogPath'] = $ui.LogPath
        }

        $diagnostics = @(Test-Spooler @diagnoseParams | Where-Object { $null -ne $_ })
        if ($diagnostics.Count -eq 1) {
            Write-SpoolDoctorStatusText -Form $Form -Text (Format-SpoolerDiagnostic -Diagnostic $diagnostics[0])
        }
        elseif ($diagnostics.Count -gt 1) {
            $blocks = @(
                foreach ($diag in $diagnostics) {
                    Format-SpoolerDiagnostic -Diagnostic $diag
                }
            )
            $summaryText = "Diagnóstico em lote concluído ($($diagnostics.Count) máquinas):`r`n`r`n$($blocks -join "`r`n`r`n")"
            Write-SpoolDoctorStatusText -Form $Form -Text $summaryText
        }
    }
    catch {
        $nowText = (Get-Date).ToString('dd/MM/yyyy HH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture)
        Write-SpoolDoctorStatusText -Form $Form -Text "[$nowText] [ERRO] Falha ao executar diagnóstico: $($_.Exception.Message)"
    }
    finally {
        Sync-SpoolDoctorBusyState -Form $Form -IsBusy $false
    }
}

function Show-SpoolDoctorFormDialog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [System.Windows.Forms.Form]$Form
    )

    $null = $Form.ShowDialog()
}

function Close-SpoolDoctorForm {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [System.Windows.Forms.Form]$Form
    )

    $Form.Close()
}

function Invoke-SpoolDoctorElevate {
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

    if (Test-SpoolDoctorElevated) {
        $nowText = (Get-Date).ToString('dd/MM/yyyy HH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture)
        Write-SpoolDoctorStatusText -Form $Form -Text "[$nowText] O SpoolDoctor já está sendo executado como Administrador."
        return
    }

    Sync-SpoolDoctorBusyState -Form $Form -IsBusy $true

    try {
        $elevateParams = @{
            ScriptPath = $ui.ScriptPath
            Force      = $true
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$ui.LogPath)) {
            $elevateParams['LogPath'] = $ui.LogPath
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$ui.AllowedComputersPath)) {
            $elevateParams['AllowedComputersPath'] = $ui.AllowedComputersPath
        }

        $result = Request-SpoolDoctorElevation @elevateParams
        if ($result.ShouldExitCurrentProcess) {
            Close-SpoolDoctorForm -Form $Form
            return
        }

        $nowText = (Get-Date).ToString('dd/MM/yyyy HH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture)
        Write-SpoolDoctorStatusText -Form $Form -Text "[$nowText] [AVISO] $($result.Message)"
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
        [string]$LogPath,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$AllowedComputersPath,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$ScriptPath = $script:SpoolDoctorUIScriptPath,

        [Parameter()]
        [AllowEmptyString()]
        [string]$StartupNotice = ''
    )

    $computerName = if (-not [string]::IsNullOrWhiteSpace($env:COMPUTERNAME)) {
        $env:COMPUTERNAME
    }
    else {
        [System.Environment]::MachineName
    }

    $isElevated = [bool](Test-SpoolDoctorElevated)
    $privilegeTitleSuffix = if ($isElevated) { 'Administrador' } else { 'Usuário padrão' }

    $form = New-Object -TypeName System.Windows.Forms.Form
    $form.Text = "SpoolDoctor - Fila de Impressão ($privilegeTitleSuffix)"
    $form.Size = New-Object -TypeName System.Drawing.Size(1040, 580)
    $form.MinimumSize = New-Object -TypeName System.Drawing.Size(820, 500)
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $form.Font = New-Object -TypeName System.Drawing.Font('Segoe UI', 9)

    $layout = New-Object -TypeName System.Windows.Forms.TableLayoutPanel
    $layout.Dock = [System.Windows.Forms.DockStyle]::Fill
    $layout.Padding = New-Object -TypeName System.Windows.Forms.Padding(10)
    $layout.ColumnCount = 2
    $layout.RowCount = 5
    $null = $layout.ColumnStyles.Add((New-Object -TypeName System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    $null = $layout.ColumnStyles.Add((New-Object -TypeName System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::AutoSize)))
    $null = $layout.RowStyles.Add((New-Object -TypeName System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
    $null = $layout.RowStyles.Add((New-Object -TypeName System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
    $null = $layout.RowStyles.Add((New-Object -TypeName System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 65)))
    $null = $layout.RowStyles.Add((New-Object -TypeName System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
    $null = $layout.RowStyles.Add((New-Object -TypeName System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 35)))

    $topPanel = New-Object -TypeName System.Windows.Forms.FlowLayoutPanel
    $topPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
    $topPanel.AutoSize = $true
    $topPanel.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
    $topPanel.WrapContents = $true
    $topPanel.Margin = New-Object -TypeName System.Windows.Forms.Padding(0)
    $topPanelBottomPadding = if ($isElevated) { 4 } else { 2 }
    $topPanel.Padding = New-Object -TypeName System.Windows.Forms.Padding(0, 0, 0, $topPanelBottomPadding)

    $targetLabel = New-Object -TypeName System.Windows.Forms.Label
    $targetLabel.Text = 'Máquina:'
    $targetLabel.AutoSize = $true
    $targetLabel.Font = New-Object -TypeName System.Drawing.Font('Segoe UI', 9.5, [System.Drawing.FontStyle]::Bold)
    $targetLabel.Margin = New-Object -TypeName System.Windows.Forms.Padding(0, 6, 6, 2)

    $targetComboBox = New-Object -TypeName System.Windows.Forms.ComboBox
    $targetComboBox.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
    $targetComboBox.Width = 250
    $targetComboBox.Margin = New-Object -TypeName System.Windows.Forms.Padding(0, 3, 12, 2)

    $filterLabel = New-Object -TypeName System.Windows.Forms.Label
    $filterLabel.Text = 'Impressora (opcional):'
    $filterLabel.AutoSize = $true
    $filterLabel.Margin = New-Object -TypeName System.Windows.Forms.Padding(0, 6, 6, 2)

    $filterTextBox = New-Object -TypeName System.Windows.Forms.TextBox
    $filterTextBox.Width = 200
    $filterTextBox.Margin = New-Object -TypeName System.Windows.Forms.Padding(0, 3, 10, 2)

    $refreshButton = New-Object -TypeName System.Windows.Forms.Button
    $refreshButton.Text = 'Atualizar'
    $refreshButton.AutoSize = $true
    $refreshButton.Padding = New-Object -TypeName System.Windows.Forms.Padding(10, 2, 10, 2)
    $refreshButton.Margin = New-Object -TypeName System.Windows.Forms.Padding(0, 1, 12, 2)

    $credentialCheckBox = New-Object -TypeName System.Windows.Forms.CheckBox
    $credentialCheckBox.Text = 'Usar credencial alternativa'
    $credentialCheckBox.AutoSize = $true
    $credentialCheckBox.Enabled = $false
    $credentialCheckBox.Checked = $false
    $credentialCheckBox.Margin = New-Object -TypeName System.Windows.Forms.Padding(0, 5, 0, 2)

    $topPanel.Controls.AddRange(@($targetLabel, $targetComboBox, $filterLabel, $filterTextBox, $refreshButton, $credentialCheckBox))

    $privilegeLabel = New-Object -TypeName System.Windows.Forms.Label
    $privilegeLabel.AutoSize = $true
    $privilegeLabel.Font = New-Object -TypeName System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
    $privilegeLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleRight
    $privilegeLabel.Anchor = [System.Windows.Forms.AnchorStyles]::Right
    $privilegeLabel.Margin = New-Object -TypeName System.Windows.Forms.Padding(12, 2, 0, 4)
    if ($isElevated) {
        $privilegeLabel.Text = 'Privilégio: Administrador'
        $privilegeLabel.ForeColor = [System.Drawing.Color]::DarkGreen
    }
    else {
        $privilegeLabel.Text = 'Privilégio: Usuário padrão (somente leitura)'
        $privilegeLabel.ForeColor = [System.Drawing.Color]::DarkRed
    }

    $elevatePanel = New-Object -TypeName System.Windows.Forms.FlowLayoutPanel
    $elevatePanel.Dock = [System.Windows.Forms.DockStyle]::Fill
    $elevatePanel.AutoSize = $true
    $elevatePanel.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
    $elevatePanel.FlowDirection = [System.Windows.Forms.FlowDirection]::RightToLeft
    $elevatePanel.WrapContents = $false
    $elevatePanel.Margin = New-Object -TypeName System.Windows.Forms.Padding(0)
    $elevatePanel.Padding = New-Object -TypeName System.Windows.Forms.Padding(0, 0, 0, 6)
    $elevatePanel.Visible = (-not $isElevated)

    $elevateButton = New-Object -TypeName System.Windows.Forms.Button
    $elevateButton.Text = 'Reiniciar como Administrador'
    $elevateButton.AutoSize = $true
    $elevateButton.Padding = New-Object -TypeName System.Windows.Forms.Padding(10, 2, 10, 2)
    $elevateButton.Margin = New-Object -TypeName System.Windows.Forms.Padding(0, 0, 0, 2)
    $elevateButton.Visible = (-not $isElevated)
    $elevateButton.Enabled = (-not $isElevated)

    $elevatePanel.Controls.Add($elevateButton)

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
        @{ Name = 'ComputerName'; Header = 'Máquina'; Weight = 15 },
        @{ Name = 'Id'; Header = 'ID'; Weight = 8 },
        @{ Name = 'PrinterName'; Header = 'Impressora'; Weight = 20 },
        @{ Name = 'Document'; Header = 'Documento'; Weight = 22 },
        @{ Name = 'Status'; Header = 'Status'; Weight = 12 },
        @{ Name = 'Size'; Header = 'Tamanho'; Weight = 9 },
        @{ Name = 'Age'; Header = 'Idade'; Weight = 9 },
        @{ Name = 'SubmittedAt'; Header = 'Enviado em'; Weight = 16 }
    )
    foreach ($colDef in $columns) {
        $colIndex = $grid.Columns.Add($colDef.Name, $colDef.Header)
        $grid.Columns[$colIndex].FillWeight = $colDef.Weight
    }

    $actionPanel = New-Object -TypeName System.Windows.Forms.FlowLayoutPanel
    $actionPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
    $actionPanel.AutoSize = $true
    $actionPanel.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
    $actionPanel.WrapContents = $true
    $actionPanel.Margin = New-Object -TypeName System.Windows.Forms.Padding(0)
    $actionPanel.Padding = New-Object -TypeName System.Windows.Forms.Padding(0, 6, 0, 6)

    $whatIfCheckBox = New-Object -TypeName System.Windows.Forms.CheckBox
    $whatIfCheckBox.Text = 'Modo simulação (-WhatIf)'
    $whatIfCheckBox.AutoSize = $true
    $whatIfCheckBox.Margin = New-Object -TypeName System.Windows.Forms.Padding(0, 6, 16, 4)

    $backupCheckBox = New-Object -TypeName System.Windows.Forms.CheckBox
    $backupCheckBox.Text = 'Fazer backup antes de resetar'
    $backupCheckBox.Checked = $true
    $backupCheckBox.AutoSize = $true
    $backupCheckBox.Margin = New-Object -TypeName System.Windows.Forms.Padding(0, 6, 16, 4)

    $diagnoseButton = New-Object -TypeName System.Windows.Forms.Button
    $diagnoseButton.Text = 'Diagnosticar'
    $diagnoseButton.AutoSize = $true
    $diagnoseButton.Padding = New-Object -TypeName System.Windows.Forms.Padding(10, 2, 10, 2)
    $diagnoseButton.Margin = New-Object -TypeName System.Windows.Forms.Padding(0, 2, 10, 4)

    $cancelButton = New-Object -TypeName System.Windows.Forms.Button
    $cancelButton.Text = 'Cancelar job selecionado'
    $cancelButton.AutoSize = $true
    $cancelButton.Enabled = $false
    $cancelButton.Padding = New-Object -TypeName System.Windows.Forms.Padding(10, 2, 10, 2)
    $cancelButton.Margin = New-Object -TypeName System.Windows.Forms.Padding(0, 2, 10, 4)

    $resetButton = New-Object -TypeName System.Windows.Forms.Button
    $resetButton.Text = 'Resetar Spooler'
    $resetButton.AutoSize = $true
    $resetButton.Enabled = $isElevated
    $resetButton.Padding = New-Object -TypeName System.Windows.Forms.Padding(10, 2, 10, 2)
    $resetButton.Margin = New-Object -TypeName System.Windows.Forms.Padding(0, 2, 0, 4)

    $actionPanel.Controls.AddRange(@($whatIfCheckBox, $backupCheckBox, $diagnoseButton, $cancelButton, $resetButton))

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
    $layout.Controls.Add($privilegeLabel, 1, 0)
    $layout.Controls.Add($elevatePanel, 0, 1)
    $layout.SetColumnSpan($elevatePanel, 2)
    $layout.Controls.Add($grid, 0, 2)
    $layout.SetColumnSpan($grid, 2)
    $layout.Controls.Add($actionPanel, 0, 3)
    $layout.SetColumnSpan($actionPanel, 2)
    $layout.Controls.Add($statusGroup, 0, 4)
    $layout.SetColumnSpan($statusGroup, 2)

    $form.Controls.Add($layout)

    $resolvedLogPath = if ($PSBoundParameters.ContainsKey('LogPath')) { $LogPath } else { $null }
    $resolvedAllowPath = if ($PSBoundParameters.ContainsKey('AllowedComputersPath')) { $AllowedComputersPath } else { $null }
    $resolvedScriptPath = if (-not [string]::IsNullOrWhiteSpace($ScriptPath)) { $ScriptPath } else { $script:SpoolDoctorUIScriptPath }
    $resolvedStartupNotice = if (-not [string]::IsNullOrWhiteSpace($StartupNotice)) { $StartupNotice } else { '' }

    $targetOptions = New-Object -TypeName 'System.Collections.Generic.List[PSCustomObject]'
    $localDisplayText = "Local ($computerName)"
    $targetOptions.Add([PSCustomObject]@{
        Mode             = 'Local'
        DisplayText      = $localDisplayText
        ComputerNames    = @()
        IsRemote         = $false
        IsBatch          = $false
        IsPrintServer    = $false
        PrintServerNames = @()
    })
    $null = $targetComboBox.Items.Add($localDisplayText)

    try {
        $allowQueryParams = @{ ErrorAction = 'Stop' }
        if (-not [string]::IsNullOrWhiteSpace([string]$resolvedAllowPath)) {
            $allowQueryParams['AllowedComputersPath'] = $resolvedAllowPath
        }

        $allowedEntries = @(Get-SpoolerAllowedComputer @allowQueryParams | Where-Object { $null -ne $_ })
        $allRemoteNames = New-Object -TypeName 'System.Collections.Generic.List[string]'
        $printServerNames = New-Object -TypeName 'System.Collections.Generic.List[string]'

        foreach ($entry in $allowedEntries) {
            $entryName = [string](Get-SpoolDoctorPropertyValue -InputObject $entry -PropertyName 'ComputerName' -DefaultValue '')
            if ([string]::IsNullOrWhiteSpace($entryName)) {
                continue
            }

            $entryIsPrintServer = [bool](Get-SpoolDoctorPropertyValue -InputObject $entry -PropertyName 'IsPrintServer' -DefaultValue $false)
            $entryDisplay = if ($entryIsPrintServer) {
                "$entryName [Servidor de Impressão]"
            }
            else {
                $entryName
            }

            $allRemoteNames.Add($entryName)
            if ($entryIsPrintServer) {
                $printServerNames.Add($entryName)
            }

            $targetOptions.Add([PSCustomObject]@{
                Mode             = 'SingleRemote'
                DisplayText      = $entryDisplay
                ComputerNames    = @($entryName)
                IsRemote         = $true
                IsBatch          = $false
                IsPrintServer    = $entryIsPrintServer
                PrintServerNames = if ($entryIsPrintServer) { @($entryName) } else { @() }
            })
            $null = $targetComboBox.Items.Add($entryDisplay)
        }

        if ($allRemoteNames.Count -ge 2) {
            $batchDisplay = "Todas autorizadas ($($allRemoteNames.Count) máquinas)"
            $targetOptions.Add([PSCustomObject]@{
                Mode             = 'BatchRemote'
                DisplayText      = $batchDisplay
                ComputerNames    = $allRemoteNames.ToArray()
                IsRemote         = $true
                IsBatch          = $true
                IsPrintServer    = $false
                PrintServerNames = $printServerNames.ToArray()
            })
            $null = $targetComboBox.Items.Add($batchDisplay)
        }
    }
    catch {
        $allowErrorNotice = "Não foi possível carregar a lista de máquinas remotas (allow-list): $($_.Exception.Message) Operando apenas em modo local."
        if ([string]::IsNullOrWhiteSpace($resolvedStartupNotice)) {
            $resolvedStartupNotice = $allowErrorNotice
        }
        else {
            $resolvedStartupNotice = "$resolvedStartupNotice`r`n$allowErrorNotice"
        }
    }

    $targetComboBox.SelectedIndex = 0

    $form.Tag = @{
        ComputerName               = $computerName
        LogPath                    = $resolvedLogPath
        AllowedComputersPath       = $resolvedAllowPath
        IsElevated                 = $isElevated
        ScriptPath                 = $resolvedScriptPath
        StartupNotice              = $resolvedStartupNotice
        TargetOptions              = $targetOptions.ToArray()
        Credential                 = $null
        UpdatingCredentialCheckBox = $false
        TargetLabel                = $targetLabel
        TargetComboBox             = $targetComboBox
        CredentialCheckBox         = $credentialCheckBox
        PrivilegeLabel             = $privilegeLabel
        ElevateButton              = $elevateButton
        FilterTextBox              = $filterTextBox
        RefreshButton              = $refreshButton
        Grid                       = $grid
        WhatIfCheckBox             = $whatIfCheckBox
        BackupCheckBox             = $backupCheckBox
        DiagnoseButton             = $diagnoseButton
        CancelButton               = $cancelButton
        ResetButton                = $resetButton
        StatusTextBox              = $statusTextBox
    }

    if (-not [string]::IsNullOrWhiteSpace($resolvedStartupNotice)) {
        $nowText = (Get-Date).ToString('dd/MM/yyyy HH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture)
        Write-SpoolDoctorStatusText -Form $form -Text "[$nowText] [AVISO] $resolvedStartupNotice"
    }

    $targetComboBox.Add_SelectedIndexChanged({
        $owner = $this.FindForm()
        if ($null -ne $owner) {
            Sync-SpoolDoctorTargetState -Form $owner
        }
    })
    $credentialCheckBox.Add_CheckedChanged({
        $owner = $this.FindForm()
        if ($null -ne $owner) {
            Invoke-SpoolDoctorCredentialChange -Form $owner
        }
    })
    $clearCredentialHandler = {
        if ($null -ne $this.Tag) {
            $this.Tag.Credential = $null
        }
    }
    $form.Add_FormClosed($clearCredentialHandler)
    $form.Add_Disposed($clearCredentialHandler)

    $refreshButton.Add_Click({
        $owner = $this.FindForm()
        if ($null -ne $owner) {
            Invoke-SpoolDoctorRefresh -Form $owner
        }
    })
    $elevateButton.Add_Click({
        $owner = $this.FindForm()
        if ($null -ne $owner) {
            Invoke-SpoolDoctorElevate -Form $owner
        }
    })
    $diagnoseButton.Add_Click({
        $owner = $this.FindForm()
        if ($null -ne $owner) {
            Invoke-SpoolDoctorDiagnose -Form $owner
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

    Sync-SpoolDoctorTargetState -Form $form

    return $form
}

function Show-SpoolDoctorUI {
    [CmdletBinding()]
    param(
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$LogPath,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$AllowedComputersPath,

        [Parameter()]
        [switch]$NoElevate,

        [Parameter()]
        [switch]$ElevationAttempted,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$ScriptPath = $script:SpoolDoctorUIScriptPath
    )

    $elevationParams = @{
        ScriptPath = $ScriptPath
    }
    if ($PSBoundParameters.ContainsKey('LogPath')) {
        $elevationParams['LogPath'] = $LogPath
    }
    if ($PSBoundParameters.ContainsKey('AllowedComputersPath')) {
        $elevationParams['AllowedComputersPath'] = $AllowedComputersPath
    }
    if ($NoElevate) {
        $elevationParams['NoElevate'] = $true
    }
    if ($ElevationAttempted) {
        $elevationParams['ElevationAttempted'] = $true
    }

    $elevationResult = Request-SpoolDoctorElevation @elevationParams
    if ($elevationResult.ShouldExitCurrentProcess) {
        return
    }

    Import-SpoolDoctorModule -Force
    [System.Windows.Forms.Application]::EnableVisualStyles()

    $formParams = @{}
    if ($PSBoundParameters.ContainsKey('LogPath')) {
        $formParams['LogPath'] = $LogPath
    }
    if ($PSBoundParameters.ContainsKey('AllowedComputersPath')) {
        $formParams['AllowedComputersPath'] = $AllowedComputersPath
    }
    if (-not [string]::IsNullOrWhiteSpace($ScriptPath)) {
        $formParams['ScriptPath'] = $ScriptPath
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$elevationResult.Message)) {
        $formParams['StartupNotice'] = [string]$elevationResult.Message
    }

    $form = Initialize-SpoolDoctorForm @formParams
    try {
        $form.Add_Shown({
            $hasStartupNotice = ($null -ne $this.Tag -and -not [string]::IsNullOrWhiteSpace([string]$this.Tag.StartupNotice))
            Invoke-SpoolDoctorRefresh -Form $this -PreserveStatus:$hasStartupNotice
        })
        Show-SpoolDoctorFormDialog -Form $form
    }
    finally {
        $form.Dispose()
    }
}

Import-SpoolDoctorModule

if (-not $NoShow -and $MyInvocation.InvocationName -ne '.') {
    $showParams = @{
        ScriptPath = $script:SpoolDoctorUIScriptPath
    }
    if ($PSBoundParameters.ContainsKey('LogPath')) {
        $showParams['LogPath'] = $LogPath
    }
    if ($PSBoundParameters.ContainsKey('AllowedComputersPath')) {
        $showParams['AllowedComputersPath'] = $AllowedComputersPath
    }
    if ($NoElevate) {
        $showParams['NoElevate'] = $true
    }
    if ($ElevationAttempted) {
        $showParams['ElevationAttempted'] = $true
    }
    Show-SpoolDoctorUI @showParams
}
