function Test-TcServiceModule {
    <#
    .SYNOPSIS
    Checks that the modules of a service are installed at the minimum version. Azure needs two.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Service
    )

    $info = Get-TcServiceInfo $Service
    if (-not $info['Module']) { return @{ ok = $true } }
    if ($script:TcVerifiedServices.ContainsKey($Service)) { return $script:TcVerifiedServices[$Service] }

    $required = @(Get-TcRequiredModule | Where-Object {
            @($_['Services']) -contains $Service -and ($_['Name'] -ne 'Microsoft.Graph.Authentication' -or $Service -eq 'Graph')
        })
    if ($required.Count -eq 0) {
        $required = @(@{ Name = $info['Module']; Minimum = '0.0'; WindowsPowerShell = ($Service -eq 'PowerPlatform') })
    }

    $missing = @($required | Where-Object {
            $version = Get-TcModuleVersion -Name $_['Name'] -WindowsPowerShell:([bool](Get-TcProperty $_ 'WindowsPowerShell' $false))
            -not $version -or $version -lt [version]$_['Minimum']
        })

    $result = if ($missing.Count -eq 0) {
        @{ ok = $true }
    }
    else {
        @{
            ok      = $false
            status  = 'Module missing'
            message = 'Module {0} not found or too old.' -f (($missing | ForEach-Object { '{0} {1}+' -f $_['Name'], $_['Minimum'] }) -join ', ')
            remedy  = "Run Test-TcPrerequisite -Install, or: $($info['Install'])"
        }
    }
    $script:TcVerifiedServices[$Service] = $result
    $result
}
