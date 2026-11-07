# UNTESTED: this script has never been run on a real tenant. Read it, try it on a test tenant first, and use it at your own risk.
<#
.SYNOPSIS
    Exports the schedules and holidays of the source and recreates the holidays in the target (procedure TEL-SCHEDULES).

.DESCRIPTION
    First exports, to <output>\telephony\<tenant>: the schedules (schedules.json) and the holidays of each auto attendant
    (Export-CsAutoAttendantHolidays). These files outlive the closure of the source.
    Holidays are shared calendars: New-CsOnlineSchedule recreates them before the auto attendants, without the admin center. Only
    future dates are carried over, after the customer decision in decisions\TEL-SCHEDULES.csv. A calendar with no future date is
    reported and not created.
    Business hours belong to each auto attendant: they are entered with it (TEL-VOICE-APPS), from schedules.json.
#>
$c = Open-TcRemediation

$HolidayType = 'Fixed dates (holidays)'

function Get-SourceSchedule {
    <# Schedules of the source, read once: each change of tenant opens a Teams session again. #>
    param([string]$Source)
    if (-not $script:TcRemediationRun['CacheSourceSchedules']) { $script:TcRemediationRun['CacheSourceSchedules'] = @{} }
    if (-not $script:TcRemediationRun['CacheSourceSchedules'][$Source]) { $script:TcRemediationRun['CacheSourceSchedules'][$Source] = @(Invoke-TcServiceCommand -Tenant $Source -Service Teams -Command 'Get-CsOnlineSchedule') }
    return $script:TcRemediationRun['CacheSourceSchedules'][$Source]
}

$proposals = foreach ($t in $c.Tenants) {
    Write-TcRemediationTenant $t
    $schedules = @(Get-TcRemediationTable $t 'phoneSchedules')
    $holidays = @($schedules | Where-Object { $_['Type'] -eq $HolidayType })
    $autoAttendants = @(Get-TcRemediationTable $t 'autoAttendants')
    Write-TcRemediationNote ("{0} schedule(s), {1} holiday calendar(s); {2} auto attendant(s)" -f $schedules.Count, $holidays.Count, $autoAttendants.Count)
    if ($autoAttendants.Count) {
        $exportFolder = Join-Path (Get-TcRemediationOutput) "telephony\$t"
        Add-TcBlockAction -Tenant $t -Service Teams -Object 'Schedules export' -Description "Export the schedules and holidays of $t" -Critical -Data @{ Folder = $exportFolder; AutoAttendants = @($autoAttendants | ForEach-Object { @{ Name = $_['Name']; Id = $_['Identity'] } }) } `
            -Reason 'Reads the source: nothing to undo, the files stay for closure.' `
            -Block {
                param($a)
                New-Item -ItemType Directory -Force -Path $a.data.Folder | Out-Null
                Get-SourceSchedule -Source $a.tenant | ConvertTo-Json -Depth 10 -WarningAction SilentlyContinue | Set-Content -LiteralPath (Join-Path $a.data.Folder 'horaires.json') -Encoding utf8
                foreach ($s in $a.data.AutoAttendants) {
                    try {
                        $bytes = Invoke-TcServiceCommand -Tenant $a.tenant -Service Teams -Command 'Export-CsAutoAttendantHolidays' -Parameters @{ Identity = (Get-TcText $s 'Id') }
                        [System.IO.File]::WriteAllBytes((Join-Path $a.data.Folder ("holidays-{0}.csv" -f (Get-TcMember $s 'Name'))), [byte[]]$bytes)
                    }
                    catch { Write-TcRemediationAlert ("Holidays of {0} not exported: {1}" -f (Get-TcMember $s 'Name'), (Get-TcErrorText $_)) }
                }
            }
        Add-TcManualAction -Tenant 'Target' -Object "Business hours" -Description "Enter the business hours with each auto attendant" `
            -Instruction @(("The {0} weekly schedules belong to the auto attendants: they are entered when each one is created in the Teams admin center." -f ($schedules.Count - $holidays.Count)), "Reference: $exportFolder\horaires.json", 'Review the time zone of each auto attendant.')
    }
    foreach ($h in $holidays) { [ordered]@{ Tenant = $t; Calendar = $h['Name']; 'Used by' = $h['Used by']; Proposal = 'Recreate' } }
}
$decisions = @(Get-TcDecision -Name 'TEL-SCHEDULES' -Proposal @($proposals) -Key 'Tenant', 'Calendar' -Choice 'Recreate', 'Ignore')

foreach ($d in $decisions | Where-Object { (Get-TcMember $_ 'Decision') -eq 'Recreate' -and (Get-TcMember $_ 'Tenant') -in $c.Tenants }) {
    Add-TcBlockAction -Tenant 'Target' -Service Teams -Object (Get-TcMember $d 'Calendar') -Description ("Recreate the holiday calendar {0}" -f (Get-TcMember $d 'Calendar')) -Data @{ Source = (Get-TcMember $d 'Tenant'); Name = (Get-TcMember $d 'Calendar') } `
        -Test { param($a) [bool]@(Invoke-TcServiceCommand -Tenant $a.tenant -Service Teams -Command 'Get-CsOnlineSchedule' | Where-Object { (Get-TcMember $_ 'Name') -eq $a.data.Name }).Count } `
        -Block {
            param($a)
            $s = @(Get-SourceSchedule -Source $a.data.Source | Where-Object { (Get-TcMember $_ 'Name') -eq $a.data.Name }) | Select-Object -First 1
            if (-not $s) { throw "Calendar $($a.data.Name) not found in $($a.data.Source)" }
            $now = Get-Date
            $ranges = @((Get-TcMember (Get-TcMember $s 'FixedSchedule') 'DateTimeRanges') | Where-Object { [datetime](Get-TcMember $_ 'End') -gt $now })
            if (-not $ranges.Count) { throw "Calendar $($a.data.Name): no future date, to be completed by the customer." }
            $culture = [System.Globalization.CultureInfo]::InvariantCulture
            $objects = @(foreach ($p in $ranges) {
                Invoke-TcServiceCommand -Tenant $a.tenant -Service Teams -Command 'New-CsOnlineDateTimeRange' -Parameters @{ Start = ([datetime](Get-TcMember $p 'Start')).ToString('d/M/yyyy H:mm', $culture); End = ([datetime](Get-TcMember $p 'End')).ToString('d/M/yyyy H:mm', $culture) }
            })
            $n = Invoke-TcServiceCommand -Tenant $a.tenant -Service Teams -Command 'New-CsOnlineSchedule' -Parameters @{ Name = $a.data.Name; FixedSchedule = $true; DateTimeRanges = $objects }
            $a.undo = @{ command = 'Remove-CsOnlineSchedule'; parameters = @{ Id = (Get-TcText $n 'Id') } }
        }
}

Invoke-TcRemediationPlan -Verify {
    param($t)
    $l = @(Invoke-TcServiceCommand -Tenant 'Target' -Service Teams -Command 'Get-CsOnlineSchedule')
    foreach ($d in $decisions | Where-Object { (Get-TcMember $_ 'Decision') -eq 'Recreate' -and (Get-TcMember $_ 'Tenant') -eq $t }) {
        if (@($l | Where-Object { (Get-TcMember $_ 'Name') -eq (Get-TcMember $d 'Calendar') }).Count) { New-TcRemediationResult OK ("calendar {0} present" -f (Get-TcMember $d 'Calendar')) } else { New-TcRemediationResult Blocking ("calendar {0} missing from the target" -f (Get-TcMember $d 'Calendar')) }
    }
}
Close-TcRemediation
