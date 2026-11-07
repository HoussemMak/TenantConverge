function ConvertTo-TcHashtable {
    <#
    .SYNOPSIS
    Turns nested objects into ordered dictionaries and arrays.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()]$InputObject
    )

    if ($null -eq $InputObject) { return $null }

    if ($InputObject -is [System.Collections.IDictionary]) {
        $copy = [ordered]@{}
        foreach ($key in @($InputObject.Keys)) { $copy[$key] = ConvertTo-TcHashtable -InputObject $InputObject[$key] }
        return $copy
    }

    if ($InputObject -is [string] -or $InputObject.GetType().IsValueType) { return $InputObject }

    if ($InputObject -is [System.Collections.IEnumerable]) {
        return , @($InputObject | ForEach-Object { ConvertTo-TcHashtable -InputObject $_ })
    }

    if ($InputObject -is [psobject]) {
        $copy = [ordered]@{}
        foreach ($property in $InputObject.PSObject.Properties) { $copy[$property.Name] = ConvertTo-TcHashtable -InputObject $property.Value }
        return $copy
    }

    $InputObject
}
