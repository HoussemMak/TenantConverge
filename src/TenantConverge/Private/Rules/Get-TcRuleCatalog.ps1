function Get-TcRuleCatalog {
    <#
    .SYNOPSIS
    Returns the rule catalog by identifier: texts, owner, moment, effort and question.

    .DESCRIPTION
    Read once from Data\rules.json. The texts live in the catalog, so fixing a rule's wording does not
    touch the code. Variants override the title, the finding, the action, the severity or the category
    for one case, for example when the rule fires on the target instead of a source.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param()

    if ($null -eq $script:TcRuleCatalog) {
        $file = Join-Path $PSScriptRoot '..' '..' 'Data' 'rules.json'
        $catalog = [ordered]@{}
        foreach ($rule in @((Read-TcJsonFile -Path $file)['rules'])) { $catalog[$rule['id']] = $rule }
        $script:TcRuleCatalog = $catalog
    }
    $script:TcRuleCatalog
}
