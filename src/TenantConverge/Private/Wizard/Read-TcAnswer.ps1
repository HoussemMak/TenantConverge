function Read-TcAnswer {
    <#
    .SYNOPSIS
    Asks the user one question. This is the only call to Read-Host in the module.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Prompt
    )

    Read-Host -Prompt $Prompt
}
