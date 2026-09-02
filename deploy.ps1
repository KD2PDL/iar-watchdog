<#
  Kiosk deploy.

  Elevated PowerShell on the board:

    iex (irm https://raw.githubusercontent.com/KD2PDL/iar-watchdog/main/deploy.ps1)

  Runs automatically with sensible defaults. Press M during the countdown for the menu,
  or call it with -Menu. Auto mode never sets auto-logon (that needs a password) - use
  the menu for a machine that has to come back from a power cut on its own.
#>
[CmdletBinding()]
param(
    [string]$Repo       = "https://raw.githubusercontent.com/KD2PDL/iar-watchdog/main",
    [string]$InstallDir = "C:\kiosk-watchdog",
    [string]$DefaultUrl = "https://dashboard.iamresponding.com/",
    [switch]$Menu,
    [int]   $CountdownSeconds = 5
)

$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
        ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Run this from an elevated PowerShell (Run as administrator)."
}

$script:Ver = "1.0"
$W = "White"; $Y = "Yellow"; $G = "Green"; $C = "Cyan"; $R = "Red"

function Rule       { Write-Host "        ______________________________________________________________" }
function SubRule    { Write-Host "               _______________________________________________" }
function Item($k,$t){ Write-Host "               [$k] $t" }
function Fit($v,$max) { if ($v.Length -le $max) { return $v }; return $v.Substring(0, $max - 3) + "..." }
# Values line up in one column whether they are settings or toggles.
function ItemVal($k,$t,$v) { Write-Host "               [$k] $($t.PadRight(21)) [$(Fit $v 32)]" }
function Toggle($k,$t,$on,$val) {
    # MAS renders a non-default toggle in yellow so it stands out against the list.
    Write-Host "               [$k] $($t.PadRight(21)) " -NoNewline
    if ($on) { Write-Host "[$val]" }
    else     { Write-Host "[$val]" -ForegroundColor $Y }
}
function ReadChoice($valid) {
    while ($true) {
        $k = [Console]::ReadKey($true).KeyChar.ToString().ToUpper()
        if ($valid -contains $k) { return $k }
    }
}

# ------------------------------------------------------------------ survey
function Get-State {
    $consoleUser = (Get-CimInstance Win32_ComputerSystem).UserName
    $chrome = @("$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
                "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe") |
              Where-Object { Test-Path $_ } | Select-Object -First 1
    $titles = @(Get-Process -Name chrome -ErrorAction SilentlyContinue |
                Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -ExpandProperty MainWindowTitle)
    $browsers = @(Get-CimInstance Win32_Process -Filter "Name='chrome.exe'" -ErrorAction SilentlyContinue |
                  Where-Object { $_.CommandLine -and $_.CommandLine -notlike "*--type=*" })
    $liveUrl = $null
    foreach ($b in $browsers) { if ($b.CommandLine -match '(https?://[^\s"]+)') { $liveUrl = $Matches[1]; break } }

    $user = if ($consoleUser) { ($consoleUser -split '\\')[-1] } else { $env:USERNAME }
    $startupDir = "C:\Users\$user\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup"
    $startupItems = if (Test-Path $startupDir) { @(Get-ChildItem $startupDir -File | Select-Object -ExpandProperty Name) } else { @() }

    $wer = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting" -Name DontShowUI -ErrorAction SilentlyContinue
    $wl  = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" -ErrorAction SilentlyContinue

    [pscustomobject]@{
        User        = $user
        Chrome      = $chrome
        Titles      = $titles
        LiveUrl     = $liveUrl
        StartupDir  = $startupDir
        Launchers   = @($startupItems | Where-Object { $_ -ne "KioskWatchdog.lnk" })
        Hardened    = ($null -ne $wer -and $wer.DontShowUI -eq 1)
        AutoLogon   = ($wl.AutoAdminLogon -eq "1")
        AutoLogonAs = $wl.DefaultUserName
        Installed   = (Test-Path (Join-Path $InstallDir "watchdog.ps1"))
    }
}

