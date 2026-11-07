function Read-TcChoice {
    <#
    .SYNOPSIS
    Repeats a question until the answer is one of the allowed values.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [Parameter(Mandatory)][string[]]$Allowed,
        [Parameter(Mandatory)][string]$Help
    )

    while ($true) {
        $answer = ([string](Read-TcAnswer -Prompt $Prompt)).Trim().ToLowerInvariant()
        if ($answer -in $Allowed) { return $answer }
        Write-TcMessage -Message $Help -Level Warning
    }
}
