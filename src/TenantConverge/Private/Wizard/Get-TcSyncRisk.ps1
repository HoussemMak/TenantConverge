function Get-TcSyncRisk {
    <#
    .SYNOPSIS
    Returns the cloud service that syncs a folder, or nothing for a local folder.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Path
    )

    $normalized = ($Path -replace '/', '\').TrimEnd('\')

    foreach ($root in $env:OneDrive, $env:OneDriveCommercial, $env:OneDriveConsumer) {
        if ([string]::IsNullOrWhiteSpace($root)) { continue }
        $folder = ($root -replace '/', '\').TrimEnd('\')
        if ($normalized.Equals($folder, [StringComparison]::OrdinalIgnoreCase) -or
            $normalized.StartsWith("$folder\", [StringComparison]::OrdinalIgnoreCase)) {
            return 'OneDrive'
        }
    }

    foreach ($segment in $normalized -split '\\') {
        if ($segment -match '^OneDrive') { return 'OneDrive' }
        if ($segment -eq 'Dropbox') { return 'Dropbox' }
        if ($segment -eq 'Google Drive') { return 'Google Drive' }
        if ($segment -eq 'iCloudDrive') { return 'iCloud' }
    }
}
