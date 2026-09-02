<#
  TV watchdog - keeps the television showing the board.

  The Chrome watchdog guards the picture the PC sends. This guards the screen that
  shows it: a TV that has switched itself off, drifted to another input, or drawn its
  own screensaver over a perfectly healthy signal looks identical to a dead board from
  the room, and identical to a healthy one from every monitoring tool.

  Roku today. Amazon Fire TV needs ADB and is not wired up yet.

    $s = irm https://raw.githubusercontent.com/KD2PDL/iar-watchdog/main/tv-watchdog-install.ps1
    & ([scriptblock]::Create($s)) -TvAddress 192.168.1.50
#>
[CmdletBinding()]
param(
    [string]$TvAddress,                       # bare IP or full http:// URL
    [ValidateSet("roku")]
    [string]$TvKind      = "roku",
    [string]$TvInput     = "tvinput.hdmi1",
    [int]   $IntervalMin = 5,
    [string]$InstallDir  = "C:\kiosk-watchdog",
    [string]$TaskName    = "IaR TV Watchdog",
    [switch]$Uninstall,
    [switch]$Status,
    [switch]$Discover,
    [switch]$Inputs,
    [string]$Subnet
)

$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$Y = "Yellow"; $G = "Green"; $C = "Cyan"

function Resolve-Ecp($a) {
    if (-not $a) { return $null }
    if ($a -notmatch '^https?://') { $a = "http://$a" }
    if ($a -notmatch ':\d+$')      { $a = "${a}:8060" }
    return $a
}

