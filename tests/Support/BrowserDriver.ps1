# Drives a headless Edge or Chrome over the DevTools protocol, with no dependency beyond the browser.
# Each run starts its own instance on its own empty profile and closes it by its process ID: a browser the
# user has open is never touched. The DevTools port listens on this computer only.

function Find-TcBrowser {
    <#
    .SYNOPSIS
    Returns the path of an installed Edge or Chrome, or nothing.
    #>
    $folders = @(${env:ProgramFiles(x86)}, $env:ProgramFiles, $env:LOCALAPPDATA) | Where-Object { $_ }
    foreach ($relative in 'Microsoft\Edge\Application\msedge.exe', 'Google\Chrome\Application\chrome.exe') {
        foreach ($folder in $folders) {
            $path = Join-Path $folder $relative
            if (Test-Path -LiteralPath $path) { return $path }
        }
    }
}

function Start-TcBrowser {
    <#
    .SYNOPSIS
    Starts a private headless browser and connects to its page.
    #>
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Folder)

    $profilePath = Join-Path $Folder ('browser-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $profilePath -Force | Out-Null
    $arguments = @('--headless=new', '--disable-gpu', '--no-first-run', '--no-default-browser-check', '--disable-extensions', '--disable-sync', '--disable-background-networking', '--disable-component-update', '--remote-debugging-port=0', "--user-data-dir=`"$profilePath`"", 'about:blank')
    $process = Start-Process -FilePath $Path -ArgumentList $arguments -PassThru -WindowStyle Hidden

    $portFile = Join-Path $profilePath 'DevToolsActivePort'
    $deadline = [datetime]::UtcNow.AddSeconds(30)
    while (-not (Test-Path -LiteralPath $portFile) -or -not (Get-Content -LiteralPath $portFile -ErrorAction SilentlyContinue)) {
        if ([datetime]::UtcNow -gt $deadline) { throw 'The browser did not open its DevTools port.' }
        Start-Sleep -Milliseconds 100
    }
    $port = [int]((Get-Content -LiteralPath $portFile)[0])

    $targets = Invoke-RestMethod -Uri "http://127.0.0.1:$port/json/list"
    $page = @($targets | Where-Object { $_.type -eq 'page' })[0]
    $socket = [System.Net.WebSockets.ClientWebSocket]::new()
    $socket.Options.SetBuffer(1048576, 1048576)
    $null = $socket.ConnectAsync([uri]$page.webSocketDebuggerUrl, [System.Threading.CancellationToken]::None).GetAwaiter().GetResult()

    $browser = [pscustomobject]@{ Process = $process; Socket = $socket; Profile = $profilePath; Port = $port; NextId = 0; Events = [System.Collections.Generic.List[object]]::new() }
    foreach ($domain in 'Page', 'Runtime', 'Log', 'Network') { Invoke-TcBrowser -Browser $browser -Method "$domain.enable" | Out-Null }
    $browser
}

function Open-TcBrowserTab {
    <#
    .SYNOPSIS
    Opens a second real tab in the running browser, on the same profile, driven like the first one.
    #>
    param($Browser, [Parameter(Mandatory)][string]$Path)

    $target = Invoke-RestMethod -Method Put -Uri "http://127.0.0.1:$($Browser.Port)/json/new?about:blank"
    $socket = [System.Net.WebSockets.ClientWebSocket]::new()
    $socket.Options.SetBuffer(1048576, 1048576)
    $null = $socket.ConnectAsync([uri]$target.webSocketDebuggerUrl, [System.Threading.CancellationToken]::None).GetAwaiter().GetResult()
    $tab = [pscustomobject]@{ Socket = $socket; Port = $Browser.Port; TargetId = $target.id; NextId = 0; Events = [System.Collections.Generic.List[object]]::new() }
    foreach ($domain in 'Page', 'Runtime') { Invoke-TcBrowser -Browser $tab -Method "$domain.enable" | Out-Null }
    Open-TcBrowserPage -Browser $tab -Path $Path
    $tab
}

function Close-TcBrowserTab {
    <#
    .SYNOPSIS
    Closes a tab opened by Open-TcBrowserTab, as a person closes it: nothing runs in the page first.
    #>
    param($Tab)

    if (-not $Tab) { return }
    Invoke-RestMethod -Uri "http://127.0.0.1:$($Tab.Port)/json/close/$($Tab.TargetId)" | Out-Null
    $Tab.Socket.Dispose()
}

function Receive-TcBrowserMessage {
    param($Browser, [int]$TimeoutSeconds = 90)

    $source = [System.Threading.CancellationTokenSource]::new([timespan]::FromSeconds($TimeoutSeconds))
    $buffer = [byte[]]::new(1048576)
    $stream = [System.IO.MemoryStream]::new()
    try {
        do {
            $result = $Browser.Socket.ReceiveAsync([ArraySegment[byte]]::new($buffer), $source.Token).GetAwaiter().GetResult()
            $stream.Write($buffer, 0, $result.Count)
        } while (-not $result.EndOfMessage)
        [System.Text.Encoding]::UTF8.GetString($stream.ToArray()) | ConvertFrom-Json -AsHashtable -Depth 40
    }
    finally { $stream.Dispose(); $source.Dispose() }
}

function Invoke-TcBrowser {
    <#
    .SYNOPSIS
    Sends one DevTools command and returns its result. Events that arrive meanwhile are kept.
    #>
    param($Browser, [Parameter(Mandatory)][string]$Method, [hashtable]$Parameters = @{}, [int]$TimeoutSeconds = 90)

    $Browser.NextId++
    $id = $Browser.NextId
    $bytes = [System.Text.Encoding]::UTF8.GetBytes((@{ id = $id; method = $Method; params = $Parameters } | ConvertTo-Json -Depth 20 -Compress))
    $null = $Browser.Socket.SendAsync([ArraySegment[byte]]::new($bytes), [System.Net.WebSockets.WebSocketMessageType]::Text, $true, [System.Threading.CancellationToken]::None).GetAwaiter().GetResult()

    while ($true) {
        $message = Receive-TcBrowserMessage -Browser $Browser -TimeoutSeconds $TimeoutSeconds
        if ($message.ContainsKey('id') -and $message['id'] -eq $id) {
            if ($message.ContainsKey('error')) { throw "$Method failed: $($message['error']['message'])" }
            return $message['result']
        }
        if ($message.ContainsKey('method')) { $Browser.Events.Add($message) }
    }
}

function Wait-TcBrowserEvent {
    <#
    .SYNOPSIS
    Waits for an event that has not been seen yet.
    #>
    param($Browser, [Parameter(Mandatory)][string]$Method, [int]$TimeoutSeconds = 60)

    while ($true) {
        $message = Receive-TcBrowserMessage -Browser $Browser -TimeoutSeconds $TimeoutSeconds
        if ($message.ContainsKey('method')) {
            $Browser.Events.Add($message)
            if ($message['method'] -eq $Method) { return $message }
        }
    }
}

function Open-TcBrowserPage {
    <#
    .SYNOPSIS
    Opens a local file and waits for it to load. Any earlier event is forgotten.
    #>
    param($Browser, [Parameter(Mandatory)][string]$Path)

    $Browser.Events.Clear()
    $address = ([System.Uri]::new((Resolve-Path -LiteralPath $Path).Path)).AbsoluteUri
    Invoke-TcBrowser -Browser $Browser -Method 'Page.navigate' -Parameters @{ url = $address } | Out-Null
    Wait-TcBrowserEvent -Browser $Browser -Method 'Page.loadEventFired' | Out-Null
}

function Invoke-TcPageScript {
    <#
    .SYNOPSIS
    Runs JavaScript in the page and returns its value, waiting for a promise. The code runs in a block, so
    each call has its own constants.
    #>
    param($Browser, [Parameter(Mandatory)][string]$Script)

    $result = Invoke-TcBrowser -Browser $Browser -Method 'Runtime.evaluate' -Parameters @{ expression = "{ $Script`n}"; awaitPromise = $true; returnByValue = $true; userGesture = $true }
    if ($result.ContainsKey('exceptionDetails')) {
        $details = $result['exceptionDetails']
        $text = if ($details.ContainsKey('exception') -and $details['exception'].ContainsKey('description')) { $details['exception']['description'] } else { $details['text'] }
        throw "The page script failed: $text"
    }
    $result['result']['value']
}

