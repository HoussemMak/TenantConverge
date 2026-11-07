<#
    The rules every remediation script keeps, read from its text, and the checks of the manifest.
#>

# Microsoft license part numbers. Compare case-sensitively. The license of a project is a setting.
$script:TcLicenseSkuPattern = '\b(SPE_[A-Z0-9_]+|SPB|ENTERPRISEPACK|ENTERPRISEPREMIUM|STANDARDPACK|DESKLESSPACK|EMS[A-Z0-9_]*|O365_[A-Z0-9_]+|M365_[A-Z0-9_]+|Microsoft_365_[A-Za-z0-9_]+|MCO[A-Z0-9_]+|AAD_[A-Z0-9_]+|ATP_[A-Z0-9_]+|INTUNE_[A-Z0-9_]+|EXCHANGE(STANDARD|ENTERPRISE)|SHAREPOINT(STANDARD|ENTERPRISE))\b'

function Get-TcManifestDefect {
    <# What is wrong with one entry of the manifest. #>
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Entry)
    foreach ($key in 'id', 'title', 'workload', 'ruleIds', 'nature', 'risk', 'reversible', 'permissions', 'testedOnRealTenant', 'testedEvidence', 'service', 'scope', 'roles', 'taskIds', 'removesObjects', 'path') {
        if (-not $Entry.Contains($key)) { "$($Entry['id']): no $key" }
    }
    if ($Entry['nature'] -cnotin 'Decision', 'Partial', 'Report', 'Automated') { "$($Entry['id']): nature $($Entry['nature'])" }
    if ($Entry['risk'] -cnotin 'Low', 'Medium', 'High') { "$($Entry['id']): risk $($Entry['risk'])" }
    if ($Entry['testedOnRealTenant'] -and -not ([string]$Entry['testedEvidence']).Trim()) { "$($Entry['id']): tested on a real tenant with no evidence" }
}

function Get-TcDelegatedPermission {
    <# The Graph permissions a delegated sign-in can request, held as data in this folder. #>
    @(Get-Content -LiteralPath (Join-Path $PSScriptRoot 'GraphDelegatedPermissions.txt') -Encoding utf8 | Where-Object { $_ -and $_ -notmatch '^#' })
}

function Get-TcGraphCaller {
    <# The functions of the module that reach Microsoft Graph, directly or through another one. #>
    param([Parameter(Mandatory)][string]$Folder)
    $calls = @{}
    foreach ($file in Get-ChildItem -LiteralPath $Folder -Recurse -Filter '*.ps1') {
        $tokens = $null; $errors = $null
        $tree = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
        foreach ($function in $tree.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
            $calls[$function.Name] = @($function.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { $_.GetCommandName() } | Where-Object { $_ })
        }
    }
    $found = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    [void]$found.Add('Invoke-TcGraph')
    [void]$found.Add('Add-TcGraphAction')
    # These run the action they are given, and reach Graph only when the action does.
    $engine = 'Invoke-TcRemediationPlan', 'Invoke-TcRemediationAction', 'Invoke-TcUndoOperation', 'Connect-TcRemediationService', 'Get-TcAutomaticUndo'
    do {
        $before = $found.Count
        foreach ($name in @($calls.Keys | Where-Object { $_ -notin $engine })) { if (@($calls[$name] | Where-Object { $found.Contains($_) }).Count) { [void]$found.Add($name) } }
    } while ($found.Count -gt $before)
    @($found)
}

function Get-TcGraphPermissionBreak {
    <# A script that reaches Graph with no Graph permission in the manifest. #>
    param([Parameter(Mandatory)][string]$Text, [Parameter(Mandatory)][System.Collections.IDictionary]$Entry, [Parameter(Mandatory)][string[]]$GraphCaller)
    if (@($Entry['permissions']).Count) { return }
    $tokens = $null; $errors = $null
    $tree = [System.Management.Automation.Language.Parser]::ParseInput($Text, [ref]$tokens, [ref]$errors)
    $reached = @($tree.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true) | Where-Object {
            $name = [string]$_.GetCommandName()
            $name -in $GraphCaller -or ($name -eq 'Add-TcBlockAction' -and $_.Extent.Text -match '-Service\s+''?Graph')
        })
    if ($reached.Count) { "$($Entry['id']): $($reached[0].GetCommandName()), line $($reached[0].Extent.StartLineNumber), with no Graph permission" }
}

