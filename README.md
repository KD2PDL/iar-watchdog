# IaR Watchdog

Takes a Windows box to a working, unattended [IamResponding](https://iamresponding.com)
status board — installs Chrome, launches the dashboard at login, hides everything Windows
and Chrome would otherwise put on top of it, and puts the board back when something covers
it or kills it.

## New machine: one line

Elevated PowerShell on the box:

```powershell
iex (irm https://raw.githubusercontent.com/KD2PDL/iar-watchdog/main/deploy.ps1)
```

It surveys the machine (Chrome present? board running? what's in Startup? already
hardened?), prints what it decided, counts down five seconds, and **runs on its own** —
installing Chrome if needed, retiring an existing launcher, writing the Startup shortcut,
hardening, installing the watchdog, then waiting for the watchdog's first healthy
heartbeat before claiming success.

Press **M** during the countdown (or pass `-Menu`) for the menu; **X** cancels.

```
        ______________________________________________________________

               [1] Deploy Kiosk  (everything set below)
               [2] Install Watchdog Only
               [3] Harden Windows Only
               [4] Set Up IamResponding Auto Login
               _______________________________________________

               [5] Board URL             [https://dashboard.iamrespo...]
               [6] Window Title          [*IaR*]
               [7] Board Account         [Gear Room IAR]
               [8] Set Auto-Logon        [No]
               [9] Retire Old Launchers  [Yes]
               [H] Harden Windows        [No]
               _______________________________________________

               [T] Test Watchdog
               [L] View Watchdog Log
               [0] Exit
        ______________________________________________________________

       Choose a menu option using your keyboard [1,2,3,4,5,6,7,8,9,H,T,L,0]
```

Settings persist while the menu is open, so you can flip a couple of toggles and then
run `[1]`. The one thing auto mode will not do is set **auto-logon**, because that needs a
password — use `[8]`. Without it a new box comes back from its first reboot on the lock
screen with a dark display, so the auto run says so at the end.

The scripted forms below are still there for RMM jobs and for re-running one piece.

## One command

**Existing kiosk** — add hardening + the watchdog. Run elevated (Administrator
PowerShell, or an RMM script as SYSTEM):

```powershell
iex (irm https://raw.githubusercontent.com/KD2PDL/iar-watchdog/main/bootstrap.ps1)
```

**Bare Windows box** — full build. `iex (irm ...)` cannot take arguments, so fetch the
script and call it as a scriptblock:

```powershell
$b = irm https://raw.githubusercontent.com/KD2PDL/iar-watchdog/main/bootstrap.ps1
& ([scriptblock]::Create($b)) -Provision -KioskUrl "https://auth.iamresponding.com/login/autolauncher/redirect?token=..."
```

Silent either way; full transcript in `C:\kiosk-watchdog\bootstrap.log`.

| Parameter | Default | Meaning |
| --- | --- | --- |
| `-KioskTitle` | `*IaR*` | Window title that identifies the legitimate board. **Set this per board.** |
| `-KioskUrl` | *(discovered)* | The board. Blank = read off the running `--kiosk` Chrome, else `kiosk-url.txt`. Required with `-Provision` |
| `-ChromeExe` | *(found)* | Only needed for a non-standard install path |
| `-KillProcs` | `ms-teams,Teams,OneDrive` | Killed on sight every cycle |
| `-Provision` | off | Bare-metal build: install Chrome, set policies, create the Startup shortcut |
| `-KioskUser` | *(logged-in user)* | Whose Startup folder the board and watchdog go in |
| `-Launcher` | `chrome` | What opens the board at login: `chrome` (our Startup shortcut) or `iar` (IamResponding's Auto Login program). Never both |
| `-ClearStartup` | off | Retire an existing board launcher first: browser-launching Startup items are **moved** to `startup-backup\<timestamp>`, everything else is listed and left alone |
| `-AutoLogonUser` / `-AutoLogonPassword` | — | Winlogon auto-logon. **Windows stores the password in the registry in plaintext** |
| `-ExtraInstallers` | — | URLs of vendor installers to run silently during provisioning |
| `-SkipHarden` | off | Skip the Teams/Google-Update/notification/WER suppression |
| `-InstallDir` | `C:\kiosk-watchdog` | |
| `-Reboot` | off | Reboot when done. **Only if the board auto-logs-in** |

### Board URL and window title

The board lives at `https://dashboard.iamresponding.com/`, whose window title is
`IaR Dashboard - Google Chrome` — so the default `-KioskTitle` of `*IaR*` matches. The
older `www.iamresponding.com/v3/agency/def.aspx` URL now redirects an unauthenticated
session to the marketing home page, so do not inherit it from an existing shortcut.

To confirm the title on a board that is already up:

```powershell
Get-Process chrome | Where-Object MainWindowHandle -ne 0 | Select-Object Id, MainWindowTitle
```

## Setting up the IamResponding Auto Login app

Its first-run window wants agency name, username, password, browser, a kiosk toggle and
terms acceptance, and there are no switches for any of that — `--silent` only suppresses
Squirrel's installer UI. So it is a one-time attended step **per department**, not per
machine. Run this on the first board, in a **normal (not elevated) PowerShell, signed in
as the kiosk user** — Squirrel refuses to run as administrator:

```powershell
$s = irm https://raw.githubusercontent.com/KD2PDL/iar-watchdog/main/autolauncher-setup.ps1
& ([scriptblock]::Create($s))
```

It installs the app, opens it, waits while you fill in the form, and once the app writes
its config and launches the browser it copies `launch_data.txt` / `terms.txt` to
`C:\kiosk-watchdog\autolauncher-config\` and prints the browser command line and window
title — which is what you feed the watchdog as `-KioskTitle`. Those captured files can be
dropped onto that department's other boards instead of retyping the form.

**They encode the agency's IamResponding username and password.** Same department only,
never a repo; `.gitignore` blocks them here.

## What the scripts do

**`kiosk-provision.ps1`** — bare box to kiosk:

- Installs Chrome from Google's enterprise MSI if it isn't already there
- Chrome policies: no promo tab after an update, no "make Chrome default", no sign-in
  or sync prompts, no save-password bubble, no background mode, no auto-update
- `KioskChrome.lnk` in the kiosk user's Startup folder — this is what launches the board
- Optional Winlogon auto-logon, and optional vendor installers by URL

`-ClearStartup` exists because a box that already has a board launcher will otherwise end
up with two, and the watchdog will close one of them. It is deliberately narrow: only
shortcuts that launch a browser or open a URL are touched, they are moved rather than
deleted, and everything else is listed and left in place. Emptying that folder wholesale
would take the remote-access agent with it, and on a firehouse board that means a site
visit. `test-startup-classifier.ps1` covers the classifier against real Startup entries.

With `-Launcher iar` it installs [IamResponding's Auto Login
program](https://support.iamresponding.com/hc/en-us/articles/41236776699668-Auto-Login-Programs)
(`download.iamresponding.com/autolauncher/autolauncher-win.exe`) instead of creating our
own shortcut. That installer is a **Squirrel** package: it installs per-user into
`%LocalAppData%` and refuses to run elevated, so provisioning cannot run it directly —
it stages the exe and drops a one-shot `InstallAutoLauncher.cmd` in the kiosk user's
Startup folder, which installs it silently at that user's next logon and then deletes
itself. The vendor program signs in from the browser's **saved cookies**, so never set
the browser to clear cookies on exit. Pick one launcher or the other: two launchers
means two browser windows, and the watchdog will close one of them.

**`kiosk-debloat.ps1`** — **opt-in**, off by default. Wraps
[Raphire/Win11Debloat](https://github.com/Raphire/Win11Debloat) (MIT) with a flag set
chosen for display kiosks, pinned to a known upstream release rather than floating on
`latest`. Enable with `[D]` in the menu or `-Debloat` on the bootstrap.

It permanently removes the ~84 preinstalled apps upstream marks `safe` — Candy Crush,
every Bing app, Copilot, Solitaire, Teams, Xbox, Netflix, Spotify, TikTok and the rest of
the shovelware — and turns off telemetry, Bing web results in Start, lock-screen tips and
Spotlight. It takes a system restore point first.

Deliberately **not** passed: `-ForceRemoveEdge`, `-DisableFastStartup`,
`-DisableUpdateASAP`, `-RunDefaults`. Removing Edge or changing Windows Update silently on
a client's machine is not a thing to do from a deploy script, and `-RunDefaults` also
rewrites taskbar and Explorer layout that nobody sees on a board. Upstream's defaults
already leave Edge, OneDrive, Snipping Tool and Remote Desktop alone.

Every flag it passes is verified against the pinned release's parameter block — passing
one that does not exist would fail the run, so re-check after bumping the version.

**`kiosk-harden.ps1`** — removes the things that paint over a board:

- Uninstalls Teams (MSIX + provisioned package, so a Store refresh can't bring it back) and classic Teams
- Disables Google Update services and scheduled tasks
- Notification Center, consumer-feature auto-installs and "soft landing" tips off
- **Windows Error Reporting dialogs suppressed without losing logging** — `DontShowUI=1`
  plus a standing `DefaultConsent`, WER queues cleared, and `ErrorMode=2` for hard-error
  dialogs. Kernel dumps, System/1001 BugCheck events and WHEA-Logger are unaffected
- `powercfg` sleep / display / hibernate timeouts to 0

**`watchdog-install.ps1`** — writes `watchdog.ps1` and its Startup shortcut. Every 120s:

1. Kills anything on `-KillProcs`
2. Closes any Chrome window whose title doesn't match `-KioskTitle` (`PostMessage WM_CLOSE`)
3. Relaunches Chrome in `--kiosk` mode if it is gone entirely

It aborts if no live window matches `-KioskTitle` — a wrong pattern would make the
watchdog close the board itself.

**`watchdog-cleanup.ps1`** / **`watchdog-test.ps1`** — full uninstall (keeps the log),
and ~11 assertions plus a live test that opens a non-matching window and waits for the
watchdog to close it.

## Design notes

**Startup shortcut, not a scheduled task.** `MainWindowHandle` and `PostMessage` need
the logged-in user's own session; scheduled tasks land in session 0 or the wrong
session and see nothing. This is also why running the bootstrap from an RMM installs
everything but cannot start it — it goes live on the kiosk user's next login, and the
bootstrap says so when it detects session 0.

**`conhost --headless`, not a VBS launcher.** `powershell -WindowStyle Hidden` still
flashes a console; `wscript.exe` + `launcher.vbs` works but Windows 11 is deprecating
VBScript. `conhost.exe --headless powershell.exe ...` is the native replacement.

**`--disable-session-crashed-bubble` is not optional.** After any hard power loss Chrome
otherwise greets the room with "Restore pages?" sitting on top of the board. Both the
Startup shortcut and the watchdog's relaunch use the same quiet flag set.

**No allow-list of processes.** The watchdog only closes non-matching *Chrome* windows
plus an explicit `-KillProcs` list. A blanket "close every foreign window" rule would
also close the remote-support session you are using to fix the thing.

**No secrets in here.** Board URLs (which for IamResponding contain a login JWT) are
discovered at install time and recorded on the kiosk in `kiosk-url.txt`.

## Verify

```powershell
Get-Content "C:\kiosk-watchdog\watchdog.log" -Tail 20 -Wait
powershell -ExecutionPolicy Bypass -File "C:\kiosk-watchdog\bin\watchdog-test.ps1"
```

A healthy log shows `OK - kiosk window active` every two minutes. If a relaunch lands
on a login page, the site's saved session or token has gone stale — get a fresh URL and
re-run with `-KioskUrl`.
