<#
    Checks that a script reads, from a snapshot table, only the columns of that table.
#>

function Get-TcScriptColumnBreak {
    <# One line per column read that the table does not have. $Columns is a dictionary: table to column list. #>
    param([Parameter(Mandatory)][string]$Text, [string]$Name = 'script', [Parameter(Mandatory)][hashtable]$Columns)

    $tokens = $null; $errors = $null
    $tree = [System.Management.Automation.Language.Parser]::ParseInput($Text, [ref]$tokens, [ref]$errors)

    $tableOf = {
        # The table a statement reads, when it reads one directly.
        param($Node)
        if ($null -eq $Node) { return $null }
        $source = $Node.Extent.Text
        if ($source -match "Get-TcRemediationTable\s+\S+\s+'([A-Za-z]+)'") { return $Matches[1] }
        $null
    }

    $check = {
        param($Body, [string]$Variable, [string]$Table)
        foreach ($index in $Body.FindAll({ param($n) $n -is [System.Management.Automation.Language.IndexExpressionAst] -and $n.Index -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $n.Target -is [System.Management.Automation.Language.VariableExpressionAst] }, $true)) {
            if ($index.Target.VariablePath.UserPath -ne $Variable) { continue }
            if ($index.Index.Value -notin $Columns[$Table]) { "$Name`: $Table has no column '$($index.Index.Value)', line $($index.Extent.StartLineNumber)" }
        }
    }

    # A variable set from a table, or filtered from such a variable: foreach ($x in $thatVariable).
    $variables = @{}
    $assignments = @($tree.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left -is [System.Management.Automation.Language.VariableExpressionAst] }, $true))
    foreach ($round in 1..3) {
        foreach ($node in $assignments) {
            $right = $node.Right.Extent.Text
            # A filter keeps the table, a projection does not.
            if ($right -match 'ForEach-Object|Select-Object -(Expand|Property)|Group-Object|Measure-Object') { continue }
            $table = & $tableOf $node.Right
            if (-not $table -and $right -match '^(@\()?\$(\w+)(\)|\s*\|)') { $table = $variables[$Matches[2]] }
            if ($table) { $variables[$node.Left.VariablePath.UserPath] = $table }
        }
    }

    foreach ($loop in $tree.FindAll({ param($n) $n -is [System.Management.Automation.Language.ForEachStatementAst] }, $true)) {
        $table = & $tableOf $loop.Condition
        if (-not $table -and $loop.Condition.Extent.Text -match '^(@\()?\$(\w+)\)?$') { $table = $variables[$Matches[2]] }
        if ($table -and $Columns.ContainsKey($table) -and $loop.Condition.Extent.Text -notmatch 'ForEach-Object') { & $check $loop.Body $loop.Variable.VariablePath.UserPath $table }
    }

    foreach ($pipeline in $tree.FindAll({ param($n) $n -is [System.Management.Automation.Language.PipelineAst] -and @($n.PipelineElements).Count -gt 1 }, $true)) {
        $elements = @($pipeline.PipelineElements)
        $table = & $tableOf $elements[0]
        if (-not $table -and $elements[0].Extent.Text -match '^(@\()?\$(\w+)\)?$') { $table = $variables[$Matches[2]] }
        if (-not $table -or -not $Columns.ContainsKey($table)) { continue }
        foreach ($element in $elements[1..($elements.Count - 1)]) {
            if ($element -isnot [System.Management.Automation.Language.CommandAst]) { break }
            & $check $element '_' $table
            # What comes after a projection is no longer the table.
            if ([string]$element.GetCommandName() -in 'ForEach-Object', 'Group-Object', 'Measure-Object') { break }
        }
    }
}