function Get-TcScriptRuleBreak {
    <# One line per break of a rule. #>
    param([Parameter(Mandatory)][string]$Text, [string]$Name = 'script', [string[]]$ModuleFunction = @())

    $tokens = $null; $errors = $null
    $tree = [System.Management.Automation.Language.Parser]::ParseInput($Text, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { return "$Name`: PARSE $($errors[0].Message)" }
    $banned = 'Connect-MgGraph', 'Connect-ExchangeOnline', 'Connect-IPPSSession', 'Connect-MicrosoftTeams', 'Connect-PnPOnline', 'Connect-AzAccount', 'Invoke-MgGraphRequest', 'Invoke-RestMethod', 'Invoke-WebRequest',
        'Read-Host', 'Send-MailMessage', 'Start-Process', 'Import-Module', 'Install-Module', 'Resolve-DnsName', 'Invoke-Expression', 'Start-Sleep', 'Set-ExecutionPolicy'
    $commands = @($tree.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true))

    foreach ($command in $commands) {
        if ([string]$command.GetCommandName() -in $banned) { "$Name`: DIRECT $($command.GetCommandName()), line $($command.Extent.StartLineNumber)" }
    }
    foreach ($node in $tree.FindAll({ param($n) $n -is [System.Management.Automation.Language.ExitStatementAst] }, $true)) { "$Name`: EXIT, line $($node.Extent.StartLineNumber)" }

    # A $script: variable is the module's: a script keeps its data in the run.
    foreach ($node in $tree.FindAll({ param($n) $n -is [System.Management.Automation.Language.VariableExpressionAst] -and $n.VariablePath.IsScript }, $true)) {
        if ($node.VariablePath.UserPath -notmatch '^script:Tc') { "$Name`: SCOPE $($node.Extent.Text), line $($node.Extent.StartLineNumber)" }
    }

    # A script does not redefine a function of the module.
    foreach ($node in $tree.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
        if ($node.Name -in $ModuleFunction) { "$Name`: DUPLICATE $($node.Name), line $($node.Extent.StartLineNumber)" }
    }

    # In a method call the comma of -replace 'a', 'b' separates two arguments.
    foreach ($node in $tree.FindAll({ param($n) $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] }, $true)) {
        $arguments = @($node.Arguments)
        if ($arguments.Count -ge 2 -and $arguments[0].Extent.Text -match '-(i|c)?replace\s+\S+\s*$') { "$Name`: COMMA, line $($node.Extent.StartLineNumber)" }
    }

    # An engine variable is not assigned at the level of the script.
    foreach ($node in $tree.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left -is [System.Management.Automation.Language.VariableExpressionAst] }, $true)) {
        if ($node.Left.VariablePath.UserPath -match '^tc[A-Z]') { "$Name`: RESERVED $($node.Left.Extent.Text), line $($node.Extent.StartLineNumber)" }
    }

    # A block runs after the loop that declared it: it reads what its action carries, not a loop variable.
    $topLoops = @($tree.FindAll({ param($n) $n -is [System.Management.Automation.Language.ForEachStatementAst] }, $true) | Where-Object {
            $parent = $_.Parent; $inside = $false
            while ($parent) { if ($parent -is [System.Management.Automation.Language.FunctionDefinitionAst] -or $parent -is [System.Management.Automation.Language.ScriptBlockExpressionAst]) { $inside = $true }; $parent = $parent.Parent }
            -not $inside
        })
    $loopNames = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($loop in $topLoops) { [void]$loopNames.Add($loop.Variable.VariablePath.UserPath) }
    foreach ($command in $commands | Where-Object { [string]$_.GetCommandName() -match '^Add-Tc\w+Action$|^Invoke-TcRemediationPlan$' }) {
        foreach ($element in $command.CommandElements) {
            if ($element -isnot [System.Management.Automation.Language.ScriptBlockExpressionAst]) { continue }
            $own = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
            foreach ($item in $element.FindAll({ param($n) $n -is [System.Management.Automation.Language.ParameterAst] }, $true)) { [void]$own.Add($item.Name.VariablePath.UserPath) }
            foreach ($item in $element.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left -is [System.Management.Automation.Language.VariableExpressionAst] }, $true)) { [void]$own.Add($item.Left.VariablePath.UserPath) }
            foreach ($item in $element.FindAll({ param($n) $n -is [System.Management.Automation.Language.ForEachStatementAst] }, $true)) { [void]$own.Add($item.Variable.VariablePath.UserPath) }
            foreach ($read in $element.FindAll({ param($n) $n -is [System.Management.Automation.Language.VariableExpressionAst] }, $true)) {
                $path = $read.VariablePath.UserPath
                if ($loopNames.Contains($path) -and -not $own.Contains($path)) { "$Name`: LOOP `$$path read in a deferred block, line $($read.Extent.StartLineNumber)" }
            }
        }
    }

    # A record published from a block goes through Invoke-TcDnsRecord, which waits and keeps the undo.
    foreach ($command in $commands | Where-Object { [string]$_.GetCommandName() -eq 'Invoke-TcDnsAction' }) { "$Name`: DNSRECORD hand-built record, line $($command.Extent.StartLineNumber)" }

    # A write goes through the plan: only a function or a block can hold one.
    foreach ($command in $commands) {
        $name = [string]$command.GetCommandName()
        $text = $command.Extent.Text
        $write = ($name -eq 'Invoke-TcGraph' -and $text -match '-Method\s+''?(POST|PATCH|PUT|DELETE)') -or ($name -eq 'Invoke-TcServiceCommand' -and $text -match '-Command\s+''(?!Get-|Test-|Export-)') -or $name -in 'Invoke-TcDnsAction', 'Invoke-TcDnsRecord'
        if (-not $write) { continue }
        $parent = $command.Parent; $deferred = $false
        while ($parent) { if ($parent -is [System.Management.Automation.Language.ScriptBlockExpressionAst] -or $parent -is [System.Management.Automation.Language.FunctionDefinitionAst]) { $deferred = $true; break }; $parent = $parent.Parent }
        if (-not $deferred) { "$Name`: WRITE outside the plan, line $($command.Extent.StartLineNumber)" }
    }

    # No path of one computer, no certificate subject.
    foreach ($token in $tokens) {
        if ($token.Kind -in 'StringLiteral', 'StringExpandable', 'HereStringLiteral', 'HereStringExpandable' -and $token.Text -match '[A-Za-z]:\\\w|\bCN=\w') { "$Name`: PATH, line $($token.Extent.StartLineNumber)" }
    }
}

