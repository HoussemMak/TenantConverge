function ConvertTo-TcReportHtml {
    <#
    .SYNOPSIS
    Assembles the single-file report from the template, the fonts and the data.

    .DESCRIPTION
    The template is cut at its markers first, then each piece is added in turn, so nothing inside a value
    can ever be read as a marker or as a replacement pattern. The policy of the page names the script by
    its hash: only this script runs, even if a value got past the escaping. HTML turns CRLF into LF before
    a browser hashes a script, so the script is hashed in that form.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowNull()]$Data,
        [Parameter(Mandatory)][AllowNull()]$Tables
    )

    $template = Join-Path $PSScriptRoot 'Template'
    $utf8 = [System.Text.UTF8Encoding]::new($false)
    $read = { param([string]$Name) [System.IO.File]::ReadAllText((Join-Path $template $Name), $utf8).TrimStart([char]0xFEFF).Replace("`r`n", "`n") }
    $font = { param([string]$Name) [Convert]::ToBase64String([System.IO.File]::ReadAllBytes((Join-Path $PSScriptRoot 'Fonts' $Name))) }

    $styles = (& $read 'styles.css').Replace('__TEXT_FONT__', (& $font 'instrument-sans.woff2')).Replace('__CODE_FONT__', (& $font 'jetbrains-mono.woff2'))
    $code = @('core.js', 'tracking.js', 'views-summary.js', 'views-tenant.js', 'views-solutions.js', 'views-analysis.js', 'views-steering.js', 'startup.js' | ForEach-Object { & $read $_ }) -join "`n"
    $hash = [Convert]::ToBase64String([System.Security.Cryptography.SHA256]::HashData($utf8.GetBytes($code)))

    $parts = @{
        '/*__STYLES__*/'      = $styles
        '/*__SCRIPT_HASH__*/' = $hash
        '<!--__ICONS__-->'    = & $read 'icons.svg'
        '/*__DATA__*/'        = ConvertTo-TcReportJson -InputObject $Data
        '/*__TABLES__*/'      = ConvertTo-TcReportJson -InputObject $Tables
        '/*__SCRIPT__*/'      = $code
    }

    $page = [System.Text.StringBuilder]::new()
    foreach ($piece in [regex]::Split((& $read 'index.html'), '(/\*__[A-Z_]+__\*/|<!--__[A-Z_]+__-->)')) {
        [void]$page.Append($(if ($parts.ContainsKey($piece)) { $parts[$piece] } else { $piece }))
    }
    $page.ToString()
}
