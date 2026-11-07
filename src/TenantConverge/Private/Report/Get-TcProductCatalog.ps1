function Get-TcProductCatalog {
    <#
    .SYNOPSIS
    Returns the public product facts of Data\products.json, read once.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param()

    if (-not $script:TcProductCatalog) {
        $script:TcProductCatalog = Read-TcJsonFile -Path (Join-Path $PSScriptRoot '..' '..' 'Data' 'products.json')
    }
    $script:TcProductCatalog
}