function Get-TcCommandArgument {
    <# The argument of a named parameter of a command, or nothing. #>
    param([Parameter(Mandatory)]$Command, [Parameter(Mandatory)][string]$Parameter)
    $elements = @($Command.CommandElements)
    for ($index = 1; $index -lt $elements.Count - 1; $index++) {
        if ($elements[$index] -is [System.Management.Automation.Language.CommandParameterAst] -and $elements[$index].ParameterName -eq $Parameter) { return $elements[$index + 1] }
    }
}

function Test-TcReadCommandText {
    <# True when a command name is a read, from the text of the script: a literal Get- or Export-, itself or through what fills the variable. #>
    param([Parameter(Mandatory)]$Expression, [Parameter(Mandatory)]$Tree)
    $literal = '[''"](Get|Export)-'
    if ($Expression.Extent.Text -match $literal -or $Expression.Extent.Text -match '^(Get|Export)-') { return $true }
    if ($Expression -isnot [System.Management.Automation.Language.VariableExpressionAst]) { return $false }
    $name = $Expression.VariablePath.UserPath

    # Filled by an assignment in the script.
    $assigned = @($Tree.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and $n.Left.VariablePath.UserPath -eq $name }, $true))
    if ($assigned.Count) { return -not @($assigned | Where-Object { $_.Right.Extent.Text -notmatch $literal }).Count }

    # A parameter of a local function: every call gives a literal, first by position or by name.
    $parent = $Expression.Parent
    while ($parent -and $parent -isnot [System.Management.Automation.Language.FunctionDefinitionAst]) { $parent = $parent.Parent }
    if (-not $parent) { return $false }
    $function = $parent.Name
    $calls = @($Tree.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq $function }, $true))
    if (-not $calls.Count) { return $false }
    -not @($calls | Where-Object {
            $given = Get-TcCommandArgument -Command $_ -Parameter $name
            if (-not $given -and @($_.CommandElements).Count -gt 1) { $given = @($_.CommandElements)[1] }
            -not $given -or $given.Extent.Text -notmatch $literal
        }).Count
}

function Get-TcEnclosingAction {
    <# The Add-Tc*Action or Invoke-TcRemediationPlan whose scriptblock holds a node, and that scriptblock. #>
    param([Parameter(Mandatory)]$Node)
    $block = $null
    $parent = $Node.Parent
    while ($parent) {
        if ($parent -is [System.Management.Automation.Language.ScriptBlockExpressionAst]) { $block = $parent }
        if ($parent -is [System.Management.Automation.Language.CommandAst] -and $block -and [string]$parent.GetCommandName() -match '^Add-Tc\w+Action$|^Invoke-TcRemediationPlan$') { return @{ Command = $parent; Block = $block } }
        $parent = $parent.Parent
    }
}

