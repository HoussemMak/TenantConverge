function Resolve-TcDnsTransport {
    <#
    .SYNOPSIS
    The only public DNS read of the remediations.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Type,
        [string]$Server
    )

    Resolve-DnsName -Name $Name -Type $Type -DnsOnly -NoHostsFile -Server $Server -ErrorAction Stop
}

function Invoke-TcCloudflareTransport {
    <#
    .SYNOPSIS
    The only call to the Cloudflare API. The token stays in its environment variable.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Method,
        [Parameter(Mandatory)][string]$Path,
        $Body
    )

    $variable = Get-TcRemediationOption 'DnsApiTokenVariable'
    $token = [Environment]::GetEnvironmentVariable($variable)
    if (-not $token) { throw "No Cloudflare token: set the environment variable $variable." }
    $request = @{ Method = $Method; Uri = "https://api.cloudflare.com/client/v4/$Path"; Headers = @{ Authorization = "Bearer $token" } }
    if ($Body) { $request['Body'] = $Body | ConvertTo-Json -Depth 5; $request['ContentType'] = 'application/json' }
    Invoke-RestMethod @request
}

function Resolve-TcDnsEntry {
    <#
    .SYNOPSIS
    The published records of a name: value, TTL and priority.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ValidateSet('MX', 'TXT', 'CNAME')][string]$Type
    )

    $records = try { @(Resolve-TcDnsTransport -Name $Name -Type $Type -Server (Get-TcRemediationOption 'DnsServer')) } catch { @() }
    @($records | Where-Object { $_.Type -eq $Type } | ForEach-Object {
            # Inside a switch, $_ is the value of the switch.
            $record = $_
            switch ($Type) {
                'MX' { @{ value = ([string]$record.NameExchange).TrimEnd('.'); ttl = $record.TTL; priority = $record.Preference } }
                'TXT' { @{ value = (-join $record.Strings); ttl = $record.TTL } }
                'CNAME' { @{ value = ([string]$record.NameHost).TrimEnd('.'); ttl = $record.TTL } }
            }
        })
}

function Get-TcDnsHost {
    <#
    .SYNOPSIS
    The DNS host of a zone: the remediation settings first, then the snapshot, otherwise Manual.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Zone
    )

    $hosts = Get-TcRemediationOption 'DnsHosts'
    if ($hosts.ContainsKey($Zone) -and $hosts[$Zone] -ne 'Manual') { return $hosts[$Zone] }
    foreach ($role in $script:TcRemediationRun['Known']) {
        $row = @(Get-TcProperty (Get-TcProperty (Get-TcProperty $script:TcRemediationRun['Snapshot']['tenants'] $role) 'tables') 'dnsDomains' @()) | Where-Object { $_['Domain'] -eq $Zone } | Select-Object -First 1
        if ($row -and $row['DNS host']) { return [string]$row['DNS host'] }
    }
    'Manual'
}

function Set-TcCloudflareRecord {
    <#
    .SYNOPSIS
    Writes a record: Set replaces, Add adds, Remove deletes, Restore puts one value back. For a TXT, Set only replaces the SPF or the DMARC.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Runs inside an action a person confirmed.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Tenant,
        [Parameter(Mandatory)][string]$Zone,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Type,
        [AllowEmptyString()][string]$Value,
        [int]$Ttl,
        [int]$Priority,
        [Parameter(Mandatory)][string]$Action
    )

    Assert-TcRemediationCall -What "Cloudflare $Action $Type $Name" -Tenant $Tenant -Write
    $zoneRow = @((Invoke-TcCloudflareTransport -Method GET -Path "zones?name=$Zone").result) | Select-Object -First 1
    if (-not $zoneRow) { throw "Zone $Zone is not in the Cloudflare account." }
    $records = @((Invoke-TcCloudflareTransport -Method GET -Path "zones/$($zoneRow.id)/dns_records?type=$Type&name=$Name").result)
    if ($Action -eq 'Remove') {
        foreach ($record in @($records | Where-Object { -not $Value -or $_.content -eq $Value })) { [void](Invoke-TcCloudflareTransport -Method DELETE -Path "zones/$($zoneRow.id)/dns_records/$($record.id)") }
        return
    }
    $body = @{ type = $Type; name = $Name; content = $Value; ttl = $Ttl }
    if ($Type -eq 'MX') { $body['priority'] = $Priority }
    $current = $null
    if ($Action -eq 'Set') {
        $pattern = if ($Type -eq 'TXT' -and $Value -like 'v=spf1*') { 'v=spf1*' } elseif ($Type -eq 'TXT' -and $Value -like 'v=DMARC1*') { 'v=DMARC1*' } else { '*' }
        $current = $records | Where-Object { $_.content -like $pattern } | Select-Object -First 1
    }
    if ($Action -eq 'Restore') { $current = $records | Where-Object { $_.content -eq $Value } | Select-Object -First 1 }
    if ($current) { [void](Invoke-TcCloudflareTransport -Method PUT -Path "zones/$($zoneRow.id)/dns_records/$($current.id)" -Body $body) }
    else { [void](Invoke-TcCloudflareTransport -Method POST -Path "zones/$($zoneRow.id)/dns_records" -Body $body) }
}

