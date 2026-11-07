<#
    Offline stubs for the remediation engine. They replace, inside the module, the only functions that
    leave this computer, and record every call. Nothing here reaches a tenant or the network.

    Read modes:
      Empty  every read returns nothing, which exercises the refusals.
      Echo   every read returns a plausible object, which pushes the code further.
#>

function Install-TcRemediationStub {
    <# Replaces the transports of the loaded module. Run Remove-Module or re-import to restore them. #>
    param([ValidateSet('Empty', 'Echo')][string]$Mode = 'Empty')

    $module = Get-Module TenantConverge
    & $module {
        param($ReadMode)

        $script:TcStub = @{ Mode = $ReadMode; Graph = [System.Collections.Generic.List[object]]::new(); Commands = [System.Collections.Generic.List[object]]::new(); Connections = [System.Collections.Generic.List[object]]::new(); Dns = [System.Collections.Generic.List[object]]::new(); Seconds = 0; Answers = [System.Collections.Generic.Queue[string]]::new(); Prompts = [System.Collections.Generic.List[string]]::new(); Messages = [System.Collections.Generic.List[string]]::new(); FailGraph = '' }

        function script:New-TcStubEcho {
            param([string]$Name = 'stub')
            @{
                id = 'stub-id'; appId = 'stub-appid'; displayName = $Name; userPrincipalName = $Name; mail = $Name; name = $Name; accountEnabled = $true; isVerified = $true
                state = 'enabledForReportingButNotEnforced'; createdDateTime = '2020-01-01T00:00:00Z'; modifiedDateTime = '2020-01-01T00:00:00Z'; expirationDateTime = '2099-01-01T00:00:00Z'
                proxyAddresses = @("SMTP:$Name"); supportedServices = @('Email')
                conditions = @{ users = @{ includeUsers = @('All'); excludeUsers = @(); includeGroups = @(); excludeGroups = @(); includeRoles = @(); excludeRoles = @() } }
                appRoles = @(); assignments = @()
            }
        }

        ${function:script:Connect-TcRemediationService} = {
            param([string]$Tenant, [string]$Service, [string]$Url)
            $script:TcStub['Connections'].Add([pscustomobject]@{ Tenant = $Tenant; Service = $Service; Scopes = @(Get-TcRemediationScope) })
            $script:TcStub['Current'] = $Tenant
            $null
        }

        ${function:script:Invoke-TcGraphTransport} = {
            param([string]$Method, [string]$Url, $Body, [hashtable]$Headers)
            if ($null -ne $Body) { [void]($Body | ConvertTo-Json -Depth 30 -Compress) }
            $script:TcStub['Graph'].Add([pscustomobject]@{ Tenant = $script:TcStub['Current']; Method = $Method; Url = $Url; Body = $Body })
            if ($script:TcStub['GraphAnswer']) { $answer = & $script:TcStub['GraphAnswer'] $Method $Url; if ($null -ne $answer) { return $answer } }
            if ($script:TcStub['FailGraph'] -and $Url -match $script:TcStub['FailGraph'] -and $Method -ne 'GET') { throw 'Stub failure' }
            if ($Method -ne 'GET') { return @{ id = 'stub-id'; appId = 'stub-appid' } }
            if ($script:TcStub['Mode'] -ne 'Echo') { return @{ value = @() } }
            $name = if ([uri]::UnescapeDataString($Url) -match "eq '([^']+)'") { $Matches[1] } else { 'stub' }
            $echo = New-TcStubEcho -Name $name
            $echo['value'] = @(New-TcStubEcho -Name $name)
            $echo
        }

        ${function:script:Invoke-TcCommandTransport} = {
            param([string]$Service, [string]$Command, [hashtable]$Parameters, $Connection)
            $script:TcStub['Commands'].Add([pscustomobject]@{ Service = $Service; Command = $Command; Parameters = $Parameters })
            if ($script:TcStub['CommandAnswer']) { $answer = & $script:TcStub['CommandAnswer'] $Command $Parameters; if ($null -ne $answer) { return $answer } }
            if ($Command -notmatch '^Get-') { return $null }
            if ($script:TcStub['Mode'] -ne 'Echo') { return @() }
            $name = [string]$(if ($Parameters['Identity']) { $Parameters['Identity'] } elseif ($Parameters['Name']) { $Parameters['Name'] } else { 'stub' })
            [pscustomobject]@{ Name = $name; Identity = $name; DisplayName = $name; PrimarySmtpAddress = $name; ExternalDirectoryObjectId = 'stub-id'; Guid = 'stub-id'; EmailAddresses = @("SMTP:$name"); AutoForwardingMode = 'Off'; Enabled = $true; Status = 'Valid'; Default = $false }
        }

        # Other test files load the service modules in this process. The real check has its own test.
        ${function:script:Assert-TcModuleFamily} = { param([string]$Service) $null = $Service }

        ${function:script:Get-TcCommandParameter} = {
            param([string]$Command)
            $names = @{}
            foreach ($name in 'Name', 'Comments', 'Mode', 'Enabled', 'Priority', 'FromScope', 'SentToScope', 'SubjectContainsWords', 'ApplyHtmlDisclaimerText', 'ApplyHtmlDisclaimerLocation', 'SenderAddressLocation') { $names[$name] = $true }
            $names
        }

        ${function:script:Resolve-TcDnsTransport} = {
            param([string]$Name, [string]$Type, [string]$Server)
            $script:TcStub['Dns'].Add([pscustomobject]@{ Kind = 'Read'; Name = $Name; Type = $Type })
            if ($script:TcStub['DnsAnswer']) { return (& $script:TcStub['DnsAnswer'] $Name $Type) }
            @()
        }

        ${function:script:Invoke-TcCloudflareTransport} = {
            param([string]$Method, [string]$Path, $Body)
            $script:TcStub['Dns'].Add([pscustomobject]@{ Kind = $Method; Name = $Path; Type = 'Cloudflare' })
            if ($script:TcStub['CloudflareAnswer']) { return (& $script:TcStub['CloudflareAnswer'] $Method $Path $Body) }
            [pscustomobject]@{ result = @([pscustomobject]@{ id = 'stub'; content = 'stub'; type = 'TXT'; name = 'stub'; ttl = 300 }) }
        }

        ${function:script:Wait-TcRemediation} = { param([int]$Seconds) $script:TcStub['Seconds'] += [Math]::Max($Seconds, 1) }
        ${function:script:Get-TcRemediationNow} = { (Microsoft.PowerShell.Utility\Get-Date).AddSeconds($script:TcStub['Seconds']) }

        ${function:script:Read-TcAnswer} = {
            param([string]$Prompt)
            $script:TcStub['Prompts'].Add($Prompt)
            if ($script:TcStub['Answers'].Count) { return $script:TcStub['Answers'].Dequeue() }
            if (-not $script:TcStub['AutoConfirm']) { return '' }
            if ($Prompt -cmatch 'Type UNTESTED') { return 'UNTESTED' }
            if ($Prompt -cmatch 'Type REMOVE') { return $script:TcStub['RemoveAnswer'] }
            if ($Prompt -match 'primary domain of .* \((?<role>\w+)\)') { return (Get-TcRemediationTenant -Tenant $Matches['role'])['PrimaryDomain'] }
            ''
        }

        ${function:script:Write-TcMessage} = { param([string]$Message, [string]$Level = 'Info') $script:TcStub['Messages'].Add($Message) }
    } $Mode
}

