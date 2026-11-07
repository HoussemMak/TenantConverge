function Get-TcProperty {
    <#
    .SYNOPSIS
    Reads a property or dictionary key that may be missing.

    .DESCRIPTION
    Works on dictionaries and on objects, and on $null. Module code runs under strict mode, where a
    dotted read of a missing member stops the script, so anything that comes from a file or a service
    is read through this function. A missing property returns -Default, which is $null unless given.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()]$Object,
        [Parameter(Mandatory)][string]$Name,
        [AllowNull()]$Default = $null
    )

    if ($null -eq $Object) { return $Default }

    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        return $Default
    }

    $property = $Object.PSObject.Properties[$Name]
    if ($property) { return $property.Value }
    $Default
}