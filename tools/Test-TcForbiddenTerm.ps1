<#
.SYNOPSIS
Checks a repository against a private list of forbidden patterns.

.DESCRIPTION
Each line of the terms file is a regular expression. Lines that start with # are comments. Patterns are
case-sensitive unless they say otherwise.

The output names the place and the pattern number, never the pattern or the matching text, because the
output can end up in a public log.

Exit codes: 0 clean, 1 at least one match, 2 the terms file cannot be used.

.PARAMETER TermsPath
The private terms file. It stays outside the repository.

.PARAMETER Path
The repository to check.

.PARAMETER IncludeGitHistory
Also checks every commit, for its author, committer, message and changes, and every branch and tag, for
its name and, for an annotated tag, its tagger and message.

.PARAMETER MessageFile
Checks only this commit message file. The commit-msg hook uses it.

.PARAMETER Staged
Checks only what is about to be committed, as stored in the index. The pre-commit hook uses it.

.EXAMPLE
pwsh tools/Test-TcForbiddenTerm.ps1 -TermsPath ../private/terms.txt -Path . -IncludeGitHistory
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TermsPath,
    [string]$Path = '.',
    [switch]$IncludeGitHistory,
    [string]$MessageFile,
    [switch]$Staged
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)

function Exit-WithUsageError {
    param([string]$Message)
    Write-Output $Message
    exit 2
}

function Read-TermList {
    param([string]$File)

    if (-not (Test-Path -LiteralPath $File -PathType Leaf)) {
        Exit-WithUsageError 'The terms file was not found.'
    }

    $patterns = [Collections.Generic.List[regex]]::new()
    $lineNumber = 0
    foreach ($line in [IO.File]::ReadAllLines((Resolve-Path -LiteralPath $File).ProviderPath)) {
        $lineNumber++
        if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith('#')) { continue }
        try {
            $patterns.Add([regex]::new($line.Trim()))
        }
        catch {
            Exit-WithUsageError "Line $lineNumber of the terms file is not a valid pattern."
        }
    }

    if ($patterns.Count -eq 0) { Exit-WithUsageError 'The terms file has no pattern.' }
    , $patterns
}

function Hide-Term {
    param([string]$Text, $Patterns)
    foreach ($pattern in $Patterns) { $Text = $pattern.Replace($Text, '***') }
    $Text
}

function Find-Term {
    <# Returns one record per pattern and line. Text never leaves this function. #>
    param([string[]]$Lines, $Patterns)

    for ($p = 0; $p -lt $Patterns.Count; $p++) {
        for ($l = 0; $l -lt $Lines.Count; $l++) {
            if ($Patterns[$p].IsMatch($Lines[$l])) {
                [pscustomobject]@{ Term = $p + 1; Line = $l + 1 }
            }
        }
    }
}

function Read-FileLine {
    <# Binary files are read byte for byte, so that plain text inside them is still found. #>
    param([string]$File)

    $bytes = [IO.File]::ReadAllBytes($File)
    $encoding = if ([Array]::IndexOf($bytes, [byte]0) -ge 0) { [Text.Encoding]::Latin1 } else { [Text.UTF8Encoding]::new($false) }
    $encoding.GetString($bytes) -split "`r?`n"
}

$patterns = Read-TermList -File $TermsPath
$found = 0

if ($MessageFile) {
    foreach ($match in Find-Term -Lines ([IO.File]::ReadAllLines((Resolve-Path -LiteralPath $MessageFile).ProviderPath)) -Patterns $patterns) {
        Write-Output "commit message:$($match.Line) matched term #$($match.Term)"
        $found++
    }
    exit $(if ($found) { 1 } else { 0 })
}

$root = (Resolve-Path -LiteralPath $Path).ProviderPath

if ($Staged) {
    $listing = (& git -C $root diff --cached --name-only --diff-filter=ACMR -z) -join ''
    foreach ($relative in @($listing -split "`0" | Where-Object { $_ })) {
        $shown = Hide-Term -Text $relative -Patterns $patterns

        foreach ($match in Find-Term -Lines @($relative) -Patterns $patterns) {
            Write-Output "$($shown):0 matched term #$($match.Term)"
            $found++
        }

        foreach ($match in Find-Term -Lines @(& git -C $root show ":$relative") -Patterns $patterns) {
            Write-Output "$($shown):$($match.Line) matched term #$($match.Term)"
            $found++
        }
    }
    exit $(if ($found) { 1 } else { 0 })
}

$listing = (& git -C $root ls-files --cached --others --exclude-standard -z) -join ''

foreach ($relative in @($listing -split "`0" | Where-Object { $_ })) {
    $shown = Hide-Term -Text $relative -Patterns $patterns

    foreach ($match in Find-Term -Lines @($relative) -Patterns $patterns) {
        Write-Output "$($shown):0 matched term #$($match.Term)"
        $found++
    }

    $file = Join-Path $root $relative
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { continue }

    foreach ($match in Find-Term -Lines (Read-FileLine -File $file) -Patterns $patterns) {
        Write-Output "$($shown):$($match.Line) matched term #$($match.Term)"
        $found++
    }
}

if ($IncludeGitHistory) {
    $commits = @(& git -C $root log --all --format=%H 2>$null)
    foreach ($commit in $commits) {
        $lines = @(& git -C $root show --no-color --text --format='%an%n%ae%n%cn%n%ce%n%B' $commit)
        $terms = @(Find-Term -Lines $lines -Patterns $patterns | Select-Object -ExpandProperty Term -Unique)
        foreach ($term in $terms) {
            Write-Output "commit $($commit.Substring(0, 7)) matched term #$term"
            $found++
        }
    }

    # A tag holds its own tagger and message, which no commit shows.
    foreach ($ref in @(& git -C $root for-each-ref '--format=%(refname)' 2>$null)) {
        $lines = @($ref) + @(& git -C $root for-each-ref '--format=%(taggername)%0a%(taggeremail)%0a%(contents)' $ref)
        $shown = Hide-Term -Text $ref -Patterns $patterns
        foreach ($term in @(Find-Term -Lines $lines -Patterns $patterns | Select-Object -ExpandProperty Term -Unique)) {
            Write-Output "ref $shown matched term #$term"
            $found++
        }
    }
}

exit $(if ($found) { 1 } else { 0 })
