function Resolve-TcDnsRecord {
    <#
    .SYNOPSIS
    Asks for the records of one name, and tells a name with no such record from a query that failed.

    .DESCRIPTION
    Returns Records, Failed and Error. A name that does not exist, or has no record of this type, is an
    answer: no record and no failure. Anything else is a failure, so a timeout never reads as a domain
    with no SPF. When the server in the resolver state does not answer, the query goes to the system
    resolver, and so do the next ones: Server is emptied and Fallback set.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Type,
        [Parameter(Mandatory)][hashtable]$Resolver
    )

    while ($true) {
        $server = $Resolver['Server']
        $options = @{}
        if ($server) { $options['Server'] = $server }

        try {
            $records = @(Resolve-DnsName -Name $Name -Type $Type -DnsOnly -NoHostsFile -ErrorAction Stop @options | Where-Object { (Get-TcProperty $_ 'Type') -eq $Type })
            return [pscustomobject]@{ Records = $records; Failed = $false; Error = $null }
        }
        catch {
            # 9003 is a name that does not exist, 9501 a name with no record of this type.
            if ((Get-TcProperty $_.Exception 'NativeErrorCode') -in 9003, 9501 -or [string]$_.FullyQualifiedErrorId -match '^(DNS_ERROR_RCODE_NAME_ERROR|DNS_INFO_NO_RECORDS)\b') {
                return [pscustomobject]@{ Records = @(); Failed = $false; Error = $null }
            }
            if (-not $server) { return [pscustomobject]@{ Records = @(); Failed = $true; Error = $_ } }

            Write-TcLog -Message "The DNS server $server did not answer for $Name ($Type): $(Get-TcErrorText $_). The system resolver takes over." -Level WARN
            $Resolver['Server'] = $null
            $Resolver['Fallback'] = $true
        }
    }
}
