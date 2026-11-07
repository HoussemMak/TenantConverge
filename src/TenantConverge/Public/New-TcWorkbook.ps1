function New-TcWorkbook {
    <#
    .SYNOPSIS
    Writes consolidation-workbook.xlsx, the working file of the project, without Excel.

    .DESCRIPTION
    Works from the project and the snapshot alone, with no connection. The tabs are Dashboard, Tenant
    view, Action plan, Detailed steps, Target configurations, Remediations when the plan has some,
    Identity matrix, Decisions and Settings. The yellow columns are for the team to fill in.

    Every value of a tenant is written as text. A name that starts with = does not run, and a phone number
    or an identifier with leading zeros stays as it is.

    Replacing a workbook keeps the old one in the same folder, as consolidation-workbook-previous-<date>.xlsx,
    and the run says so. The yellow columns do not carry over: the new workbook takes only what the tracking
    file holds, so the old file is the only copy of what was typed in them. Do not delete it. They are
    Action plan (Status, Assigned to, Note, Done on); Detailed steps (Status, Done on, Note); Target
    configurations (Applied, Done on, Note); Identity matrix (Validated decision, License, Groups, Validated
    by, Validated on); Decisions (Status, Answer, Decided by, Date).

    .PARAMETER Project
    The project file, or a project as read from it.

    .PARAMETER Snapshot
    The snapshot, as read from snapshot.json.

    .PARAMETER Plan
    The result of New-TcPlan on this snapshot. Without it, the plan is computed.

    .PARAMETER RuleSet
    The result of Invoke-TcRuleSet on this snapshot. Without it, the rules run first.

    .PARAMETER OutputPath
    The workbook file, or the folder to write it in. The default is the output folder of the project.

    .PARAMETER IgnoreNameSuffix
    Words to remove from the end of a display name when looking for duplicates, as for New-TcPlan.

    .PARAMETER TrackingPath
    The tracking file of the team. The default is team-tracking.csv next to the workbook. What it records
    shows in the tabs, and a row that matches nothing in the plan stays visible, as an Orphan row.

    .PARAMETER AddSlicers
    Adds slicers above the tables. They need Excel, which runs hidden in an instance of its own, closed
    when it is done. An Excel you have open is left alone. Without Excel, or when Excel fails while it
    works, the workbook is written without slicers, with a message.

    A call to Excel has no time limit yet. A dialog in the hidden instance, such as an activation or a
    sign-in, stops the run with nothing on the screen. On a computer where Excel may ask something, open
    it once by hand first.

    .EXAMPLE
    $snapshot = Get-Content ./snapshot.json -Raw | ConvertFrom-Json -AsHashtable
    New-TcWorkbook -Project ./project.json -Snapshot $snapshot

    Writes the workbook in the output folder of the project and returns its path.

    .EXAMPLE
    New-TcWorkbook -Project ./project.json -Snapshot $snapshot -OutputPath ./review.xlsx -AddSlicers

    Writes the workbook under another name, with slicers when Excel is on this computer.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][object]$Project,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Snapshot,
        [System.Collections.IDictionary]$Plan,
        [System.Collections.IDictionary]$RuleSet,
        [string]$OutputPath,
        [AllowEmptyCollection()][string[]]$IgnoreNameSuffix = @(),
        [string]$TrackingPath,
        [switch]$AddSlicers
    )

    $projectData = if ($Project -is [string]) { Read-TcProjectFile -Path (Resolve-TcPath -Path $Project) } else { $Project }
    $path = Resolve-TcWorkbookPath -Project $Project -ProjectData $projectData -OutputPath $OutputPath
    if (-not $PSCmdlet.ShouldProcess($path, 'Write the workbook')) { return }

    Import-TcWorkbookModule

    if (-not $RuleSet) { $RuleSet = Invoke-TcRuleSet -Snapshot $Snapshot }
    if (-not $Plan) { $Plan = New-TcPlan -Project $projectData -Snapshot $Snapshot -RuleSet $RuleSet -IgnoreNameSuffix $IgnoreNameSuffix }

    $folder = Split-Path -Path $path -Parent
    [void][System.IO.Directory]::CreateDirectory($folder)
    $temporary = Join-Path $folder ('{0}.tmp.xlsx' -f [guid]::NewGuid())

    try {
        $package = Open-ExcelPackage -Path $temporary -Create
        try {
            $book = @{
                Package = $package; Project = $projectData; Snapshot = $Snapshot; Plan = $Plan; RuleSet = $RuleSet; IgnoreNameSuffix = $IgnoreNameSuffix
                Readiness = @(Get-TcReadiness -Snapshot $Snapshot -RuleSet $RuleSet); Theme = Get-TcWorkbookTheme; Sheets = @{}; Tables = @{}
                Tracking = @(Read-TcWorkbookTracking -Path $(if ($TrackingPath) { Resolve-TcPath -Path $TrackingPath } else { Join-Path $folder 'team-tracking.csv' }))
            }
            Write-TcSettingsSheet -Book $book
            Write-TcActionPlanSheet -Book $book
            Write-TcDetailedStepSheet -Book $book
            Write-TcTargetConfigurationSheet -Book $book
            Write-TcRemediationSheet -Book $book
            Write-TcIdentityMatrixSheet -Book $book
            Write-TcDecisionSheet -Book $book
            Write-TcWorkbookLinkFormula -Book $book
            Write-TcWorkbookTableFormat -Book $book
            Write-TcTenantViewSheet -Book $book
            Write-TcDashboardSheet -Book $book
            foreach ($name in 'Dashboard', 'Tenant view', 'Action plan', 'Detailed steps', 'Target configurations', 'Remediations', 'Identity matrix', 'Decisions', 'Settings') {
                if ($book['Sheets'].ContainsKey($name)) { $package.Workbook.Worksheets.MoveToEnd($name) }
            }

            # One tab selected, or Excel opens them grouped and typing in one writes in all. After a move, the
            # TabSelected property of EPPlus no longer sets anything, so this goes in the XML.
            foreach ($sheet in $package.Workbook.Worksheets) { $sheet.View.TabSelected = $false }
            $package.Workbook.Worksheets['Dashboard'].WorksheetXml.SelectSingleNode('//*[local-name()="sheetView"]').SetAttribute('tabSelected', '1')

            $properties = $package.Workbook.Properties
            $properties.Author = 'TenantConverge'
            $properties.LastModifiedBy = 'TenantConverge'
            $properties.Company = 'TenantConverge'
            $properties.Title = 'Consolidation workbook'
            [OfficeOpenXml.CalculationExtension]::Calculate($package.Workbook)
            $package.Save()
        }
        finally { $package.Dispose() }

        if ($AddSlicers -and (Add-TcWorkbookSlicer -Path $temporary -Book $book)) { Repair-TcWorkbookProperty -Path $temporary }

        Save-TcWorkbookFile -Temporary $temporary -Path $path -YellowColumn (Get-TcWorkbookYellowColumn -Book $book)
    }
    finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
    }
}
