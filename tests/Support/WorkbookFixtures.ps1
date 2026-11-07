# Fictional projects and snapshots for the workbook tests.

function New-TcWorkbookProject {
    <#
    .SYNOPSIS
    A valid project object with one wave per source.
    #>
    param([int]$SourceCount = 1, [string[]]$Team = @(), [string]$OutputPath = './output')

    $names = @(@('S1', 'Alpine Group', 'alpine.example'), @('S2', 'Birch Partners', 'birch.example'), @('S3', 'Cedar Services', 'cedar.example'))
    [pscustomobject]@{
        schemaVersion = 1
        name          = 'Summit consolidation'
        target        = [pscustomobject]@{ displayName = 'Summit Holdings'; primaryDomain = 'summit.example'; tenantId = $null; state = 'Production' }
        sources       = @(for ($i = 0; $i -lt $SourceCount; $i++) {
                [pscustomobject]@{ role = $names[$i][0]; displayName = $names[$i][1]; primaryDomain = $names[$i][2]; tenantId = $null; wave = $i + 1 }
            })
        access        = [pscustomobject]@{ mode = 'Browser' }
        output        = [pscustomobject]@{ path = $OutputPath }
        team          = $Team
    }
}

function Get-TcSmallPlan {
    <#
    .SYNOPSIS
    A copy of a plan cut down to its first actions and tasks, for a test that is not about size.
    #>
    param([Parameter(Mandatory)]$Plan, [int]$Actions = 12, [int]$Tasks = 6)

    $copy = $Plan | ConvertTo-Json -Depth 30 | ConvertFrom-Json -AsHashtable
    $copy['actions'] = @(@($copy['actions']) | Select-Object -First $Actions)
    $copy['tasks'] = @(@($copy['tasks']) | Select-Object -First $Tasks)
    $kept = @(@($copy['actions']) + @($copy['tasks']) | ForEach-Object { $_['id'] })
    $copy['decisions'] = @(@($copy['decisions']) | Where-Object { $_['reference'] -in $kept })
    $copy['targetConfigurations'] = @(@($copy['targetConfigurations']) | Where-Object { $_['action'] -in $kept })
    $copy
}

function Clear-TcWorkbookTenant {
    <#
    .SYNOPSIS
    Makes a tenant of a snapshot look as if nothing could be collected from it.
    #>
    param([Parameter(Mandatory)]$Snapshot, [Parameter(Mandatory)][string]$Role)

    $Snapshot['tenants'][$Role]['tables'] = [ordered]@{}
    foreach ($line in @($Snapshot['coverage'])) {
        if ($line['role'] -ne $Role) { continue }
        $line['status'] = 'Insufficient access'
        $line['message'] = 'Access denied.'
        $line['remedy'] = 'Give the account a role that can read this.'
        $line['rows'] = 0
        $line['tables'] = @()
    }
}

function Get-TcHostileText {
    <#
    .SYNOPSIS
    Values that a person can type in a tenant and that a spreadsheet may run or change.
    #>
    @(
        '=1+1'
        '=HYPERLINK("http://evil.example/x","click me")'
        "=cmd|' /C calc'!A0"
        '+1+1'
        '-2+3'
        '@SUM(1,1)'
        "`t=1+1"
        ' =1+1'
        "$([char]0xFF1D)1+1"
        'http://evil.example/phish'
        '<img src=x onerror=alert(1)>'
    )
}

function Get-TcFragileText {
    <#
    .SYNOPSIS
    Values that a spreadsheet tends to turn into numbers or dates.
    #>
    @('00123', '+15145550100', '2026-01-15', '1E5', '3/4', '0001234567890123456789', 'TRUE', '12:30', '1,5', '$12')
}