function Set-TcCloudflareTtl {
    <#
    .SYNOPSIS
    Lowers the TTL of existing records without changing their value.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Runs inside an action a person confirmed.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Tenant,
        [Parameter(Mandatory)][string]$Zone,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Type,
        [int]$Ttl
    )

    Assert-TcRemediationCall -What "Cloudflare TTL $Type $Name" -Tenant $Tenant -Write
    $zoneRow = @((Invoke-TcCloudflareTransport -Method GET -Path "zones?name=$Zone").result) | Select-Object -First 1
    if (-not $zoneRow) { throw "Zone $Zone is not in the Cloudflare account." }
    foreach ($record in @((Invoke-TcCloudflareTransport -Method GET -Path "zones/$($zoneRow.id)/dns_records?type=$Type&name=$Name").result)) {
        $body = @{ type = $record.type; name = $record.name; content = $record.content; ttl = $Ttl }
        if ($record.PSObject.Properties['priority']) { $body['priority'] = $record.priority }
        [void](Invoke-TcCloudflareTransport -Method PUT -Path "zones/$($zoneRow.id)/dns_records/$($record.id)" -Body $body)
    }
}

function Invoke-TcDnsRecord {
    <#
    .SYNOPSIS
    Publishes a record from a block, with what Add-TcDnsAction gives: the wait for the public DNS, and the undo.

    .DESCRIPTION
    For a record whose value is only known once the block runs. The block goes on when the record shows,
    and stops when it does not show within the delay. The undo is added to the action, after any it holds.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Action,
        [Parameter(Mandatory)][string]$Zone,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ValidateSet('MX', 'TXT', 'CNAME')][string]$Type,
        [Parameter(Mandatory)][string]$Value,
        [int]$Ttl = 300,
        [int]$Priority = 0,
        [ValidateSet('Set', 'Add')][string]$Verb = 'Set'
    )

    $entry = @{ id = $Action['id']; tenant = $Action['tenant']; type = 'Dns'; dns = [ordered]@{ zone = $Zone; name = $Name; type = $Type; value = $Value; ttl = $Ttl; priority = $Priority; action = $Verb; wait = $true } }
    $Action['undo'] = @(@($Action['undo']) | Where-Object { $_ }) + @(Get-TcAutomaticUndo -Action $entry)
    Invoke-TcDnsAction -Action $entry
}

function Get-TcDnsAddedValue {
    <#
    .SYNOPSIS
    The value the undo of a DNS change takes away: what the action published, when it was not there before.

    .DESCRIPTION
    A failed read before a Set gives an empty list, which says nothing of what the Set replaced, so
    nothing is taken away. A Set on a CNAME is put back over the record itself.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]$Undo
    )

    $record = $Undo['dns']
    $before = @(Get-TcProperty $Undo 'before' @())
    $value = [string](Get-TcProperty $record 'value' '')
    if (-not $value -or $value -in @($before | ForEach-Object { [string]$_['value'] })) { return '' }
    if ($record['action'] -eq 'Add' -or ($record['action'] -eq 'Set' -and $record['type'] -ne 'CNAME' -and $before.Count)) { return $value }
    ''
}

