function Add-TcWorkbookRoleFormat {
    <#
    .SYNOPSIS
    Colors cells that hold a role with the color of that role. A role not in the project gets no rule.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Book,
        [Parameter(Mandatory)][object]$Sheet,
        [Parameter(Mandatory)][string]$Address
    )

    $theme = $Book['Theme']
    foreach ($role in @(@(Get-TcProperty $Book['Plan'] 'tenants' @() | ForEach-Object { $_['role'] }) + 'All')) {
        $format = $Sheet.ConditionalFormatting.AddEqual($Sheet.Cells[$Address])
        $format.Formula = '"{0}"' -f $role
        $format.Style.Fill.BackgroundColor.Color = ConvertTo-TcWorkbookColor $theme['Roles'][$role]
        $format.Style.Font.Color.Color = [System.Drawing.Color]::White
    }
}
