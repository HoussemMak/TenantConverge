# Contributing

Contributions are welcome. Open an issue first for anything larger than a small fix.

## Set up

You need PowerShell 7.4 or later, Pester 6.2.0 and PSScriptAnalyzer 1.25.0.

```powershell
Install-Module Pester -RequiredVersion 6.2.0 -Scope CurrentUser
Install-Module PSScriptAnalyzer -RequiredVersion 1.25.0 -Scope CurrentUser
```

## Run the checks

```powershell
Invoke-Pester tests
Invoke-ScriptAnalyzer -Path src -Recurse -Settings ./PSScriptAnalyzerSettings.psd1
Invoke-ScriptAnalyzer -Path tools -Recurse -Settings ./PSScriptAnalyzerSettings.psd1
```

Both must be clean before a pull request.

## Maintainers

Maintainers keep a private list of terms that must never enter this repository. Turn on the hooks once per clone:

```powershell
pwsh tools/Enable-TcHooks.ps1 -TermsPath ../private/terms.txt
```

The hooks check each commit, each merge and each push. Run the check on a contributor's branch before merging it.

## Rules

- Write a failing test first, then the code.
- Write code, messages and documentation in English.
- Use fictional data only, on reserved `.example` domains. Never put real tenant data in an issue, a test or a fixture.
- Keep the limit of 3 source tenants in `$script:TcMaxSources`.
- Ask questions only through `Read-TcAnswer`.

## Releases

A tag such as `v0.9.0-beta1` starts `.github/workflows/release.yml`: it runs the tests and the term check, then publishes `src/TenantConverge` to the PowerShell Gallery. The tag must be the version of the manifest, and the first entry of `CHANGELOG.md` names that version. The repository needs two secrets: `PSGALLERY_API_KEY` and `TC_FORBIDDEN_TERMS`. Without the second, nothing is published.

A version cannot be taken back from the Gallery. Keep `LICENSE`, `NOTICE` and `THIRD-PARTY-NOTICES.md` the same at the root and in `src/TenantConverge`: the package holds only that folder.

## Diagrams

The pictures in `docs/images` come from the SVG files in `docs/images/source`. Change the SVG, then run `./tools/New-TcDiagram.ps1`, which needs Edge or Chrome. A test checks that the counts in the diagrams match the code.
