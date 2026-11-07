function Add-TcWorkbookSlicer {
    <#
    .SYNOPSIS
    Adds slicers to a saved workbook, in an Excel of its own, closed by its process identifier.

    .DESCRIPTION
    Slicers need Excel. With no Excel, this says so and leaves the workbook as it is: the filter buttons
    of the header rows do the same work. An Excel the user already has open is never touched: if the
    instance that comes back is one that was running before, nothing is done and it stays open.

    An error inside Excel does the same: the workbook stays as it was written, without slicers, with a
    message. Excel changes the file only when it saves, and that is its last step.

    The process of the instance says whose it is. When it cannot be read, the instance belongs to this run
    if no Excel was running before, or if a process appeared since: only then is it quit. With no way to
    tell which process is its own, Quit is all there is, and nothing is stopped.

    Excel writes the name of the user and the folder of the file when it saves, so the file goes through
    Repair-TcWorkbookProperty afterwards.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][hashtable]$Book
    )

    $running = @(Get-TcRunningExcel)
    try { $excel = New-TcExcelApplication }
    catch {
        Write-TcMessage -Message 'Excel is not available on this computer, so the workbook has no slicers. It is complete without them: the filter buttons of the header rows do the same work.' -Level Warning
        return $false
    }

    $release = { if ([System.Runtime.InteropServices.Marshal]::IsComObject($excel)) { [void][System.Runtime.InteropServices.Marshal]::FinalReleaseComObject($excel) } }

    # A window that does not exist gives 0 and no error, so 0 means the same as a failure here.
    $processId = 0
    try { $processId = Get-TcExcelProcessId -Excel $excel }
    catch { Write-Verbose "The process of the Excel instance could not be read: $(Get-TcErrorText $_)" }

    if ($processId) { $ours = $processId -notin $running }
    else {
        $appeared = @(Get-TcRunningExcel | Where-Object { $_ -notin $running })
        $ours = $appeared.Count -gt 0 -or -not $running.Count
        if ($appeared.Count -eq 1) { $processId = $appeared[0] }
    }

    if (-not $ours) {
        & $release
        Write-TcMessage -Message 'Excel answered with an instance that was already open, and that one is left alone. The workbook has no slicers: close Excel and run this again to add them.' -Level Warning
        return $false
    }

    # Field, buttons per row, width of a button.
    $slicers = [ordered]@{
        ActionPlan           = @(@('Kind', 2, 58), @('Tenant', 2, 110), @('Moment', 3, 88), @('Severity', 3, 58), @('Blocking', 1, 60), @('Owner', 2, 120), @('Status', 3, 76))
        DetailedSteps        = @(@('Tenant', 2, 110), @('Moment', 3, 88), @('Type', 2, 84), @('Status', 3, 76))
        TargetConfigurations = @(@('Tenant', 2, 110), @('Origin', 2, 92), @('Applied', 2, 60))
        Remediations         = @(@('Workload', 3, 90), @('Nature', 2, 84), @('Risk', 3, 60), @('Test status', 2, 76))
        IdentityMatrix       = @(@('Tenant', 2, 110), @('Type', 3, 66), @('Proposed decision', 3, 76))
        Decisions            = @(@('Tenant', 2, 110), @('Moment', 3, 88), @('Status', 3, 66))
    }

    $workbook = $null
    $added = $false
    try {
        $excel.Visible = $false
        $excel.DisplayAlerts = $false
        $workbook = $excel.Workbooks.Open($Path)
        $excel.ScreenUpdating = $false
        $excel.EnableEvents = $false
        $excel.Calculation = -4135

        foreach ($name in $slicers.Keys) {
            $table = $Book['Tables'][$name]
            if (-not $table -or -not $table['Count']) { continue }
            $sheet = $workbook.Worksheets.Item($table['SheetName'])
            $sheet.Rows.Item('5:8').Hidden = $false
            $list = $sheet.ListObjects.Item($name)
            $top = [double]$sheet.Rows.Item(5).Top + 2
            $left = 4.0
            foreach ($definition in $slicers[$name]) {
                if (-not $table['Columns'].Contains($definition[0])) { continue }
                $width = $definition[1] * $definition[2] + 14
                $cache = $workbook.SlicerCaches.Add2($list, $definition[0])
                $slicer = $cache.Slicers.Add($sheet, [Type]::Missing, ('{0} {1}' -f $name, $definition[0]), $definition[0], $top, $left, $width, 76)
                $slicer.NumberOfColumns = $definition[1]
                $slicer.Style = 'SlicerStyleLight1'
                $slicer.Shape.Placement = 3
                $left += $width + 6
            }
        }

        $excel.Calculation = -4105
        $excel.CalculateFull()
        $workbook.Worksheets.Item(1).Activate()
        $workbook.Save()
        $added = $true
    }
    catch {
        Write-TcMessage -Message "Excel stopped while it added the slicers, so the workbook has no slicers: $(Get-TcErrorText $_) It is complete without them: the filter buttons of the header rows do the same work." -Level Warning
    }
    finally {
        # One step at a time: a step that fails must not skip the next, or a hidden Excel stays behind.
        if ($workbook) {
            try { $workbook.Close($false) }
            catch { Write-Verbose "The workbook could not be closed in Excel: $(Get-TcErrorText $_)" }
        }
        try { $excel.Quit() }
        catch { Write-Verbose "Excel could not be quit: $(Get-TcErrorText $_)" }
        & $release
        [System.GC]::Collect()
        [System.GC]::WaitForPendingFinalizers()
        if ($processId) {
            Wait-Process -Id $processId -Timeout 5 -ErrorAction SilentlyContinue
            $stillThere = Get-Process -Id $processId -ErrorAction SilentlyContinue
            if ($stillThere -and $stillThere.ProcessName -eq 'EXCEL') {
                Stop-Process -Id $processId -ErrorAction SilentlyContinue
                Wait-Process -Id $processId -Timeout 5 -ErrorAction SilentlyContinue
            }
        }
    }
    $added
}
