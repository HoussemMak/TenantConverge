# UNTESTED: this script has never been run on a real tenant. Read it, try it on a test tenant first, and use it at your own risk.
<#
.SYNOPSIS
    Compares the DLP policies of a source with those of the target and creates a provisional policy in test mode, on decision (procedure PUR-DLP).

.DESCRIPTION
    Data read: the dlpPolicies table of the source and the target, then, in an -Apply run, the policies and their rules on both tenants.
    The export exports\dlp-*.csv documents the locations, sensitive information types and actions.

    decisions\PUR-DLP.csv: one row per policy of the source.
      - Covered by target: the protection of the target is enough;
      - Postpone until after cutover: the Purview design will take it up;
      - Provisional policy: the script creates in the target the policy <source>-<name> in TestWithNotifications mode, with the locations of
        the source and the rules read on the source, with no blocking effect;
      - Enable the provisional one: moves this policy to Enable mode, after analyzing the matches.
    The Covered by target proposal only looks at workloads; only the rule export allows comparing the content.

    Limits: an All scope goes beyond the migrated data and touches the whole target, hence test mode. Any provisional policy must be
    removed or merged after cutover. Match analysis is read in the Purview portal.
#>
$c = Open-TcRemediation

$TestMode = 'TestWithNotifications'
$Locations = @{ Exchange = 'ExchangeLocation'; SharePoint = 'SharePointLocation'; OneDriveForBusiness = 'OneDriveLocation'; Teams = 'TeamsLocation' }

function Get-DlpPolicy {
    <# Read through the list: -Identity fails if the policy does not exist yet. #>
    param([string]$Tenant, [string]$Name)
    return @(Invoke-TcServiceCommand -Tenant $Tenant -Service Scc -Command 'Get-DlpCompliancePolicy' | Where-Object { (Get-TcMember $_ 'Name') -eq $Name }) | Select-Object -First 1
}

function Get-ProvisionalName { param([string]$Source, [string]$Name) return ('{0}-{1}' -f $Source, $Name) }

$targetPolicies = @(Get-TcRemediationTable 'Target' 'dlpPolicies')
$proposals = foreach ($t in $c.Tenants) {
    Write-TcRemediationTenant $t 'DLP policies read'
    $source = @(Get-TcRemediationTable $t 'dlpPolicies')
    if (-not $source.Count -and -not (Test-TcCollectionComplete $t 'dlpPolicies')) { Write-TcRemediationAlert 'DLP policies: collection incomplete, an empty table proves nothing.' }
    $activeInTarget = @($targetPolicies | Where-Object { $_['Mode'] -eq 'Enable' })
    Write-TcRemediationNote ("{0} policy(ies) in {1}; {2} policy(ies) in the target, {3} active" -f $source.Count, $t, $targetPolicies.Count, $activeInTarget.Count)
    foreach ($p in $source) {
        $workloads = @(([string]$p['Workloads']) -split ',\s*' | Where-Object { $_ })
        $coveredOne = @($workloads | Where-Object { $ch = $_; @($activeInTarget | Where-Object { @(([string]$_['Workloads']) -split ',\s*') -contains $ch }).Count -gt 0 }).Count -eq $workloads.Count
        [ordered]@{ Tenant = $t; Policy = $p['Name']; Mode = $p['Mode']; Workloads = $p['Workloads']; 'Active policies of the target' = (@($activeInTarget | ForEach-Object { $_['Name'] }) -join ' ; ')
                    Proposal = $(if ($coveredOne) { 'Covered by target' } else { 'Provisional policy' }) }
    }
}
$decisions = @(Get-TcDecision -Name 'PUR-DLP' -Proposal @($proposals | Where-Object { $_ }) -Key 'Tenant', 'Policy' -Choice 'Covered by target', 'Postpone until after cutover', 'Provisional policy', 'Enable the provisional one')

foreach ($t in @($c.Tenants) + @('Target') | Select-Object -Unique) {
    Add-TcBlockAction -Tenant $t -Service Scc -Object 'DLP export' -Description ("Document the DLP policies and rules of {0} (read only)" -f $t) -Reason 'Read only.' -Block {
        param($a)
        $rules = foreach ($p in @(Invoke-TcServiceCommand -Tenant $a.tenant -Service Scc -Command 'Get-DlpCompliancePolicy')) {
            foreach ($r in @(Invoke-TcServiceCommand -Tenant $a.tenant -Service Scc -Command 'Get-DlpComplianceRule' -Parameters @{ Policy = (Get-TcMember $p 'Name') })) {
                [ordered]@{ Policy = (Get-TcMember $p 'Name'); Mode = (Get-TcText $p 'Mode'); Rule = (Get-TcMember $r 'Name'); Exchange = (@((Get-TcMember $p 'ExchangeLocation')) -join ' '); SharePoint = (@((Get-TcMember $p 'SharePointLocation')) -join ' '); OneDrive = (@((Get-TcMember $p 'OneDriveLocation')) -join ' '); Teams = (@((Get-TcMember $p 'TeamsLocation')) -join ' ')
                            'Sensitive types' = (@((Get-TcMember $r 'ContentContainsSensitiveInformation') | ForEach-Object { (Get-TcMember $_ 'name') }) -join ' ; '); 'Advanced rule' = $(if ((Get-TcMember $r 'AdvancedRule')) { 'Yes' } else { 'No' }); 'Blocks access' = (Get-TcMember $r 'BlockAccess'); 'Notifies' = (@((Get-TcMember $r 'NotifyUser')) -join ' ') }
            }
        }
        Export-TcRemediationReport -Name "dlp-$($a.tenant)" -Rows @($rules | Where-Object { $_ }) | Out-Null
    }
}