function Restore-TcDnsRecord {
    <#
    .SYNOPSIS
    Goes back on a DNS change, record by record, so two MX stay two. A record the change did not touch stays.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Runs inside an undo a person confirmed.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Tenant,
        [Parameter(Mandatory)]$Undo
    )

    $record = $Undo['dns']
    $added = Get-TcDnsAddedValue -Undo $Undo
    $dnsHost = Get-TcDnsHost -Zone $record['zone']
    $verb = if ($record['type'] -eq 'CNAME') { 'Set' } else { 'Restore' }
    foreach ($value in @(Get-TcProperty $Undo 'before' @())) {
        if ($dnsHost -eq 'Cloudflare') { Set-TcCloudflareRecord -Tenant $Tenant -Zone $record['zone'] -Name $record['name'] -Type $record['type'] -Value $value['value'] -Ttl ([int]$value['ttl']) -Priority ([int](Get-TcProperty $value 'priority' 0)) -Action $verb }
        else { Write-TcRemediationInstruction -Line @(('To restore at {0}: {1} {2} = {3}' -f $dnsHost, $record['type'], $record['name'], $value['value'])) }
    }
    if (-not $added) { return }
    if ($dnsHost -eq 'Cloudflare') { Set-TcCloudflareRecord -Tenant $Tenant -Zone $record['zone'] -Name $record['name'] -Type $record['type'] -Value $added -Action Remove }
    else { Write-TcRemediationInstruction -Line @(('To remove at {0}: {1} {2} = {3}' -f $dnsHost, $record['type'], $record['name'], $added)) }
}

function Wait-TcDnsEntry {
    <#
    .SYNOPSIS
    True as soon as a record shows in the public DNS, or is gone with -Absent. False at the end of the delay.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Type,
        [AllowEmptyString()][string]$Value,
        [switch]$Absent,
        [int]$Minutes = 0
    )

    if (-not $Minutes) { $Minutes = [int](Get-TcRemediationOption 'DnsWaitMinutes') }
    $end = (Get-TcRemediationNow).AddMinutes($Minutes)
    $pause = [int](Get-TcRemediationOption 'DnsPollSeconds')
    while ($true) {
        $seen = @(Resolve-TcDnsEntry -Name $Name -Type $Type | Where-Object { $_['value'] -eq $Value -or ($Type -eq 'TXT' -and $_['value'] -like "*$Value*") }).Count -gt 0
        if ($seen -ne [bool]$Absent) { return $true }
        if ((Get-TcRemediationNow) -ge $end) { return $false }
        Write-TcMessage -Message ('        {0} {1}: next read in {2} s (limit {3:HH:mm})' -f $Type, $Name, $pause, $end)
        Wait-TcRemediation -Seconds $pause
    }
}

function Invoke-TcDnsAction {
    <#
    .SYNOPSIS
    Writes a DNS record through the API of its host, or asks a person, then watches the public DNS.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Action
    )

    $record = $Action['dns']
    Assert-TcRemediationCall -What "DNS $($record['action']) $($record['type']) $($record['name'])" -Tenant $Action['tenant'] -Write
    $dnsHost = Get-TcDnsHost -Zone $record['zone']
    if ($dnsHost -eq 'Cloudflare') {
        if ($record['action'] -eq 'TTL') { Set-TcCloudflareTtl -Tenant $Action['tenant'] -Zone $record['zone'] -Name $record['name'] -Type $record['type'] -Ttl $record['ttl'] }
        else { Set-TcCloudflareRecord -Tenant $Action['tenant'] -Zone $record['zone'] -Name $record['name'] -Type $record['type'] -Value $record['value'] -Ttl $record['ttl'] -Priority $record['priority'] -Action $record['action'] }
    }
    else {
        $verb = @{ Set = 'REPLACE'; Add = 'ADD'; Remove = 'REMOVE'; TTL = 'LOWER THE TTL OF' }[$record['action']]
        Write-TcRemediationInstruction -Line @(
            ('To do at {0}, zone {1}: {2} the {3} record' -f $dnsHost, $record['zone'], $verb, $record['type'])
            ('Name:  {0}' -f $record['name'])
            ('Value: {0}{1}' -f $record['value'], $(if ($record['type'] -eq 'MX') { " (priority $($record['priority']))" } else { '' }))
            ('TTL:   {0} s' -f $record['ttl'])
            'The script watches the public DNS and goes on as soon as the change shows.'
        )
        Write-TcLog -Message ('DNS at {0}: {1} {2} {3} = {4}' -f $dnsHost, $verb, $record['type'], $record['name'], $record['value']) -Step $Action['id']
    }
    if ($record['wait'] -and $record['action'] -ne 'TTL') {
        if (-not (Wait-TcDnsEntry -Name $record['name'] -Type $record['type'] -Value $record['value'] -Absent:($record['action'] -eq 'Remove'))) { throw "$($record['type']) $($record['name']) does not show in the public DNS at the end of the delay." }
    }
}
