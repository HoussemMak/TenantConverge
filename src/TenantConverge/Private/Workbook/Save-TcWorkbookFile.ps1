function Save-TcWorkbookFile {
    <#
    .SYNOPSIS
    Puts a finished workbook in its place, and keeps the one it replaces.

    .DESCRIPTION
    A team fills in the yellow columns of a workbook, and only the tracking file passes to the next one, so
    the one already there is kept under another name, never overwritten, and the person is told that it
    is the only copy of those columns. A file open in Excel cannot be replaced: that stops here, with what
    to do, and the file stays as it was.

    .PARAMETER YellowColumn
    The columns that do not carry over, in words, for the message.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Temporary,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$YellowColumn
    )

    $previous = $null
    try {
        if (Test-Path -LiteralPath $Path) {
            $stem = '{0}-previous-{1:yyyyMMdd-HHmmss}' -f [System.IO.Path]::GetFileNameWithoutExtension($Path), (Get-Date)
            $folder = Split-Path -Path $Path -Parent
            $previous = Join-Path $folder "$stem.xlsx"
            $number = 2
            while (Test-Path -LiteralPath $previous) {
                $previous = Join-Path $folder "$stem-$number.xlsx"
                $number++
            }
            [System.IO.File]::Move($Path, $previous)
        }
        [System.IO.File]::Move($Temporary, $Path)
    }
    catch {
        throw "$Path could not be replaced: it may be open in another program. Close it, or choose another file with -OutputPath. ($($_.Exception.Message))"
    }

    if ($previous) {
        Write-TcMessage -Message "The previous workbook was kept as $previous. What the team typed in its yellow columns is not in the new workbook: $YellowColumn. The new workbook takes only what the tracking file holds, so the previous file is the only copy of the rest. Do not delete it." -Level Warning
    }
    $Path
}
