# Restart the build runners of one repository on this machine, with the rights
# the machine was set up with (the runners' services, as add-runner.ps1 installs
# them). Run by the plugin's listener after the person approved a request, or by
# hand:
#   powershell -ExecutionPolicy Bypass -File restart-runners.ps1 -Repo garden
# It restarts only services named for that repository's runners, never anything
# else, and prints how many it restarted. A build running on one is stopped and
# run again by GitHub.
param(
  [Parameter(Mandatory = $true)][ValidatePattern('^[A-Za-z0-9._-]{1,100}$')][string]$Repo
)
$ErrorActionPreference = "Stop"
$services = @(Get-Service -Name "actions.runner.*-$Repo.*" -ErrorAction SilentlyContinue)
if ($services.Count -eq 0) { Write-Output "No runner service for $Repo on this machine."; exit 2 }
foreach ($s in $services) { Restart-Service -InputObject $s -Force }
Write-Output ("Restarted " + $services.Count + " runner(s).")
