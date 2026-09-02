# IaR Watchdog - Installer
# Installs the watchdog that monitors Chrome and closes any window not matching $KioskTitle
# Runs hidden (no visible window) in the user's session via a Startup folder shortcut

param(
    [string]$InstallDir = "C:\kiosk-watchdog",
    [string]$KioskTitle = "*IaR*",   # override for any other board
    [string]$ChromeExe  = "C:\Program Files\Google\Chrome\Application\chrome.exe",
    # Leave blank: discovered from the running kiosk Chrome so we never hand-copy a JWT.
    # Pass explicitly only when Chrome is not already up on the board.
    [string]$KioskUrl   = "",
    # Processes to kill on sight - these paint their own windows over the board.
    [string[]]$KillProcs = @("ms-teams","Teams","OneDrive")
)

# --- Locate Chrome (fall back to the x86 path) ---
if (-not (Test-Path $ChromeExe)) {
    $alt = "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe"
    if (Test-Path $alt) { $ChromeExe = $alt } else {
        Write-Host "ERROR: chrome.exe not found. Pass -ChromeExe, or run bootstrap with -Provision to install it." -ForegroundColor Red
        exit 1
    }
}

# --- Work out the URL to relaunch with: live process, then what provisioning recorded ---
# Browser processes only - renderers and GPU helpers carry --type= and no URL.
$browsers = @(Get-CimInstance Win32_Process -Filter "Name='chrome.exe'" -ErrorAction SilentlyContinue |
              Where-Object { $_.CommandLine -and $_.CommandLine -notlike "*--type=*" })
if (-not $KioskUrl) {
    # Prefer a kiosk process, but a board is often launched without that flag (a vendor
    # auto-login program, --app=, or just a URL argument), so fall back to any browser
    # process that was handed a URL at launch.
    # Match "-kiosk", not "--kiosk": Chrome accepts single-dash switches and real
    # shortcuts in the field are written that way.
    $cl = ($browsers | Where-Object { $_.CommandLine -like "*-kiosk*" } | Select-Object -First 1).CommandLine
    if (-not $cl) {
        $cl = ($browsers | Where-Object { $_.CommandLine -match 'https?://' } | Select-Object -First 1).CommandLine
    }
    if ($cl -match '(https?://[^\s"]+)') { $KioskUrl = $Matches[1].Trim('"') }
}
if (-not $KioskUrl -and (Test-Path "$InstallDir\kiosk-url.txt")) {
    $KioskUrl = (Get-Content "$InstallDir\kiosk-url.txt" -Raw).Trim()
    if ($KioskUrl) { Write-Host "Using URL recorded by provisioning" }
}
if (-not $KioskUrl) {
    Write-Host "ERROR: No kiosk URL found - no running Chrome was launched with a URL," -ForegroundColor Red
    Write-Host "       and $InstallDir\kiosk-url.txt does not exist." -ForegroundColor Red
    Write-Host "       Re-run with -KioskUrl '<board URL>'." -ForegroundColor Red
    if ($browsers) {
        Write-Host "       Chrome browser processes seen (the URL may be in one of these):" -ForegroundColor Yellow
        $browsers | ForEach-Object { Write-Host "         [$($_.ProcessId)] $($_.CommandLine)" -ForegroundColor Yellow }
    } else {
        Write-Host "       No Chrome browser process is running at all." -ForegroundColor Yellow
    }
    exit 1
}

# --- Detect logged-in interactive user ---
$loggedInUser = (Get-WmiObject -Class Win32_ComputerSystem).UserName
if (-not $loggedInUser) {
    Write-Host "ERROR: Could not detect logged-in user." -ForegroundColor Red
    exit 1
}
$userName = ($loggedInUser -split '\\')[-1]
$userProfile = "C:\Users\$userName"
$startupFolder = "$userProfile\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup"

Write-Host "Logged-in user:   $loggedInUser"
Write-Host "User profile:     $userProfile"
Write-Host "Startup folder:   $startupFolder"
Write-Host "Install dir:      $InstallDir"

# --- Create install directory ---
if (-not (Test-Path $InstallDir)) {
    New-Item -Path $InstallDir -ItemType Directory -Force | Out-Null
}
Write-Host "Install directory ready" -ForegroundColor Green

# Keep a copy of the URL we are relaunching with (this is the recovery artifact).
$KioskUrl | Out-File -FilePath "$InstallDir\kiosk-url.txt" -Encoding UTF8 -Force
Write-Host "Kiosk URL: $($KioskUrl.Substring(0,[Math]::Min(60,$KioskUrl.Length)))..."

