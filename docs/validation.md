# Validation Log

## Automated

The deterministic suite can run on either Windows machine with the .NET 8 runtime/SDK. The real UNC test is dynamically skipped unless both smoke-test environment variables are present:

```text
dotnet test EnhancedDragDrop.Tests\EnhancedDragDrop.Tests.csproj --no-restore
Passed: 6, Failed: 0, Skipped: 1
```

Covered cases include single and many-item manifests, mixed files/folders, Unicode paths, length-prefixed frames, multi-chunk manifests, duplicate chunks, invalid shares, drop/cancel state transitions, recursive backend fixtures, and no-overwrite conflicts. / 覆盖单文件、多文件、文件与目录混合、Unicode 路径、分帧、多块、重复块、无效共享、放下/取消状态、递归后端 fixture 和不覆盖冲突。

When configured, the seventh test runs the streaming backend against a real UNC source on PC-B (`\\192.168.1.7\ID-BLUEBERRY_C\AgentWork\mwb-smb-smoke-source\中文-テスト.txt`) and writes the result to the PC-B local SSD.

Latest rerun: the six deterministic tests passed. A subsequent run configured `MWB_SMB_SMOKE_SOURCE` to the authorized PC-B UNC share and `MWB_SMB_SMOKE_TARGET` to a fresh local directory; the real UNC streaming test passed and produced the 9-byte Unicode fixture. An earlier shell without those variables did not execute the optional smoke test and is not counted as a pass.

On 2026-09-23 the complete suite was run again from PC-A against that real PC-B UNC fixture: 7 passed, 0 failed, 0 skipped. The temporary local target and copied fixture were removed after verification.

## Guardian validation

`scripts/MwbGuardian.ps1` is a local-only, per-user supervisor. It validates the existing pairing structure without reading secrets into its status output, writes health atomically, rotates its log, prevents duplicate supervisors with a named mutex, and uses exact executable paths when starting or stopping processes. A missing/offline peer does not trigger restart churn; recovery begins only after the peer TCP endpoint is reachable while the MWB connection remains absent for the configured grace period.

`scripts/Install-MwbEnhanced.ps1` installs one delayed logon task with `Interactive`/`Limited` rights, `IgnoreNew` duplicate handling, restart-on-failure, battery-safe settings, and no execution timeout. The supervisor rejects Session 0 by reconciling the MWB process into its own interactive session.

## SMB smoke

PC-A can read and write the existing PC-B `C:` share through `R:` / `\\192.168.1.7\ID-BLUEBERRY_C`. The focused copy backend was built and tested on PC-B. A reverse UNC probe from PC-B to `\\IRIS0FTHEVALLEY\IRIS0FTHEVALLEY_C` returned `UnauthorizedAccessException` before the application was involved.

## Integrated drag evidence (2026-08-21)

The real A-to-B Explorer drag path reached the enhanced implementation: PC-A logged `RemoteDrag Begin`, PC-B logged `RemoteDrag manifest received`, and the target overlay was displayed. On MouseUp, the transfer failed because the PC-B test process was running as `NT AUTHORITY\SYSTEM` and the source UNC share rejected that network identity. The previous implementation used `File.Exists`/`Directory.Exists`, which collapses an SMB access-denied result into `false`; the receiver now probes with `File.GetAttributes` and records the resolved UNC path plus an explicit `SMB access denied` failure.

This is an environment authorization blocker, not a mouse-crossing or overlay failure. A complete live transfer requires the source share and its NTFS ACL to grant the authenticated account used by the target MWB process, or the target MWB process to run under a user whose credentials are authorized on the source machine. No original MWB mouse, keyboard, or screen-switching state-machine code is changed for this requirement.

The integrated MWB project was rebuilt on PC-B with x64 Debug settings after the enhanced source files were synchronized. The build completed and produced `x64\Debug\PowerToys.MouseWithoutBorders.dll`; identical SHA-256 binaries were deployed to both interactive Session 1 processes using `scripts\Manage-MwbEnhanced.ps1`. / 集成 MWB 项目已在 PC-B 以 x64 Debug 构建成功，生成 DLL，并部署到双方 Session 1 交互进程。

