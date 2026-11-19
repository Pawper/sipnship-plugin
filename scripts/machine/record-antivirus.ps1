# Record how much the antivirus costs while programs start. Run elevated by
# the plugin's listener after the person approved a request, or by hand in
# an administrator window:
#   powershell -ExecutionPolicy Bypass -File record-antivirus.ps1 -Seconds 60
# It only measures: it changes no setting and no exclusion. The recording is
# kept in the machine's own program-data folder, and an earlier one is moved
# aside, never deleted. It prints the length it recorded, nothing else, and
# leaves a two-line summary beside the recording (the antivirus's share of one
# core in percent, and how many programs started meanwhile) for the listener.
param(
  [ValidateRange(10, 300)][int]$Seconds = 60
)
$ErrorActionPreference = "Stop"
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  throw "Run this from an elevated PowerShell; recording the antivirus needs it."
}

$dir = Join-Path $env:ProgramData "sipnship"
New-Item -ItemType Directory -Force -Path $dir | Out-Null
$file = Join-Path $dir "antivirus.etl"
if (Test-Path $file) {
  Move-Item -Path $file -Destination (Join-Path $dir ("antivirus-" + (Get-Date -Format "yyyyMMdd-HHmmss") + ".etl"))
}

$summary = Join-Path $dir "antivirus-summary.txt"
Set-Content -Path $summary -Value "" -Encoding ascii
$began = Get-Date
New-MpPerformanceRecording -RecordTo $file -Seconds $Seconds -ErrorAction Stop
if (-not (Test-Path $file)) { throw "The antivirus recording was not saved." }

# The figures are best effort: a recording that cannot be read leaves the summary empty, never a failed request.
try {
  $report = Get-MpPerformanceReport -Path $file -TopProcesses 1000 -ErrorAction Stop
  $busy = 0.0
  foreach ($p in $report.TopProcesses) { $busy += ([TimeSpan]$p.TotalDuration).TotalSeconds }
  $share = [Math]::Min(999, [Math]::Round(100 * $busy / $Seconds))
  $programs = @(Get-Process | Where-Object { $_.StartTime -ge $began }).Count
  if ($programs -lt 1) { $programs = 1 }
  Set-Content -Path $summary -Value @("share=$share", "programs=$programs") -Encoding ascii
} catch { }
Write-Output ("seconds=" + $Seconds)
