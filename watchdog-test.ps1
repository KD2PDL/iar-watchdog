# IaR Watchdog - Tests
# Verifies the watchdog components work correctly
# Run this on the kiosk machine to validate the installation

param(
    [string]$InstallDir = "C:\kiosk-watchdog",
    [string]$KioskTitle = "*IaR*"   # override for any other board
)

$script:PassCount = 0
$script:FailCount = 0

function Test-Assert {
    param([string]$Name, [bool]$Condition, [string]$Detail = "")
    if ($Condition) {
        Write-Host "  [PASS] $Name" -ForegroundColor Green
        $script:PassCount++
    } else {
        Write-Host "  [FAIL] $Name" -ForegroundColor Red
        if ($Detail) { Write-Host "         $Detail" -ForegroundColor Red }
        $script:FailCount++
    }
}

function Test-Section {
    param([string]$Name)
    Write-Host ""
    Write-Host "=== $Name ===" -ForegroundColor Cyan
}

# --- 1. File structure ---
Test-Section "Installation files"
Test-Assert "Install dir exists" (Test-Path $InstallDir) "Expected: $InstallDir"
Test-Assert "watchdog.ps1 present" (Test-Path "$InstallDir\watchdog.ps1")

$startupFolder = [Environment]::GetFolderPath("Startup")
$shortcutPath = "$startupFolder\KioskWatchdog.lnk"
Test-Assert "Startup shortcut present" (Test-Path $shortcutPath) "Expected: $shortcutPath"

# --- 2. Watchdog process running ---
Test-Section "Running process"
$watchdogProc = Get-WmiObject Win32_Process | Where-Object { $_.CommandLine -like "*watchdog.ps1*" }
Test-Assert "Watchdog PowerShell process running" ($null -ne $watchdogProc) "No PowerShell with watchdog.ps1 in command line"
if ($watchdogProc) {
    Write-Host "         Watchdog PID: $($watchdogProc.ProcessId)" -ForegroundColor Gray
}

# --- 3. Chrome is running and has the kiosk window ---
Test-Section "Chrome state"
$chromeProcs = Get-Process -Name chrome -ErrorAction SilentlyContinue
Test-Assert "Chrome is running" ($null -ne $chromeProcs)

if ($chromeProcs) {
    $chromeWindows = Get-Process -Name chrome | Where-Object { $_.MainWindowHandle -ne 0 }
    Test-Assert "Chrome has at least one visible window" ($null -ne $chromeWindows)

    if ($chromeWindows) {
        $kioskWindow = $chromeWindows | Where-Object { $_.MainWindowTitle -like $KioskTitle }
        Test-Assert "Kiosk window present" ($null -ne $kioskWindow) "No window matching $KioskTitle"
        if ($kioskWindow) {
            Write-Host "         Kiosk window: '$($kioskWindow.MainWindowTitle)'" -ForegroundColor Gray
        }
    }
}

# --- 4. Log file health ---
Test-Section "Log file"
$logPath = "$InstallDir\watchdog.log"
Test-Assert "Log file exists" (Test-Path $logPath)

if (Test-Path $logPath) {
    $logLines = Get-Content $logPath
    Test-Assert "Log has content" ($logLines.Count -gt 0)

    $recentEntries = $logLines | Select-Object -Last 20
    $hasRecentInfo = $recentEntries | Where-Object { $_ -like "*[INFO]*" }
    Test-Assert "Recent INFO entries present" ($null -ne $hasRecentInfo)

    # Check log isn't growing unbounded
    $logSize = (Get-Item $logPath).Length
    Test-Assert "Log file under 5MB" ($logSize -lt 5MB) "Current size: $([math]::Round($logSize/1KB,2)) KB"
}

# --- 5. Window closing logic (LIVE TEST) ---
Test-Section "Live window-closing behavior"
Write-Host "  Opening a test Chrome window..."

$chromeExe = "C:\Program Files\Google\Chrome\Application\chrome.exe"
if (-not (Test-Path $chromeExe)) { $chromeExe = "C:\Program Files (x86)\Google\Chrome\Application\chrome.exe" }

if (Test-Path $chromeExe) {
    # Count windows before
    $beforeWindows = Get-Process -Name chrome | Where-Object { $_.MainWindowHandle -ne 0 } | Measure-Object | Select-Object -ExpandProperty Count

    # Launch new window (will show as "New Tab")
    Start-Process $chromeExe -ArgumentList "--new-window", "about:blank"
    Start-Sleep -Seconds 3

    $afterLaunch = Get-Process -Name chrome | Where-Object { $_.MainWindowHandle -ne 0 -and $_.MainWindowTitle -notlike $KioskTitle }
    $extraWindowOpened = $null -ne $afterLaunch
    Write-Host "  Extra window opened: $extraWindowOpened"

    if ($extraWindowOpened) {
        Write-Host "  Waiting up to 150 seconds for watchdog to close it..."
        $closed = $false
        $waited = 0
        while ($waited -lt 150 -and -not $closed) {
            Start-Sleep -Seconds 10
            $waited += 10
            $stillThere = Get-Process -Name chrome | Where-Object { $_.MainWindowHandle -ne 0 -and $_.MainWindowTitle -notlike $KioskTitle }
            if (-not $stillThere) { $closed = $true }
            Write-Host "    ${waited}s elapsed - non-kiosk window still present: $($null -ne $stillThere)"
        }
        Test-Assert "Watchdog closed the non-kiosk window within 150s" $closed
    } else {
        Write-Host "  [SKIP] Could not spawn a testable extra window" -ForegroundColor Yellow
    }
} else {
    Write-Host "  [SKIP] Chrome not found at expected path" -ForegroundColor Yellow
}

# --- Summary ---
Test-Section "Summary"
Write-Host "  Passed: $script:PassCount" -ForegroundColor Green
Write-Host "  Failed: $script:FailCount" -ForegroundColor $(if ($script:FailCount -eq 0) { "Green" } else { "Red" })
Write-Host ""
if ($script:FailCount -eq 0) {
    Write-Host "All tests passed" -ForegroundColor Green
    exit 0
} else {
    Write-Host "Some tests failed - review output above" -ForegroundColor Red
    exit 1
}