# Sanity-check the title pattern against the board that is actually up.
# A pattern that does not match would make the watchdog close the board itself.
$liveTitles = Get-Process -Name chrome -ErrorAction SilentlyContinue |
              Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -ExpandProperty MainWindowTitle
if ($liveTitles) {
    Write-Host "Chrome window titles seen: $($liveTitles -join ' | ')"
    if (-not ($liveTitles | Where-Object { $_ -like $KioskTitle })) {
        Write-Host "ERROR: no live Chrome window matches '$KioskTitle' - the watchdog would close the board." -ForegroundColor Red
        Write-Host "       Re-run with -KioskTitle matching one of the titles above." -ForegroundColor Red
        exit 1
    }
    Write-Host "Title pattern '$KioskTitle' matches the live board" -ForegroundColor Green
} else {
    Write-Host "WARNING: no Chrome window visible from this session - title pattern unverified." -ForegroundColor Yellow
}

# --- Write watchdog.ps1 ---
$KillProcsLiteral = '@(' + (($KillProcs | ForEach-Object { '"' + $_ + '"' }) -join ',') + ')'

$watchdogPs1 = @"
# Chrome Kiosk Watchdog - Main Loop
# Runs continuously in the user's session, closing any Chrome window that doesn't match the kiosk title

`$LogPath       = "$InstallDir\watchdog.log"
`$MaxLogLines   = 2000
`$KioskTitle    = "$KioskTitle"
`$ChromeExe     = "$ChromeExe"
`$KioskUrl      = "$KioskUrl"
`$KillProcs     = $KillProcsLiteral
`$CheckInterval = 120   # seconds between checks
`$GCInterval    = 30    # force GC every N iterations to prevent memory creep

function Write-Log {
    param([string]`$Message, [string]`$Level = "INFO")
    `$timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    try {
        Add-Content -Path `$LogPath -Value "[`$timestamp] [`$Level] `$Message" -ErrorAction Stop
    } catch {
        # Can't log - nothing we can do
    }
}

function Rotate-Log {
    if (Test-Path `$LogPath) {
        `$lines = Get-Content `$LogPath
        if (`$lines.Count -gt `$MaxLogLines) {
            `$lines | Select-Object -Last `$MaxLogLines | Set-Content `$LogPath
        }
    }
}

# Load WinAPI once for the life of the process
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class WinAPI {
    [DllImport("user32.dll")]
    public static extern bool PostMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);
}
'@

function Start-Kiosk {
    # Relaunch Chrome in kiosk mode.
    if (-not (Test-Path `$ChromeExe)) {
        Write-Log "Cannot relaunch - chrome.exe not found at `$ChromeExe" "ERROR"
        return
    }
    # Same flags the Startup shortcut uses. --disable-session-crashed-bubble matters most:
    # without it a relaunch after a hard power loss shows "Restore pages?" over the board.
    `$chromeArgs = @(
        "--kiosk",
        "--noerrdialogs",
        "--disable-session-crashed-bubble",
        "--disable-infobars",
        "--no-first-run",
        "--no-default-browser-check",
        "--disable-features=Translate,TranslateUI",
        `$KioskUrl
    )
    Start-Process -FilePath `$ChromeExe -ArgumentList `$chromeArgs
    Write-Log "RELAUNCHED Chrome in kiosk mode" "WARN"
}

Write-Log "Watchdog started (PID: `$PID, interval: `$CheckInterval s)"

