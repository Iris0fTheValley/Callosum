[CmdletBinding()]
param(
    [ValidateSet('run', 'once', 'status', 'start', 'restart', 'pause', 'resume', 'stop')]
    [string]$Action = 'run',

    [string]$MainPath = (Join-Path $PSScriptRoot 'PowerToys.MouseWithoutBorders.exe'),
    [string]$HelperPath = (Join-Path $PSScriptRoot 'PowerToys.MouseWithoutBordersHelper.exe'),
    [string]$TrayPath = (Join-Path $PSScriptRoot 'MwbTray.ps1'),
    [string]$SettingsPath = '',
    [string]$StateDirectory = '',
    [int]$TcpPort = 15101,
    [ValidateRange(3, 300)] [int]$CheckIntervalSeconds = 10,
    [ValidateRange(15, 3600)] [int]$DisconnectGraceSeconds = 90,
    [ValidateRange(30, 3600)] [int]$RestartCooldownSeconds = 120
)

$ErrorActionPreference = 'Stop'
$script:mainPath = [IO.Path]::GetFullPath($MainPath)
$script:helperPath = [IO.Path]::GetFullPath($HelperPath)
$script:trayPath = [IO.Path]::GetFullPath($TrayPath)
$script:settingsPath = if ([string]::IsNullOrWhiteSpace($SettingsPath)) {
    Join-Path $env:LOCALAPPDATA 'Microsoft\PowerToys\MouseWithoutBorders\settings.json'
} else {
    [IO.Path]::GetFullPath($SettingsPath)
}
$script:stateDirectory = if ([string]::IsNullOrWhiteSpace($StateDirectory)) {
    Join-Path $env:LOCALAPPDATA 'Callosum'
} else {
    [IO.Path]::GetFullPath($StateDirectory)
}
$script:healthPath = Join-Path $script:stateDirectory 'health.json'
$script:desiredStatePath = Join-Path $script:stateDirectory 'desired-state.json'
$script:logPath = Join-Path $script:stateDirectory 'guardian.log'
$script:mutex = $null
$script:lastRestartAt = [DateTimeOffset]::MinValue
$script:disconnectedSince = $null

function Initialize-StateDirectory {
    New-Item -ItemType Directory -Path $script:stateDirectory -Force | Out-Null
}

function Write-GuardianLog([string]$Message, [string]$Level = 'INFO') {
    Initialize-StateDirectory
    if ((Test-Path -LiteralPath $script:logPath) -and (Get-Item -LiteralPath $script:logPath).Length -gt 1MB) {
        Move-Item -LiteralPath $script:logPath -Destination ($script:logPath + '.1') -Force
    }
    $line = '{0:o} [{1}] {2}' -f [DateTimeOffset]::Now, $Level, $Message
    Add-Content -LiteralPath $script:logPath -Value $line -Encoding utf8
}

function Write-AtomicJson([string]$Path, [object]$Value) {
    Initialize-StateDirectory
    $temporary = "$Path.tmp.$PID"
    [IO.File]::WriteAllText($temporary, ($Value | ConvertTo-Json -Depth 12), [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temporary -Destination $Path -Force
}

function Get-DesiredState {
    if (-not (Test-Path -LiteralPath $script:desiredStatePath)) { return 'Running' }
    try {
        $value = Get-Content -LiteralPath $script:desiredStatePath -Raw | ConvertFrom-Json
        if ($value.desired -eq 'Paused') { return 'Paused' }
    }
    catch {
        Write-GuardianLog "Ignoring invalid desired-state file: $($_.Exception.Message)" 'WARN'
    }
    return 'Running'
}

function Set-DesiredState([ValidateSet('Running', 'Paused')] [string]$Desired) {
    Write-AtomicJson $script:desiredStatePath ([ordered]@{
        schemaVersion = 1
        desired = $Desired
        changedAt = [DateTimeOffset]::Now.ToString('o')
        changedBy = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    })
}

function Get-ExactProcess([string]$Path) {
    $fullPath = [IO.Path]::GetFullPath($Path)
    @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
        $_.ExecutablePath -and [IO.Path]::GetFullPath($_.ExecutablePath).Equals($fullPath, [StringComparison]::OrdinalIgnoreCase)
    })
}

