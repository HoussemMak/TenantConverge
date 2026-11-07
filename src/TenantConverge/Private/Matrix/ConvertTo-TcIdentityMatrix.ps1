function ConvertTo-TcIdentityMatrix {
    <#
    .SYNOPSIS
    Drafts the identity matrix of one source from a snapshot, and flags likely duplicates in the target.

    .DESCRIPTION
    Each member account of the source gets one row, with a proposed decision: Create, Duplicate or To
    review. Two accounts are likely the same person when their display names match once accents, case
    and punctuation are set aside. This is a draft for a person to confirm, not a decision. When the
    accounts of the target were not read, no duplicate can be ruled out, so nothing reads Create.

    .PARAMETER IgnoreNameSuffix
    Words to remove from the end of a display name before comparing, for a tenant that marks its
    accounts that way.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Snapshot,
        [Parameter(Mandatory)][string]$SourceRole,
        [AllowEmptyCollection()][string[]]$IgnoreNameSuffix = @(),
        [int]$InactiveDays = 90
    )

    $tenants = $Snapshot['tenants']
    if (-not $tenants.Contains($SourceRole)) { throw "This snapshot has no source $SourceRole." }

    $sourceTables = Get-TcProperty $tenants[$SourceRole] 'tables'
    $targetTables = Get-TcProperty $tenants['Target'] 'tables'

    # Dates are relative to the run, so a saved snapshot always gives the same draft.
    $reference = Get-Date
    $started = [string](Get-TcProperty (Get-TcProperty $Snapshot 'meta') 'started')
    if ($started) {
        $parsed = [datetime]::MinValue
        if ([datetime]::TryParse($started, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$parsed)) { $reference = $parsed }
    }
    $limit = $reference.AddDays(-$InactiveDays)

    $targetRead = (Get-TcTableState -Snapshot $Snapshot -Role 'Target' -Table 'users').State -notin 'NotCollected', 'NotFullyRead'
    $targetUsers = @(Get-TcProperty $targetTables 'users' @()) | Where-Object { (Get-TcProperty $_ 'Type') -eq 'Member' }
    $index = @{}
    foreach ($user in $targetUsers) { $index[(ConvertTo-TcMatchName -Name (Get-TcProperty $user 'Name') -IgnoreSuffix $IgnoreNameSuffix)] = $user }

    $initial = @(Get-TcProperty $targetTables 'domains' @()) | Where-Object { Get-TcProperty $_ 'Initial' $false } | Select-Object -First 1
    $targetDomain = Get-TcProperty $initial 'Domain' (Get-TcProperty $tenants['Target'] 'primaryDomain')

    $mailboxes = @(Get-TcProperty $sourceTables 'mailboxes' @())
    $sourceUsers = @(Get-TcProperty $sourceTables 'users' @()) | Where-Object { (Get-TcProperty $_ 'Type') -eq 'Member' }

    foreach ($user in @($sourceUsers | Sort-Object { Get-TcProperty $_ 'Name' })) {
        $upn = [string](Get-TcProperty $user 'UPN')
        $mailbox = $mailboxes | Where-Object { (Get-TcProperty $_ 'UPN') -eq $upn } | Select-Object -First 1
        $mailboxType = [string](Get-TcProperty $mailbox 'Type')

        # A Bookings page is a mailbox with no license, like a shared mailbox.
        $type = switch ($mailboxType) {
            { $_ -in 'SharedMailbox', 'SchedulingMailbox' } { 'Shared' }
            { $_ -in 'RoomMailbox', 'EquipmentMailbox' } { 'Resource' }
            default { 'User' }
        }

        $duplicate = $index[(ConvertTo-TcMatchName -Name (Get-TcProperty $user 'Name') -IgnoreSuffix $IgnoreNameSuffix)]
        $decision = if ($duplicate) { 'Duplicate' } else { 'Create' }
        $notes = [System.Collections.Generic.List[string]]::new()

        $enabled = [bool](Get-TcProperty $user 'Enabled')
        $lastText = [string](Get-TcProperty $user 'Last sign-in')
        $last = $null
        if ($lastText) {
            $parsed = [datetime]::MinValue
            if ([datetime]::TryParse($lastText, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$parsed)) { $last = $parsed }
        }
        $licenseCount = [int](Get-TcProperty $user 'License count' 0)

        if ($type -eq 'User' -and (-not $enabled -or ($last -and $last -lt $limit) -or (-not $last -and -not $licenseCount))) {
            $decision = 'To review'
            if (-not $enabled) { $notes.Add('disabled account') }
            elseif ($last) { $notes.Add("inactive since $($last.ToString('yyyy-MM-dd'))") }
            else { $notes.Add('no license and no known sign-in') }
        }

        if ($mailboxType -eq 'SchedulingMailbox') {
            # Bookings cannot be moved: the page is recreated in the target or dropped.
            $decision = 'To review'
            $notes.Add('Bookings page: recreate it in the target or drop it (Bookings cannot be moved)')
        }

        if ($duplicate) { $notes.Add("likely duplicate of $(Get-TcProperty $duplicate 'UPN')") }

        if (-not $targetRead) {
            $decision = 'To review'
            $notes.Add('the accounts of the target were not read, so duplicates were not looked for')
        }

        $alias = (Get-TcAddressPrefix $upn).ToLowerInvariant()
        [ordered]@{
            'Source UPN'    = $upn
            'Display name'  = Get-TcProperty $user 'Name'
            'First name'    = Get-TcProperty $user 'First name'
            'Last name'     = Get-TcProperty $user 'Last name'
            'Type'          = $type
            'Decision'      = $decision
            'Target UPN'    = $(if ($duplicate) { Get-TcProperty $duplicate 'UPN' } else { $upn })
            'Temporary UPN' = $(if ($duplicate) { '' } else { '{0}.{1}@{2}' -f $SourceRole.ToLowerInvariant(), $alias, $targetDomain })
            'License'       = ''
            'Groups'        = ''
            'Notes'         = @($notes) -join '; '
        }
    }
}