function New-Settings($s) {
    # The legacy def.aspx URL redirects to the marketing home page, so never inherit it.
    $url = if ($s.LiveUrl -and $s.LiveUrl -notmatch 'def\.aspx') { $s.LiveUrl } else { $DefaultUrl }
    $title = "*IaR*"
    if ($s.Titles -and -not ($s.Titles | Where-Object { $_ -like "*IaR*" })) {
        $title = "*" + (($s.Titles[0] -split ' - ')[0]) + "*"
    }
    [pscustomobject]@{
        Url          = $url
        Title        = $title
        KioskUser    = $s.User
        Provision    = $true
        ClearStartup = [bool]$s.Launchers
        Harden       = (-not $s.Hardened)
        AutoLogon    = $false
        AutoLogonPwd = ""
        Debloat      = $false
    }
}

# ------------------------------------------------------------------ run
function Invoke-Deploy($set) {
    $a = @{ Repo = $Repo; InstallDir = $InstallDir; KioskTitle = $set.Title; KioskUrl = $set.Url }
    if ($set.Provision)    { $a.Provision = $true; $a.Launcher = "chrome"; $a.KioskUser = $set.KioskUser }
    if ($set.ClearStartup) { $a.ClearStartup = $true }
    if (-not $set.Harden)  { $a.SkipHarden = $true }
    if ($set.Debloat)      { $a.Debloat = $true }
    if ($set.AutoLogon -and $set.AutoLogonPwd) {
        $a.AutoLogonUser = $set.KioskUser; $a.AutoLogonPassword = $set.AutoLogonPwd
    }
    & ([scriptblock]::Create((irm "$Repo/bootstrap.ps1"))) @a

    $log = Join-Path $InstallDir "watchdog.log"
    Write-Host ""
    Write-Host "Waiting up to 150s for the watchdog's first healthy heartbeat..." -ForegroundColor $C
    $ok = $false
    for ($i = 0; $i -lt 30; $i++) {
        Start-Sleep -Seconds 5
        if (Test-Path $log) {
            $tail = Get-Content $log -Tail 5 -ErrorAction SilentlyContinue
            if ($tail -match 'kiosk window active|RELAUNCHED|CLOSED') { $ok = $true; break }
        }
        Write-Host "." -NoNewline
    }
    Write-Host ""
    if ($ok) { Write-Host "Watchdog is healthy:" -ForegroundColor $G; Get-Content $log -Tail 5 }
    else {
        Write-Host "No heartbeat yet - expected if this ran from a different session than the board;" -ForegroundColor $Y
        Write-Host "it starts at the kiosk user's next login. Otherwise: Get-Content $log -Tail 20" -ForegroundColor $Y
    }
    if (-not $set.AutoLogon -and $set.Provision) {
        Write-Host ""
        Write-Host "Auto-logon NOT set. Confirm $($set.KioskUser) logs in by itself, or the board" -ForegroundColor $Y
        Write-Host "comes back from a reboot sitting on the lock screen. Menu option [8] sets it." -ForegroundColor $Y
    }
}