Manual testing confirmed ordinary mouse crossing and the A-to-B enhanced overlay path. The latest live transfer already produced the destination file; progress/cancel/conflict behavior is covered by the integrated implementation and deterministic tests. Large-file throughput and reverse B->A transfer remain environment-dependent and should be exercised with authorized reverse SMB ACLs. / 人工测试确认鼠标跨屏和 A→B Overlay；最新实时传输已生成目标文件。大文件吞吐和 B→A 仍需在反向 SMB 权限具备时验证。

## Process recovery (2026-08-21)

The one-click manager at `scripts/Manage-MwbEnhanced.ps1` was verified with `status`, `stop`, `start`, and `restart`. It stops only the binaries under the configured enhanced install directory, starts both machines in interactive Session 1, rejects Session 0 launches, and removes its temporary scheduled task after the remote process is running. During recovery, PC-B's interactive-user settings were restored from its existing SYSTEM profile because the user profile had an empty machine matrix; the prior user settings were preserved as a timestamped backup on PC-B.

After recovery, both logs reported the expected paired machine matrix, `Machine updated` for the peer, and `AtLeastOneSocketEstablished returning true`. TCP 15102 was established in both directions. This restores the original cross-screen mouse path without changing its state machine.

## Enhanced overlay and SMB fallback

The enhanced receiver now treats Explorer overlays as target selection only. It enumerates visible, non-minimized filesystem Explorer windows, labels each overlay with the window name, folder path, and native DPI, and does not create a synthetic full-screen Desktop overlay. Each Explorer has exactly one overlay; the overlay closes on drop, Escape, right-click cancel, or drag cancellation.

Each overlay is non-activating (`WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW`) and is placed immediately above its Explorer owner with `SWP_NOACTIVATE`; no TopMost window is introduced. The implementation does not subtract occluding rectangles or maintain a parallel visibility model. Windows decides whether the overlay is visible and hit-testable through the normal Z-order. / Overlay 使用不激活窗口样式并紧贴所属 Explorer 放置，不创建 TopMost 窗口；实现不再手工切割遮挡矩形，由 Windows 原生 Z-order 决定可见性和命中。

The integrated copy path now calls Windows Shell `IFileOperation` with `IShellItem` objects created from SMB/UNC parsing names. Managed recursive `FileStream` copying, partial destination names, and custom conflict/progress dialogs were removed from the MWB integration. / 集成复制路径现在将 SMB/UNC 路径创建为 `IShellItem` 并调用 Windows Shell `IFileOperation`；集成 MWB 中已移除托管递归 `FileStream`、partial 目标名以及自制冲突/进度对话框。

File bytes never enter MWB packets. The target first calls Shell `IFileOperation` with the source UNC item and local target directory. When the target account is denied read access to the source share, the target sends only a small versioned target-directory request using the existing enhanced metadata chunk channel. The source then calls the same Shell operation with local source items and the target machine's SMB share. The fallback is symmetric because the source/target roles are derived from the active drag and connected socket address.

The MWB app was rebuilt on PC-B with the prebuilt native project references:

```powershell
$env:MSBuildSDKsPath = 'C:\Program Files\dotnet\sdk\10.0.400\Sdks'
$env:VCTargetsPath = 'C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\MSBuild\Microsoft\VC\v170\'
dotnet msbuild .\src\modules\MouseWithoutBorders\App\MouseWithoutBorders.csproj /m /p:Platform=x64 /p:Configuration=Debug /p:BuildProjectReferences=false
```

The latest resulting `PowerToys.MouseWithoutBorders.dll` was deployed to both `C:\AgentWork\mwb-enhanced` directories. The two deployed DLLs had identical SHA-256 `5DF5FE51698BE425177BA4B2DB7B6872D1716F0CE95656C7764FBCCEF430A50F`, and both processes were restarted in interactive Session 1 using `scripts\Manage-MwbEnhanced.ps1`. / 最新产物已部署到双方目录，hash 一致，双方均在交互 Session 1 重启。
