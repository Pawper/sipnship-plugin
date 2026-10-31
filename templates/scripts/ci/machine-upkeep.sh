#!/bin/sh
# What a runner's machine is quietly collecting: files left in its Temp
# folder, and shell processes left running for more than a day. Each file a
# program leaves behind keeps kernel records for as long as it exists, so a
# Temp folder that only grows slows every program start on the machine long
# before anything looks wrong. One line per finding, nothing when clean.
# The nightly audit runs it on a runner, so it reports on that machine.
#
# Usage: sh scripts/ci/machine-upkeep.sh
here=$(dirname "$0")
. "$here/lib.sh"

# The Temp folder the runner's own programs use. Never the suite's scratch
# area: that one is removed by every run that makes it.
temp=${TEMP:-${TMP:-${TMPDIR:-/tmp}}}
if [ -d "$temp" ]; then
  count=$(ls -A "$temp" 2>/dev/null | wc -l | tr -d ' \r')
  temp_entries_warning "$count" 5000 "$temp"
fi

# Kernel memory held for non-paged records, from the performance counter
# (readable without administrator rights). Skipped where there is no
# PowerShell.
if command -v powershell >/dev/null 2>&1; then
  pool=$(powershell -NoProfile -Command "(Get-Counter '\Memory\Pool Nonpaged Bytes').CounterSamples[0].CookedValue" 2>/dev/null | tr -d '\r' | sed 's/\..*//')
  kernel_pool_warning "$pool" 4294967296
  old=$(powershell -NoProfile -Command "Get-CimInstance Win32_Process | Where-Object { \$_.Name -in 'sh.exe','bash.exe' -and \$_.CreationDate } | ForEach-Object { '{0}\`t{1}\`t{2}' -f \$_.ProcessId, [int]((Get-Date) - \$_.CreationDate).TotalHours, \$_.Name }" 2>/dev/null | tr -d '\r')
else
  old=$(ps -eo pid=,etimes=,comm= 2>/dev/null | awk '$3 == "sh" || $3 == "bash" { printf "%s\t%d\t%s\n", $1, $2 / 3600, $3 }')
fi
old_shells_warning "$old" 24
