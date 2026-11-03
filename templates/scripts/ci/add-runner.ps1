# Add self-hosted GitHub Actions runners on this Windows machine, each
# installed as a Windows service so it survives a restart and a logged-out
# user. Two is the recommended minimum, since a single runner makes every job
# wait for the last. Name one runner with -Name, or ask for several with
# -Count: one elevated run, so Windows asks once, for every runner and the
# antivirus exclusion together.
#
# Usage, from an elevated PowerShell in the project folder (it refuses to
# run unelevated, because installing a service needs it):
#   powershell -ExecutionPolicy Bypass -File scripts\ci\add-runner.ps1 -Name build-2
#   powershell -ExecutionPolicy Bypass -File scripts\ci\add-runner.ps1 -Count 3
# An agent can launch the elevated shell and the owner clicks the prompt:
#   Start-Process powershell -Verb RunAs -Wait -ArgumentList '-ExecutionPolicy Bypass -File scripts\ci\add-runner.ps1 -Count 3'
#
# With -Count N the runners take the next free names, the repository's own
# last word and a number ("garden-1", "garden-2"): the same rule the
# dashboard uses, counting the names GitHub lists and the folders already
# under the runner root. -Name and -Count are not given together.
#
# It asks gh for a registration token (you must be signed in with gh and
# have admin rights on the repository), downloads the current runner into
# C:\actions-runner-<repo>\<Name> (one root per repository, so a second
# project's runner never lands inside the first's; -Root overrides it),
# configures it with the labels the workflows expect, and starts the
# service. It changes nothing else on the machine. Afterwards, run
# scripts/ci/runner-doctor.sh and the Runner check workflow.
#
# The "pr" label lets the runner take pull requests' jobs from its first
# one. Where ci.yml keeps one runner for the batch and main, the merge
# queue takes "pr" off exactly one online runner and keeps the rest
# labelled (scripts/ci/RUNNERS.md); nobody sets the labels by hand.
param(
  [string]$Name = "",
  [ValidateRange(0, 20)][int]$Count = 0,
  [string]$Labels = "self-hosted,windows,x64,pr",
  [string]$Root = ""
)
$ErrorActionPreference = "Stop"

if ($Name -and $Count -gt 0) { throw "Give -Name for one runner or -Count for several, not both." }
if (-not $Name -and $Count -lt 1) { throw "Give -Name NAME for one runner or -Count N for several." }

$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  $again = if ($Name) { "-Name $Name" } else { "-Count $Count" }
  throw "Run this from an elevated PowerShell; installing a service needs it. From any shell: Start-Process powershell -Verb RunAs -Wait -ArgumentList '-ExecutionPolicy Bypass -File scripts\ci\add-runner.ps1 $again'"
}

# The repository name from the git remote, not from the API: a GraphQL
# budget that is spent must not stop a runner install.
$remote = (git remote get-url origin).Trim()
if ($remote -match 'github\.com[:/]([^/]+)/([^/]+?)(\.git)?$') { $repo = "$($Matches[1])/$($Matches[2])" } else { throw "Could not read owner/repo from the origin remote: $remote" }
if (-not $Root) { $Root = "C:\actions-runner-" + ($repo -split "/")[1] }

# The next free names: the repository's last word, then 1, 2, 3 ... skipping
# any name GitHub lists or any folder already under the root.
function Get-FreeRunnerNames([string]$Repo, [string]$Root, [int]$How) {
  $word = (($Repo -split "/")[-1].ToLower() -split "[^a-z0-9]+" | Where-Object { $_ } | Select-Object -Last 1)
  if (-not $word) { $word = "runner" }
  if ($word.Length -gt 20) { $word = $word.Substring(0, 20) }
  if ($word -notmatch "^[a-z]") { $word = "r$word" }
  $taken = @()
  $listed = gh api "repos/$Repo/actions/runners" --paginate --jq ".runners[].name" 2>$null
  if ($LASTEXITCODE -eq 0 -and $listed) { $taken += @($listed) }
  if (Test-Path $Root) { $taken += @(Get-ChildItem -Path $Root -Directory | ForEach-Object { $_.Name }) }
  $names = @()
  for ($n = 1; $names.Count -lt $How; $n++) {
    $candidate = "$word-$n"
    if ($taken -notcontains $candidate) { $names += $candidate }
  }
  return $names
}

$names = if ($Name) { @($Name) } else { Get-FreeRunnerNames $repo $Root $Count }
if ($Name -and (Test-Path (Join-Path (Join-Path $Root $Name) ".runner"))) { throw "A runner is already configured in $(Join-Path $Root $Name). Pick another -Name." }

$release = gh api repos/actions/runner/releases/latest | ConvertFrom-Json
$asset = $release.assets | Where-Object { $_.name -like "actions-runner-win-x64-*.zip" } | Select-Object -First 1
if (-not $asset) { throw "Could not find the Windows runner download in the latest release." }

$installed = @()
$failure = $null
foreach ($runnerName in $names) {
  try {
    # A registration token lasts an hour and each runner takes its own.
    $token = (gh api -X POST "repos/$repo/actions/runners/registration-token" --jq .token).Trim()
    $dir = Join-Path $Root $runnerName
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
        --name $runnerName --labels $Labels --work _work --runasservice --replace
      if ($LASTEXITCODE -ne 0) { throw "config.cmd failed with exit code $LASTEXITCODE" }
    } finally { Pop-Location }
    $installed += $dir
    Write-Output "Runner $runnerName is registered and running as a service."
  } catch {
    # The runners that did install keep their exclusion; the one that failed is named at the end.
    $failure = "Runner $runnerName was not added: $($_.Exception.Message)"
    break
  }
}

# Windows Defender scans every process start and every file a job writes,
# which makes a shell suite two to four times slower. Exclude the runner's
# folders, Git, node and pnpm's store, once for all the runners just added.
# Exclusions are only ever added by this script, never removed. If Defender
# cannot be changed from here (no rights, or another antivirus), print the
# line to run by hand and go on.
if ($installed.Count -gt 0) {
  $gitDir = "C:\Program Files\Git"
  $nodeCmd = Get-Command node -ErrorAction SilentlyContinue
  $nodeDir = if ($nodeCmd) { Split-Path -Parent $nodeCmd.Source } else { "" }
  $pnpmStore = ""
  if (Get-Command pnpm -ErrorAction SilentlyContinue) { $pnpmStore = (& pnpm store path 2>$null | Select-Object -First 1) }
  $works = $installed | ForEach-Object { Join-Path $_ "_work" }
  $exclusions = @($Root) + @($works) + @($gitDir, $nodeDir, $pnpmStore) | Where-Object { $_ -and (Test-Path $_) }
  $paths = ($exclusions | ForEach-Object { "'$_'" }) -join ","
  try {
    Add-MpPreference -ExclusionPath $exclusions -ErrorAction Stop
    Write-Output "Defender will skip: $($exclusions -join '; ')"
  } catch {
    Write-Output "Could not add Defender exclusions ($($_.Exception.Message)). Run this by hand as administrator:"
    Write-Output "Add-MpPreference -ExclusionPath $paths"
  }
}

if ($failure) { throw $failure }
Write-Output "Added $($installed.Count) runner(s): $((Split-Path -Leaf $installed) -join ', ')."
Write-Output "Next: sh scripts/ci/runner-doctor.sh, then the Runner check workflow from the Actions tab."
