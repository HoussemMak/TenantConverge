function Write-TcMessage {
    <#
    .SYNOPSIS
    Shows a message to the user.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('Info', 'Warning', 'Success')][string]$Level = 'Info'
    )

    $color = switch ($Level) {
        'Warning' { [ConsoleColor]::Yellow }
        'Success' { [ConsoleColor]::Green }
        default { [ConsoleColor]::Gray }
    }

    $record = [System.Management.Automation.HostInformationMessage]@{
        Message         = $Message
        ForegroundColor = $color
        NoNewLine       = $false
    }
    Write-Information -MessageData $record -InformationAction Continue
}
