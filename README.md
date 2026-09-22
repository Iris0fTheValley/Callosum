# Mouse Without Borders SMB DragDrop

Mouse Without Borders SMB DragDrop / Mouse Without Borders SMB 跨机拖放增强版

This public repository contains an enhanced Explorer-to-Explorer file drag flow for Mouse Without Borders on trusted Windows LANs. The feature keeps MWB mouse crossing, keyboard forwarding, and the existing clipboard protocol. It adds a metadata-only drag manifest and uses the existing SMB shares for the data path.

本仓库面向可信 Windows 局域网，增强 Mouse Without Borders 的资源管理器跨机拖放。鼠标跨屏、键盘转发和剪贴板协议保持原样；增强通道只传输拖放元数据，文件内容仍通过现有 SMB 共享传输。

## Workflow

1. `FormHelper` reads the complete `DataFormats.FileDrop` `string[]` and passes every file/folder to the existing drag state machine.
2. The source creates a GUID-based manifest and sends UTF-8 chunks containing only source machine, paths, directory flags, and drag ID.
3. The target reassembles and validates chunks, enumerates visible non-minimized filesystem Explorer windows, and shows one temporary overlay per Explorer HWND. The Windows desktop is not represented by a synthetic full-screen overlay.
4. MouseUp selects one target directory. The target resolves the source drive to the established `<machine>_<drive>` share and streams files/folders over UNC/SMB without reading the whole file into memory.
5. Esc, right-click, return-to-source, duplicate IDs, malformed manifests, unavailable shares, conflicts, cancellation, and partial failures are reported and logged.

目标端会为每个可用 Explorer 窗口创建独立的半透明 Overlay，不创建合成的全屏 Desktop Overlay。Overlay 使用 Windows 返回的 Bounds 和 DPI，一对一覆盖 Explorer；它紧贴 Explorer 正上方但低于原本位于 Explorer 上方的窗口，因此重叠和遮挡由 Windows 自己处理。窗口移动、缩放、最小化或关闭时每 250 ms 同步。Overlay 不抢焦点，MouseUp 只用于选择目录。

The target shows one non-activating translucent overlay per usable Explorer window; it does not create a synthetic full-screen desktop overlay. Each overlay uses the native Explorer bounds/DPI and is placed immediately above its Explorer owner while remaining below windows that were already above it, so Windows handles overlap, occlusion, and hit-testing. It refreshes every 250 ms as windows move, resize, minimize, or close. MouseUp selects the directory; it does not replace MWB input handling.

文件落盘优先调用 Windows Shell `IFileOperation`，源 SMB/UNC 路径和目标目录都作为 Shell item 交给系统。Windows 负责递归目录、原生进度、冲突、错误和取消交互；MWB 只负责 manifest、SMB 路径解析和把目标目录传回源端。

File materialization now prefers Windows Shell `IFileOperation`: SMB/UNC sources and the target directory are passed as Shell items. Windows owns recursive directory handling, native progress, conflicts, errors, and cancellation; MWB only coordinates the manifest, SMB path mapping, and target-directory request.

MWB never carries file contents for enhanced drags.

## Layout

- `EnhancedDragDrop/`: standalone net8 Windows implementation and reusable logic.
- `EnhancedDragDrop.Tests/`: manifest, chunking, path resolver, state machine, Unicode, and streaming-copy tests.
- `src/modules/MouseWithoutBorders/App/`: focused upstream MWB source snapshot and integration changes.
- `docs/`: environment mapping, validation evidence, limitations, and deployment notes.

## Build and tests

Build/test commands must run on the physical machine containing the source. On PC-B, where the .NET SDK is installed:

```powershell
dotnet test EnhancedDragDrop.Tests\EnhancedDragDrop.Tests.csproj
```

The focused deterministic test suite currently passes 6/6 on PC-B. The optional UNC smoke test is environment-dependent and is run only when its source and target variables are configured. The integrated MWB project also builds on PC-B with the documented x64 MSBuild command and produces `x64\Debug\PowerToys.MouseWithoutBorders.dll`.

PC-B 当前确定性测试为 6/6 通过；真实 UNC smoke 测试需要显式配置源和目标环境变量。集成 MWB 项目可在 PC-B 按下方 x64 MSBuild 命令构建，产物为 `x64\Debug\PowerToys.MouseWithoutBorders.dll`。

## Run and rollback

Build the full PowerToys tree with its normal developer instructions, deploy the resulting MWB binaries to both machines, and stop the forked MWB process to roll back. The official installed PowerToys binaries remain untouched by this repository.

The target MWB process must run in the logged-on interactive user context that has read access to the source machine's drive share. Running the target as `SYSTEM` is sufficient for mouse hooks in some test setups, but it cannot authenticate to a peer's local SMB share and will make the overlay appear without transferring files. Configure the source share and the corresponding NTFS ACL for the actual peer account, then verify the UNC path from that same account before testing a drag. The enhanced receiver logs the resolved UNC source and reports `SMB access denied` separately from a missing source.

