# Register the runner watch as a Windows scheduled task, every fifteen
# minutes, running as the signed-in user from this project folder. No
# admin needed: it writes under the user's folder and talks to GitHub with
# the user's gh sign-in. The watch itself is scripts/ci/runner-watch.sh.
#
# Usage, from the project root:
#   powershell -ExecutionPolicy Bypass -File scripts\ci\runner-watch-install.ps1
#   powershell -ExecutionPolicy Bypass -File scripts\ci\runner-watch-install.ps1 -Remove
param(
  [switch]$Remove,
  [int]$EveryMinutes = 15
)
$ErrorActionPreference = "Stop"
$root = (Get-Location).Path
$repo = (git remote get-url origin).Trim() -replace '.*github\.com[:/]', '' -replace '\.git$', ''
$task = "SipNShip runner watch " + ($repo -replace '/', '-')
if ($Remove) {
  Unregister-ScheduledTask -TaskName $task -Confirm:$false -ErrorAction SilentlyContinue
  Write-Output "Removed the scheduled task '$task'."
  exit 0
}
# Git's bin\sh.exe is the wrapper that sets up the shell's PATH; the one in
# usrin, which Get-Command finds first, starts bare under Task Scheduler
# and cannot find its own tools. The interpreter inside the command is
# named by its absolute path for the same reason.
$sh = "C:/Program Files/Git/bin/sh.exe"
if (-not (Test-Path $sh)) { $sh = (Get-Command sh.exe -ErrorAction SilentlyContinue).Source }
if (-not $sh -or $sh -like "*System32*" -or -not (Test-Path $sh)) { throw "Git's sh.exe was not found; install Git for Windows." }
# The task runs the watch through sh -c with an absolute path and keeps a
# log: sh.exe given a bare script path with no console ran the watch but
# reported result 1 to Task Scheduler every time, and nothing said why.
# Git's sh reads C:\x as /c/x. Windows PowerShell 5 has no scriptblock
# -replace, so the drive letter is turned by hand.
function ToUnix([string]$p) { $p = $p.Replace('\', '/'); if ($p -match '^([A-Za-z]):(.*)$') { '/' + $Matches[1].ToLower() + $Matches[2] } else { $p } }
$unixRoot = ToUnix $root
$logDir = Join-Path $env:USERPROFILE ".sipnship\runner-watch"
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$log = Join-Path $logDir (($repo -replace '/', '-') + ".log")
$unixLog = ToUnix $log
$cmd = "/usr/bin/sh '$unixRoot/scripts/ci/runner-watch.sh' >> '$unixLog' 2>&1; tail -c 200000 '$unixLog' > '$unixLog.new' 2>/dev/null && mv '$unixLog.new' '$unixLog'"
$action = New-ScheduledTaskAction -Execute $sh -Argument "-c `"$cmd`"" -WorkingDirectory $root
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes $EveryMinutes)
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 5) -MultipleInstances IgnoreNew -DontStopIfGoingOnBatteries -AllowStartIfOnBatteries
Unregister-ScheduledTask -TaskName $task -Confirm:$false -ErrorAction SilentlyContinue
Register-ScheduledTask -TaskName $task -Description "SipNShip: watches this project's runners and the machine they share; comments on the audit issue when something changes." -Action $action -Trigger $trigger -Settings $settings | Out-Null
Start-ScheduledTask -TaskName $task
Write-Output "The runner watch runs every $EveryMinutes minutes as the scheduled task '$task', logging to $log. First run started; sh scripts/ci/runner-watch.sh --print shows what it sees."
