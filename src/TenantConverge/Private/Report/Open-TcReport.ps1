function Open-TcReport {
    <#
    .SYNOPSIS
    Opens the report in the default browser, when someone is at the screen.

    .DESCRIPTION
    A report that cannot be opened is no failure: its path is already on screen.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path
    )

    if (-not [Environment]::UserInteractive) { return }

    try { Invoke-Item -LiteralPath $Path -ErrorAction Stop }
    catch { Write-TcMessage -Message "The report could not be opened: $(Get-TcErrorText $_). Open it from its folder." -Level Warning }
}