function Get-TcDeclaredBreak {
    <# Why a write inside an action goes to a tenant the action did not declare, or nothing. #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Tenant, [AllowNull()]$Holder)
    if (-not $Holder) { return 'outside an action' }
    $name = [string]$Holder['Command'].GetCommandName()
    if ($name -eq 'Invoke-TcRemediationPlan') { return 'in a check, which only reads' }
    $own = Get-TcCommandArgument -Command $Holder['Command'] -Parameter 'Tenant'
    $first = @($Holder['Block'].ScriptBlock.ParamBlock.Parameters | Select-Object -First 1)
    $variable = if ($first.Count) { $first[0].Name.VariablePath.UserPath } else { 'a' }
    if ($Tenant -ieq "`$$variable.tenant") { return }
    if ($Tenant -imatch "^\`$$variable\.alsoWrites\[\d+\]$" -and (Get-TcCommandArgument -Command $Holder['Command'] -Parameter 'AlsoWrites')) { return }
    if ($Tenant -match "^'\w+'$" -and $own -and $own.Extent.Text -eq $Tenant) { return }
    "to $(if ($Tenant) { $Tenant } else { 'no tenant' }), not declared by the action on $(if ($own) { $own.Extent.Text })"
}

function Get-TcScriptTenantBreak {
    <#
        Every write of a script that goes to a tenant its action did not declare, from the syntax tree.
        A block reaches its own tenant through $a.tenant, and a second one through $a.alsoWrites, which
        -AlsoWrites fills: nothing else can name a tenant whose domain was typed.
    #>
    param([Parameter(Mandatory)][string]$Text, [string]$Name = 'script')

    $tokens = $null; $errors = $null
    $tree = [System.Management.Automation.Language.Parser]::ParseInput($Text, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { return "$Name`: PARSE $($errors[0].Message)" }
    $writers = 'Invoke-TcGraph', 'Invoke-TcServiceCommand', 'Set-TcCloudflareRecord', 'Set-TcCloudflareTtl', 'Invoke-TcDnsAction', 'Invoke-TcDnsRecord', 'Assert-TcExclusionKept'
    $commands = @($tree.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true))

    $writing = [System.Collections.Generic.List[object]]::new()
    foreach ($command in $commands | Where-Object { [string]$_.GetCommandName() -in $writers }) {
        $tool = [string]$command.GetCommandName()
        if ($tool -eq 'Invoke-TcGraph') {
            $method = Get-TcCommandArgument -Command $command -Parameter 'Method'
            if (-not $method -or $method.Extent.Text -match '^''?GET''?$') { continue }
        }
        if ($tool -eq 'Invoke-TcServiceCommand' -and (Test-TcReadCommandText -Expression (Get-TcCommandArgument -Command $command -Parameter 'Command') -Tree $tree)) { continue }
        $tenant = if ($tool -in 'Invoke-TcDnsAction', 'Invoke-TcDnsRecord') {
            $record = Get-TcCommandArgument -Command $command -Parameter 'Action'
            if (-not $record) { $record = @($command.CommandElements)[1] }
            if ($record -is [System.Management.Automation.Language.HashtableAst]) { @($record.KeyValuePairs | Where-Object { $_.Item1.Extent.Text -eq 'tenant' } | ForEach-Object { $_.Item2.Extent.Text }) -join '' }
            else { "$($record.Extent.Text).tenant" }
        }
        else { [string](Get-TcCommandArgument -Command $command -Parameter 'Tenant').Extent.Text }
        $writing.Add(@{ Command = $command; Tenant = $tenant })
    }

    foreach ($write in $writing) {
        $holder = Get-TcEnclosingAction -Node $write['Command']
        $inFunction = $false
        $parent = $write['Command'].Parent
        while ($parent -and -not $holder) { if ($parent -is [System.Management.Automation.Language.FunctionDefinitionAst]) { $inFunction = $parent.Name; break }; $parent = $parent.Parent }
        if (-not $inFunction) {
            $break = Get-TcDeclaredBreak -Tenant $write['Tenant'] -Holder $holder
            if ($break) { "$Name`: TENANT write $break, line $($write['Command'].Extent.StartLineNumber)" }
            continue
        }

        # A local function writes for whoever calls it: each call is held to the same rule.
        $calls = @($commands | Where-Object { $_.GetCommandName() -eq $inFunction })
        if (-not $calls.Count) { "$Name`: TENANT write in $inFunction, which nothing calls, line $($write['Command'].Extent.StartLineNumber)" }
        foreach ($call in $calls) {
            $break = Get-TcDeclaredBreak -Tenant $write['Tenant'] -Holder (Get-TcEnclosingAction -Node $call)
            if ($break) { "$Name`: TENANT write through $inFunction $break, line $($call.Extent.StartLineNumber)" }
        }
    }
}

