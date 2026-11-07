function Clear-TcConnectionState {
    <#
    .SYNOPSIS
    Forgets which tenant each service is connected to.
    #>
    [CmdletBinding()]
    param()

    $script:TcActive = @{ Graph = $null; Exo = $null }
    $script:TcServiceConnections = @{ Ipps = $null; Teams = $null; Pnp = $null; Azure = $null }
    $script:TcPnpConnection = $null
}
