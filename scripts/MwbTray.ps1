[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$MainPath,

    [Parameter(Mandatory)]
    [string]$HelperPath,

    [string]$SettingsPath = '',

    [string]$GuardianPath = '',

    [string]$StateDirectory = '',

    [int]$TcpPort = 15101
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$script:mainPath = [IO.Path]::GetFullPath($MainPath)
$script:helperPath = [IO.Path]::GetFullPath($HelperPath)
$script:settingsPath = if ([string]::IsNullOrWhiteSpace($SettingsPath)) {
    Join-Path $env:LOCALAPPDATA 'Microsoft\PowerToys\MouseWithoutBorders\settings.json'
} else {
    [IO.Path]::GetFullPath($SettingsPath)
}
$script:guardianPath = if ([string]::IsNullOrWhiteSpace($GuardianPath)) {
    Join-Path $PSScriptRoot 'MwbGuardian.ps1'
} else {
    [IO.Path]::GetFullPath($GuardianPath)
}
$script:stateDirectory = if ([string]::IsNullOrWhiteSpace($StateDirectory)) {
    Join-Path $env:LOCALAPPDATA 'Callosum'
} else {
    [IO.Path]::GetFullPath($StateDirectory)
}
$script:healthPath = Join-Path $script:stateDirectory 'health.json'
$script:busy = $false
$script:currentState = ''
$script:mutex = $null
$created = $false

try {
    $mutexName = 'Local\MwbEnhancedTray-' + ([IO.Path]::GetFileNameWithoutExtension($script:mainPath))
    $script:mutex = New-Object Threading.Mutex($false, $mutexName, [ref]$created)
    if (-not $created) {
        exit 0
    }

    $script:notifyIcon = New-Object Windows.Forms.NotifyIcon
    $script:notifyIcon.Visible = $true
    $script:notifyIcon.Icon = [Drawing.SystemIcons]::Application

    $script:statusItem = New-Object Windows.Forms.ToolStripMenuItem
    $script:statusItem.Enabled = $false

    $script:layoutItem = New-Object Windows.Forms.ToolStripMenuItem('屏幕布局 / Screen layout...')
    $script:restartItem = New-Object Windows.Forms.ToolStripMenuItem('重新连接 / Restart')
    $script:stopItem = New-Object Windows.Forms.ToolStripMenuItem('暂停连接 / Pause')
    $script:exitItem = New-Object Windows.Forms.ToolStripMenuItem('退出状态栏 / Exit tray')

    $menu = New-Object Windows.Forms.ContextMenuStrip
    [void]$menu.Items.Add($script:statusItem)
    [void]$menu.Items.Add((New-Object Windows.Forms.ToolStripSeparator))
    [void]$menu.Items.Add($script:layoutItem)
    [void]$menu.Items.Add($script:restartItem)
    [void]$menu.Items.Add($script:stopItem)
    [void]$menu.Items.Add((New-Object Windows.Forms.ToolStripSeparator))
    [void]$menu.Items.Add($script:exitItem)
    $script:notifyIcon.ContextMenuStrip = $menu

    function Get-MwbProcesses {
        $paths = @($script:mainPath, $script:helperPath)
        @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
            Where-Object { $_.ExecutablePath -and $paths -contains ([IO.Path]::GetFullPath($_.ExecutablePath)) })
    }

    function Get-MwbState {
        if (Test-Path -LiteralPath $script:healthPath) {
            try {
                $health = Get-Content -LiteralPath $script:healthPath -Raw | ConvertFrom-Json
                $age = ([DateTimeOffset]::Now - [DateTimeOffset]::Parse([string]$health.observedAt)).TotalSeconds
                if ($age -le 45) {
                    switch ([string]$health.state) {
                        'Connected' { return '已连接 / Connected' }
                        'WaitingForPeer' { return '等待对端 / Peer offline' }
                        'Connecting' { return '正在连接 / Connecting' }
                        'NotListening' { return '本机监听异常 / Listener down' }
                        'Paused' { return '已暂停 / Paused' }
                        'InvalidSettings' { return '配对配置无效 / Invalid settings' }
                        'MissingBinary' { return '程序缺失 / Binary missing' }
                        'Stopped' { return '正在恢复 / Recovering' }
                        'Error' { return '守护异常 / Guardian error' }
                    }
                }
            }
            catch { }
        }
        $processes = Get-MwbProcesses
        $main = $processes | Where-Object { [IO.Path]::GetFullPath($_.ExecutablePath) -eq $script:mainPath } | Select-Object -First 1
        $helper = $processes | Where-Object { [IO.Path]::GetFullPath($_.ExecutablePath) -eq $script:helperPath } | Select-Object -First 1

        if (-not $main) { return '已停止 / Stopped' }
        if (-not $helper) { return '运行中，助手缺失 / Helper missing' }

        $connected = $false
        try {
            $connected = @(Get-NetTCPConnection -OwningProcess $main.ProcessId -State Established -ErrorAction SilentlyContinue).Count -gt 0
        }
        catch {
            $connected = $false
        }

        if ($connected) { return '已连接 / Connected' }
        return "运行中，未连接 / Disconnected ($TcpPort/$($TcpPort + 1))"
    }

    function Update-MwbState {
        $state = Get-MwbState
        if ($state -eq $script:currentState) { return }
        $script:currentState = $state
        $script:statusItem.Text = "状态 / Status: $state"
        $script:notifyIcon.Text = "MWB: $state"
        $script:stopItem.Text = if ($state -eq '已暂停 / Paused') { '恢复连接 / Resume' } else { '暂停连接 / Pause' }
        if ($state -eq '已连接 / Connected') {
            $script:notifyIcon.Icon = [Drawing.SystemIcons]::Information
        }
        elseif ($state -like '*Stopped*' -or $state -like '*missing*' -or $state -like '*无效*' -or $state -like '*异常*') {
            $script:notifyIcon.Icon = [Drawing.SystemIcons]::Error
        }
        else {
            $script:notifyIcon.Icon = [Drawing.SystemIcons]::Warning
        }
    }

    function Get-MwbSettings {
        if (-not (Test-Path -LiteralPath $script:settingsPath)) {
            throw "MWB settings not found: $script:settingsPath"
        }
        $settings = Get-Content -LiteralPath $script:settingsPath -Raw | ConvertFrom-Json
        if (-not $settings.properties) {
            throw 'MWB settings have no properties object.'
        }
        return $settings
    }

    function Get-MachineNames([object]$Settings) {
        $pool = [string]$Settings.properties.MachinePool.value
        $names = @($pool -split ',' | ForEach-Object {
            if ($_ -match '^([^:]+):\d+$') { $Matches[1] }
        } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        if ($names.Count -lt 2) {
            throw 'At least two machines must be paired before screen layout can be configured.'
        }
        return @($names | Select-Object -Unique)
    }

    function Get-MatrixValues([object]$Settings) {
        $values = @($Settings.properties.MachineMatrixString)
        while ($values.Count -lt 4) { $values += '' }
        return @($values[0..3] | ForEach-Object { [string]$_ })
    }

    function Save-MwbSettings([object]$Settings) {
        $temporary = "$script:settingsPath.mwb-tray.tmp"
        $backup = "$script:settingsPath.mwb-tray.bak"
        Copy-Item -LiteralPath $script:settingsPath -Destination $backup -Force
        [IO.File]::WriteAllText($temporary, ($Settings | ConvertTo-Json -Depth 30), [Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $temporary -Destination $script:settingsPath -Force
    }

    function Show-MatrixDialog {
        $settings = Get-MwbSettings
        $machineNames = Get-MachineNames $settings
        $current = Get-MatrixValues $settings
        $oneRow = [bool]$settings.properties.MatrixOneRow.value

        $form = New-Object Windows.Forms.Form
        $form.Text = 'Mouse Without Borders - Screen layout'
        $form.StartPosition = 'CenterScreen'
        $form.FormBorderStyle = 'FixedDialog'
        $form.MaximizeBox = $false
        $form.MinimizeBox = $false
        $form.ClientSize = New-Object Drawing.Size(520, 300)

        $hint = New-Object Windows.Forms.Label
        $hint.Text = 'Configure the four MWB positions. In one-row mode they are ordered left to right.'
        $hint.AutoSize = $true
        $hint.Location = New-Object Drawing.Point(16, 16)
        $form.Controls.Add($hint)

        $oneRowBox = New-Object Windows.Forms.CheckBox
        $oneRowBox.Text = 'One row (left to right)'
        $oneRowBox.AutoSize = $true
        $oneRowBox.Checked = $oneRow
        $oneRowBox.Location = New-Object Drawing.Point(16, 45)
        $form.Controls.Add($oneRowBox)

        $layout = New-Object Windows.Forms.TableLayoutPanel
        $layout.ColumnCount = 2
        $layout.RowCount = 4
        $layout.Location = New-Object Drawing.Point(16, 78)
        $layout.Size = New-Object Drawing.Size(488, 130)
        $layout.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Absolute, 180)))
        $layout.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Percent, 100)))
        $labels = @('Position 1 (top-left / first)', 'Position 2 (top-right / second)', 'Position 3 (bottom-left / third)', 'Position 4 (bottom-right / fourth)')
        $boxes = @()
        for ($i = 0; $i -lt 4; $i++) {
            $label = New-Object Windows.Forms.Label
            $label.Text = $labels[$i]
            $label.AutoSize = $true
            $label.Anchor = 'Left'
            $layout.Controls.Add($label, 0, $i)

            $box = New-Object Windows.Forms.ComboBox
            $box.DropDownStyle = 'DropDownList'
            $box.Width = 270
            [void]$box.Items.Add('(empty)')
            foreach ($name in $machineNames) { [void]$box.Items.Add($name) }
            $selected = $box.Items.IndexOf($current[$i])
            $box.SelectedIndex = if ($selected -ge 0) { $selected } else { 0 }
            $boxes += $box
            $layout.Controls.Add($box, 1, $i)
        }
        $form.Controls.Add($layout)

        $ok = New-Object Windows.Forms.Button
        $ok.Text = 'Save'
        $ok.DialogResult = [Windows.Forms.DialogResult]::None
        $ok.Location = New-Object Drawing.Point(326, 238)
        $ok.add_Click({
            $chosen = @($boxes | ForEach-Object { if ($_.SelectedIndex -le 0) { '' } else { [string]$_.SelectedItem } })
            $duplicates = @($chosen | Where-Object { $_ } | Group-Object | Where-Object Count -gt 1)
            if ($duplicates.Count -gt 0) {
                [Windows.Forms.MessageBox]::Show('Each machine can appear only once in the matrix.', 'MWB', [Windows.Forms.MessageBoxButtons]::OK, [Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
                return
            }
            $settings.properties.MachineMatrixString = $chosen
            $settings.properties.MatrixOneRow.value = [bool]$oneRowBox.Checked
            $form.Tag = $settings
            $form.DialogResult = [Windows.Forms.DialogResult]::OK
        })
        $form.Controls.Add($ok)

        $cancel = New-Object Windows.Forms.Button
        $cancel.Text = 'Cancel'
        $cancel.DialogResult = [Windows.Forms.DialogResult]::Cancel
        $cancel.Location = New-Object Drawing.Point(414, 238)
        $form.Controls.Add($cancel)
        $form.AcceptButton = $ok
        $form.CancelButton = $cancel

        try {
            if ($form.ShowDialog() -eq [Windows.Forms.DialogResult]::OK) {
                return $form.Tag
            }
            return $null
        }
        finally {
            $form.Dispose()
        }
    }

    function Stop-Mwb {
        if (Test-Path -LiteralPath $script:guardianPath) {
            & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $script:guardianPath -Action pause -MainPath $script:mainPath -HelperPath $script:helperPath -TrayPath $script:trayPath -SettingsPath $script:settingsPath -StateDirectory $script:stateDirectory -TcpPort $TcpPort | Out-Null
            return
        }
        @(Get-MwbProcesses) | ForEach-Object {
            Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
        }
    }

    function Start-Mwb {
        if (-not (Test-Path -LiteralPath $script:mainPath)) {
            throw "MWB binary not found: $script:mainPath"
        }

        if (Test-Path -LiteralPath $script:guardianPath) {
            & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $script:guardianPath -Action restart -MainPath $script:mainPath -HelperPath $script:helperPath -TrayPath $script:trayPath -SettingsPath $script:settingsPath -StateDirectory $script:stateDirectory -TcpPort $TcpPort | Out-Null
            return
        }

        Stop-Mwb
        $process = Start-Process -FilePath $script:mainPath -WorkingDirectory ([IO.Path]::GetDirectoryName($script:mainPath)) -PassThru
        Start-Sleep -Seconds 2
        if (-not (Get-MwbProcesses | Where-Object { $_.ProcessId -eq $process.Id })) {
            throw "MWB failed to start: PID=$($process.Id)"
        }

        Start-Sleep -Seconds 2
        if ((Test-Path -LiteralPath $script:helperPath) -and -not (Get-MwbProcesses | Where-Object { [IO.Path]::GetFullPath($_.ExecutablePath) -eq $script:helperPath })) {
            Start-Process -FilePath $script:helperPath -WorkingDirectory ([IO.Path]::GetDirectoryName($script:helperPath)) | Out-Null
        }
    }

    function Configure-MwbLayout {
        $updated = Show-MatrixDialog
        if ($null -eq $updated) { return }
        Stop-Mwb
        Save-MwbSettings $updated
        Start-Mwb
    }

    function Invoke-MwbAction([scriptblock]$action) {
        if ($script:busy) { return }
        $script:busy = $true
        $script:restartItem.Enabled = $false
        $script:stopItem.Enabled = $false
        try {
            & $action
        }
        catch {
            [Windows.Forms.MessageBox]::Show($_.Exception.Message, 'MWB', [Windows.Forms.MessageBoxButtons]::OK, [Windows.Forms.MessageBoxIcon]::Error) | Out-Null
        }
        finally {
            $script:busy = $false
            $script:restartItem.Enabled = $true
            $script:stopItem.Enabled = $true
            Update-MwbState
        }
    }

    $script:layoutItem.add_Click({ Invoke-MwbAction { Configure-MwbLayout } })
    $script:restartItem.add_Click({ Invoke-MwbAction { Start-Mwb } })
    $script:stopItem.add_Click({ Invoke-MwbAction { if ($script:currentState -eq '已暂停 / Paused') { Start-Mwb } else { Stop-Mwb } } })
    $script:notifyIcon.add_DoubleClick({ Invoke-MwbAction { Start-Mwb } })
    $script:exitItem.add_Click({
        $script:notifyIcon.Visible = $false
        $script:notifyIcon.Dispose()
        [Windows.Forms.Application]::ExitThread()
    })

    $timer = New-Object Windows.Forms.Timer
    $timer.Interval = 3000
    $timer.add_Tick({ Update-MwbState })
    $timer.Start()
    Update-MwbState
    [Windows.Forms.Application]::Run()
}
finally {
    if ($script:notifyIcon) {
        $script:notifyIcon.Visible = $false
        $script:notifyIcon.Dispose()
    }
    if ($script:mutex) {
        try { $script:mutex.ReleaseMutex() } catch { }
        $script:mutex.Dispose()
    }
}
