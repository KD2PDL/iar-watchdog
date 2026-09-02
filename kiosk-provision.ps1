# Kiosk Provisioning - takes a bare Windows box to a working kiosk.
# Installs Chrome if missing, applies Chrome policies that stop it interrupting the
# board, drops a Startup shortcut that launches the board, and optionally sets
# auto-logon and runs extra vendor installers.
# Run elevated. Safe to re-run.

param(
    [Parameter(Mandatory)]
    [string]  $KioskUrl,
    [string]  $ChromeExe        = "",                      # blank = find it, install if absent
    [string]  $KioskUser        = "",                      # blank = the logged-in interactive user
    # What actually opens the board at login:
    #   chrome = our own Startup shortcut, Chrome in --kiosk (default)
    #   iar    = IamResponding's Auto Login program (installs at the kiosk user's next logon)
    # Never both - two launchers means two browser windows and the watchdog closes one.
    [ValidateSet("chrome","iar")]
    [string]  $Launcher         = "chrome",
    [switch]  $ClearStartup,                               # retire existing browser launchers first
    [string]  $AutoLauncherUrl  = "https://download.iamresponding.com/autolauncher/autolauncher-win.exe",
    [string]  $AutoLogonUser    = "",                      # set to enable Winlogon auto-logon
    [string]  $AutoLogonPassword= "",                      # NOTE: Windows stores this in the registry in plaintext
    [string[]]$ExtraInstallers  = @(),                     # URLs of vendor installers to run silently
    [string]  $ExtraArgs        = "/S /quiet /qn /norestart",
    [string]  $InstallDir       = "C:\kiosk-watchdog"
)

$ErrorActionPreference = "Stop"
$stage = Join-Path $InstallDir "bin"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Flags that keep Chrome from putting its own UI over the board.
# --disable-session-crashed-bubble is the important one: after any hard power loss
# Chrome otherwise greets the room with "Restore pages?" sitting on top of the board.
$script:KioskFlags = @(
    "--kiosk"
    "--noerrdialogs"
    "--disable-session-crashed-bubble"
    "--disable-infobars"
    "--no-first-run"
    "--no-default-browser-check"
    "--disable-features=Translate,TranslateUI"
)

# --- Chrome ---
function Resolve-Chrome {
    if ($ChromeExe -and (Test-Path $ChromeExe)) { return $ChromeExe }
    foreach ($p in "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
                   "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe") {
        if (Test-Path $p) { return $p }
    }
    return $null
}

$chrome = Resolve-Chrome
if ($chrome) {
    Write-Host "Chrome already installed: $chrome" -ForegroundColor Green
} else {
    Write-Host "Chrome not found - installing the enterprise MSI (~160 MB)..."
    $msi = Join-Path $env:TEMP "chrome_enterprise64.msi"
    Invoke-WebRequest -Uri "https://dl.google.com/dl/chrome/install/googlechromestandaloneenterprise64.msi" `
                      -OutFile $msi -UseBasicParsing
    $p = Start-Process msiexec.exe -ArgumentList "/i `"$msi`" /qn /norestart" -Wait -PassThru
    Remove-Item $msi -Force -ErrorAction SilentlyContinue
    if ($p.ExitCode -ne 0 -and $p.ExitCode -ne 3010) { throw "Chrome MSI failed with exit code $($p.ExitCode)" }
    $chrome = Resolve-Chrome
    if (-not $chrome) { throw "Chrome MSI reported success but chrome.exe is still missing" }
    Write-Host "Installed $chrome" -ForegroundColor Green
}

# --- Chrome policies: no promos, no sign-in nags, no self-updating over the board ---
$pol = "HKLM:\SOFTWARE\Policies\Google\Chrome"
New-Item -Path $pol -Force | Out-Null
foreach ($kv in @{
    PromotionalTabsEnabled     = 0   # no "welcome"/what's-new tab after an update
    DefaultBrowserSettingEnabled = 0 # no "make Chrome your default" prompt
    MetricsReportingEnabled    = 0
    BrowserSignin              = 0   # no sign-in prompts
    SyncDisabled               = 1
    PasswordManagerEnabled     = 0   # no "save password?" bubble
    AutofillAddressEnabled     = 0
    AutofillCreditCardEnabled  = 0
    ShowHomeButton             = 0
    BackgroundModeEnabled      = 0
}.GetEnumerator()) {
    Set-ItemProperty -Path $pol -Name $kv.Key -Value $kv.Value -Type DWord
}
$upd = "HKLM:\SOFTWARE\Policies\Google\Update"
New-Item -Path $upd -Force | Out-Null
Set-ItemProperty -Path $upd -Name UpdateDefault -Value 0 -Type DWord      # 0 = updates disabled
Set-ItemProperty -Path $upd -Name AutoUpdateCheckPeriodMinutes -Value 0 -Type DWord
Write-Host "Chrome policies applied (no promos, no sign-in, no auto-update)" -ForegroundColor Green

# --- Startup shortcut: this is what actually launches the board at login ---
if (-not $KioskUser) {
    $cs = (Get-CimInstance Win32_ComputerSystem).UserName
    if ($cs) { $KioskUser = ($cs -split '\\')[-1] }
}
if (-not $KioskUser) { throw "No kiosk user - pass -KioskUser (nobody is logged in right now)." }

$startup = "C:\Users\$KioskUser\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup"
if (-not (Test-Path $startup)) { throw "Startup folder not found for '$KioskUser': $startup" }

New-Item -Path $InstallDir -ItemType Directory -Force | Out-Null
$KioskUrl | Out-File -FilePath (Join-Path $InstallDir "kiosk-url.txt") -Encoding UTF8 -Force

