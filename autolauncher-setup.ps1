<#
  IamResponding Auto Login - attended install, then capture the config for reuse.

  Run in a NORMAL (NOT elevated) PowerShell, signed in as the kiosk user:

    $s = irm https://raw.githubusercontent.com/KD2PDL/iar-watchdog/main/autolauncher-setup.ps1
    & ([scriptblock]::Create($s))

  It installs the app, opens it, then waits while you fill in agency / username /
  password / browser / kiosk toggle. Once the app writes its config and launches the
  browser, it copies the config out so every other board in the same department can be
  set up without retyping any of it.

  The captured launch_data.txt encodes the agency's IamResponding username and password.
  Treat the capture folder as a credential: same department only, never a repo.
#>
[CmdletBinding()]
param(
    [string]$Url        = "https://download.iamresponding.com/autolauncher/autolauncher-win.exe",
    [string]$InstallDir = "C:\kiosk-watchdog",
    [int]   $TimeoutMin = 20,          # how long to wait for you to finish the form
    [switch]$SkipInstall               # app is already installed; just launch and capture
)

$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# --- Squirrel installs per-user and refuses to run elevated. This is the one script here
# --- that must NOT be run as administrator.
if (([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Run this WITHOUT elevation, as the kiosk user. The installer is a Squirrel package and refuses to run as administrator."
}

$appRoot = Join-Path $env:LOCALAPPDATA "autolauncher"
$capture = Join-Path $InstallDir "autolauncher-config"
$stage   = Join-Path $InstallDir "bin"

function Find-Artifacts {
    # The app writes launch_data.txt / terms.txt with a RELATIVE path, so they land in
    # whatever the process's working directory was. Look everywhere it plausibly runs.
    $roots = @($appRoot, $env:USERPROFILE, "$env:USERPROFILE\Documents", $PWD.Path) |
             Where-Object { $_ -and (Test-Path $_) } | Select-Object -Unique
    foreach ($r in $roots) {
        $hit = Get-ChildItem $r -Recurse -Depth 4 -Filter "launch_data.txt" -File -ErrorAction SilentlyContinue |
               Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($hit) { return $hit }
    }
    return $null
}

# --- Install ---
if (-not $SkipInstall) {
    New-Item -Path $stage -ItemType Directory -Force | Out-Null
    $exe = Join-Path $stage "autolauncher-win.exe"
    if (-not (Test-Path $exe)) {
        Write-Host "Downloading IamResponding Auto Login (~97 MB)..."
        Invoke-WebRequest -Uri $Url -OutFile $exe -UseBasicParsing
    }
    Write-Host "Installing (silent)..."
    Start-Process -FilePath $exe -ArgumentList "--silent" -Wait
    for ($i = 0; $i -lt 60 -and -not (Test-Path $appRoot); $i++) { Start-Sleep 2 }
    if (-not (Test-Path $appRoot)) { throw "Install finished but $appRoot never appeared." }
    Write-Host "Installed to $appRoot" -ForegroundColor Green
}

# --- Launch it for the operator ---
$appExe = Get-ChildItem $appRoot -Recurse -Filter "autolauncher.exe" -File -ErrorAction SilentlyContinue |
          Where-Object { $_.FullName -notmatch 'ExecutionStub' } |
          Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not $appExe) { throw "Could not find autolauncher.exe under $appRoot" }

$before = Find-Artifacts
if (-not (Get-Process -Name autolauncher -ErrorAction SilentlyContinue)) {
    # Working directory matters: the app writes its config relative to it.
    Start-Process -FilePath $appExe.FullName -WorkingDirectory $appExe.DirectoryName
}

Write-Host ""
Write-Host "=== Over to you ===" -ForegroundColor Cyan
Write-Host "In the IamResponding window: agency name, username, password, pick the browser,"
Write-Host "set the kiosk toggle, accept the terms, then Launch."
Write-Host "Waiting up to $TimeoutMin minutes for it to write its config and open the browser..."

# --- Wait for the config to appear (or change) and the browser to come up ---
$deadline = (Get-Date).AddMinutes($TimeoutMin)
$found = $null
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 5
    $now = Find-Artifacts
    if ($now -and (-not $before -or $now.LastWriteTime -gt $before.LastWriteTime)) { $found = $now; break }
    Write-Host "." -NoNewline
}
Write-Host ""

if (-not $found) {
    Write-Host "Timed out - no launch_data.txt was written." -ForegroundColor Red
    Write-Host "If you did complete the form, find it yourself and re-run with -SkipInstall:" -ForegroundColor Yellow
    Write-Host '  Get-ChildItem $env:LOCALAPPDATA, $env:USERPROFILE -Recurse -Filter launch_data.txt -ErrorAction SilentlyContinue | Select FullName' -ForegroundColor Yellow
    exit 1
}

# --- Capture ---
New-Item -Path $capture -ItemType Directory -Force | Out-Null
$srcDir = $found.DirectoryName
$copied = @()
foreach ($f in "launch_data.txt","terms.txt","IaRVersion.txt") {
    $p = Join-Path $srcDir $f
    if (Test-Path $p) { Copy-Item $p -Destination $capture -Force; $copied += $f }
}
"Config written by the app to: $srcDir" | Out-File (Join-Path $capture "SOURCE-PATH.txt") -Encoding UTF8

Write-Host "Captured: $($copied -join ', ')" -ForegroundColor Green
Write-Host "  from $srcDir"
Write-Host "  to   $capture"

# --- Report what the app actually launched: this is what the watchdog must match ---
$browsers = @(Get-CimInstance Win32_Process -Filter "Name='chrome.exe'" -ErrorAction SilentlyContinue |
              Where-Object { $_.CommandLine -and $_.CommandLine -notlike "*--type=*" })
$titles = Get-Process -Name chrome -ErrorAction SilentlyContinue |
          Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -ExpandProperty MainWindowTitle
Write-Host ""
if ($browsers) {
    Write-Host "Browser launched with:" -ForegroundColor Cyan
    $browsers | ForEach-Object { Write-Host "  [$($_.ProcessId)] $($_.CommandLine)" }
}
if ($titles) {
    Write-Host "Window title(s) - use this for the watchdog's -KioskTitle:" -ForegroundColor Cyan
    $titles | ForEach-Object { Write-Host "  $_" }
} else {
    Write-Host "No browser window visible yet - re-check before installing the watchdog." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "Done. Next: install the watchdog from an ELEVATED PowerShell:" -ForegroundColor Green
Write-Host '  $b = irm https://raw.githubusercontent.com/KD2PDL/iar-watchdog/main/bootstrap.ps1'
Write-Host '  & ([scriptblock]::Create($b)) -SkipHarden -KioskTitle "*<title above>*"'
Write-Host ""
Write-Host "The captured files hold the agency's IamResponding credentials." -ForegroundColor Yellow
Write-Host "Reuse them on that department's other boards only. Never commit them." -ForegroundColor Yellow
