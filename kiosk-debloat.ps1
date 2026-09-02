<#
  Optional: run Raphire/Win11Debloat with a flag set chosen for display kiosks.
  https://github.com/Raphire/Win11Debloat  (MIT)

  This runs third-party code that permanently removes ~84 preinstalled apps and changes
  privacy/telemetry settings, so it is opt-in and pinned to a known release rather than
  floating on "latest". A system restore point is taken first unless you skip it.
#>
param(
    [string]  $KioskUser        = "",            # HKCU tweaks are applied to this user
    [string]  $Version          = "2026.08.24",  # pinned; "latest" floats with upstream
    [switch]  $SkipRestorePoint,
    [string[]]$ExtraArgs        = @(),           # anything else to pass through
    [string]  $InstallDir       = "C:\kiosk-watchdog"
)

$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$url = if ($Version -eq "latest") {
    "https://github.com/Raphire/Win11Debloat/releases/latest/download/Get.ps1"
} else {
    "https://github.com/Raphire/Win11Debloat/releases/download/$Version/Get.ps1"
}

$bin = Join-Path $InstallDir "bin"
New-Item -Path $bin -ItemType Directory -Force | Out-Null
$get = Join-Path $bin "Win11Debloat-Get.ps1"

Write-Host "Fetching Win11Debloat $Version"
Invoke-WebRequest -Uri $url -OutFile $get -UseBasicParsing
Write-Host "  sha256 $((Get-FileHash $get -Algorithm SHA256).Hash)"

if (-not $KioskUser) {
    $cs = (Get-CimInstance Win32_ComputerSystem).UserName
    if ($cs) { $KioskUser = ($cs -split '\\')[-1] }
}

# Every flag below is verified present in the pinned release's param block. Passing one
# that does not exist would fail the whole run, so re-check after bumping $Version.
$flags = @(
    "-Silent"                        # no prompts
    "-RemoveApps"                    # the 84 apps marked "safe" upstream (Candy Crush, Bing *, Copilot, Teams, ...)
    "-RemoveGamingApps"              # Xbox
    "-DisableTelemetry"
    "-DisableBing"                   # no web results in Start search
    "-DisableSuggestions"
    "-DisableLockscreenTips"
    "-DisableDesktopSpotlight"       # no rotating lock screen images
    "-DisableSettings365Ads"
    "-DisableStoreSearchSuggestions"
    "-DisableSearchHighlights"
    "-DisableSearchHistory"
    "-DisableDeviceAutoAppDownload"  # stop Windows reinstalling what we just removed
    "-SkipExplorerRestart"           # we are about to reboot anyway; do not blink the board
)
if (-not $SkipRestorePoint) { $flags += "-CreateRestorePoint" }
if ($KioskUser)             { $flags += @("-User", $KioskUser) }
$flags += $ExtraArgs

# Deliberately NOT passed: -ForceRemoveEdge, -DisableFastStartup, -DisableUpdateASAP,
# -RunDefaults. Edge removal and Windows Update changes are not something to do silently
# on a client's board, and -RunDefaults also rewrites taskbar/Explorer layout we do not
# care about on a machine nobody logs into.

Write-Host "Running: Get.ps1 $($flags -join ' ')"
& $get @flags

Write-Host ""
Write-Host "Debloat complete. A reboot is needed before the removals fully settle." -ForegroundColor Green
if (-not $SkipRestorePoint) { Write-Host "A restore point was requested first (System Protection must be on for it to exist)." }
