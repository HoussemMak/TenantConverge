function Get-TcSafeProperty {
    <#
    .SYNOPSIS
    Reads a property that may throw: some CSOM and remote properties do when they are not loaded.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)][AllowNull()]$Object,
        [Parameter(Mandatory, Position = 1)][string]$Name,
        [Parameter(Position = 2)][AllowNull()]$Default = $null
    )

    try { Get-TcProperty $Object $Name $Default }
    catch { $Default }
}
