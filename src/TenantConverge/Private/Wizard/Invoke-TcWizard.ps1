function Invoke-TcWizard {
    <#
    .SYNOPSIS
    Asks the setup questions and returns a project, or nothing if the user declines the summary.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()

    $yesNo = @{ Allowed = @('y', 'n', 'yes', 'no'); Help = 'Please answer y or n.' }

    function Read-DisplayName {
        param([string]$Prompt)
        while ($true) {
            $answer = ([string](Read-TcAnswer -Prompt $Prompt)).Trim()
            if (Test-TcDisplayName -Value $answer) { return $answer }
            Write-TcMessage -Message 'A display name is required, up to 64 characters, with no control characters.' -Level Warning
        }
    }

    function Read-Domain {
        param([string]$Prompt, [string[]]$Used)
        while ($true) {
            $answer = ConvertTo-TcDomain -Value (Read-TcAnswer -Prompt $Prompt)
            if (-not (Test-TcDomainName -Value $answer)) {
                Write-TcMessage -Message "'$answer' is not a valid domain name." -Level Warning
            }
            elseif ($answer -in $Used) {
                Write-TcMessage -Message "'$answer' is already used by another tenant in this project." -Level Warning
            }
            else {
                return $answer
            }
        }
    }

    function Read-Wave {
        param([string]$Prompt, [int]$Count)
        [int](Read-TcChoice -Prompt $Prompt -Allowed @(1..$Count | ForEach-Object { "$_" }) -Help "Please enter a number from 1 to $Count.")
    }

    function Test-WaveList {
        param([int[]]$Wave)
        $distinct = @($Wave | Sort-Object -Unique)
        ($distinct -join ',') -eq ((1..$distinct.Count) -join ',')
    }

    $count = [int](Read-TcChoice -Prompt 'How many source tenants will move into the target? (1, 2 or 3)' `
            -Allowed @(1..$script:TcMaxSources | ForEach-Object { "$_" }) `
            -Help 'TenantConverge handles 1, 2 or 3 source tenants into 1 target.')

    $targetDomain = Read-Domain -Prompt 'Target primary domain' -Used @()
    $targetName = Read-DisplayName -Prompt 'Target display name'
    $production = (Read-TcChoice -Prompt 'Is the target already in production? (y/n)' @yesNo) -in 'y', 'yes'

    if ($count -gt 1) {
        Write-TcMessage -Message 'A wave is a group of sources that move together. Wave 1 moves first, and two sources can share a wave.'
    }

    $used = @($targetDomain)
    $sources = @()
    for ($i = 1; $i -le $count; $i++) {
        $name = Read-DisplayName -Prompt "Source $i display name"
        $domain = Read-Domain -Prompt "Source $i primary domain" -Used $used
        $used += $domain
        $wave = if ($count -eq 1) { 1 } else { Read-Wave -Prompt "Source $i wave (1 to $count)" -Count $count }
        $sources += @{ DisplayName = $name; PrimaryDomain = $domain; Wave = $wave }
    }

    while (-not (Test-WaveList -Wave @($sources | ForEach-Object { $_['Wave'] }))) {
        Write-TcMessage -Message 'Waves must start at 1 and have no gaps. Please enter them again.' -Level Warning
        for ($i = 1; $i -le $count; $i++) {
            $sources[$i - 1]['Wave'] = Read-Wave -Prompt "Source $i wave (1 to $count)" -Count $count
        }
    }

    $signIn = Read-TcChoice -Prompt 'Sign-in: 1 = browser, 2 = read-only application with a certificate' `
        -Allowed @('1', '2') -Help 'Please enter 1 or 2.'

    $projectName = "$targetName consolidation"
    $defaultOutput = Join-Path $HOME "TenantConverge/$(ConvertTo-TcSlug -Value $projectName)"
    while ($true) {
        $answer = ([string](Read-TcAnswer -Prompt "Output folder [$defaultOutput]")).Trim()
        $outputPath = if ($answer) { $answer } else { $defaultOutput }
        $service = Get-TcSyncRisk -Path $outputPath
        if (-not $service) { break }
        $prompt = "This folder syncs to $service. Reports contain personal data. Continue? (y/n)"
        if ((Read-TcChoice -Prompt $prompt @yesNo) -in 'y', 'yes') { break }
    }

    $teamAnswer = [string](Read-TcAnswer -Prompt 'Team member names, separated by commas (optional)')
    $team = @($teamAnswer -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })

    $objectArguments = @{
        Name              = $projectName
        TargetDomain      = $targetDomain
        TargetDisplayName = $targetName
        TargetState       = if ($production) { 'Production' } else { 'New' }
        Source            = $sources
        AccessMode        = if ($signIn -eq '2') { 'Application' } else { 'Browser' }
        OutputPath        = $outputPath
        Team              = $team
    }
    $project = ConvertTo-TcProjectObject @objectArguments

    Write-TcMessage -Message "Target: $targetName ($targetDomain)"
    foreach ($source in $project.sources) {
        Write-TcMessage -Message "$($source.role), wave $($source.wave): $($source.displayName) ($($source.primaryDomain))"
    }
    Write-TcMessage -Message "Output folder: $outputPath"

    if ((Read-TcChoice -Prompt 'Save this project? (y/n)' @yesNo) -in 'y', 'yes') { return $project }
}
