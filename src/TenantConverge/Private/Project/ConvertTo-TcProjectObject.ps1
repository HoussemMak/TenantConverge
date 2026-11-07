function ConvertTo-TcProjectObject {
    <#
    .SYNOPSIS
    Builds a project in its file format, assigning source roles in order.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$TargetDomain,
        [Parameter(Mandatory)][string]$TargetDisplayName,
        [Parameter(Mandatory)][string]$TargetState,
        [Parameter(Mandatory)][AllowEmptyCollection()][hashtable[]]$Source,
        [string]$AccessMode = 'Browser',
        [string]$OutputPath = './output',
        [AllowEmptyCollection()][string[]]$Team = @()
    )

    $sources = @()
    for ($i = 0; $i -lt $Source.Count; $i++) {
        $entry = $Source[$i]
        $sources += [pscustomobject][ordered]@{
            role          = "S$($i + 1)"
            displayName   = $entry['DisplayName']
            primaryDomain = ConvertTo-TcDomain -Value $entry['PrimaryDomain']
            tenantId      = $entry['TenantId']
            wave          = if ($entry.ContainsKey('Wave')) { $entry['Wave'] } else { 1 }
        }
    }

    [pscustomobject][ordered]@{
        schemaVersion = $script:TcSchemaVersion
        name          = $Name
        target        = [pscustomobject][ordered]@{
            displayName   = $TargetDisplayName
            primaryDomain = ConvertTo-TcDomain -Value $TargetDomain
            tenantId      = $null
            state         = $TargetState
        }
        sources       = $sources
        access        = [pscustomobject]@{ mode = $AccessMode }
        output        = [pscustomobject]@{ path = $OutputPath }
        team          = @($Team)
    }
}
