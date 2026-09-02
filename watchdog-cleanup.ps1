# IaR Watchdog - Cleanup
# Removes the watchdog installation completely

param(
    [string]$InstallDir = "C:\kiosk-watchdog"
)

$loggedInUser = (Get-WmiObject -Class Win32_ComputerSystem).UserName
$userName = ($loggedInUser -split '\\')[-1]
$startupShortcut = "C:\Users\$userName\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup\KioskWatchdog.lnk"

Write-Host "Cleaning up watchdog..."

# --- Stop any running watchdog processes ---
Write-Host "Stopping running watchdog processes..."
Get-WmiObject Win32_Process | Where-Object {
    $_.CommandLine -like "*watchdog.ps1*"
} | ForEach-Object {
    Write-Host "  Killing PID $($_.ProcessId) ($($_.Name))"
    Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
}

# --- Remove legacy scheduled task if present ---
# Cmdlets, not schtasks.exe: schtasks writes "cannot find the file specified" to
# stderr when the task is absent, which PowerShell surfaces as a red
# NativeCommandError and reads like a failure in an RMM job log. It never was one.
if (Get-ScheduledTask -TaskName "ChromeKioskWatchdog" -ErrorAction SilentlyContinue) {
    Unregister-ScheduledTask -TaskName "ChromeKioskWatchdog" -Confirm:$false
    Write-Host "Removed legacy scheduled task"
}

# --- Remove startup shortcut ---
if (Test-Path $startupShortcut) {
    Remove-Item $startupShortcut -Force
    Write-Host "Removed startup shortcut"
}

# --- Remove legacy C:\kiosk-watchdog.ps1 if present ---
if (Test-Path "C:\kiosk-watchdog.ps1") {
    Remove-Item "C:\kiosk-watchdog.ps1" -Force
    Write-Host "Removed legacy C:\kiosk-watchdog.ps1"
}

# --- Remove install directory (but keep log for reference) ---
if (Test-Path $InstallDir) {
    Remove-Item "$InstallDir\watchdog.ps1" -Force -ErrorAction SilentlyContinue
    Remove-Item "$InstallDir\launcher.vbs" -Force -ErrorAction SilentlyContinue  # legacy, pre-conhost installs
    Remove-Item "$InstallDir\watchdog-test.ps1" -Force -ErrorAction SilentlyContinue
    Write-Host "Removed scripts from $InstallDir (log file kept)"
}

Write-Host ""
Write-Host "Cleanup complete" -ForegroundColor Green