The original mouse, keyboard, clipboard, and screen-switching paths are preserved, with one reliability fix: a transient failure to query the input desktop during an injected cross-machine click no longer closes MWB sockets. Apply `scripts/Apply-MwbDesktopSwitchFix.ps1` to the full PowerToys source tree before building the MWB binary. To roll back only the enhancement, deploy the unmodified upstream MWB binaries; no registry, service, or installed PowerToys package is modified by this repository.

原有鼠标、键盘、剪贴板和跨屏状态机保持原逻辑，并增加了上述桌面查询失败保护。若需回滚增强功能，只需部署未修改的上游 MWB DLL；本仓库不会修改注册表、服务或已安装的 PowerToys 包。

桌面切换检测增加了一个稳定性修复：跨机注入点击期间，如果 Windows 短暂无法查询输入桌面，不再误关闭 MWB socket。构建完整 PowerToys 源码前先运行 `scripts/Apply-MwbDesktopSwitchFix.ps1` 应用该补丁。

### Zero-touch startup and recovery / 无感启动与自愈

Run this once on **each machine**, from the signed-in Windows account that uses MWB:

```powershell
.\scripts\Install-MwbEnhanced.ps1 -Action install
```

The installer copies the guardian and tray scripts beside the enhanced binaries and creates one delayed, per-user logon task. The task runs in the interactive user session, starts MWB silently, publishes health to `%LOCALAPPDATA%\Callosum\health.json`, and keeps checking the local process, helper, listening ports, pairing settings, peer reachability, and the actual established MWB connection.

每台机器只需在实际使用 MWB 的登录用户下运行一次上述命令。之后双方各自启动、各自检查，不依赖某一台机器通过 SSH 拉起另一台，也不依赖跨屏已经可用。守护器会区分“对端关机”和“对端在线但连接异常”：前者安静等待，后者持续 90 秒仍未恢复时才重启本机 MWB，并有冷却时间防止重启风暴。

The guardian never creates or replaces a pairing key. If pairing is absent or invalid, it reports `InvalidSettings` and waits for the user to complete the normal one-time MWB pairing flow. Existing settings are left untouched.

Common local controls are deliberately small:

```powershell
.\scripts\Install-MwbEnhanced.ps1 -Action status
.\scripts\Install-MwbEnhanced.ps1 -Action restart
.\scripts\Install-MwbEnhanced.ps1 -Action stop      # pause automatic recovery
.\scripts\Install-MwbEnhanced.ps1 -Action start     # resume automatic recovery
.\scripts\Install-MwbEnhanced.ps1 -Action uninstall # keep binaries and settings
```

The bilingual tray shows `Connected`, `WaitingForPeer`, `Connecting`, `Paused`, or a concrete configuration/error state. Pausing from the tray is persistent, so the guardian will not immediately undo an intentional stop. Logs are bounded and stored at `%LOCALAPPDATA%\Callosum\guardian.log`.

For an optional controlled two-machine restart, run the management script on PC-A. This is an administrative convenience only; normal startup and recovery are local and independent on both machines:

```powershell
.\scripts\Manage-MwbEnhanced.ps1 -Action status
.\scripts\Manage-MwbEnhanced.ps1 -Action restart
```

The default remote target is the existing `pc-b` SSH alias and the default interactive account is `ID-BLUEBERRY\12298`. Override `-RemoteHost`, `-RemoteInteractiveUser`, or either install directory when deploying elsewhere. The script matches the exact enhanced-binary paths, starts the remote process through the logged-on interactive session, verifies that it is not Session 0, and supports `status`, `start`, `stop`, and `restart`.

`Start-MwbEnhanced.ps1` also synchronizes the MWB pairing key, machine pool, and TCP base port before starting. The default base port is `15101`, so both peers must listen on `15101` and `15102`. It removes stale legacy MWB processes, verifies an established peer connection, and starts `MwbTray.ps1` in the interactive session on both machines. The tray status icon reports stopped, running/disconnected, or connected; its context menu provides quick restart and stop actions for that machine.

The tray context menu also includes `Screen layout...`. It edits the same `MachineMatrixString` and `MatrixOneRow` settings used by the original MWB UI: one-row mode orders four slots from left to right; two-row mode uses top-left, top-right, bottom-left, and bottom-right. The layout is saved with a backup and applied after the local MWB process restarts; the enhanced launcher propagates a valid local layout to the peer during the next coordinated restart.

## License

The original code in this repository is licensed under the GNU General Public License, version 3 or any later version (GPL-3.0-or-later). See [LICENSE](LICENSE) for the full license text.

The MWB snapshot retains the original Microsoft PowerToys license headers and is derived from `microsoft/PowerToys`; those upstream files remain subject to their original licenses. The GPL-3.0-or-later license applies to the original code added in this repository.
