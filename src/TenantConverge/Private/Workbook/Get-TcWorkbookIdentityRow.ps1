function Get-TcWorkbookIdentityRow {
    <#
    .SYNOPSIS
    Returns the rows of the Identity matrix tab: the draft of each source, or one row that says why there is none.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)][hashtable]$Book
    )

    $plan = $Book['Plan']
    $snapshot = $Book['Snapshot']
    $notice = {
        param($Tenant, [string]$Decision, [string]$Notes)
        [ordered]@{ Role = $Tenant['role']; Tenant = $Tenant['displayName']; 'Proposed decision' = $Decision; Notes = $Notes }
    }

    foreach ($tenant in @(Get-TcProperty $plan 'tenants' @() | Where-Object { $_['role'] -ne 'Target' })) {
        $role = $tenant['role']
        $action = @(Get-TcProperty $plan 'actions' @()) | Where-Object { $_['id'] -eq "$role-IDENTITY-MATRIX" } | Select-Object -First 1
        if ($action -and -not (Get-TcProperty $action 'drafted' $true)) {
            & $notice $tenant 'No draft' $action['finding']
            continue
        }

        $accounts = Get-TcTableState -Snapshot $snapshot -Role $role -Table 'users'
        if ($accounts.State -in 'NotCollected', 'NotFullyRead') {
            & $notice $tenant 'No draft' ('The accounts of this source could not be read ({0}). {1}' -f $accounts.Status, $accounts.Message).Trim()
            continue
        }

        $lines = @(ConvertTo-TcIdentityMatrix -Snapshot $snapshot -SourceRole $role -IgnoreNameSuffix $Book['IgnoreNameSuffix'])
        if (-not $lines.Count) {
            & $notice $tenant 'No account' 'This source has no member account.'
            continue
        }

        foreach ($line in $lines) {
            [ordered]@{
                Role = $role; Tenant = $tenant['displayName']; 'Display name' = $line['Display name']; 'Source UPN' = $line['Source UPN']; Type = $line['Type']
                'Proposed decision' = $line['Decision']; 'Target UPN' = $line['Target UPN']; 'Temporary UPN' = $line['Temporary UPN']; Notes = $line['Notes']
            }
        }
    }
}
