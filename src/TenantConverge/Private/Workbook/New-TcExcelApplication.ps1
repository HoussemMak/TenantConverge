function New-TcExcelApplication {
    <#
    .SYNOPSIS
    Starts Excel, hidden. It fails on a computer without Excel, and the caller says so.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Starts a hidden process that the caller closes. It changes nothing on the computer.')]
    [CmdletBinding()]
    [OutputType([object])]
    param()

    New-Object -ComObject Excel.Application -ErrorAction Stop
}
