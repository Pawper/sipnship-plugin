# Remove one self-hosted runner from this machine: unregister it from
# GitHub, stop and delete its service, and move its folder aside (never
# deleted). The pair of add-runner.ps1. Needs an elevated PowerShell,
# because removing a service does; an agent launches it and the owner
# clicks the prompt:
#   Start-Process powershell -Verb RunAs -Wait -ArgumentList '-ExecutionPolicy Bypass -File scripts\ci\remove-runner.ps1 -Name build-3'
# It writes nothing to the repository: the doctor, the watch and the
# session brief read the runners GitHub has registered.
param(
  [Parameter(Mandatory = $true)][string]$Name,
  [string]$Root = ""
)
$ErrorActionPreference = "Stop"
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { throw "Run this from an elevated PowerShell; removing a service needs it." }
$remote = (git remote get-url origin).Trim()
$repo = $remote -replace '.*github\.com[:/]', '' -replace '\.git$', ''
if (-not $Root) { $Root = "C:\actions-runner-" + ($repo -split "/")[1] }
$dir = Join-Path $Root $Name
if (-not (Test-Path (Join-Path $dir ".runner"))) { throw "No configured runner in $dir." }
$token = (gh api -X POST "repos/$repo/actions/runners/remove-token" --jq .token).Trim()
Push-Location $dir
try {
  & .\config.cmd remove --token $token
  if ($LASTEXITCODE -ne 0) { throw "config.cmd remove failed with exit code $LASTEXITCODE" }
} finally { Pop-Location }
$aside = "$dir.removed-" + (Get-Date -Format "yyyy-MM-dd")
Move-Item -Path $dir -Destination $aside -Force
Write-Output "Runner $Name is unregistered and its service is gone; its folder was moved to $aside (delete it by hand when you are sure)."
