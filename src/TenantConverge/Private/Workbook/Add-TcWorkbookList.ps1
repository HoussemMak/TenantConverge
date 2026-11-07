function Add-TcWorkbookList {
    <#
    .SYNOPSIS
    Makes a drop-down menu of a range, from a named list of the Settings tab.

    .PARAMETER Free
    Lets a person type something else, as for a name that is not in the team.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Sheet,
        [Parameter(Mandatory)][string]$Address,
        [Parameter(Mandatory)][string]$List,
        [switch]$Free
    )

    $rule = $Sheet.DataValidations.AddListValidation($Address)
    $rule.Formula.ExcelFormula = $List
    $rule.AllowBlank = $true
    if (-not $Free) {
        $rule.ShowErrorMessage = $true
        $rule.ErrorTitle = 'Choose from the list'
        $rule.Error = 'Choose a value from the list.'
    }
}
