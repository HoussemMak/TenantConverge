function Get-TcMember {
    <#
    .SYNOPSIS
    Reads a member that may be missing, from a dictionary, an object, a list of them, or $null.

    .DESCRIPTION
    The scripts read what Graph and the service cmdlets return, and strict mode stops on a dotted read of a
    missing member. On a list it reads each item, as PowerShell does for a dotted read. A missing member
    gives nothing, so a script must not read nothing as a value.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)][AllowNull()]$InputObject,
        [Parameter(Mandatory, Position = 1)][string]$Name
    )

    if ($null -eq $InputObject) { return }
    if ($InputObject -is [System.Collections.IDictionary]) {
        if ($InputObject.Contains($Name)) { return $InputObject[$Name] }
        return
    }
    if ($InputObject -isnot [string] -and $InputObject -is [System.Collections.IEnumerable]) {
        foreach ($item in $InputObject) { Get-TcMember -InputObject $item -Name $Name }
        return
    }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($property) { return $property.Value }
}

function Get-TcText {
    <#
    .SYNOPSIS
    Reads a member as text: an empty string when it is missing, never $null.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Position = 0)][AllowNull()]$InputObject,
        [Parameter(Mandatory, Position = 1)][string]$Name
    )

    # A variable that holds nothing casts to $null, unlike $null itself.
    $value = Get-TcMember -InputObject $InputObject -Name $Name
    if ($null -eq $value) { return '' }
    [string]$value
}

function Get-TcSourceGroup {
    <#
    .SYNOPSIS
    The groups a project plans to create for a source, from the SourceGroups setting: @{ S1 = @(@{ name = 'Finance' }) }.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Tenant
    )

    $groups = Get-TcRemediationOption 'SourceGroups'
    if ($groups -is [System.Collections.IDictionary] -and $groups.Contains($Tenant)) { @($groups[$Tenant]) }
}

function ConvertTo-TcSecret {
    <#
    .SYNOPSIS
    Turns text that a service returned into a secure string, for a file only this Windows account can read.
    #>
    [CmdletBinding()]
    [OutputType([securestring])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text
    )

    $secret = [securestring]::new()
    foreach ($character in $Text.ToCharArray()) { $secret.AppendChar($character) }
    $secret.MakeReadOnly()
    $secret
}

function Get-TcCount {
    <#
    .SYNOPSIS
    The number of items of a value that may be $null, one object, a list or a dictionary.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Position = 0)][AllowNull()]$InputObject
    )

    if ($null -eq $InputObject) { return 0 }
    $property = $InputObject.PSObject.Properties['Count']
    if ($property) { return [int]$property.Value }
    @($InputObject).Count
}

function Get-TcSourceRole {
    <#
    .SYNOPSIS
    The source roles of the project.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    @($script:TcRemediationRun['Sources'])
}

function Get-TcProjectRole {
    <#
    .SYNOPSIS
    The roles of the project: the target and each source.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    @($script:TcRemediationRun['Known'])
}

function Get-TcObjectName {
    <#
    .SYNOPSIS
    The name of an object a script creates: the ObjectPrefix setting, then a neutral text.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Text
    )

    "$(Get-TcRemediationOption 'ObjectPrefix')$Text"
}

function Get-TcRemediationOutput {
    <#
    .SYNOPSIS
    The output folder of the project.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $script:TcRemediationRun['Output']
}

function Get-TcDecisionName {
    <#
    .SYNOPSIS
    A decisions file name without its folder and extension.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Name
    )

    [System.IO.Path]::GetFileName($Name) -replace '\.csv$', ''
}

function Test-TcDecisionFile {
    <#
    .SYNOPSIS
    True when a decisions file exists.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Name
    )

    Test-Path -LiteralPath (Join-Path (Get-TcDecisionFolder) ('{0}.csv' -f (Get-TcDecisionName $Name)))
}

function Read-TcDecisionRow {
    <#
    .SYNOPSIS
    The usable rows of a decisions file of this or of another remediation. A refused row raises an alert.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Name
    )

    $file = Read-TcDecisionFile -Name (Get-TcDecisionName $Name)
    foreach ($number in @($file['Refused'])) { Write-TcRemediationAlert ('{0}, row {1}: a cell starts with a formula sign. The row is not used.' -f $file['Path'], $number) }
    @($file['Rows'])
}

