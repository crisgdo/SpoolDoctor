function Resolve-SpoolerTarget {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$ComputerName,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$AllowedComputersPath,

        [Parameter()]
        [switch]$HasCredential
    )

    $localName = if (-not [string]::IsNullOrWhiteSpace($env:COMPUTERNAME)) {
        $env:COMPUTERNAME.Trim()
    }
    else {
        [System.Environment]::MachineName.Trim()
    }

    $hasComputerName = $PSBoundParameters.ContainsKey('ComputerName')
    if (-not $hasComputerName) {
        if ($HasCredential) {
            return [PSCustomObject]@{
                IsValid             = $false
                IsLocal             = $true
                ComputerName        = $localName
                IsPrintServerListed = $false
                FailureOutcome      = 'Failed'
                ErrorMessage        = "Parâmetro -Credential inválido na execução local da máquina '$localName': informe um -ComputerName remoto autorizado."
            }
        }

        return [PSCustomObject]@{
            IsValid             = $true
            IsLocal             = $true
            ComputerName        = $localName
            IsPrintServerListed = $false
            FailureOutcome      = $null
            ErrorMessage        = $null
        }
    }

    $trimmedInput = if ($null -eq $ComputerName) { '' } else { $ComputerName.Trim() }
    if (-not (Test-ValidComputerName -ComputerName $ComputerName)) {
        $displayName = if ([string]::IsNullOrWhiteSpace($trimmedInput)) { '(inválido)' } else { $trimmedInput }
        return [PSCustomObject]@{
            IsValid             = $false
            IsLocal             = $false
            ComputerName        = $displayName
            IsPrintServerListed = $false
            FailureOutcome      = 'Failed'
            ErrorMessage        = "Nome de máquina inválido em -ComputerName ('$displayName'): informe apenas um hostname ou FQDN válido (IP literal, espaços e caracteres especiais não são permitidos)."
        }
    }

    $localAliases = New-Object -TypeName 'System.Collections.Generic.List[string]'
    $localAliases.Add('localhost')
    $localAliases.Add($localName)
    if (-not [string]::IsNullOrWhiteSpace($env:USERDNSDOMAIN)) {
        $localAliases.Add("$localName.$($env:USERDNSDOMAIN.Trim())")
    }

    $isLocalAlias = $false
    foreach ($alias in $localAliases) {
        if ([string]::Equals($trimmedInput, $alias, [System.StringComparison]::OrdinalIgnoreCase)) {
            $isLocalAlias = $true
            break
        }
    }

    if ($isLocalAlias) {
        if ($HasCredential) {
            return [PSCustomObject]@{
                IsValid             = $false
                IsLocal             = $true
                ComputerName        = $localName
                IsPrintServerListed = $false
                FailureOutcome      = 'Failed'
                ErrorMessage        = "Parâmetro -Credential não pode ser usado quando -ComputerName aponta para a máquina local '$localName'."
            }
        }

        return [PSCustomObject]@{
            IsValid             = $true
            IsLocal             = $true
            ComputerName        = $localName
            IsPrintServerListed = $false
            FailureOutcome      = $null
            ErrorMessage        = $null
        }
    }

    try {
        $allowParams = @{}
        if ($PSBoundParameters.ContainsKey('AllowedComputersPath')) {
            $allowParams['Path'] = $AllowedComputersPath
        }
        $allowedEntries = @(Get-AllowedComputer @allowParams)
    }
    catch {
        return [PSCustomObject]@{
            IsValid             = $false
            IsLocal             = $false
            ComputerName        = $trimmedInput
            IsPrintServerListed = $false
            FailureOutcome      = 'Failed'
            ErrorMessage        = "Falha ao carregar a allow-list para validar a máquina '$trimmedInput': $($_.Exception.Message)"
        }
    }

    $matchedEntry = $null
    foreach ($entry in $allowedEntries) {
        if ($null -eq $entry) {
            continue
        }
        if ([string]::Equals([string]$entry.ComputerName, $trimmedInput, [System.StringComparison]::OrdinalIgnoreCase)) {
            $matchedEntry = $entry
            break
        }
    }

    if ($null -eq $matchedEntry) {
        return [PSCustomObject]@{
            IsValid             = $false
            IsLocal             = $false
            ComputerName        = $trimmedInput
            IsPrintServerListed = $false
            FailureOutcome      = 'Failed'
            ErrorMessage        = "A máquina '$trimmedInput' não está autorizada na allow-list (config/allowed-computers.txt). Execução remota recusada."
        }
    }

    return [PSCustomObject]@{
        IsValid             = $true
        IsLocal             = $false
        ComputerName        = [string]$matchedEntry.ComputerName
        IsPrintServerListed = [bool]$matchedEntry.IsPrintServer
        FailureOutcome      = $null
        ErrorMessage        = $null
    }
}
