# Kiosk Hardening
# Removes the things that paint over the board. Run as Administrator/SYSTEM, once, before the watchdog installer.

# --- Teams: New Teams is an MSIX; removing the package removes its startup task too. ---
Get-Process -Name ms-teams,Teams -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Get-AppxPackage -AllUsers *MSTeams* -ErrorAction SilentlyContinue | ForEach-Object {
    Write-Host "Removing appx $($_.Name)"
    Remove-AppxPackage -Package $_.PackageFullName -AllUsers -ErrorAction SilentlyContinue
}
Get-AppxProvisionedPackage -Online | Where-Object DisplayName -like "*MSTeams*" | ForEach-Object {
    Write-Host "Removing provisioned $($_.DisplayName)"
    Remove-AppxProvisionedPackage -Online -PackageName $_.PackageName -ErrorAction SilentlyContinue
}
# Legacy/classic Teams installer, if this box ever had it
Get-ChildItem "C:\Users\*\AppData\Local\Microsoft\Teams\Update.exe" -ErrorAction SilentlyContinue | ForEach-Object {
    Write-Host "Uninstalling classic Teams for $($_.FullName)"
    & $_.FullName --uninstall -s
}

# --- Google Update: the original rogue-window cause on the NWP kiosk ---
foreach ($svc in "gupdate","gupdatem","GoogleChromeElevationService") {
    $s = Get-Service -Name $svc -ErrorAction SilentlyContinue
    if ($s) {
        Stop-Service $svc -Force -ErrorAction SilentlyContinue
        Set-Service  $svc -StartupType Disabled
        Write-Host "Disabled service $svc"
    }
}
Get-ScheduledTask -TaskName "GoogleUpdate*" -ErrorAction SilentlyContinue | ForEach-Object {
    Disable-ScheduledTask -TaskName $_.TaskName -TaskPath $_.TaskPath | Out-Null
    Write-Host "Disabled task $($_.TaskName)"
}

# --- Machine-wide toast/notification suppression so nothing else slides over the board ---
$np = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer"
New-Item -Path $np -Force | Out-Null
Set-ItemProperty -Path $np -Name DisableNotificationCenter -Value 1 -Type DWord
$cc = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent"
New-Item -Path $cc -Force | Out-Null
Set-ItemProperty -Path $cc -Name DisableWindowsConsumerFeatures  -Value 1 -Type DWord   # no Store app auto-installs
Set-ItemProperty -Path $cc -Name DisableSoftLanding              -Value 1 -Type DWord   # no "tips" popups
Write-Host "Notification centre + consumer features disabled"

# --- Windows Error Reporting: keep the logging, lose the dialog ---
# A crash dialog sitting on a firehouse board is the failure. DontShowUI + a standing
# consent stop the popup and the "check for a solution" prompt; kernel dumps,
# System/1001 BugCheck events and WHEA-Logger are unaffected by these keys.
$wer = "HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting"
New-Item -Path $wer -Force | Out-Null
Set-ItemProperty -Path $wer -Name DontShowUI -Value 1 -Type DWord
New-Item -Path "$wer\Consent" -Force | Out-Null
Set-ItemProperty -Path "$wer\Consent" -Name DefaultConsent -Value 1 -Type DWord
foreach ($q in "$env:ProgramData\Microsoft\Windows\WER\ReportQueue",
               "$env:ProgramData\Microsoft\Windows\WER\ReportArchive") {
    if (Test-Path $q) {
        $n = (Get-ChildItem $q -ErrorAction SilentlyContinue).Count
        Get-ChildItem $q -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "Cleared $n queued WER report(s) from $(Split-Path $q -Leaf)"
    }
}
# Suppress hard-error dialogs (missing DLL, disk not ready) the same way.
Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Windows" -Name ErrorMode -Value 2 -Type DWord
Write-Host "Error dialogs suppressed (logging intact)"

# --- Never sleep or blank the display ---
powercfg /change standby-timeout-ac 0
powercfg /change monitor-timeout-ac 0
powercfg /change hibernate-timeout-ac 0
Write-Host "Sleep/display timeouts disabled"

Write-Host ""
Write-Host "Hardening complete. Some of it (Teams removal, notification policy) only fully takes effect after a reboot." -ForegroundColor Green