function Get-TcPageProblem {
    <#
    .SYNOPSIS
    Returns what went wrong in the page since it opened: exceptions, and errors in the console.
    #>
    param($Browser)

    foreach ($message in $Browser.Events) {
        if ($message['method'] -eq 'Runtime.exceptionThrown') { 'Exception: ' + $message['params']['exceptionDetails']['text'] + ' ' + ($message['params']['exceptionDetails']['exception']['description'] ?? '') }
        if ($message['method'] -eq 'Log.entryAdded' -and $message['params']['entry']['level'] -eq 'error') { 'Console: ' + $message['params']['entry']['text'] }
    }
}

function Get-TcPageRequest {
    <#
    .SYNOPSIS
    Returns every address the page asked for since it opened, apart from data: and blob: addresses.
    #>
    param($Browser)

    foreach ($message in $Browser.Events) {
        if ($message['method'] -eq 'Network.requestWillBeSent') {
            $url = [string]$message['params']['request']['url']
            if ($url -notmatch '^(data|blob):') { $url }
        }
    }
}

function Set-TcBrowserSize {
    <#
    .SYNOPSIS
    Sets the size of the page: a phone when -Phone is given, a desktop otherwise.
    #>
    param($Browser, [switch]$Phone)

    $size = if ($Phone) { @{ width = 390; height = 844; deviceScaleFactor = 2; mobile = $true } } else { @{ width = 1440; height = 900; deviceScaleFactor = 1; mobile = $false } }
    Invoke-TcBrowser -Browser $Browser -Method 'Emulation.setDeviceMetricsOverride' -Parameters $size | Out-Null
}

