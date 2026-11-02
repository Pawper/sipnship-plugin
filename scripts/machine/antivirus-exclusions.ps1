# Let the antivirus skip, or scan again, the fixed folders a build runner
# uses: the runner root and its work folders, Git's folder, node's folder
# and the package store. Run elevated by the plugin's listener after the
# person approved a request, or by hand in an administrator window:
#   powershell -ExecutionPolicy Bypass -File antivirus-exclusions.ps1 -Action Add -Root C:\actions-runner-garden
#   powershell -ExecutionPolicy Bypass -File antivirus-exclusions.ps1 -Action Remove -Root C:\actions-runner-garden
# It only adds or removes these folders from the exclusions. It never turns
# the antivirus off, never excludes anything else, and reads back what is
# set. It prints the folders by their short names, never a file's contents.
param(
  [Parameter(Mandatory = $true)][ValidateSet("Add", "Remove")][string]$Action,
  [Parameter(Mandatory = $true)][string]$Root
)
$ErrorActionPreference = "Stop"
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  throw "Run this from an elevated PowerShell; changing the antivirus exclusions needs it."
}

$git = Get-Command git -ErrorAction SilentlyContinue
$node = Get-Command node -ErrorAction SilentlyContinue
$store = $null
try { $store = (pnpm store path 2>$null | Out-String).Trim() } catch { $store = $null }
$folders = [ordered]@{
  runners  = @($Root, (Get-ChildItem -Path $Root -Directory -ErrorAction SilentlyContinue | ForEach-Object { Join-Path $_.FullName "_work" }))
  git      = @($(if ($git) { Split-Path (Split-Path $git.Source) -Parent }))
  node     = @($(if ($node) { Split-Path $node.Source -Parent }))
  packages = @($store)
}
$paths = @($folders.Values | ForEach-Object { $_ } | Where-Object { $_ -and (Test-Path $_) } | Select-Object -Unique)
if ($paths.Count -eq 0) { throw "None of the runner folders exist on this machine." }

if ($Action -eq "Add") { Add-MpPreference -ExclusionPath $paths -ErrorAction Stop }
else { Remove-MpPreference -ExclusionPath $paths -ErrorAction Stop }

# Read back what is set, and fail when it is not what was asked.
$now = @((Get-MpPreference).ExclusionPath)
$missing = @($paths | Where-Object { $now -contains $_ })
if ($Action -eq "Add" -and $missing.Count -ne $paths.Count) { throw "The antivirus did not keep every exclusion." }
if ($Action -eq "Remove" -and $missing.Count -ne 0) { throw "The antivirus still skips some of these folders." }
$done = @($folders.Keys | Where-Object { @($folders[$_] | Where-Object { $_ -and ($paths -contains $_) }).Count -gt 0 })
Write-Output ("folders=" + ($done -join ","))
