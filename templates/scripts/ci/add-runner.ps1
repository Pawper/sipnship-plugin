# Add a self-hosted GitHub Actions runner on this Windows machine, installed
# as a Windows service so it survives a restart and a logged-out user. Run
# it once for each runner you want: two is the recommended minimum, since a
# single runner makes every job wait for the last.
#
# Usage, from an elevated PowerShell in the project folder (it refuses to
# run unelevated, because installing a service needs it):
#   powershell -ExecutionPolicy Bypass -File scripts\ci\add-runner.ps1 -Name build-2
# An agent can launch the elevated shell and the owner clicks the prompt:
#   Start-Process powershell -Verb RunAs -Wait -ArgumentList '-ExecutionPolicy Bypass -File scripts\ci\add-runner.ps1 -Name build-2'
#
# It asks gh for a registration token (you must be signed in with gh and
# have admin rights on the repository), downloads the current runner into
# C:\actions-runner-<repo>\<Name> (one root per repository, so a second
# project's runner never lands inside the first's; -Root overrides it),
# configures it with the labels the workflows expect, and starts the
# service. It changes nothing else on the machine. Afterwards, run
# scripts/ci/runner-doctor.sh and the Runner check workflow.
param(
  [Parameter(Mandatory = $true)][string]$Name,
  [string]$Labels = "self-hosted,windows,x64",
  [string]$Root = ""
)
$ErrorActionPreference = "Stop"

$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  throw "Run this from an elevated PowerShell; installing a service needs it. From any shell: Start-Process powershell -Verb RunAs -Wait -ArgumentList '-ExecutionPolicy Bypass -File scripts\ci\add-runner.ps1 -Name $Name'"
}

# The repository name from the git remote, not from the API: a GraphQL
# budget that is spent must not stop a runner install.
$remote = (git remote get-url origin).Trim()
if ($remote -match 'github\.com[:/]([^/]+)/([^/]+?)(\.git)?$') { $repo = "$($Matches[1])/$($Matches[2])" } else { throw "Could not read owner/repo from the origin remote: $remote" }
if (-not $Root) { $Root = "C:\actions-runner-" + ($repo -split "/")[1] }
$token = (gh api -X POST "repos/$repo/actions/runners/registration-token" --jq .token).Trim()
$release = gh api repos/actions/runner/releases/latest | ConvertFrom-Json
$asset = $release.assets | Where-Object { $_.name -like "actions-runner-win-x64-*.zip" } | Select-Object -First 1
if (-not $asset) { throw "Could not find the Windows runner download in the latest release." }

$dir = Join-Path $Root $Name
if (Test-Path (Join-Path $dir ".runner")) { throw "A runner is already configured in $dir. Pick another -Name." }
New-Item -ItemType Directory -Force -Path $dir | Out-Null
$zip = Join-Path $dir $asset.name
Write-Output "Downloading $($asset.name) to $dir"
Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zip
Expand-Archive -Path $zip -DestinationPath $dir -Force
Move-Item -Path $zip -Destination "$zip.downloaded" -Force

Push-Location $dir
try {
  # --runasservice installs and starts the Windows service under
  # NT AUTHORITY\NETWORK SERVICE. That account sees only the machine PATH,
  # which is why the doctor checks Git, Node and gh there.
  & .\config.cmd --unattended --url "https://github.com/$repo" --token $token `
    --name $Name --labels $Labels --work _work --runasservice --replace
  if ($LASTEXITCODE -ne 0) { throw "config.cmd failed with exit code $LASTEXITCODE" }
} finally { Pop-Location }

Write-Output "Runner $Name is registered and running as a service."
Write-Output "Next: sh scripts/ci/runner-doctor.sh, then the Runner check workflow from the Actions tab."