# ------------------------------------------------------------------ discovery
# Roku answers SSDP M-SEARCH on 239.255.255.250:1900 with its ECP base in LOCATION.
function Find-Roku {
    $found = @{}
    $msg = "M-SEARCH * HTTP/1.1`r`nHost: 239.255.255.250:1900`r`nMan: `"ssdp:discover`"`r`nST: roku:ecp`r`nMX: 3`r`n`r`n"
    $bytes = [Text.Encoding]::ASCII.GetBytes($msg)
    $udp = New-Object Net.Sockets.UdpClient
    try {
        $udp.Client.ReceiveTimeout = 4000
        $ep = New-Object Net.IPEndPoint([Net.IPAddress]::Parse("239.255.255.250"), 1900)
        [void]$udp.Send($bytes, $bytes.Length, $ep)
        $from = New-Object Net.IPEndPoint([Net.IPAddress]::Any, 0)
        $deadline = (Get-Date).AddSeconds(4)
        while ((Get-Date) -lt $deadline) {
            try   { $resp = [Text.Encoding]::ASCII.GetString($udp.Receive([ref]$from)) }
            catch { break }
            if ($resp -match 'LOCATION:\s*(http://[\d\.]+:\d+)') { $found[$Matches[1]] = $true }
        }
    } finally { $udp.Close() }

    # SSDP is one packet and instant, but plenty of managed switches filter multicast
    # and it never crosses a VPN. Fall back to knocking on 8060 across the local /24.
    if (-not $found.Count) {
        $net = $Subnet
        if (-not $net) {
            $local = [Net.Dns]::GetHostAddresses([Net.Dns]::GetHostName()) |
                     Where-Object { $_.AddressFamily -eq 'InterNetwork' -and $_.ToString() -notlike '127.*' } |
                     Select-Object -First 1
            if ($local) { $net = ($local.ToString() -split '\.')[0..2] -join '.' }
        }
        if ($net) {
            Write-Verbose "SSDP found nothing; sweeping $net.0/24 on 8060"
            $pend = @{}
            foreach ($i in 1..254) {
                $c = New-Object Net.Sockets.TcpClient
                try { [void]$c.BeginConnect("$net.$i", 8060, $null, $null); $pend["$net.$i"] = $c }
                catch { $c.Close() }
            }
            Start-Sleep -Milliseconds 900
            foreach ($ip in $pend.Keys) {
                if ($pend[$ip].Connected) { $found["http://${ip}:8060"] = $true }
                $pend[$ip].Close()
            }
        }
    }

    foreach ($base in $found.Keys) {
        $name = "(unnamed)"; $model = ""
        try {
            $i = (Invoke-RestMethod -Uri "$base/query/device-info" -TimeoutSec 4).'device-info'
            $name = $i.'user-device-name'; $model = $i.'model-name'
        } catch {}
        [pscustomobject]@{ Address = ([Uri]$base).Host; Name = $name; Model = $model; Base = $base }
    }
}

# ------------------------------------------------------------------ status
function Get-TvStatus($base) {
    $i = (Invoke-RestMethod -Uri "$base/query/device-info" -TimeoutSec 5).'device-info'
    $app = (Invoke-RestMethod -Uri "$base/query/active-app" -TimeoutSec 5).'active-app'.app
    $saver = try { (Invoke-RestMethod -Uri "$base/query/screensavers" -TimeoutSec 5).screensavers.screensaver |
                   Where-Object { $_.selected -eq 'true' } | Select-Object -ExpandProperty '#text' } catch { $null }
    [pscustomobject]@{
        Name        = $i.'user-device-name'
        Model       = $i.'model-name'
        Power       = $i.'power-mode'
        Input       = $app.'ui-location'
        InputLabel  = $app.'#text'
        Network     = $i.'network-type'
        Screensaver = $saver
    }
}

# The TV reports its own inputs, so nobody has to guess which HDMI the PC is on.
function Get-TvInputs($base) {
    (Invoke-RestMethod -Uri "$base/query/apps" -TimeoutSec 6).apps.app |
        Where-Object { $_.type -eq 'tvin' } |
        ForEach-Object { [pscustomobject]@{ Id = $_.id; Label = $_.'#text' } }
}

if ($Discover) { return @(Find-Roku) }

if ($Inputs) {
    if (-not $TvAddress) { throw "-Inputs needs -TvAddress." }
    return @(Get-TvInputs (Resolve-Ecp $TvAddress))
}

$base = Resolve-Ecp $TvAddress

if ($Status) {
    if (-not $base) { throw "-Status needs -TvAddress." }
    return (Get-TvStatus $base)
}

# ------------------------------------------------------------------ uninstall
if ($Uninstall) {
    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-Host "  Removed scheduled task '$TaskName'." -ForegroundColor $G
    } else { Write-Host "  No scheduled task '$TaskName'." -ForegroundColor $Y }
    $s = Join-Path $InstallDir "tv-watchdog.ps1"
    if (Test-Path $s) { Remove-Item $s -Force; Write-Host "  Removed $s (log kept)." -ForegroundColor $G }
    return
}

# ------------------------------------------------------------------ install
if (-not $TvAddress) { throw "Need -TvAddress (or -Discover to find one)." }

# Same guard as the Chrome watchdog: prove the target is real before installing
# something that will poke it every five minutes forever.
try { $st = Get-TvStatus $base }
catch { throw "No Roku ECP response at $base. Check the address, and that the TV is on the network." }

Write-Host ""
Write-Host "  $($st.Name)  ($($st.Model))" -ForegroundColor $C
Write-Host "  power $($st.Power)   input $($st.Input)   network $($st.Network)"
if ($st.Screensaver) { Write-Host "  screensaver: $($st.Screensaver)" -ForegroundColor $Y }
if ($st.Network -eq 'wifi') {
    Write-Host "  TV is on Wi-Fi. The watchdog can only reach it while it is on the" -ForegroundColor $Y
    Write-Host "  network, so a dropout is the one fault this cannot correct." -ForegroundColor $Y
}

New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
$script = Join-Path $InstallDir "tv-watchdog.ps1"
$log    = Join-Path $InstallDir "tv-watchdog.log"

Set-Content -Path $script -Encoding UTF8 -Value @'
param(
    [Parameter(Mandatory)][string]$Roku,
    [string]$Src = 'tvinput.hdmi1',
    [string]$Log,
    [int]$Keep = 2000
)

# $PSScriptRoot is empty while param defaults are evaluated under -File; resolve it here.
if (-not $Log) { $Log = Join-Path (Split-Path -Parent $PSCommandPath) 'tv-watchdog.log' }

if ($Roku -notmatch '^https?://') { $Roku = "http://$Roku" }
if ($Roku -notmatch ':\d+$')      { $Roku = "${Roku}:8060" }

function Note($m) { "{0:yyyy-MM-dd HH:mm:ss}  {1}" -f (Get-Date), $m | Add-Content -Path $Log }
function Post($p) { Invoke-RestMethod -Method Post -Uri "$Roku/$p" -TimeoutSec 5 | Out-Null }

try {
    $power = (Invoke-RestMethod -Uri "$Roku/query/device-info" -TimeoutSec 5).'device-info'.'power-mode'
    $app   = (Invoke-RestMethod -Uri "$Roku/query/active-app"  -TimeoutSec 5).'active-app'.app.'ui-location'
} catch {
    Note "UNREACHABLE  $Roku  $($_.Exception.Message)"
    exit 1
}

$act = @()
if ($power -ne 'PowerOn') { $act += 'WAKE'; Post 'keypress/PowerOn'; Start-Sleep -Seconds 5 }
if ($app   -ne $Src)      { $act += 'INPUT' }

# Unconditional: a screensaver still reports PowerOn on the right input, so status
# alone cannot see it. Relaunching the input we are already on dismisses it and is
# otherwise a no-op.
Post "launch/$Src"

$tag = if ($act) { $act -join '+' } else { 'ok' }
Note "$tag  power=$power input=$app"

if ((Test-Path $Log) -and (Get-Item $Log).Length -gt 1MB) {
    Set-Content $Log -Value (Get-Content $Log -Tail $Keep)
}
'@

$arg = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$script`" " +
       "-Roku $TvAddress -Src $TvInput -Log `"$log`""
$a = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $arg
$t = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes $IntervalMin)
$s = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -StartWhenAvailable `
     -ExecutionTimeLimit (New-TimeSpan -Minutes 2) -AllowStartIfOnBatteries
Register-ScheduledTask -TaskName $TaskName -Action $a -Trigger $t -Settings $s `
     -User "SYSTEM" -RunLevel Highest -Force | Out-Null

Start-ScheduledTask -TaskName $TaskName
Start-Sleep -Seconds 8
Write-Host ""
if (Test-Path $log) {
    Write-Host "  TV watchdog installed, every $IntervalMin min as SYSTEM:" -ForegroundColor $G
    Get-Content $log -Tail 3
} else {
    Write-Host "  Installed, but no log line yet. Check:" -ForegroundColor $Y
    Write-Host "    schtasks /Query /TN `"$TaskName`" /V /FO LIST" -ForegroundColor $Y
}
