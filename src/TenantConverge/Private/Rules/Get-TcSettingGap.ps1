function Get-TcSettingGap {
    <#
    .SYNOPSIS
    Returns the settings found in the target and in a source, whose value differs for at least one source.

    .DESCRIPTION
    Identifiers and names are left out. Important marks what users feel after a migration: sharing,
    external access, guests, meetings, authentication. A table that cannot be compared is reported in
    errors, and the other tables carry on.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param()

    $roles = @($script:TcRuleRun['Roles'])
    $sources = @($script:TcRuleRun['Sources'])
    if ('Target' -notin $roles -or -not $sources.Count) { return }

    $tables = [ordered]@{
        sharePointSettings = 'SharePoint and OneDrive'; teamsSettings = 'Teams'; exchangeSettings = 'Exchange Online'; securitySettings = 'Entra ID'
        groupSettings = 'Entra ID'; crossTenantSettings = 'Entra ID'; reportSettings = 'Other services'
    }

    # Two collector labels hold a word of the list without being about it: Email-based self-service
    # sign-up and Email-verified users, and the labels of the groups below for the important list.
    $ignored = '(?i)(DisplayName|Name$|Identity|Guid|\bId$|Url$|Uri|Date|Time$|TenantId|ObjectId|Version|Thumbprint|Certificate|Email(?!-based self-service sign-up$|-verified users can join$)|Contact|Owner|Admin|Sku|Banner|Logo|Location$|Region|ServiceNumber|Bridge|Domain$|DomainName|Created|Modified|Changed|Description|Tag$)'
    $important = '(?i)(Sharing|Anonymous|External|Guest|Federat|Consumer|AllowedDomains|BlockedDomains|LegacyAuth|ConditionalAccess|Recording|Transcription|Lobby|AutoAdmit|StorageQuota|Retention|Invit|^Method |User permissions|Audit|EnableGroupCreation|AllowToAddGuests|Expiration|DefaultLink|Resharing|Unmanaged|SecurityDefaults|Security defaults|concealed)'
    $neutralLabel = '^(External access|ACS federation)\.'

    foreach ($table in $tables.Keys) {
        try {
            if (-not (Test-TcRuleTable 'Target' $table)) { continue }
            $target = @{}
            foreach ($row in Get-TcRuleRow 'Target' $table) { $target[[string](Get-TcProperty $row 'Setting')] = [string](Get-TcProperty $row 'Value') }

            $settings = [ordered]@{}
            foreach ($source in $sources) {
                if (-not (Test-TcRuleTable $source $table)) { continue }
                foreach ($row in Get-TcRuleRow $source $table) {
                    $name = [string](Get-TcProperty $row 'Setting')
                    if ($name -match $ignored -or -not $target.ContainsKey($name)) { continue }
                    if (-not $settings.Contains($name)) { $settings[$name] = [ordered]@{ Target = $target[$name] } }
                    $settings[$name][$source] = [string](Get-TcProperty $row 'Value')
                }
            }

            foreach ($name in $settings.Keys) {
                $values = $settings[$name]
                $different = @($sources | Where-Object { $values.Contains($_) -and $values[$_] -ne $values['Target'] })
                if (-not $different.Count) { continue }
                [ordered]@{ workload = $tables[$table]; table = $table; setting = $name; important = (($name -replace $neutralLabel, '') -match $important); values = $values; different = $different }
            }
        }
        catch { Add-TcRuleError -Role 'All' -Workload $tables[$table] -ErrorRecord $_ }
    }
}
