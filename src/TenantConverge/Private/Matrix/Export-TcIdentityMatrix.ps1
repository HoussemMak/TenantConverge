function Export-TcIdentityMatrix {
    <#
    .SYNOPSIS
    Writes the draft identity matrix of each source to identity-matrix-<role>.csv in a folder.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Snapshot,
        [Parameter(Mandatory)][string]$Folder,
        [AllowEmptyCollection()][string[]]$IgnoreNameSuffix = @()
    )

    foreach ($role in @($Snapshot['tenants'].Keys | Where-Object { $_ -ne 'Target' })) {
        $rows = @(ConvertTo-TcIdentityMatrix -Snapshot $Snapshot -SourceRole $role -IgnoreNameSuffix $IgnoreNameSuffix)
        if ($rows.Count -eq 0) { continue }
        $rows | ForEach-Object {
            $row = $_
            $line = [ordered]@{}
            foreach ($column in @($row.Keys)) { $line[$column] = ConvertTo-TcCsvCell $row[$column] }
            [pscustomobject]$line
        } |
            Export-Csv -LiteralPath (Join-Path $Folder "identity-matrix-$role.csv") -NoTypeInformation -Encoding utf8BOM
    }
}
