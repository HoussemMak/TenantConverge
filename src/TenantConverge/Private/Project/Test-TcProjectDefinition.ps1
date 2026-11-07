function Test-TcProjectDefinition {
    <#
    .SYNOPSIS
    Validates a project and returns one record per problem.

    .DESCRIPTION
    This is the only place that decides whether a project is valid. It returns records with Code,
    Path and Message, and returns nothing when the project is valid. It tolerates any shape of input
    because project files can be edited by hand.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][AllowNull()]$Project
    )

    function Add-Problem {
        param([string]$Code, [string]$Path, [string]$Message)
        [pscustomobject]@{ Code = $Code; Path = $Path; Message = $Message }
    }

    function Test-Whole {
        param($Value)
        ($Value -is [int] -or $Value -is [long]) -and $Value -ge 1
    }

    function Test-Tenant {
        param($Tenant, [string]$Path)

        if (-not (Test-TcDisplayName -Value (Get-TcProperty $Tenant 'displayName'))) {
            Add-Problem 'TC1010' "$Path.displayName" 'A display name is required, up to 64 characters, with no control characters.'
        }

        $domain = ConvertTo-TcDomain -Value (Get-TcProperty $Tenant 'primaryDomain')
        if (-not (Test-TcDomainName -Value $domain)) {
            Add-Problem 'TC1004' "$Path.primaryDomain" "'$domain' is not a valid domain name."
        }

        $tenantId = Get-TcProperty $Tenant 'tenantId'
        $parsed = [guid]::Empty
        if ($null -ne $tenantId -and -not [guid]::TryParse([string]$tenantId, [ref]$parsed)) {
            Add-Problem 'TC1005' "$Path.tenantId" "'$tenantId' is not a valid tenant ID."
        }
    }

    $version = Get-TcProperty $Project 'schemaVersion'
    if ($version -ne $script:TcSchemaVersion -or -not (Test-Whole $version)) {
        $shown = if ($null -eq $version) { 'none' } else { $version }
        Add-Problem 'TC1008' 'schemaVersion' "This project uses schema version $shown. This module reads version $script:TcSchemaVersion."
    }

    $target = Get-TcProperty $Project 'target'
    if ($null -eq $target) {
        Add-Problem 'TC1003' 'target' 'A project needs exactly 1 target tenant.'
    }
    else {
        Test-Tenant $target 'target'
        if ((Get-TcProperty $target 'state') -cnotin 'Production', 'New') {
            Add-Problem 'TC1013' 'target.state' 'Target state must be Production or New.'
        }
    }

    # Get-TcProperty unrolls a list of one, so the shape is read from the property itself.
    $holder = if ($Project -is [System.Collections.IDictionary]) { [pscustomobject]$Project } else { $Project }
    $listed = if ($null -ne $holder) { $holder.PSObject.Properties['sources'] }
    if ($listed -and $null -ne $listed.Value -and $listed.Value -isnot [System.Collections.IList]) {
        Add-Problem 'TC1016' 'sources' 'Sources must be a list, in [ ], even for one source.'
    }

    $sources = @(Get-TcProperty $Project 'sources' | Where-Object { $null -ne $_ })
    if ($sources.Count -eq 0) {
        Add-Problem 'TC1001' 'sources' 'A project needs at least 1 source tenant.'
    }
    elseif ($sources.Count -gt $script:TcMaxSources) {
        Add-Problem 'TC1002' 'sources' "TenantConverge supports at most $script:TcMaxSources source tenants into 1 target. This project has $($sources.Count)."
    }
    else {
        for ($i = 0; $i -lt $sources.Count; $i++) {
            if ((Get-TcProperty $sources[$i] 'role') -cne "S$($i + 1)") {
                Add-Problem 'TC1009' 'sources' 'Source roles must be S1, S2, S3, in order.'
                break
            }
        }
    }

    for ($i = 0; $i -lt $sources.Count; $i++) {
        Test-Tenant $sources[$i] "sources[$i]"
    }

    $seen = @{}
    foreach ($tenant in @($target) + $sources) {
        $keys = @(ConvertTo-TcDomain -Value (Get-TcProperty $tenant 'primaryDomain'))
        $tenantId = Get-TcProperty $tenant 'tenantId'
        if ($null -ne $tenantId) { $keys += ([string]$tenantId).ToLowerInvariant() }

        foreach ($key in $keys) {
            if (-not $key) { continue }
            if ($seen.ContainsKey($key)) {
                Add-Problem 'TC1006' 'sources' "'$key' appears more than once. Each tenant can only appear once in a project."
            }
            $seen[$key] = $true
        }
    }

    if ($sources.Count -gt 0) {
        $waves = @($sources | ForEach-Object { Get-TcProperty $_ 'wave' })
        $whole = ($waves.Count -eq $sources.Count) -and (@($waves | Where-Object { -not (Test-Whole $_) }).Count -eq 0)
        if (-not $whole) {
            Add-Problem 'TC1007' 'sources' "Each source needs a wave, a whole number from 1. Found: $($waves -join ', ')."
        }
        else {
            $distinct = @($waves | Sort-Object -Unique)
            if (($distinct -join ',') -ne ((1..$distinct.Count) -join ',')) {
                Add-Problem 'TC1007' 'sources' "Waves must start at 1 and have no gaps. Found: $($waves -join ', ')."
            }
        }
    }

    if ((Get-TcProperty (Get-TcProperty $Project 'access') 'mode') -cnotin 'Browser', 'Application') {
        Add-Problem 'TC1011' 'access.mode' 'Access mode must be Browser or Application.'
    }

    if ([string]::IsNullOrWhiteSpace([string](Get-TcProperty (Get-TcProperty $Project 'output') 'path'))) {
        Add-Problem 'TC1012' 'output.path' 'An output folder is required.'
    }
}
