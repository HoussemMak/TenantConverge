function Get-TcCollectionSetting {
    <#
    .SYNOPSIS
    Reads one setting of the collection, such as a row limit or the report period.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Name
    )

    $script:TcCollectionSettings[$Name]
}