function Stop-ExactProcesses {
    @((Get-ExactProcess $script:helperPath) + (Get-ExactProcess $script:mainPath)) |
        Sort-Object ProcessId -Unique |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}

function Get-SettingsSummary {
    $result = [ordered]@{
        valid = $false
        machine = $env:COMPUTERNAME
        peers = @()
        error = $null
    }
    if (-not (Test-Path -LiteralPath $script:settingsPath)) {
        $result.error = 'SettingsMissing'
        return [pscustomobject]$result
    }
    try {
        $settings = Get-Content -LiteralPath $script:settingsPath -Raw | ConvertFrom-Json
        if ($null -eq $settings.properties) { throw 'properties is missing' }
        $pool = [string]$settings.properties.MachinePool.value
        $keyPresent = -not [string]::IsNullOrWhiteSpace([string]$settings.properties.SecurityKey.value)
        $machines = @($pool -split ',' | ForEach-Object {
            if ($_ -match '^([^:]+):(\d+)$') { $Matches[1] }
        } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
        $result.peers = @($machines | Where-Object { -not $_.Equals($env:COMPUTERNAME, [StringComparison]::OrdinalIgnoreCase) })
        $result.valid = $keyPresent -and $machines.Count -ge 2
        if (-not $result.valid) { $result.error = 'PairingIncomplete' }
    }
    catch {
        $result.error = 'SettingsInvalid: ' + $_.Exception.Message
    }
    return [pscustomobject]$result
}

function Test-TcpEndpoint([string]$ComputerName, [int]$Port, [int]$TimeoutMilliseconds = 750) {
    $client = [Net.Sockets.TcpClient]::new()
    try {
        $task = $client.ConnectAsync($ComputerName, $Port)
        if (-not $task.Wait($TimeoutMilliseconds)) { return $false }
        return $client.Connected
    }
    catch {
        return $false
    }
    finally {
        $client.Dispose()
    }
}

function Test-PeerReachable([string[]]$Peers) {
    foreach ($peer in $Peers) {
        if ((Test-TcpEndpoint $peer $TcpPort) -or (Test-TcpEndpoint $peer ($TcpPort + 1))) {
            return $true
        }
    }
    return $false
}

function Test-TrayRunning {
    if (-not (Test-Path -LiteralPath $script:trayPath)) { return $false }
    $escaped = [regex]::Escape($script:trayPath)
    $pattern = '(?i)(?:-File|-f)\s+"?' + $escaped + '"?(?:\s|$)'
    return $null -ne (Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and $_.CommandLine -match $pattern } |
        Select-Object -First 1)
}

function Start-TrayIfNeeded {
    if (-not (Test-Path -LiteralPath $script:trayPath) -or (Test-TrayRunning)) { return }
    $arguments = @(
        '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-WindowStyle', 'Hidden',
        '-File', ('"{0}"' -f $script:trayPath),
        '-MainPath', ('"{0}"' -f $script:mainPath),
        '-HelperPath', ('"{0}"' -f $script:helperPath),
        '-SettingsPath', ('"{0}"' -f $script:settingsPath),
        '-GuardianPath', ('"{0}"' -f $PSCommandPath),
        '-StateDirectory', ('"{0}"' -f $script:stateDirectory),
        '-TcpPort', $TcpPort
    )
    Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -WorkingDirectory ([IO.Path]::GetDirectoryName($script:mainPath)) -WindowStyle Hidden | Out-Null
    Write-GuardianLog 'Tray started.'
}

function Start-MwbProcesses {
    if (-not (Test-Path -LiteralPath $script:mainPath)) {
        throw "MWB binary not found: $script:mainPath"
    }
    $main = Get-ExactProcess $script:mainPath | Select-Object -First 1
    $startedMain = $false
    if ($null -eq $main) {
        $process = Start-Process -FilePath $script:mainPath -WorkingDirectory ([IO.Path]::GetDirectoryName($script:mainPath)) -PassThru
        Write-GuardianLog "MWB started. PID=$($process.Id)"
        Start-Sleep -Seconds 2
        $startedMain = $true
    }
    # MWB normally launches its helper itself; allow one check interval before intervening.
    if (-not $startedMain -and (Test-Path -LiteralPath $script:helperPath) -and -not (Get-ExactProcess $script:helperPath | Select-Object -First 1)) {
        $helper = Start-Process -FilePath $script:helperPath -WorkingDirectory ([IO.Path]::GetDirectoryName($script:helperPath)) -PassThru
        Write-GuardianLog "MWB helper started. PID=$($helper.Id)"
    }
}

