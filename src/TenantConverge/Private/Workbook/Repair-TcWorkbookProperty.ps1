function Repair-TcWorkbookProperty {
    <#
    .SYNOPSIS
    Takes back out of a saved workbook what Excel writes about the person: name, company and folder.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path
    )

    $rules = @{
        'docProps/core.xml' = {
            param([string]$Text)
            $Text -replace '<cp:lastModifiedBy>[^<]*</cp:lastModifiedBy>', '<cp:lastModifiedBy>TenantConverge</cp:lastModifiedBy>' -replace '<dc:creator>[^<]*</dc:creator>', '<dc:creator>TenantConverge</dc:creator>'
        }
        'docProps/app.xml'  = {
            param([string]$Text)
            $Text -replace '<Company>[^<]*</Company>', '<Company>TenantConverge</Company>' -replace '<Manager>[^<]*</Manager>', ''
        }
        'xl/workbook.xml'   = {
            param([string]$Text)
            $Text -replace '(?s)<mc:AlternateContent(?:(?!</mc:AlternateContent>).)*?x15ac:absPath(?:(?!</mc:AlternateContent>).)*?</mc:AlternateContent>', '' -replace '<x15ac:absPath[^>]*/>', ''
        }
    }

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [System.IO.Compression.ZipFile]::Open($Path, 'Update')
    try {
        foreach ($part in $rules.Keys) {
            $entry = $archive.GetEntry($part)
            if (-not $entry) { continue }
            $reader = [System.IO.StreamReader]::new($entry.Open(), [System.Text.Encoding]::UTF8)
            try { $text = $reader.ReadToEnd() } finally { $reader.Dispose() }
            $entry.Delete()
            $writer = [System.IO.StreamWriter]::new($archive.CreateEntry($part).Open(), [System.Text.UTF8Encoding]::new($false))
            try { $writer.Write((& $rules[$part] $text)) } finally { $writer.Dispose() }
        }
    }
    finally { $archive.Dispose() }
}
