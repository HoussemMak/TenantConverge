function Test-TcWindowsPowerShell {
    <#
    .SYNOPSIS
    Tells whether Windows PowerShell 5.1 is on this computer. The Power Platform module only runs there.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    [bool]($IsWindows -and (Get-Command powershell.exe -ErrorAction SilentlyContinue))
}
