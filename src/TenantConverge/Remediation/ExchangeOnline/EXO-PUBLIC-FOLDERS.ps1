# UNTESTED: this script has never been run on a real tenant. Read it, try it on a test tenant first, and use it at your own risk.
<#
.SYNOPSIS
    Has the fate of each public folder decided, before the first cutover (procedure EXO-PUBLIC-FOLDERS).

.DESCRIPTION
    Data read: publicFolders table. Volume and last change are not there: in an -Apply run, the script reads them and writes
    exports\public-folder-statistics-<tenant>.csv for the workshop.

    Decision: decisions\EXO-PUBLIC-FOLDERS.csv, one row per folder: Keep, Convert or Drop.
    Nothing is deleted: Drop means the folder is not carried over. Any removal is a separate step.

    Limits: no merge exists between the public folders of two tenants, a separate destination is needed. Copying a converted folder, and
    carrying over its permissions, stay to be done by a person.
#>
$c = Open-TcRemediation

$proposals = foreach ($t in $c.Tenants) {
    Write-TcRemediationTenant $t
    $folders = @(Get-TcRemediationTable $t 'publicFolders')
    if (-not $folders.Count -and -not (Test-TcCollectionComplete $t 'publicFolders')) { Write-TcRemediationAlert 'Public folder collection incomplete: run Invoke-TcAssessment again'; continue }
    Write-TcRemediationNote ("{0} public folder(s), {1} mail-enabled" -f $folders.Count, @($folders | Where-Object { ConvertTo-TcBoolean $_['Email'] }).Count)
    if (-not $folders.Count) { continue }
    Add-TcBlockAction -Tenant $t -Service Exo -Object 'Statistics' -Description ("Read the volume and the last change of the folders of {0}" -f $t) -Reason 'Read only: the report stays in the log folder.' `
        -Block {
            param($a)
            $rows = foreach ($f in @(Invoke-TcServiceCommand -Tenant $a.tenant -Service Exo -Command 'Get-PublicFolder' -Parameters @{ Identity = '\'; Recurse = $true; ResultSize = 'Unlimited' })) {
                if (-not (Get-TcMember $f 'ParentPath')) { continue }
                $s = Invoke-TcServiceCommand -Tenant $a.tenant -Service Exo -Command 'Get-PublicFolderStatistics' -Parameters @{ Identity = (Get-TcText $f 'Identity') }
                [pscustomobject][ordered]@{ Folder = (Get-TcText $f 'Identity'); 'Mail-enabled' = [bool](Get-TcMember $f 'MailEnabled'); 'Items' = (Get-TcMember $s 'ItemCount'); Size = (Get-TcText $s 'TotalItemSize'); 'Last modified' = (Get-TcText $s 'LastModificationTime') }
            }
            Export-TcRemediationReport -Name ("public-folder-statistics-{0}" -f $a.tenant) -Rows @($rows) | Out-Null
        }
    foreach ($d in $folders) {
        [ordered]@{ Tenant = $t; Folder = $d['Path']; Email = $d['Email']; 'Content mailbox' = $d['Content mailbox']; 'Subfolders' = $d['Subfolders']; Proposal = '' }
    }
}

$decisions = @(Get-TcDecision -Name 'EXO-PUBLIC-FOLDERS' -Proposal @($proposals) -Key 'Tenant', 'Folder' -Choice 'Keep', 'Convert', 'Drop')

foreach ($t in $c.Tenants) {
    $n = @($decisions | Where-Object { (Get-TcMember $_ 'Tenant') -eq $t -and (Get-TcMember $_ 'Decision') -eq 'Convert' }).Count
    if ($n) {
        Add-TcManualAction -Tenant $t -Object 'Conversion' -Description ("Convert {0} public folder(s) of {1}" -f $n, $t) `
            -Instruction @("Copy the content to the chosen destination with the copy tool, then check user access.", "Carry over the permissions by hand: they do not always follow the conversion.")
    }
    $s = @($decisions | Where-Object { (Get-TcMember $_ 'Tenant') -eq $t -and $t -ne 'Target' -and (Get-TcMember $_ 'Decision') -eq 'Keep' }).Count
    if ($s) { Write-TcRemediationAlert ("{0}: {1} folder(s) kept in a source: plan a separate destination, they do not merge with those of the target" -f $t, $s) }
}

Invoke-TcRemediationPlan
Close-TcRemediation
