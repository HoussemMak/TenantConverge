function Get-TcRunningExcel {
    <#
    .SYNOPSIS
    Returns the process identifiers of the Excel instances running now.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param()

    @(Get-Process -Name 'EXCEL' -ErrorAction SilentlyContinue | ForEach-Object { $_.Id })
}
