function Format-TcValue {
    <#
    .SYNOPSIS
    Turns a value into something readable and serializable: text, number or boolean, with lists and objects flattened and dates in short ISO form.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)][AllowNull()]$Value,
        [Parameter(Position = 1)][int]$Level = 0
    )

    if ($null -eq $Value) { return $null }
    if ($Value -is [string]) { return (Limit-TcText $Value) }
    if ($Value -is [bool] -or $Value -is [int] -or $Value -is [long] -or $Value -is [double] -or $Value -is [decimal] -or $Value -is [single] -or $Value -is [uint32] -or $Value -is [uint64] -or $Value -is [int16] -or $Value -is [byte]) { return $Value }
    if ($Value -is [datetime]) { return $Value.ToString('yyyy-MM-dd HH:mm') }
    if ($Value -is [datetimeoffset]) { return $Value.UtcDateTime.ToString('yyyy-MM-dd HH:mm') }
    if ($Value -is [enum] -or $Value -is [guid] -or $Value -is [timespan] -or $Value -is [uri]) { return [string]$Value }
    if ($Level -ge 2) { return [string]$Value }

    if ($Value -is [System.Collections.IDictionary]) {
        $pairs = @($Value.Keys) | ForEach-Object { '{0}={1}' -f $_, (Format-TcValue $Value[$_] ($Level + 1)) }
        return (Limit-TcText (@($pairs) -join '; '))
    }

    if ($Value -is [System.Collections.IEnumerable]) {
        $items = @($Value | Select-Object -First 300 | ForEach-Object { Format-TcValue $_ ($Level + 1) }) | Where-Object { $null -ne $_ -and "$_" -ne '' }
        return (Limit-TcText (@($items) -join '; '))
    }

    $text = [string]$Value
    if ($text -eq $Value.GetType().FullName) {
        $pairs = foreach ($property in @($Value.PSObject.Properties | Where-Object { $_.MemberType -match 'Property' } | Select-Object -First 12)) {
            try { '{0}={1}' -f $property.Name, (Format-TcValue $property.Value ($Level + 1)) }
            catch { Write-Verbose "The property $($property.Name) could not be read." }
        }
        return (Limit-TcText (@($pairs) -join '; '))
    }

    Limit-TcText $text
}