foreach ($d in $decisions | Where-Object { (Get-TcMember $_ 'Decision') -eq 'Provisional policy' }) {
    $name = Get-ProvisionalName (Get-TcMember $d 'Tenant') (Get-TcMember $d 'Policy')
    $settingRows = @{ Name = $name; Mode = $TestMode; Comment = "Provisional migration policy, source $((Get-TcMember $d 'Tenant')), to remove or merge after cutover." }
    foreach ($ch in @(((Get-TcText $d 'Workloads')) -split ',\s*' | Where-Object { $Locations[$_] })) { $settingRows[$Locations[$ch]] = 'All' }
    Write-TcRemediationAlert ("{0}: the All scope goes beyond the migrated data; narrow it if the design allows" -f $name)
    Add-TcCommandAction -Tenant 'Target' -Service Scc -Command 'New-DlpCompliancePolicy' -Parameters $settingRows -Object $name -Description ("Create the provisional policy {0} in test mode" -f $name) `
        -Test { param($a) [bool](Get-DlpPolicy $a.tenant $a.parameters.Name) } `
        -Undo @{ command = 'Remove-DlpCompliancePolicy'; parameters = @{ Identity = $name } }
    Add-TcBlockAction -Tenant 'Target' -Service Scc -Object $name -Description ("Carry over the rules of {0} into {1}" -f (Get-TcMember $d 'Policy'), $name) -Data @{ Source = (Get-TcMember $d 'Tenant'); Policy = (Get-TcMember $d 'Policy'); Name = $name } `
        -Reason 'The rules go away with the provisional policy.' `
        -Test {
            param($a)
            $over = @(Invoke-TcServiceCommand -Tenant $a.tenant -Service Scc -Command 'Get-DlpComplianceRule' -Parameters @{ Policy = $a.data.Name })
            return $over.Count -gt 0
        } `
        -Block {
            param($a)
            $sources = @(Invoke-TcServiceCommand -Tenant $a.data.Source -Service Scc -Command 'Get-DlpComplianceRule' -Parameters @{ Policy = $a.data.Policy })
            if (-not $sources.Count) { throw "No rule read on $($a.data.Source) for $($a.data.Policy)" }
            foreach ($r in $sources) {
                $p = @{ Name = ('{0}-{1}' -f $a.data.Source, (Get-TcMember $r 'Name')); Policy = $a.data.Name }
                if ((Get-TcMember $r 'AdvancedRule')) { $p.AdvancedRule = (Get-TcText $r 'AdvancedRule') }
                else { $p.ContentContainsSensitiveInformation = (Get-TcMember $r 'ContentContainsSensitiveInformation'); if ((Get-TcMember $r 'BlockAccess')) { $p.BlockAccess = $true } }
                Invoke-TcServiceCommand -Tenant $a.tenant -Service Scc -Command 'New-DlpComplianceRule' -Parameters $p | Out-Null
            }
        }
}

foreach ($d in $decisions | Where-Object { (Get-TcMember $_ 'Decision') -eq 'Enable the provisional one' }) {
    $name = Get-ProvisionalName (Get-TcMember $d 'Tenant') (Get-TcMember $d 'Policy')
    Add-TcCommandAction -Tenant 'Target' -Service Scc -Command 'Set-DlpCompliancePolicy' -Parameters @{ Identity = $name; Mode = 'Enable' } -Object $name -Description ("Enable the provisional policy {0}" -f $name) `
        -Test { param($a) $p = Get-DlpPolicy $a.tenant $a.parameters.Identity; if (-not $p) { throw "Policy missing from the target: $($a.parameters.Identity)" }; return (Get-TcText $p 'Mode') -eq 'Enable' } `
        -Undo @{ command = 'Set-DlpCompliancePolicy'; parameters = @{ Identity = $name; Mode = $TestMode } }
}

Invoke-TcRemediationPlan -Verify {
    param($t)
    foreach ($d in $decisions | Where-Object { (Get-TcMember $_ 'Tenant') -eq $t -and (Get-TcMember $_ 'Decision') -in 'Provisional policy', 'Enable the provisional one' }) {
        $name = Get-ProvisionalName (Get-TcMember $d 'Tenant') (Get-TcMember $d 'Policy')
        $p = Get-DlpPolicy 'Target' $name
        if (-not $p) { New-TcRemediationResult Blocking "$name missing from the target"; continue }
        New-TcRemediationResult OK ("{0}: mode {1}, distribution {2}" -f $name, (Get-TcMember $p 'Mode'), (Get-TcMember $p 'DistributionStatus'))
    }
}
Close-TcRemediation
