function ConvertTo-TcSettingRow {
    <#
    .SYNOPSIS
    Turns a settings object into Setting and Value rows. Technical properties are left out and sub-objects are flattened by path.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)][AllowNull()]$InputObject,
        [Parameter(Position = 1)][string]$Prefix = '',
        [Parameter(Position = 2)][int]$Level = 0
    )

    if ($null -eq $InputObject) { return }

    $excluded = '^(PSComputerName|RunspaceId|PSShowComputerName|PSSourceJobInstanceId|ObjectState|IsValid|ExchangeVersion|DistinguishedName|Guid|OriginatingServer|ObjectCategory|ObjectClass|OrganizationId|Id|ExchangeObjectId|WhenChanged|WhenCreated|WhenChangedUTC|WhenCreatedUTC|Element|XsAnyElements|XsAnyAttributes|Tenant|TypeName|Path|Context|Tag|Key|Anchor|ScopeClass|Identity|@odata\..*)$'

    $pairs = [System.Collections.Generic.List[object]]::new()
    if ($InputObject -is [System.Collections.IDictionary]) {
        foreach ($key in @($InputObject.Keys)) { $pairs.Add(@([string]$key, $InputObject[$key])) }
    }
    else {
        foreach ($property in @($InputObject.PSObject.Properties | Where-Object { $_.MemberType -match 'Property' })) {
            try { $pairs.Add(@($property.Name, $property.Value)) }
            catch { Write-Verbose "The property $($property.Name) could not be read." }
        }
    }

    foreach ($pair in $pairs) {
        $name = $pair[0]
        $value = $pair[1]
        if ($name -match $excluded) { continue }
        $path = if ($Prefix) { "$Prefix.$name" } else { $name }
        if ($Level -lt 3 -and $value -is [System.Collections.IDictionary]) {
            ConvertTo-TcSettingRow $value $path ($Level + 1)
            continue
        }
        [ordered]@{ 'Setting' = $path; 'Value' = (Format-TcValue $value) }
    }
}