function Get-TcStubWrite {
    <# Every recorded call that could change a tenant. #>
    $module = Get-Module TenantConverge
    & $module {
        @($script:TcStub['Graph'] | Where-Object Method -NE 'GET')
        @($script:TcStub['Commands'] | Where-Object Command -NotMatch '^(Get|Export)-')
        @($script:TcStub['Dns'] | Where-Object { $_.Kind -notin 'Read', 'GET' })
    }
}

function Reset-TcStub {
    <# Forgets what was recorded, and sets the answers the next prompts receive. #>
    param([string[]]$Answer = @(), [string]$FailGraph = '', [switch]$AutoConfirm, [string]$RemoveAnswer = 'REMOVE', [scriptblock]$GraphAnswer, [scriptblock]$DnsAnswer, [scriptblock]$CloudflareAnswer, [scriptblock]$CommandAnswer)
    $module = Get-Module TenantConverge
    & $module {
        param($Answers, $Failing, $Confirm, $Removal, $Reply, $DnsReply, $CloudflareReply, $CommandReply)
        foreach ($list in 'Graph', 'Commands', 'Connections', 'Dns', 'Prompts', 'Messages') { $script:TcStub[$list].Clear() }
        $script:TcStub['Answers'].Clear()
        foreach ($value in @($Answers)) { $script:TcStub['Answers'].Enqueue($value) }
        $script:TcStub['FailGraph'] = $Failing
        $script:TcStub['AutoConfirm'] = [bool]$Confirm
        $script:TcStub['RemoveAnswer'] = $Removal
        $script:TcStub['GraphAnswer'] = $Reply
        $script:TcStub['DnsAnswer'] = $DnsReply
        $script:TcStub['CloudflareAnswer'] = $CloudflareReply
        $script:TcStub['CommandAnswer'] = $CommandReply
        $script:TcStub['Seconds'] = 0
    } $Answer $FailGraph $AutoConfirm.IsPresent $RemoveAnswer $GraphAnswer $DnsAnswer $CloudflareAnswer $CommandAnswer
}

function Get-TcStubRecord {
    <# One of the lists the stubs fill: Graph, Commands, Connections, Dns, Prompts or Messages. #>
    param([Parameter(Mandatory)][string]$Name)
    $module = Get-Module TenantConverge
    & $module { param($List) @($script:TcStub[$List]) } $Name
}