# ------------------------------------------------------------------ menu
function Show-Menu($set) {
    while ($true) {
        $s = Get-State
        Clear-Host
        try { $Host.UI.RawUI.WindowSize = New-Object Management.Automation.Host.Size(78, 32) } catch {}
        $Host.UI.RawUI.WindowTitle = "Kiosk Deploy $($script:Ver)"
        Write-Host ""
        Write-Host "                        Kiosk Deploy $($script:Ver)" -ForegroundColor $C
        Write-Host ""
        Write-Host "        $($env:COMPUTERNAME)  |  board account: $($set.KioskUser)"
        if ($s.Titles) { Write-Host "        board window: $($s.Titles -join ' | ')" }
        else           { Write-Host "        board window: none visible from this session" -ForegroundColor $Y }
        Rule
        Write-Host ""
        Item 1 "Deploy Kiosk  (everything set below)"
        Item 2 "Install Watchdog Only"
        Item 3 "Harden Windows Only"
        Item 4 "Set Up IamResponding Auto Login"
        SubRule
        Write-Host ""
        ItemVal 5 "Board URL"    $set.Url
        ItemVal 6 "Window Title" $set.Title
        ItemVal 7 "Board Account" $set.KioskUser
        Toggle 8 "Set Auto-Logon"        $set.AutoLogon    $(if ($set.AutoLogon) { "Yes" } else { "No" })
        Toggle 9 "Retire Old Launchers"  $set.ClearStartup $(if ($set.ClearStartup) { "Yes" } else { "No" })
        Toggle H "Harden Windows"        $set.Harden       $(if ($set.Harden) { "Yes" } else { "No" })
        Toggle D "Debloat Windows"       $set.Debloat      $(if ($set.Debloat) { "Yes" } else { "No" })
        SubRule
        Write-Host ""
        Item T "Test Watchdog"
        Item L "View Watchdog Log"
        Item 0 "Exit"
        Rule
        Write-Host ""
        Write-Host "       " -NoNewline
        Write-Host "Choose a menu option using your keyboard [1,2,3,4,5,6,7,8,9,H,D,T,L,0]" -ForegroundColor $G

        switch (ReadChoice @('1','2','3','4','5','6','7','8','9','H','D','T','L','0')) {
            '1' { Clear-Host; Invoke-Deploy $set; Write-Host ""; Write-Host "Press any key..." -ForegroundColor $G; [void][Console]::ReadKey($true) }
            '2' { Clear-Host
                  $t = $set.PSObject.Copy(); $t.Provision = $false; $t.Harden = $false; $t.ClearStartup = $false
                  Invoke-Deploy $t; Write-Host ""; Write-Host "Press any key..." -ForegroundColor $G; [void][Console]::ReadKey($true) }
            '3' { Clear-Host; & ([scriptblock]::Create((irm "$Repo/kiosk-harden.ps1")))
                  Write-Host ""; Write-Host "Press any key..." -ForegroundColor $G; [void][Console]::ReadKey($true) }
            '4' { Clear-Host
                  Write-Host "The IamResponding Auto Login installer is a Squirrel package and refuses to" -ForegroundColor $Y
                  Write-Host "run elevated. Run this in a NORMAL PowerShell as $($set.KioskUser):" -ForegroundColor $Y
                  Write-Host ""
                  Write-Host "  `$s = irm $Repo/autolauncher-setup.ps1"
                  Write-Host "  & ([scriptblock]::Create(`$s))"
                  Write-Host ""
                  Write-Host "Note it navigates to the legacy def.aspx URL, not the dashboard." -ForegroundColor $Y
                  Write-Host "Press any key..." -ForegroundColor $G; [void][Console]::ReadKey($true) }
            '5' { Write-Host ""; $v = Read-Host "       Board URL"; if ($v) { $set.Url = $v.Trim() } }
            '6' { Write-Host ""; $v = Read-Host "       Window title to protect (wildcards ok)"; if ($v) { $set.Title = $v.Trim() } }
            '7' { Write-Host ""; $v = Read-Host "       Board account"; if ($v) { $set.KioskUser = $v.Trim() } }
            '8' { if ($set.AutoLogon) { $set.AutoLogon = $false; $set.AutoLogonPwd = "" }
                  else {
                      Write-Host ""
                      Write-Host "       Windows stores this in the registry in PLAINTEXT." -ForegroundColor $Y
                      Write-Host "       Use the board account's own password; it should hold nothing else." -ForegroundColor $Y
                      $sec = Read-Host "       Password for $($set.KioskUser)" -AsSecureString
                      $pw  = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
                             [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))
                      if ($pw) { $set.AutoLogonPwd = $pw; $set.AutoLogon = $true }
                  } }
            '9' { $set.ClearStartup = -not $set.ClearStartup }
            'H' { $set.Harden = -not $set.Harden }
            'D' { if ($set.Debloat) { $set.Debloat = $false }
                  else {
                      Clear-Host
                      Write-Host ""
                      Write-Host "  Win11Debloat (Raphire, MIT) - third-party, pinned to a known release." -ForegroundColor $C
                      Write-Host ""
                      Write-Host "  Permanently removes ~84 preinstalled apps upstream marks 'safe': Candy Crush,"
                      Write-Host "  every Bing app, Copilot, Solitaire, Teams, Xbox, Netflix, Spotify, TikTok and"
                      Write-Host "  the rest of the shovelware. Also turns off telemetry, Bing web results in"
                      Write-Host "  Start, lock-screen tips and Spotlight."
                      Write-Host ""
                      Write-Host "  It does NOT remove Edge, OneDrive, Snipping Tool or Remote Desktop, and this"
                      Write-Host "  wrapper does not pass -ForceRemoveEdge or any Windows Update changes."
                      Write-Host ""
                      Write-Host "  A system restore point is taken first. There is no undo beyond that." -ForegroundColor $Y
                      Write-Host ""
                      Write-Host "  Enable it? [Y/N]" -ForegroundColor $G
                      if ((ReadChoice @('Y','N')) -eq 'Y') { $set.Debloat = $true }
                  } }
            'T' { Clear-Host
                  $t = Join-Path $InstallDir "bin\watchdog-test.ps1"
                  if (Test-Path $t) { & $t -InstallDir $InstallDir -KioskTitle $set.Title }
                  else { Write-Host "Not installed yet - run [1] or [2] first." -ForegroundColor $Y }
                  Write-Host ""; Write-Host "Press any key..." -ForegroundColor $G; [void][Console]::ReadKey($true) }
            'L' { Clear-Host
                  $log = Join-Path $InstallDir "watchdog.log"
                  if (Test-Path $log) { Get-Content $log -Tail 30 } else { Write-Host "No log yet." -ForegroundColor $Y }
                  Write-Host ""; Write-Host "Press any key..." -ForegroundColor $G; [void][Console]::ReadKey($true) }
            '0' { return }
        }
    }
}

