BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../src/TenantConverge/TenantConverge.psd1') -Force

    function Invoke-TcMerge {
        param([object[]]$Item, [object[]]$Tracking)
        InModuleScope TenantConverge -Parameters @{ Item = $Item; Tracking = $Tracking } {
            param($Item, $Tracking)
            @(Merge-TcTrackingRow -Item $Item -Tracking $Tracking)
        }
    }

    $script:Tasks = @(
        [ordered]@{ id = 'ID-02.S1'; title = 'Matrix' }
        [ordered]@{ id = 'CUT-01.S1'; title = 'Cutover' }
    )
}

Describe 'Merge-TcTrackingRow' {
    It 'returns every planned item, with its tracking row when there is one' {
        $rows = Invoke-TcMerge -Item $script:Tasks -Tracking @(@{ id = 'ID-02.S1'; status = 'Done'; owner = 'Pat' })
        $rows.Count | Should -Be 2
        ($rows | Where-Object { $_['id'] -eq 'ID-02.S1' })['status'] | Should -Be 'Done'
        ($rows | Where-Object { $_['id'] -eq 'ID-02.S1' })['title'] | Should -Be 'Matrix'
        ($rows | Where-Object { $_['id'] -eq 'CUT-01.S1' })['status'] | Should -BeNullOrEmpty
    }

    It 'keeps a tracking row whose task is gone, and flags it' {
        $rows = Invoke-TcMerge -Item $script:Tasks -Tracking @(@{ id = 'OLD-01.S3'; status = 'In progress'; owner = 'Sam' })
        $rows.Count | Should -Be 3
        $orphan = @($rows | Where-Object { $_['orphan'] })
        $orphan.Count | Should -Be 1
        $orphan[0]['id'] | Should -Be 'OLD-01.S3'
        $orphan[0]['status'] | Should -Be 'In progress'
        $orphan[0]['owner'] | Should -Be 'Sam'
    }

    It 'does not flag a planned item' {
        foreach ($row in (Invoke-TcMerge -Item $script:Tasks -Tracking @(@{ id = 'ID-02.S1'; status = 'Done' }))) { $row['orphan'] | Should -BeFalse }
    }

    It 'lists planned items first, in plan order, then orphans' {
        $rows = Invoke-TcMerge -Item $script:Tasks -Tracking @(@{ id = 'OLD-01'; status = 'x' }, @{ id = 'CUT-01.S1'; status = 'y' })
        @($rows | ForEach-Object { $_['id'] }) -join ',' | Should -Be 'ID-02.S1,CUT-01.S1,OLD-01'
    }

    It 'reads rows from a CSV as well as from a hashtable' {
        $row = [pscustomobject]@{ id = 'ID-02.S1'; status = 'Blocked' }
        ((Invoke-TcMerge -Item $script:Tasks -Tracking @($row)) | Where-Object { $_['id'] -eq 'ID-02.S1' })['status'] | Should -Be 'Blocked'
    }

    It 'handles an empty tracking file' {
        (Invoke-TcMerge -Item $script:Tasks -Tracking @()).Count | Should -Be 2
    }

    It 'lets the last row win when a task appears twice' {
        $rows = Invoke-TcMerge -Item $script:Tasks -Tracking @(@{ id = 'ID-02.S1'; status = 'A' }, @{ id = 'ID-02.S1'; status = 'B' })
        ($rows | Where-Object { $_['id'] -eq 'ID-02.S1' })['status'] | Should -Be 'B'
        $rows.Count | Should -Be 2
    }

    It 'ignores an orphan column of the tracking file, on both sides' {
        $rows = Invoke-TcMerge -Item $script:Tasks -Tracking @([pscustomobject]@{ id = 'ID-02.S1'; orphan = 'True' }, [pscustomobject]@{ id = 'OLD-01'; Orphan = 'False' })
        ($rows | Where-Object { $_['id'] -eq 'ID-02.S1' })['orphan'] | Should -BeFalse
        ($rows | Where-Object { $_['id'] -eq 'OLD-01' })['orphan'] | Should -BeTrue
    }

    It 'does not change the plan' {
        $null = Invoke-TcMerge -Item $script:Tasks -Tracking @(@{ id = 'ID-02.S1'; status = 'Done' })
        $script:Tasks[0].Contains('status') | Should -BeFalse
    }
}