`$iteration = 0

while (`$true) {
    `$iteration++

    try {
        Rotate-Log

        # Anything on the kill list gets closed on sight - these paint over the board.
        foreach (`$p in Get-Process -Name `$KillProcs -ErrorAction SilentlyContinue) {
            Stop-Process -Id `$p.Id -Force -ErrorAction SilentlyContinue
            Write-Log "KILLED `$(`$p.Name) (PID: `$(`$p.Id))" "WARN"
        }

        `$chromeProcesses = Get-Process -Name chrome -ErrorAction SilentlyContinue
        if (-not `$chromeProcesses) {
            Write-Log "Chrome is not running - relaunching kiosk" "ERROR"
            Start-Kiosk
        } else {
            `$kioskFound  = `$false
            `$closedCount = 0
            `$innerLoop   = 0

            # Inner retry loop: close one non-kiosk window, re-check (the next window becomes active), repeat.
            # Bounded to 10 to prevent infinite loops if something goes wrong.
            while (`$innerLoop -lt 10) {
                `$innerLoop++
                `$chromeWindows = Get-Process -Name chrome -ErrorAction SilentlyContinue | Where-Object { `$_.MainWindowHandle -ne 0 }
                if (-not `$chromeWindows) { break }

                `$badWindow = `$chromeWindows | Where-Object { `$_.MainWindowTitle -notlike `$KioskTitle } | Select-Object -First 1
                `$goodWindow = `$chromeWindows | Where-Object { `$_.MainWindowTitle -like `$KioskTitle } | Select-Object -First 1

                if (`$goodWindow) { `$kioskFound = `$true }

                if (`$badWindow) {
                    [WinAPI]::PostMessage(`$badWindow.MainWindowHandle, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null
                    Write-Log "CLOSED non-kiosk window: '`$(`$badWindow.MainWindowTitle)' (PID: `$(`$badWindow.Id))" "WARN"
                    `$closedCount++
                    Start-Sleep -Milliseconds 500
                } else {
                    # No more bad windows
                    if (`$goodWindow) {
                        Write-Log "OK - kiosk window active: '`$(`$goodWindow.MainWindowTitle)' (PID: `$(`$goodWindow.Id))"
                    }
                    break
                }
            }

            if (`$closedCount -gt 0) {
                Write-Log "Summary: closed `$closedCount non-kiosk window(s) this iteration" "WARN"
            }
            # Only alarm if the board isn't found AND we didn't close anything that was covering it
            if (-not `$kioskFound -and `$closedCount -eq 0) {
                Write-Log "Kiosk window NOT found - board may be down, manual check required" "ERROR"
            }
        }
    } catch {
        Write-Log "Exception in check loop: `$_" "ERROR"
    }

    # Periodic garbage collection to prevent memory creep in long-running loop
    if (`$iteration % `$GCInterval -eq 0) {
        [System.GC]::Collect()
        [System.GC]::WaitForPendingFinalizers()
        [System.GC]::Collect()
    }

    Start-Sleep -Seconds `$CheckInterval
}
"@

$watchdogPs1 | Out-File -FilePath "$InstallDir\watchdog.ps1" -Encoding UTF8 -Force
Write-Host "Wrote $InstallDir\watchdog.ps1" -ForegroundColor Green

# --- Hidden launch via conhost --headless (native Win11, no window, no flash, no VBScript) ---
$launchTarget = "conhost.exe"
$launchArgs   = "--headless powershell.exe -NonInteractive -ExecutionPolicy Bypass -File `"$InstallDir\watchdog.ps1`""

# --- Copy test script if it's alongside the installer ---
$testScriptSrc = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "watchdog-test.ps1"
if (Test-Path $testScriptSrc) {
    Copy-Item $testScriptSrc -Destination "$InstallDir\watchdog-test.ps1" -Force
    Write-Host "Copied watchdog-test.ps1 to install dir" -ForegroundColor Green
}

# --- Create Startup folder shortcut ---
if (-not (Test-Path $startupFolder)) {
    Write-Host "WARNING: Startup folder not found at $startupFolder" -ForegroundColor Yellow
} else {
    $shortcutPath = "$startupFolder\KioskWatchdog.lnk"
    $wshShell = New-Object -ComObject WScript.Shell
    $shortcut = $wshShell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath = $launchTarget
    $shortcut.Arguments = $launchArgs
    $shortcut.WorkingDirectory = $InstallDir
    $shortcut.Description = "Chrome Kiosk Watchdog - keeps this machine locked to its kiosk page"
    $shortcut.Save()
    Write-Host "Created startup shortcut at $shortcutPath" -ForegroundColor Green
}

# --- Start watchdog immediately (hidden, in user context) ---
Write-Host ""
Write-Host "Stopping any previous watchdog instances..."
Get-WmiObject Win32_Process | Where-Object {
    $_.CommandLine -like "*watchdog.ps1*"
} | ForEach-Object {
    Write-Host "  Killing PID $($_.ProcessId)"
    Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
}

Write-Host "Launching new watchdog..."
Start-Process $launchTarget -ArgumentList $launchArgs
Start-Sleep -Seconds 3

Write-Host ""
Write-Host "=== Last 10 log lines ==="
if (Test-Path "$InstallDir\watchdog.log") {
    Get-Content "$InstallDir\watchdog.log" -Tail 10
} else {
    Write-Host "Log file not created yet. Check manually in a moment." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "=== Installation complete ===" -ForegroundColor Green
Write-Host "Watchdog will auto-start on next login for user: $userName"
Write-Host "To tail the log:  Get-Content '$InstallDir\watchdog.log' -Tail 20 -Wait"
Write-Host "To run tests:     powershell -File '$InstallDir\watchdog-test.ps1'"
