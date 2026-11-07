<#
.SYNOPSIS
Renders the diagrams of the documentation from their SVG sources.

.DESCRIPTION
Each file in docs/images/source becomes a PNG in docs/images, at twice its size, with the fonts of the
report. It uses a headless Edge or Chrome, in a profile of its own, and connects to nothing.

Change the SVG, then run this script: the PNG files are what the documents show.

Returns the paths of the pictures.

.PARAMETER OutputPath
The folder to write to. The default is docs/images in this repository.

.PARAMETER Name
The diagrams to render, by file name without extension. The default is all of them.

.EXAMPLE
./tools/New-TcDiagram.ps1

Renders every diagram.

.EXAMPLE
./tools/New-TcDiagram.ps1 -Name overview -OutputPath ./draft

Renders one diagram in another folder.
#>
[CmdletBinding()]
[OutputType([string])]
param(
    [string]$OutputPath,
    [string[]]$Name
)

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$fonts = Join-Path $root 'src/TenantConverge/Private/Report/Fonts'
if (-not $OutputPath) { $OutputPath = Join-Path $root 'docs/images' }
New-Item -ItemType Directory -Force -Path $OutputPath | Out-Null

# A headless window keeps part of its height for itself, so the size is set through the DevTools protocol.
. (Join-Path $root 'tests/Support/BrowserDriver.ps1')
$browserPath = Find-TcBrowser
if (-not $browserPath) { throw 'This script needs Edge or Chrome.' }

$text = [Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $fonts 'instrument-sans.woff2')))
$code = [Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $fonts 'jetbrains-mono.woff2')))
$style = @"
@font-face{font-family:'Instrument Sans';src:url(data:font/woff2;base64,$text) format('woff2');font-weight:400 700;font-stretch:75% 100%}
@font-face{font-family:'JetBrains Mono';src:url(data:font/woff2;base64,$code) format('woff2');font-weight:100 800}
html,body{margin:0;padding:0;overflow:hidden;background:#EFF3F1}
svg{display:block}
"@

$work = Join-Path ([IO.Path]::GetTempPath()) ('tc-diagram-' + [guid]::NewGuid())
New-Item -ItemType Directory -Force -Path $work | Out-Null
$browser = $null
try {
    $browser = Start-TcBrowser -Path $browserPath -Folder $work
    $sources = Get-ChildItem -LiteralPath (Join-Path $root 'docs/images/source') -Filter '*.svg' | Where-Object { -not $Name -or $_.BaseName -in $Name }
    foreach ($source in $sources) {
        $svg = Get-Content -LiteralPath $source.FullName -Raw -Encoding utf8
        if ($svg -notmatch 'viewBox="0 0 (\d+) (\d+)"') { throw "$($source.Name) has no viewBox." }
        $width, $height = $Matches[1], $Matches[2]

        $page = Join-Path $work "$($source.BaseName).html"
        Set-Content -LiteralPath $page -Encoding utf8 -Value "<!doctype html><html><head><meta charset='utf-8'><style>$style</style></head><body>$svg</body></html>"

        Invoke-TcBrowser -Browser $browser -Method 'Emulation.setDeviceMetricsOverride' -Parameters @{ width = [int]$width; height = [int]$height; deviceScaleFactor = 2; mobile = $false } | Out-Null
        Open-TcBrowserPage -Browser $browser -Path $page
        while ((Invoke-TcPageScript -Browser $browser -Script 'document.fonts.status') -ne 'loaded') { Start-Sleep -Milliseconds 50 }

        $picture = Join-Path ([IO.Path]::GetFullPath($OutputPath)) "$($source.BaseName).png"
        Save-TcBrowserScreenshot -Browser $browser -Path $picture
        $picture
    }
}
finally {
    if ($browser) { Stop-TcBrowser -Browser $browser }
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
