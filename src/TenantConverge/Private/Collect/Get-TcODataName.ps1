function Get-TcODataName {
    <#
    .SYNOPSIS
    Shortens an OData type name for display.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Position = 0)][AllowNull()][string]$Type
    )

    ($Type -replace '^#microsoft\.graph\.', '') -replace '(CompliancePolicy|Configuration|EnrollmentConfiguration|App)$', ''
}
