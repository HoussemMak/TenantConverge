<#
.SYNOPSIS
Turns on the git hooks of this clone for a maintainer who holds a private terms file.

.PARAMETER TermsPath
The private terms file. It stays outside the repository.

.PARAMETER Path
The clone to configure.

.EXAMPLE
pwsh tools/Enable-TcHooks.ps1 -TermsPath ../private/terms.txt
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TermsPath,
    [string]$Path = '.'
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $TermsPath -PathType Leaf)) {
    Write-Error 'The terms file was not found.'
    exit 2
}

$root = (Resolve-Path -LiteralPath $Path).ProviderPath
$terms = (Resolve-Path -LiteralPath $TermsPath).ProviderPath

git -C $root config core.hooksPath .githooks
git -C $root config tenantconverge.termsfile $terms

Write-Output 'The hooks are on for this clone.'