function Restart-MwbProcesses([string]$Reason) {
    Write-GuardianLog "Restarting MWB. Reason=$Reason" 'WARN'
    Stop-ExactProcesses
    Start-Sleep -Seconds 2
    Start-MwbProcesses
    $script:lastRestartAt = [DateTimeOffset]::Now
    $script:disconnectedSince = $null
}

function Get-HealthSnapshot {
    $desired = Get-DesiredState
    $settings = Get-SettingsSummary
    $main = Get-ExactProcess $script:mainPath | Select-Object -First 1
    $helper = Get-ExactProcess $script:helperPath | Select-Object -First 1
    $connections = @()
    $listeners = @()
    if ($main) {
        $connections = @(Get-NetTCPConnection -OwningProcess $main.ProcessId -State Established -ErrorAction SilentlyContinue)
        $listeners = @(Get-NetTCPConnection -OwningProcess $main.ProcessId -State Listen -ErrorAction SilentlyContinue |
            Where-Object { $_.LocalPort -in @($TcpPort, ($TcpPort + 1)) })
    }
    $connected = $connections.Count -gt 0
    $peerReachable = if ($connected) { $true } elseif ($settings.peers.Count -gt 0) { Test-PeerReachable $settings.peers } else { $false }
    $state = if ($desired -eq 'Paused') {
        'Paused'
    } elseif (-not (Test-Path -LiteralPath $script:mainPath)) {
        'MissingBinary'
    } elseif (-not $settings.valid) {
        'InvalidSettings'
    } elseif ($null -eq $main) {
        'Stopped'
    } elseif ($connected) {
        'Connected'
    } elseif ($listeners.Count -eq 0) {
        'NotListening'
    } elseif ($peerReachable) {
        'Connecting'
    } else {
        'WaitingForPeer'
    }
    [pscustomobject][ordered]@{
        schemaVersion = 1
        observedAt = [DateTimeOffset]::Now.ToString('o')
        machine = $env:COMPUTERNAME
        user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
        sessionId = [Diagnostics.Process]::GetCurrentProcess().SessionId
        desired = $desired
        state = $state
        healthy = $state -in @('Connected', 'WaitingForPeer')
        mainPid = if ($main) { [int]$main.ProcessId } else { $null }
        mainSessionId = if ($main) { [int]$main.SessionId } else { $null }
        helperPid = if ($helper) { [int]$helper.ProcessId } else { $null }
        listening = $listeners.Count -gt 0
        connected = $connected
        peerReachable = $peerReachable
        peers = @($settings.peers)
        settingsValid = [bool]$settings.valid
        settingsError = $settings.error
        tcpPorts = @($TcpPort, ($TcpPort + 1))
        guardianPid = $PID
    }
}

function Publish-Health {
    $health = Get-HealthSnapshot
    Write-AtomicJson $script:healthPath $health
    return $health
}

