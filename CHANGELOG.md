# Changelog

Changes to TenantConverge, the newest first. Versions follow [Semantic Versioning](https://semver.org/).

## 0.9.0-beta1

The first public version, a beta. Nothing in it has ever run against a real tenant: see [what has never been run](docs/limitations.md).

### Added

- Project setup for 1, 2 or 3 source tenants into 1 target: `Start-TenantConverge`, `New-TcProject` and `Test-TcProject`.
- A read-only assessment of 11 workloads by 56 collectors, with a coverage record for each one: `Invoke-TcAssessment`.
- 117 rules, a readiness score for each tenant, and a migration plan: `Invoke-TcRuleSet`, `Get-TcReadiness` and `New-TcPlan`.
- A report in a single HTML file and an Excel planning workbook, written without Excel: `New-TcReport` and `New-TcWorkbook`.
- A read-only application for assessments without a sign-in window, and its removal: `Initialize-TcAccess` and `Remove-TcAccess`.
- Diagrams of the tool and of how a run works, in [how it works](docs/how-it-works.md).
- 111 remediation scripts, each marked UNTESTED, a preview by default, with a journal and an undo where one exists: `Get-TcRemediation`, `Invoke-TcRemediation` and `Undo-TcRemediation`.