function Export-TcDecisionRow {
    <#
    .SYNOPSIS
    Writes rows to a file of the decisions folder, with every cell safe for Excel.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)][AllowNull()]$InputObject,
        [Parameter(Mandatory, Position = 0)][string]$Name
    )

    begin { $rows = [System.Collections.Generic.List[object]]::new() }
    process { if ($null -ne $InputObject) { $rows.Add($InputObject) } }
    end {
        if (-not $rows.Count) { return }
        New-Item -ItemType Directory -Force -Path (Get-TcDecisionFolder) | Out-Null
        $columns = [System.Collections.Generic.List[string]]::new()
        foreach ($row in $rows) {
            $names = if ($row -is [System.Collections.IDictionary]) { @($row.Keys) } else { @($row.PSObject.Properties | ForEach-Object Name) }
            foreach ($column in $names) { if ($column -notin $columns) { $columns.Add($column) } }
        }
        Write-TcDecisionFile -Path (Join-Path (Get-TcDecisionFolder) ('{0}.csv' -f (Get-TcDecisionName $Name))) -Row $rows.ToArray() -Column $columns.ToArray()
    }
}

function Test-TcCutoverStep {
    <#
    .SYNOPSIS
    True when a person marked a cutover step Done for a tenant, in decisions\CUTOVER-STEPS.csv.

    .DESCRIPTION
    This module does not run a cutover. A remediation that must wait for one of its steps reads this file,
    with the columns Tenant, Step and Decision. With no file, no step is done.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Tenant,
        [Parameter(Mandatory)][string]$Step
    )

    $done = @(Read-TcDecisionRow 'CUTOVER-STEPS') | Where-Object { (Get-TcProperty $_ 'Tenant') -eq $Tenant -and (Get-TcProperty $_ 'Step') -eq $Step -and (Get-TcProperty $_ 'Decision') -ceq 'Done' }
    [bool]$done
}

function Import-TcMatrixDraft {
    <#
    .SYNOPSIS
    The rows of the matrix of a source: the validated one if it exists, otherwise the draft.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Source
    )

    $matrix = Import-TcSourceMatrix -Source $Source
    if ($matrix['State'] -eq 'Missing') { Write-TcRemediationAlert "$Source`: no draft matrix, the accounts of this source were not read." }
    @($matrix['Rows'])
}

function Get-TcProtectedMatrixRow {
    <#
    .SYNOPSIS
    The protected accounts that are in the matrix of a source.

    .DESCRIPTION
    When sign-ins are blocked in a source, protected accounts stay open, and any enabled account of the
    matrix then fails the check, whatever its decision: only removing the row works.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Source
    )

    $info = Get-TcRemediationTenant -Tenant $Source
    $protected = @(Get-TcProtectedAccount $Source)
    @(@((Import-TcSourceMatrix -Source $Source)['Rows']) | Where-Object { $_['Source UPN'] -in $protected -or (Test-TcProtectedAccount -Account ([string]$_['Source UPN']) -Info $info) } | ForEach-Object { $_['Source UPN'] })
}

function Get-TcDomainHolder {
    <#
    .SYNOPSIS
    The display names of the accounts of a source that hold a migrated domain and have no mailbox.

    .DESCRIPTION
    Exchange does not see these accounts, so releasing mail addresses leaves them on the domain, and the
    removal of the domain stops on them. The snapshot is what tells: this is a reading, not a proof.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Tenant
    )

    $info = Get-TcRemediationTenant -Tenant $Tenant
    $mailboxes = @{}
    foreach ($row in @(Get-TcRemediationTable $Tenant 'mailboxes')) { $mailboxes[([string]$row['UPN']).ToLowerInvariant()] = $true }
    @(Get-TcRemediationTable $Tenant 'users' | Where-Object { (Get-TcAddressDomain ([string]$_['UPN'])) -in $info['Domains'] -and -not $mailboxes.ContainsKey(([string]$_['UPN']).ToLowerInvariant()) } | ForEach-Object { [string]$_['Name'] } | Select-Object -Unique)
}

function Read-TcSourceAddress {
    <#
    .SYNOPSIS
    The addresses a cutover froze for a source, in <output>\decisions\source-addresses-<role>.json. Nothing when there is no such file.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Source
    )

    $path = Join-Path (Get-TcDecisionFolder) "source-addresses-$Source.json"
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    $data = Read-TcJsonFile -Path $path
    $addresses = @{}
    foreach ($key in @($data.Keys)) { $addresses[([string]$key).ToLowerInvariant()] = @(@(Get-TcProperty $data[$key] 'addresses' @()) | ForEach-Object { ([string]$_).ToLowerInvariant() }) }
    $addresses
}
