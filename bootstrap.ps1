<#
  IaR Watchdog - one-command bootstrap.

  Existing kiosk, just add the watchdog + hardening (run elevated, or from an RMM as SYSTEM):

    iex (irm https://raw.githubusercontent.com/KD2PDL/iar-watchdog/main/bootstrap.ps1)

  Bare Windows box -> finished kiosk. iex (irm ...) cannot take arguments, so fetch
  the script and call it as a scriptblock:

    $b = irm https://raw.githubusercontent.com/KD2PDL/iar-watchdog/main/bootstrap.ps1
    & ([scriptblock]::Create($b)) -Provision -KioskUrl "https://..." -KioskUser "Gear Room IAR"

  Same, but let IamResponding's own Auto Login program open the board instead of our
  Chrome shortcut:

    & ([scriptblock]::Create($b)) -Provision -KioskUrl "https://..." -Launcher iar

  Everything is silent; a full transcript lands in C:\kiosk-watchdog\bootstrap.log.
#>
[CmdletBinding()]
param(
    [string]  $Repo       = "https://raw.githubusercontent.com/KD2PDL/iar-watchdog/main",
    [string]  $InstallDir = "C:\kiosk-watchdog",
    [string]  $KioskTitle = "*IaR*",            # override for any other board
    [string]  $KioskUrl   = "",                 # blank = discover from the running kiosk Chrome
    [string]  $ChromeExe  = "",                 # blank = find it (or install it, with -Provision)
    [string[]]$KillProcs  = @("ms-teams","Teams","OneDrive"),

    # --- bare-metal provisioning (off by default; needs -KioskUrl) ---
    [switch]  $Provision,                       # install Chrome, set policies, create the Startup shortcut
    [string]  $KioskUser        = "",           # blank = the logged-in interactive user
    [ValidateSet("chrome","iar")]
    [string]  $Launcher         = "chrome",     # chrome = our Startup shortcut; iar = IamResponding Auto Login
    [switch]  $ClearStartup,                    # move existing browser launchers out of Startup first
    [string]  $AutoLogonUser    = "",           # set to enable Winlogon auto-logon
    [string]  $AutoLogonPassword= "",           # NOTE: Windows stores this in the registry in plaintext
    [string[]]$ExtraInstallers  = @(),          # URLs of vendor installers to run silently

    [switch]  $Debloat,                         # opt-in: run Raphire/Win11Debloat first
    [string]  $DebloatVersion   = "2026.08.24",  # pinned upstream release
    [switch]  $SkipHarden,                      # skip Teams/Google-Update/notification/WER suppression
    [switch]  $Reboot                           # reboot when done (see the note at the end first)
)

$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
        ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Must run elevated (Administrator or SYSTEM)."
}
if ($Provision -and -not $KioskUrl) {
    throw "-Provision needs -KioskUrl: on a bare box there is no running Chrome to read it from."
}

$bin = Join-Path $InstallDir "bin"
New-Item -Path $bin -ItemType Directory -Force | Out-Null
Start-Transcript -Path (Join-Path $InstallDir "bootstrap.log") -Append | Out-Null

try {
    Write-Host "Fetching scripts from $Repo"
    foreach ($f in "kiosk-provision.ps1","kiosk-harden.ps1","kiosk-debloat.ps1","watchdog-cleanup.ps1","watchdog-install.ps1","watchdog-test.ps1") {
        Invoke-WebRequest -Uri "$Repo/$f" -OutFile (Join-Path $bin $f) -UseBasicParsing
        Write-Host "  got $f"
    }

    if ($Provision) {
        Write-Host "`n=== Provisioning ==="
        $pArgs = @{ KioskUrl = $KioskUrl; InstallDir = $InstallDir }
        if ($ChromeExe)         { $pArgs.ChromeExe         = $ChromeExe }
        if ($KioskUser)         { $pArgs.KioskUser         = $KioskUser }
        if ($Launcher)          { $pArgs.Launcher          = $Launcher }
        if ($ClearStartup)      { $pArgs.ClearStartup      = $true }
        if ($AutoLogonUser)     { $pArgs.AutoLogonUser     = $AutoLogonUser }
        if ($AutoLogonPassword) { $pArgs.AutoLogonPassword = $AutoLogonPassword }
        if ($ExtraInstallers)   { $pArgs.ExtraInstallers   = $ExtraInstallers }
        & (Join-Path $bin "kiosk-provision.ps1") @pArgs
    }

    if ($Debloat) {
        # Before hardening: debloat removes Teams too, and hardening re-asserts our own
        # policies afterwards so ours are the ones that stick.
        Write-Host "`n=== Debloat ==="
        $dArgs = @{ InstallDir = $InstallDir; Version = $DebloatVersion }
        if ($KioskUser) { $dArgs.KioskUser = $KioskUser }
        & (Join-Path $bin "kiosk-debloat.ps1") @dArgs
    }

    if (-not $SkipHarden) {
        Write-Host "`n=== Hardening ==="
        & (Join-Path $bin "kiosk-harden.ps1")
    }

    # From here on the child scripts shell out to native commands (schtasks, powercfg,
    # vendor installers). Those write to stderr on entirely benign conditions - "task not
    # found", say - and under 'Stop' PowerShell 5.1 promotes that to a TERMINATING error
    # that kills the whole run mid-way. This killed a real deployment at the cleanup step.
    # Child scripts that need strictness set their own preference.
    $ErrorActionPreference = "Continue"

    Write-Host "`n=== Cleanup ==="
    & (Join-Path $bin "watchdog-cleanup.ps1") -InstallDir $InstallDir

    Write-Host "`n=== Install ==="
    $iArgs = @{ InstallDir = $InstallDir; KioskTitle = $KioskTitle; KillProcs = $KillProcs }
    if ($KioskUrl)  { $iArgs.KioskUrl  = $KioskUrl }
    if ($ChromeExe) { $iArgs.ChromeExe = $ChromeExe }
    $global:LASTEXITCODE = 0
    & (Join-Path $bin "watchdog-install.ps1") @iArgs
    if ($LASTEXITCODE -ne 0) { throw "watchdog-install aborted (exit $LASTEXITCODE) - see the reason above." }

    # An RMM runs us in session 0, where the installer's own Start-Process spawns the
    # watchdog somewhere it can never see the kiosk user's windows. Say so plainly.
    # Don't claim success without checking. The install step can look fine and still
    # leave nothing running, which is exactly how a dead board goes unnoticed.
    Start-Sleep -Seconds 5
    $live = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -like "*watchdog.ps1*" }
    $sameSession = (Get-Process -Id $PID).SessionId -ne 0
    Write-Host ""
    if ($live) {
        Write-Host "Watchdog is running (PID $($live.ProcessId -join ', '))." -ForegroundColor Green
    } elseif ($sameSession -and -not $Provision) {
        Write-Host "Watchdog is NOT running despite installing cleanly - check $InstallDir\watchdog.log" -ForegroundColor Red
    } else {
        Write-Host "Not live yet - the board and the watchdog both start at the kiosk user's next login." -ForegroundColor Yellow
        Write-Host "Reboot the board (add -Reboot if it auto-logs-in), or log in as the kiosk user." -ForegroundColor Yellow
    }
    Write-Host "Log: $InstallDir\watchdog.log    Test: powershell -File $bin\watchdog-test.ps1"
}
finally {
    Stop-Transcript | Out-Null
}

if ($Reboot) {
    # Only do this if the board auto-logs-in; otherwise it comes back to a lock screen with no board.
    Write-Host "Rebooting in 30s..." -ForegroundColor Yellow
    shutdown /r /t 30 /c "Kiosk provisioning"
}
