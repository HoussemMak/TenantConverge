Describe 'TenantConverge module' {
    BeforeAll {
        $root = Join-Path $PSScriptRoot '..'
        $manifest = Join-Path $root 'src/TenantConverge/TenantConverge.psd1'
        Import-Module $manifest -Force
        $m = Test-ModuleManifest $manifest
    }

    It 'requires PowerShell 7.4 on Core' {
        $m.PowerShellVersion | Should -Be ([version]'7.4')
        $m.CompatiblePSEditions | Should -Be @('Core')
    }

    It 'uses neutral authorship' {
        $m.Author | Should -Be 'The TenantConverge Authors'
        $m.CompanyName | Should -Be 'The TenantConverge Authors'
    }

    It 'caps sources at three' {
        InModuleScope TenantConverge { $script:TcMaxSources | Should -Be 3 }
    }

    It 'reads schema version 1' {
        InModuleScope TenantConverge { $script:TcSchemaVersion | Should -Be 1 }
    }

    It 'ships the Apache-2.0 license' {
        Get-Content (Join-Path $root 'LICENSE') -Raw | Should -Match 'Apache License'
    }

    It 'names the copyright holder in NOTICE' {
        Get-Content (Join-Path $root 'NOTICE') -Raw | Should -Match 'The TenantConverge Authors'
    }

    It 'passes Test-ModuleManifest with no error' {
        { Test-ModuleManifest $manifest -ErrorAction Stop } | Should -Not -Throw
    }

    It 'is a prerelease until it has run on a real tenant' {
        $m.Version | Should -Be ([version]'0.9.0')
        $m.PrivateData.PSData.Prerelease | Should -Be 'beta1'
    }

    It 'gives the Gallery its project, its license, its tags and its release notes' {
        $data = $m.PrivateData.PSData
        $data.ProjectUri | Should -Be 'https://github.com/HoussemMak/TenantConverge'
        $data.LicenseUri | Should -Be 'https://github.com/HoussemMak/TenantConverge/blob/main/LICENSE'
        $data.Tags | Should -Contain 'Microsoft365'
        $data.ReleaseNotes | Should -Match 'real tenant'
        $data.ReleaseNotes | Should -Match 'CHANGELOG'
    }

    It 'names the version of the manifest in the first entry of the changelog' {
        $text = Get-Content (Join-Path $root 'CHANGELOG.md') -Raw
        $first = [regex]::Match($text, '(?m)^## (\S+)').Groups[1].Value
        $first | Should -Be ('{0}-{1}' -f $m.Version, $m.PrivateData.PSData.Prerelease)
    }

    It 'exports exactly the commands in Public' {
        $public = @(Get-ChildItem (Join-Path $root 'src/TenantConverge/Public') -Filter *.ps1 -ErrorAction SilentlyContinue).BaseName
        $exported = @((Get-Module TenantConverge).ExportedFunctions.Keys)
        @($exported | Sort-Object) | Should -Be @($public | Sort-Object)
    }
}