function Add-TcWorkbookUser {
    <#
    .SYNOPSIS
    Adds a member account with this display name to a source of a snapshot.
    #>
    param([Parameter(Mandatory)]$Snapshot, [Parameter(Mandatory)][string]$Role, [Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Upn)

    $Snapshot['tenants'][$Role]['tables']['users'] = @(@($Snapshot['tenants'][$Role]['tables']['users']) + [ordered]@{
            Id = ([guid]::Empty).ToString(); UPN = $Upn; Name = $Name; Type = 'Member'; Enabled = $true; 'Last sign-in' = '2026-01-10 08:00'; 'Days inactive' = 5
            Licenses = 'SPE_E3'; 'License count' = 1; 'First name' = $Name; 'Last name' = $Name
        })
}

function New-TcFakeExcel {
    <#
    .SYNOPSIS
    An object that stands for Excel in a test, so that no Excel starts. It counts its calls.

    .PARAMETER Fail
    What throws a COM error: Open, Work (reading a tab once the file is open), Close or Quit.
    #>
    param([ValidateSet('Open', 'Work', 'Close', 'Quit')][string[]]$Fail = @())

    $sheet = [pscustomobject]@{} | Add-Member -MemberType ScriptMethod -Name Activate -Value { } -PassThru
    $sheets = [pscustomobject]@{ Sheet = $sheet; Fails = 'Work' -in $Fail } | Add-Member -MemberType ScriptMethod -Name Item -Value {
        param($Index)
        if ($this.Fails) { throw [System.Runtime.InteropServices.COMException]::new('The tab could not be read.') }
        $this.Sheet
    } -PassThru

    $workbook = [pscustomobject]@{ Worksheets = $sheets; Closes = 0; Saves = 0; Fails = 'Close' -in $Fail }
    $workbook | Add-Member -MemberType ScriptMethod -Name Save -Value { $this.Saves++ }
    $workbook | Add-Member -MemberType ScriptMethod -Name Close -Value {
        param($Save)
        $this.Closes++
        if ($this.Fails) { throw [System.Runtime.InteropServices.COMException]::new('The file could not be closed.') }
    }

    $books = [pscustomobject]@{ Workbook = $workbook; Fails = 'Open' -in $Fail } | Add-Member -MemberType ScriptMethod -Name Open -Value {
        param($Path)
        if ($this.Fails) { throw [System.Runtime.InteropServices.COMException]::new('The file could not be opened.') }
        $this.Workbook
    } -PassThru

    $excel = [pscustomobject]@{ Hwnd = 42; Visible = $true; DisplayAlerts = $true; ScreenUpdating = $true; EnableEvents = $true; Calculation = 0; Workbooks = $books; Quits = 0; Fails = 'Quit' -in $Fail }
    $excel | Add-Member -MemberType ScriptMethod -Name CalculateFull -Value { }
    $excel | Add-Member -MemberType ScriptMethod -Name Quit -Value {
        $this.Quits++
        if ($this.Fails) { throw [System.Runtime.InteropServices.COMException]::new('Excel did not answer.') }
    }
    $excel
}

function New-TcHostileSnapshot {
    <#
    .SYNOPSIS
    A copy of a fake snapshot whose people, groups and sites carry hostile and fragile names.
    #>
    param([Parameter(Mandatory)]$Snapshot, [string]$Role = 'S1')

    $copy = $Snapshot | ConvertTo-Json -Depth 30 | ConvertFrom-Json -AsHashtable
    $number = 0
    foreach ($text in @(Get-TcHostileText) + @(Get-TcFragileText)) {
        $number++
        Add-TcWorkbookUser -Snapshot $copy -Role $Role -Name $text -Upn "hostile$number@alpine.example"
    }

    # Inactive administrators and names that reach rule items, whose text flows to the action plan.
    $groups = @($copy['tenants'][$Role]['tables']['groups'])
    foreach ($row in $groups) { $row['Name'] = '=HYPERLINK("http://evil.example/group","open")' }
    $sites = @($copy['tenants'][$Role]['tables']['sites'])
    foreach ($row in $sites) { $row['Title'] = '+SUM(1,1)' }
    $copy
}
