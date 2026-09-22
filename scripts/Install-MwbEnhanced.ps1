[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateSet('install', 'uninstall', 'status', 'start', 'stop', 'restart')]
    [string]$Action = 'install',

    [string]$InstallDirectory = 'C:\AgentWork\mwb-enhanced',
    [string]$TaskName = 'Callosum MWB Guardian',
    [int]$TcpPort = 15101,
    [int]$StartupDelaySeconds = 12
)

$ErrorActionPreference = 'Stop'
$installDirectory = [IO.Path]::GetFullPath($InstallDirectory)
$guardianSource = Join-Path $PSScriptRoot 'MwbGuardian.ps1'
$traySource = Join-Path $PSScriptRoot 'MwbTray.ps1'
$guardianPath = Join-Path $installDirectory 'MwbGuardian.ps1'
$trayPath = Join-Path $installDirectory 'MwbTray.ps1'
$mainPath = Join-Path $installDirectory 'PowerToys.MouseWithoutBorders.exe'
$helperPath = Join-Path $installDirectory 'PowerToys.MouseWithoutBordersHelper.exe'
$settingsPath = Join-Path $env:LOCALAPPDATA 'Microsoft\PowerToys\MouseWithoutBorders\settings.json'
$stateDirectory = Join-Path $env:LOCALAPPDATA 'Callosum'

function Set-InstalledDesiredState([ValidateSet('Running', 'Paused')] [string]$Desired) {
    New-Item -ItemType Directory -Path $stateDirectory -Force | Out-Null
    $path = Join-Path $stateDirectory 'desired-state.json'
    $temporary = "$path.tmp.$PID"
    $value = [ordered]@{
        schemaVersion = 1
        desired = $Desired
        changedAt = [DateTimeOffset]::Now.ToString('o')
        changedBy = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    }
    [IO.File]::WriteAllText($temporary, ($value | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temporary -Destination $path -Force
}

function Get-GuardianArguments([string]$GuardianAction, [switch]$QuotePaths) {
    $formatPath = {
        param([string]$Path)
        if ($QuotePaths) { return '"{0}"' -f $Path }
        return $Path
    }
    @(
        '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
        '-File', (& $formatPath $guardianPath),
        '-Action', $GuardianAction,
        '-MainPath', (& $formatPath $mainPath),
        '-HelperPath', (& $formatPath $helperPath),
        '-TrayPath', (& $formatPath $trayPath),
        '-SettingsPath', (& $formatPath $settingsPath),
        '-StateDirectory', (& $formatPath $stateDirectory),
        '-TcpPort', $TcpPort
    )
}

function Invoke-Guardian([string]$GuardianAction, [bool]$Wait = $true) {
    if (-not (Test-Path -LiteralPath $guardianPath)) {
        throw "Guardian is not installed: $guardianPath"
    }
    $parameters = @{
        FilePath = (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe')
        ArgumentList = (Get-GuardianArguments $GuardianAction -QuotePaths)
        WorkingDirectory = $installDirectory
        WindowStyle = 'Hidden'
    }
    if ($Wait) {
        & $parameters.FilePath @(Get-GuardianArguments $GuardianAction | Where-Object { $_ -notin @('-WindowStyle', 'Hidden') })
    } else {
        Start-Process @parameters | Out-Null
    }
}

function Copy-IfDifferent([string]$Source, [string]$Destination) {
    if (-not (Test-Path -LiteralPath $Source)) { throw "Required script not found: $Source" }
    if ([IO.Path]::GetFullPath($Source).Equals([IO.Path]::GetFullPath($Destination), [StringComparison]::OrdinalIgnoreCase)) { return }
    Copy-Item -LiteralPath $Source -Destination $Destination -Force
}

function Install-Guardian {
    if (-not (Test-Path -LiteralPath $mainPath)) { throw "MWB binary not found: $mainPath" }
    New-Item -ItemType Directory -Path $installDirectory -Force | Out-Null
    Copy-IfDifferent $guardianSource $guardianPath
    Copy-IfDifferent $traySource $trayPath

    $existingTask = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($existingTask -and $existingTask.State -eq 'Running') {
        Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    }
    Stop-GuardianProcess

    $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $arguments = (Get-GuardianArguments 'run' -QuotePaths) -join ' '
    $taskAction = New-ScheduledTaskAction -Execute $powershell -Argument $arguments -WorkingDirectory $installDirectory
    $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $currentUser
    $trigger.Delay = 'PT{0}S' -f [Math]::Max(0, $StartupDelaySeconds)
    $principal = New-ScheduledTaskPrincipal -UserId $currentUser -LogonType Interactive -RunLevel Limited
    $taskSettings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -StartWhenAvailable `
        -MultipleInstances IgnoreNew `
        -RestartCount 999 `
        -RestartInterval (New-TimeSpan -Minutes 1) `
        -ExecutionTimeLimit ([TimeSpan]::Zero)
    Register-ScheduledTask -TaskName $TaskName -Action $taskAction -Trigger $trigger -Principal $principal -Settings $taskSettings -Description 'Keeps the enhanced Mouse Without Borders connection healthy in the signed-in user session.' -Force | Out-Null
    Set-InstalledDesiredState 'Running'
    Start-ScheduledTask -TaskName $TaskName
    Start-Sleep -Seconds 2
    Write-Output "INSTALLED: $TaskName"
    Invoke-Guardian 'status'
}

function Stop-GuardianProcess {
    $guardianName = [IO.Path]::GetFileName($guardianPath)
    Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and $_.CommandLine.IndexOf($guardianName, [StringComparison]::OrdinalIgnoreCase) -ge 0 -and $_.ProcessId -ne $PID } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}

function Show-InstallStatus {
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    [pscustomobject]@{
        TaskName = $TaskName
        Installed = $null -ne $task
        TaskState = if ($task) { [string]$task.State } else { 'Missing' }
        GuardianPath = $guardianPath
        BinaryPresent = Test-Path -LiteralPath $mainPath
    } | Format-List
    if (Test-Path -LiteralPath $guardianPath) { Invoke-Guardian 'status' }
}

switch ($Action) {
    'install' {
        if ($PSCmdlet.ShouldProcess($TaskName, 'Install and start Callosum guardian')) { Install-Guardian }
    }
    'uninstall' {
        if ($PSCmdlet.ShouldProcess($TaskName, 'Remove Callosum guardian autostart')) {
            if (Test-Path -LiteralPath $guardianPath) { Invoke-Guardian 'pause' }
            Stop-GuardianProcess
            Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
            Write-Output "UNINSTALLED: $TaskName (binaries and settings were preserved)"
        }
    }
    'status' { Show-InstallStatus }
    'start' {
        Invoke-Guardian 'resume'
        if (-not (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue | Where-Object State -eq 'Running')) {
            Start-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        }
    }
    'stop' { Invoke-Guardian 'pause' }
    'restart' { Invoke-Guardian 'restart' }
}
