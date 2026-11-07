function Read-TcSnapshot {
    <#
    .SYNOPSIS
    Reads a snapshot and refuses a schema version this module does not know.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param(
        [Parameter(Mandatory)][string]$Path
    )

    $snapshot = Read-TcJsonFile -Path $Path
    $version = Get-TcProperty $snapshot 'schemaVersion'
    if ($version -ne $script:TcSchemaVersion) {
        throw "This snapshot uses schema version $version. This module reads version $script:TcSchemaVersion."
    }
    $snapshot
}