function Invoke-Reconcile([bool]$AllowDisconnectRecovery) {
    $desired = Get-DesiredState
    if ($desired -eq 'Paused') {
        Stop-ExactProcesses
        return Publish-Health
    }
    Start-TrayIfNeeded
    $settings = Get-SettingsSummary
    if (-not $settings.valid) {
        return Publish-Health
    }
    $main = Get-ExactProcess $script:mainPath | Select-Object -First 1
    $currentSessionId = [Diagnostics.Process]::GetCurrentProcess().SessionId
    if ($main -and $main.SessionId -ne $currentSessionId) {
        Restart-MwbProcesses "wrong interactive session $($main.SessionId), expected $currentSessionId"
    } else {
        Start-MwbProcesses
    }
    $health = Publish-Health
    if ($health.connected) {
        $script:disconnectedSince = $null
        return $health
    }
    $needsRecovery = (-not $health.listening) -or $health.peerReachable
    if (-not $AllowDisconnectRecovery -or -not $needsRecovery) {
        $script:disconnectedSince = $null
        return $health
    }
    if ($null -eq $script:disconnectedSince) {
        $script:disconnectedSince = [DateTimeOffset]::Now
        return $health
    }
    $disconnectedFor = ([DateTimeOffset]::Now - $script:disconnectedSince).TotalSeconds
    $sinceRestart = ([DateTimeOffset]::Now - $script:lastRestartAt).TotalSeconds
    if ($disconnectedFor -ge $DisconnectGraceSeconds -and $sinceRestart -ge $RestartCooldownSeconds) {
        $reason = if (-not $health.listening) {
            "local listener unavailable for $([int]$disconnectedFor)s"
        } else {
            "peer reachable but disconnected for $([int]$disconnectedFor)s"
        }
        Restart-MwbProcesses $reason
        return Publish-Health
    }
    return $health
}

function Enter-GuardianMutex {
    $identity = ([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($script:mainPath))).TrimEnd('=').Replace('/', '_').Replace('+', '-')
    if ($identity.Length -gt 80) { $identity = $identity.Substring($identity.Length - 80) }
    $created = $false
    $script:mutex = [Threading.Mutex]::new($true, "Local\Callosum-$identity", [ref]$created)
    return $created
}

function Show-Status {
    $health = if (Test-Path -LiteralPath $script:healthPath) {
        try { Get-Content -LiteralPath $script:healthPath -Raw | ConvertFrom-Json } catch { $null }
    } else { $null }
    if ($null -eq $health -or ([DateTimeOffset]::Now - [DateTimeOffset]::Parse($health.observedAt)).TotalSeconds -gt ($CheckIntervalSeconds * 3)) {
        $health = Get-HealthSnapshot
    }
    $health | ConvertTo-Json -Depth 10
}

Initialize-StateDirectory
try {
    switch ($Action) {
        'status' { Show-Status; exit 0 }
        'pause' {
            Set-DesiredState 'Paused'
            Stop-ExactProcesses
            Publish-Health | ConvertTo-Json -Depth 10
            exit 0
        }
        'stop' {
            Set-DesiredState 'Paused'
            Stop-ExactProcesses
            Publish-Health | ConvertTo-Json -Depth 10
            exit 0
        }
        'resume' {
            Set-DesiredState 'Running'
            Invoke-Reconcile $false | ConvertTo-Json -Depth 10
            exit 0
        }
        'start' {
            Set-DesiredState 'Running'
            Invoke-Reconcile $false | ConvertTo-Json -Depth 10
            exit 0
        }
        'restart' {
            Set-DesiredState 'Running'
            Restart-MwbProcesses 'manual request'
            Publish-Health | ConvertTo-Json -Depth 10
            exit 0
        }
        'once' {
            Invoke-Reconcile $false | ConvertTo-Json -Depth 10
            exit 0
        }
        'run' {
            if (-not (Enter-GuardianMutex)) { exit 0 }
            Write-GuardianLog "Guardian started. PID=$PID Session=$([Diagnostics.Process]::GetCurrentProcess().SessionId)"
            while ($true) {
                try {
                    $null = Invoke-Reconcile $true
                }
                catch {
                    Write-GuardianLog $_.Exception.Message 'ERROR'
                    try {
                        Write-AtomicJson $script:healthPath ([ordered]@{
                            schemaVersion = 1
                            observedAt = [DateTimeOffset]::Now.ToString('o')
                            machine = $env:COMPUTERNAME
                            state = 'Error'
                            healthy = $false
                            error = $_.Exception.Message
                            guardianPid = $PID
                        })
                    }
                    catch { }
                }
                Start-Sleep -Seconds $CheckIntervalSeconds
            }
        }
    }
}
finally {
    if ($script:mutex) {
        try { $script:mutex.ReleaseMutex() } catch { }
        $script:mutex.Dispose()
    }
}