# ------------------------------------------------------------------ entry
$state    = Get-State
$settings = New-Settings $state

if (-not $Menu) {
    Write-Host ""
    Write-Host "  Kiosk Deploy $($script:Ver)  -  $($env:COMPUTERNAME)" -ForegroundColor $C
    Write-Host ""
    Write-Host "  Board account : $($settings.KioskUser)"
    Write-Host "  Board URL     : $($settings.Url)"
    Write-Host "  Protect title : $($settings.Title)"
    Write-Host "  Chrome        : $(if($state.Chrome){'installed'}else{'will be installed'})"
    Write-Host "  Harden        : $(if($settings.Harden){'yes'}else{'already done, skipping'})"
    Write-Host "  Debloat       : no - press M, then D, to add it"
    Write-Host "  Retire        : $(if($settings.ClearStartup){$state.Launchers -join ', '}else{'nothing to retire'})"
    Write-Host "  Auto-logon    : $(if($state.AutoLogon){"already on as $($state.AutoLogonAs)"}else{'not set - press M to set it'})"
    Write-Host ""
    $canPrompt = $true
    try { $null = [Console]::KeyAvailable } catch { $canPrompt = $false }
    if ($canPrompt) {
        for ($i = $CountdownSeconds; $i -gt 0; $i--) {
            Write-Host "`r  Starting in $i s - press M for the menu, X to cancel...  " -NoNewline -ForegroundColor $G
            $t0 = Get-Date
            while (((Get-Date) - $t0).TotalMilliseconds -lt 1000) {
                if ([Console]::KeyAvailable) {
                    $k = [Console]::ReadKey($true).KeyChar.ToString().ToUpper()
                    if ($k -eq 'M') { Write-Host ""; Show-Menu $settings; return }
                    if ($k -eq 'X') { Write-Host "`nCancelled. Nothing changed."; return }
                }
                Start-Sleep -Milliseconds 50
            }
        }
        Write-Host ""
    }
    Write-Host ""
    Invoke-Deploy $settings
    return
}

Show-Menu $settings