function Save-TcBrowserScreenshot {
    <#
    .SYNOPSIS
    Saves the visible page as a PNG, for a person to look at.
    #>
    param($Browser, [Parameter(Mandatory)][string]$Path)

    $result = Invoke-TcBrowser -Browser $Browser -Method 'Page.captureScreenshot' -Parameters @{ format = 'png'; captureBeyondViewport = $true }
    [System.IO.File]::WriteAllBytes($Path, [Convert]::FromBase64String($result['data']))
}

function Stop-TcBrowser {
    <#
    .SYNOPSIS
    Closes the browser this run started, and only that one, then removes its profile.
    #>
    param($Browser)

    if (-not $Browser) { return }
    try { Invoke-TcBrowser -Browser $Browser -Method 'Browser.close' -TimeoutSeconds 5 | Out-Null } catch { Write-Verbose 'The browser closed before it answered.' }
    # The process started here can be a launcher that has already left, so the real one is found by its
    # profile. That path is unique to this run: no other browser on the computer carries it.
    [void]$Browser.Process.WaitForExit(5000)
    $mine = @(Get-CimInstance Win32_Process -Filter "Name='msedge.exe' OR Name='chrome.exe'" -ErrorAction SilentlyContinue | Where-Object { [string]$_.CommandLine -and ([string]$_.CommandLine).Contains($Browser.Profile) })
    foreach ($process in $mine) { Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue }
    $Browser.Socket.Dispose()
    Start-Sleep -Milliseconds 300
    Remove-Item -LiteralPath $Browser.Profile -Recurse -Force -ErrorAction SilentlyContinue
}
