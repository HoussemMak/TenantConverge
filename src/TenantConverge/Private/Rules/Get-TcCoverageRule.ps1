function Get-TcCoverageRule {
    <#
    .SYNOPSIS
    Returns the coverage rule, as a script block that takes the role of one tenant.
    #>
    [CmdletBinding()]
    [OutputType([scriptblock])]
    param()

    { # Collectors that did not collect
        param($Role)
        $lines = @(@(Get-TcProperty $script:TcRuleRun['Snapshot'] 'coverage' @()) | Where-Object { (Get-TcProperty $_ 'role') -eq $Role -and (Get-TcProperty $_ 'status') -notin 'OK', 'Partial' })
        if (-not $lines.Count) { return }
        Add-TcFinding 'INV-COVERAGE' $Role -Values @{ count = $lines.Count } -Items ($lines | ForEach-Object { '{0} {1} - {2} - {3}' -f (Get-TcProperty $_ 'id'), (Get-TcProperty $_ 'title'), (Get-TcProperty $_ 'status'), (Get-TcProperty $_ 'remedy') })
    }
}
