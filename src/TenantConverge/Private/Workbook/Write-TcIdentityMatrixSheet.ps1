function Write-TcIdentityMatrixSheet {
    <#
    .SYNOPSIS
    Writes the Identity matrix tab: the draft of each source, for the customer to validate row by row.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Book
    )

    $rows = @(Get-TcWorkbookIdentityRow -Book $Book)
    $sheet = Add-TcWorkbookSheet -Book $Book -Name 'Identity matrix' -Title 'Identity matrix' -Filters `
        -Subtitle "A draft of $($rows.Count) row(s) that a person must confirm. Likely duplicates come from display names only." `
        -Legend 'Fill in the yellow columns. Nothing moves before the customer validates it in writing. These rows hold personal data.'

    $columns = @(
        @{ Name = 'Role'; Width = 7; Center = $true }
        @{ Name = 'Tenant'; Width = 18; Center = $true; Bold = $true; Wrap = $true }
        @{ Name = 'Display name'; Width = 28; Bold = $true; Wrap = $true }
        @{ Name = 'Source UPN'; Width = 36; Small = $true }
        @{ Name = 'Type'; Width = 10; Center = $true }
        @{ Name = 'Proposed decision'; Width = 12; Center = $true; Bold = $true; Keep = $true }
        @{ Name = 'Validated decision'; Width = 13; Center = $true; Input = $true }
        @{ Name = 'Target UPN'; Width = 36; Small = $true }
        @{ Name = 'Temporary UPN'; Width = 36; Small = $true }
        @{ Name = 'License'; Width = 14; Input = $true }
        @{ Name = 'Groups'; Width = 18; Input = $true }
        @{ Name = 'Notes'; Width = 48; Small = $true; Wrap = $true }
        @{ Name = 'Validated by'; Width = 16; Input = $true }
        @{ Name = 'Validated on'; Width = 11; Input = $true }
    )

    $table = Add-TcWorkbookTable -Book $Book -Sheet $sheet -Name 'IdentityMatrix' -Column $columns -Row $rows -Empty 'No source in this plan.'
    if ($rows.Count) { $sheet.View.FreezePanes($table['First'], 4) }
}
