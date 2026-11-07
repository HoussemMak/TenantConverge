function Get-TcCollector {
    <#
    .SYNOPSIS
    Lists every collector in the order they run. A collector can read the tables of the ones before it.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    Get-TcEntraIdCollector
    Get-TcExchangeCollector
    Get-TcDnsCollector
    Get-TcSharePointCollector
    Get-TcTeamsCollector
    Get-TcTeamsPhoneCollector
    Get-TcIntuneCollector
    Get-TcPurviewCollector
    Get-TcPowerPlatformCollector
    Get-TcAzureCollector
    Get-TcOtherServiceCollector
}
