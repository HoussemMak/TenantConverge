function Write-TcIsolatedResult {
    <#
    .SYNOPSIS
    Saves what the separate process has collected so far, for the main run to read back.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path
    )

    Write-TcJsonFile -Path $Path -InputObject ([ordered]@{ coverage = @($script:TcCurrentTenant['coverage']); tables = $script:TcCurrentTenant['tables'] })
}