function Get-TcProcedureCatalog {
    <#
    .SYNOPSIS
    Returns the detailed procedures by identifier.

    .DESCRIPTION
    Read once from Data\procedures.json. A procedure shares its identifier with the rule it answers, or a
    task names it. Each one gives the goal, the prerequisites, the steps, the settings to apply, how to
    verify, the risks and links to Microsoft Learn.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param()

    if ($null -eq $script:TcProcedureCatalog) {
        $file = Join-Path $PSScriptRoot '..' '..' 'Data' 'procedures.json'
        $catalog = [ordered]@{}
        foreach ($procedure in @((Read-TcJsonFile -Path $file)['procedures'])) { $catalog[$procedure['id']] = $procedure }
        $script:TcProcedureCatalog = $catalog
    }
    $script:TcProcedureCatalog
}
