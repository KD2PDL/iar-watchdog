# the two predicates from kiosk-provision.ps1's -ClearStartup block
function Test-Item($target, $argline) {
    $isBrowser = $target -match '(^|\\)(chrome|msedge|firefox|brave|iexplore)\.exe$'
    $hasUrl    = "$target $argline" -match 'https?://'
    return ($isBrowser -or $hasUrl)
}
$cases = @(
  @{n='the real Thornwood shortcut'; t='C:\Program Files\Google\Chrome\Application\chrome.exe'; a='-kiosk "https://www.iamresponding.com/v3/agency/def.aspx"'; want=$true}
  @{n='chrome, no url';              t='C:\Program Files\Google\Chrome\Application\chrome.exe'; a='';   want=$true}
  @{n='edge';                        t='C:\Program Files\Microsoft\Edge\Application\msedge.exe'; a='';  want=$true}
  @{n='cmd that opens a url';        t='C:\Windows\System32\cmd.exe'; a='/c start https://board.local'; want=$true}
  @{n='Splashtop streamer';          t='C:\Program Files (x86)\Splashtop\Splashtop Remote\Server\SRServer.exe'; a=''; want=$false}
  @{n='Atera agent';                 t='C:\Program Files\ATERA Networks\AteraAgent\AteraAgent.exe'; a='';  want=$false}
  @{n='OneDrive';                    t='C:\Program Files\Microsoft OneDrive\OneDrive.exe'; a='/background'; want=$false}
  @{n='chromedriver (not a browser)';t='C:\tools\chromedriver.exe'; a='';                                  want=$false}
)
$fail = 0
foreach ($c in $cases) {
  $got = Test-Item $c.t $c.a
  $ok  = $got -eq $c.want
  if (-not $ok) { $fail++ }
  "{0}  {1,-28} moved={2}" -f $(if($ok){"PASS"}else{"FAIL"}), $c.n, $got
}
if ($fail) { "`n$fail case(s) failed"; exit 1 } else { "`nall $($cases.Count) cases correct" }