function Get-TcScriptHeaderBreak {
    <#
        What the header of a script says that its code does not do, in the forms this fault has taken:
        a decisions file it reads and does not name, a promise to act without a decision, a secret folder
        that is not the one of the engine, and a limit of an application sign-in in a script that signs a person in.
    #>
    param([Parameter(Mandatory)][string]$Text, [string]$Name = 'script')

    $tokens = $null; $errors = $null
    $tree = [System.Management.Automation.Language.Parser]::ParseInput($Text, [ref]$tokens, [ref]$errors)
    $help = (@($tokens | Where-Object { $_.Kind -eq 'Comment' -and $_.Text -like '<#*' } | Select-Object -First 1) | ForEach-Object Text) -join ''

    foreach ($command in $tree.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -in 'Get-TcDecision', 'Get-TcUndecidedRow' }, $true)) {
        $file = Get-TcCommandArgument -Command $command -Parameter 'Name'
        if ($file -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $help -notmatch [regex]::Escape("$($file.Value).csv")) { "$Name`: HEADER does not name $($file.Value).csv" }
    }
    foreach ($phrase in 'without waiting for a decision', 'is created in report-only in each tenant') {
        if ($help -match $phrase) { "$Name`: HEADER promises an action with no decision: $phrase" }
    }
    if ($Text -match 'Join-Path[^\r\n]*''SecretItems''') { "$Name`: HEADER the secrets go in secrets, not SecretItems" }
    foreach ($phrase in 'in application mode, Graph', 'not allow it in application mode') {
        if ($Text -match $phrase) { "$Name`: HEADER a person signs in, there is no application mode: $phrase" }
    }
}

function Get-TcScriptFrenchBreak {
    <# French left in the text of a script: a string, a here-string or a comment. Names, values and placeholders count too. #>
    param([Parameter(Mandatory)][string]$Text, [string]$Name = 'script')

    $french = '(?i)\b(le|la|les|des|du|une|dans|avec|sans|sur|est|sont|aux|cette|qui|que|compte|boite|cible|poste|lecture|fichier|lancer|aucune?|introuvable|mettre|groupes?|entrant|sortant|donnees|utilisateurs?|domaines?|licences?|valeurs?|erreurs?)\b'
    if ($Text -cmatch '[^\x00-\x7F]') { "$Name`: not ASCII" }
    $tokens = $null; $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseInput($Text, [ref]$tokens, [ref]$errors)
    foreach ($token in $tokens) {
        if ($token.Kind -in 'StringLiteral', 'StringExpandable', 'HereStringLiteral', 'HereStringExpandable', 'Comment' -and $token.Text -cmatch $french) { "$Name`: $($token.Text)" }
    }
}

function Get-TcScriptCommandBreak {
    <# Commands that resolve to nothing, and named parameters their command does not have. #>
    param([Parameter(Mandatory)][string]$Text, [string]$Name = 'script')

    $tokens = $null; $errors = $null
    $tree = [System.Management.Automation.Language.Parser]::ParseInput($Text, [ref]$tokens, [ref]$errors)
    $local = @{}
    foreach ($node in $tree.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
        $parameters = @($node.Parameters) + @(if ($node.Body.ParamBlock) { $node.Body.ParamBlock.Parameters })
        $local[$node.Name] = @($parameters | Where-Object { $_ } | ForEach-Object { $_.Name.VariablePath.UserPath })
    }
    $module = Get-Module TenantConverge
    foreach ($command in $tree.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)) {
        $commandName = $command.GetCommandName()
        if (-not $commandName) { continue }
        if ($local.ContainsKey($commandName)) { $known = @($local[$commandName]) }
        else {
            $info = & $module { param($Lookup) Microsoft.PowerShell.Core\Get-Command -Name $Lookup -ErrorAction SilentlyContinue } $commandName
            if (-not $info) { "$Name`: UNKNOWN $commandName"; continue }
            $known = @($info.Parameters.Keys) + @($info.Parameters.Values | ForEach-Object Aliases)
        }
        foreach ($element in $command.CommandElements) {
            if ($element -is [System.Management.Automation.Language.CommandParameterAst] -and -not @($known | Where-Object { $_ -like "$($element.ParameterName)*" }).Count) { "$Name`: PARAMETER $commandName -$($element.ParameterName)" }
        }
    }
}
