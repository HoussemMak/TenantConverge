function Save-TcPartialSnapshot {
    <#
    .SYNOPSIS
    Saves what has been collected so far. A failed save is logged and never stops the collection.
    #>
    [CmdletBinding()]
    param(
        [AllowEmptyString()][string]$Folder = ''
    )

    if (-not $Folder) { return }

    try {
        $snapshot = Get-TcCollectionSnapshot -ProjectName (Get-TcProperty $script:TcRunInfo 'project' '') -Started (Get-TcProperty $script:TcRunInfo 'started' '') -Partial
        Write-TcJsonFile -Path (Join-Path $Folder 'snapshot.partial.json') -InputObject $snapshot
        Write-TcLog -Message "Partial snapshot saved ($($script:TcCollection.Count) tenants)."
    }
    catch {
        Write-TcLog -Message "Partial snapshot not saved: $(Get-TcErrorText $_)" -Level WARN
    }
}
