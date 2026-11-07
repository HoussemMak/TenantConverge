function Get-TcModuleVersion {
    <#
    .SYNOPSIS
    Returns the newest installed version of a module, or nothing. The answer is cached for the session.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [switch]$WindowsPowerShell,
        [switch]$Refresh
    )

    $key = "$Name|$([bool]$WindowsPowerShell)"
    if (-not $Refresh -and $script:TcModuleVersions.ContainsKey($key)) { return $script:TcModuleVersions[$key] }

    $version = $null
    if ($WindowsPowerShell) {
        $command = "`$m = Get-Module -ListAvailable -Name '$Name' | Sort-Object Version -Descending | Select-Object -First 1; if (`$m) { `$m.Version.ToString() }"
        $text = & powershell.exe -NoProfile -NonInteractive -Command $command 2>$null
        if ($text) { $version = [version]([string]@($text)[-1]).Trim() }
    }
    else {
        $module = Get-Module -ListAvailable -Name $Name | Sort-Object Version -Descending | Select-Object -First 1
        if ($module) { $version = $module.Version }
    }

    $script:TcModuleVersions[$key] = $version
    $version
}
