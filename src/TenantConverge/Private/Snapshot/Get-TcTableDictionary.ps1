function Get-TcTableDictionary {
    <#
    .SYNOPSIS
    Returns the table dictionary by key: label, workload, collectors and columns.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param()

    if ($null -eq $script:TcTableDictionary) {
        $file = Join-Path $PSScriptRoot '..' '..' 'Data' 'tables.json'
        $dictionary = [ordered]@{}
        foreach ($table in @((Read-TcJsonFile -Path $file)['tables'])) { $dictionary[$table['key']] = $table }
        $script:TcTableDictionary = $dictionary
    }
    $script:TcTableDictionary
}