# --- Retire any existing board launcher so we do not end up with two ---
# Deliberately narrow: only shortcuts that launch a browser or open a URL are moved,
# and they are MOVED, not deleted. Emptying this folder wholesale would take the remote
# access agent with it, and on a firehouse board that means a site visit.
if ($ClearStartup) {
    $backup = Join-Path $InstallDir ("startup-backup\" + (Get-Date -Format "yyyyMMdd-HHmmss"))
    $wshC   = New-Object -ComObject WScript.Shell
    $moved  = @(); $kept = @()
    foreach ($item in Get-ChildItem $startup -File -ErrorAction SilentlyContinue) {
        if ($item.Name -eq "KioskWatchdog.lnk") { continue }   # ours; the installer rewrites it
        $target = ""; $argline = ""
        if ($item.Extension -eq ".lnk") {
            try { $sc = $wshC.CreateShortcut($item.FullName); $target = $sc.TargetPath; $argline = $sc.Arguments } catch {}
        } else {
            try { $argline = Get-Content $item.FullName -Raw -ErrorAction Stop } catch {}
        }
        $isBrowser = $target -match '(^|\\)(chrome|msedge|firefox|brave|iexplore)\.exe$'
        $hasUrl    = "$target $argline" -match 'https?://'
        if ($isBrowser -or $hasUrl) {
            New-Item -Path $backup -ItemType Directory -Force | Out-Null
            Move-Item $item.FullName -Destination $backup -Force
            $moved += $item.Name
        } else { $kept += $item.Name }
    }
    if ($moved) {
        Write-Host "Retired browser launcher(s): $($moved -join ', ')" -ForegroundColor Yellow
        Write-Host "  backed up to $backup - move them back to undo" -ForegroundColor Yellow
    } else { Write-Host "No existing browser launcher found in Startup" }
    if ($kept) { Write-Host "Left alone: $($kept -join ', ')" }
}

$ourShortcut    = Join-Path $startup "KioskChrome.lnk"
$vendorShortcut = Join-Path $startup "InstallAutoLauncher.cmd"
Remove-Item $ourShortcut, $vendorShortcut -Force -ErrorAction SilentlyContinue

if ($Launcher -eq "chrome") {
    $chromeArgs = (($script:KioskFlags -join " ") + " `"$KioskUrl`"")
    $wsh  = New-Object -ComObject WScript.Shell
    $lnk  = $wsh.CreateShortcut($ourShortcut)
    $lnk.TargetPath       = $chrome
    $lnk.Arguments        = $chromeArgs
    $lnk.WorkingDirectory = Split-Path $chrome
    $lnk.Description      = "Kiosk board"
    $lnk.Save()
    Write-Host "Startup shortcut created for $KioskUser" -ForegroundColor Green
}
else {
    # IamResponding's Auto Login is a Squirrel package: it installs per-user into
    # %LocalAppData% and REFUSES to run elevated ("Please re-run this installer as a
    # normal user instead of Run as Administrator"). We are elevated, so we cannot run
    # it here. Stage it and let the kiosk user's own next logon install it; the helper
    # then deletes itself.
    New-Item -Path $stage -ItemType Directory -Force | Out-Null
    $exe = Join-Path $stage "autolauncher-win.exe"
    Write-Host "Downloading IamResponding Auto Login (~97 MB)..."
    Invoke-WebRequest -Uri $AutoLauncherUrl -OutFile $exe -UseBasicParsing
    Write-Host "  sha256 $((Get-FileHash $exe -Algorithm SHA256).Hash)"

    @"
@echo off
rem One-shot: installs IamResponding Auto Login as this user, then deletes itself.
"$exe" --silent
timeout /t 90 /nobreak >nul
del "%~f0"
"@ | Out-File -FilePath $vendorShortcut -Encoding ASCII -Force

    Write-Host "Auto Login staged; installs at $KioskUser's next logon (Squirrel cannot run elevated)" -ForegroundColor Yellow
    Write-Host "It signs the board in from the browser's saved cookies - never set the browser to clear cookies on exit." -ForegroundColor Yellow
}

# --- Auto-logon (optional) ---
if ($AutoLogonUser) {
    # Windows keeps DefaultPassword in the registry in plaintext. Only do this on a
    # board with no data on it, on a network you control, with a throwaway password.
    $wl = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
    Set-ItemProperty -Path $wl -Name AutoAdminLogon -Value "1"
    Set-ItemProperty -Path $wl -Name DefaultUserName -Value $AutoLogonUser
    Set-ItemProperty -Path $wl -Name DefaultPassword -Value $AutoLogonPassword
    Set-ItemProperty -Path $wl -Name DefaultDomainName -Value $env:COMPUTERNAME
    Remove-ItemProperty -Path $wl -Name AutoLogonCount -ErrorAction SilentlyContinue
    Write-Host "Auto-logon set for $AutoLogonUser (password stored in plaintext by Windows)" -ForegroundColor Yellow
}

# --- Vendor installers (e.g. a board's own launcher app) ---
foreach ($u in $ExtraInstallers) {
    $name = [IO.Path]::GetFileName(([Uri]$u).LocalPath)
    $dst  = Join-Path $env:TEMP $name
    Write-Host "Downloading $name"
    Invoke-WebRequest -Uri $u -OutFile $dst -UseBasicParsing
    if ($name -like "*.msi") {
        $p = Start-Process msiexec.exe -ArgumentList "/i `"$dst`" /qn /norestart" -Wait -PassThru
    } else {
        $p = Start-Process $dst -ArgumentList $ExtraArgs -Wait -PassThru
    }
    Write-Host "  $name exit code $($p.ExitCode)"
    Remove-Item $dst -Force -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "Provisioning complete. Board launches at $KioskUser's next login." -ForegroundColor Green
