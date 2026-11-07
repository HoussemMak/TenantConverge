function Disconnect-TcService {
    <#
    .SYNOPSIS
    Closes the sessions of the current tenant, so the next tenant starts clean.
    #>
    [CmdletBinding()]
    param()

    if ($script:TcServiceConnections['Teams']) { Disconnect-MicrosoftTeams -ErrorAction SilentlyContinue | Out-Null }
    if ($script:TcActive['Exo']) { Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue }
    if ($script:TcActive['Graph']) { Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null }
    Clear-TcConnectionState
}
