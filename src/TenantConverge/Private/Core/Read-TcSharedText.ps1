function Read-TcSharedText {
    <#
    .SYNOPSIS
    Reads a text file that another program may hold open, as Excel holds a CSV.

    .DESCRIPTION
    UTF-8 first. Excel can save a CSV in an old code page, in some languages, so a file that is not valid
    UTF-8 is read as Windows-1252. The byte order mark goes away. A file that no other program may share
    throws an IOException, for the caller to say so.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Path
    )

    $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]'ReadWrite, Delete')
    try {
        $memory = [System.IO.MemoryStream]::new()
        $stream.CopyTo($memory)
        $bytes = $memory.ToArray()
    }
    finally { $stream.Dispose() }

    try { $text = [System.Text.UTF8Encoding]::new($false, $true).GetString($bytes) }
    catch [System.Text.DecoderFallbackException] { $text = [System.Text.Encoding]::GetEncoding(1252).GetString($bytes) }
    $text.TrimStart([char]0xFEFF)
}
