function Get-TcPlanConfiguration {
    <#
    .SYNOPSIS
    Lists the settings to put in place: those of the procedures, the gaps with the target, and the matrices.

    .DESCRIPTION
    A procedure setting that the assessment measured takes its real value, and replaces the gap line. Two
    actions can share a procedure, so a measured setting appears once per tenant.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)][hashtable]$Context,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Action
    )

    $procedures = Get-TcProcedureCatalog
    $dictionary = Get-TcTableDictionary
    $gaps = @(Get-TcProperty $Context['RuleSet'] 'settingGaps' @())

    $measured = @{}
    foreach ($gap in $gaps) { $measured[[string]$gap['setting']] = $gap }
    $covered = @{}
    $seen = @{}

    foreach ($item in $Action) {
        if (-not $item['procedure']) { continue }
        foreach ($line in @($procedures[$item['procedure']]['configuration'])) {
            $gap = $measured[[string]$line['setting']]
            $key = if ($gap) { "$($item['role'])|$($line['setting'])" } else { "$($item['role'])|$($line['setting'])|$($line['target'])" }
            if ($seen.ContainsKey($key)) { continue }
            $seen[$key] = $true

            $current = ''
            if ($gap) {
                $current = [string](Get-TcProperty $gap['values'] $item['role'] '')
                $covered["$($item['role'])|$($gap['setting'])"] = $true
            }
            [ordered]@{
                role = $item['role']; tenant = $item['tenant']; wave = $item['wave']; group = $(if ($item['workload']) { $item['workload'] } else { 'General' })
                setting = $line['setting']; current = $current; target = $line['target']; where = $line['where']; action = $item['id']; origin = 'Procedure'
            }
        }
    }

    foreach ($gap in $gaps) {
        $label = $dictionary[$gap['table']]['label']
        foreach ($source in @($gap['different'])) {
            if ($source -notin $Context['Sources'] -or $covered.ContainsKey("$source|$($gap['setting'])")) { continue }
            [ordered]@{
                role = $source; tenant = $Context['Names'][$source]; wave = $Context['WaveOf'][$source]; group = $gap['workload']
                setting = '{0}: {1}' -f $label, $gap['setting']; current = [string](Get-TcProperty $gap['values'] $source ''); target = [string](Get-TcProperty $gap['values'] 'Target' '')
                where = $label; action = ''; origin = $(if ($gap['important']) { 'Important gap' } else { 'Gap' })
            }
        }
    }

    foreach ($source in @($Context['Sources'])) {
        $id = "$source-IDENTITY-MATRIX"
        $matrix = @($Action | Where-Object { $_['id'] -eq $id }) | Select-Object -First 1
        $state = if (-not $matrix) { 'None' } elseif (Get-TcProperty $matrix 'drafted' $true) { 'Draft only' } else { 'Not drafted' }
        [ordered]@{
            role = $source; tenant = $Context['Names'][$source]; wave = $Context['WaveOf'][$source]; group = 'Identities'
            setting = 'Identity matrix validated'; current = $state; target = 'Validated by the customer'
            where = "identity-matrix-$source.csv"; action = $(if ($matrix) { $id } else { '' }); origin = 'Matrix'
        }
    }
}
