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
$sh = (Get-Command sh.exe -ErrorAction SilentlyContinue).Source
if (-not $sh -or $sh -like "*System32*") { $sh = "C:\Program Files\Git\bin\sh.exe" }
if (-not (Test-Path $sh)) { throw "Git's sh.exe was not found; install Git for Windows." }
$action = New-ScheduledTaskAction -Execute $sh -Argument "scripts/ci/runner-watch.sh" -WorkingDirectory $root
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes $EveryMinutes)
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 5) -MultipleInstances IgnoreNew -DontStopIfGoingOnBatteries -AllowStartIfOnBatteries
Unregister-ScheduledTask -TaskName $task -Confirm:$false -ErrorAction SilentlyContinue
Register-ScheduledTask -TaskName $task -Description "SipNShip: watches this project's runners and the machine they share; comments on the audit issue when something changes." -Action $action -Trigger $trigger -Settings $settings | Out-Null
Start-ScheduledTask -TaskName $task
Write-Output "The runner watch runs every $EveryMinutes minutes as the scheduled task '$task'. First run started; sh scripts/ci/runner-watch.sh --print shows what it sees."
