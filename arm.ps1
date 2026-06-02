param(
  [string]$Root = "",
  [switch]$Disarm     # remove all OVERRIDE alarms
)
# OVERRIDE // scheduler. Reads config.json and registers one Windows Scheduled Task
# per enabled alarm (daily, wake-from-sleep capable). Called by the control panel.

$ErrorActionPreference = "Stop"
if ($Root -eq "") { $Root = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path } }
$log = Join-Path $Root "arm.log"
function W([string]$m) { $line = "{0:HH:mm:ss}  {1}" -f (Get-Date), $m; $line | Out-File -Append -Encoding ascii $log; $line }

"" | Out-File -Encoding ascii $log   # reset log
W "=== OVERRIDE scheduler ==="
$prefix = "OVERRIDE_"

# always clear existing OVERRIDE tasks first
try {
  Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -like "$prefix*" } | ForEach-Object {
    Unregister-ScheduledTask -TaskName $_.TaskName -Confirm:$false -ErrorAction SilentlyContinue
    W "removed old task $($_.TaskName)"
  }
} catch {}

if ($Disarm) { W "DISARMED. all OVERRIDE alarms removed."; return }

# best-effort: allow wake timers so a sleeping PC can wake for the alarm
try {
  $sub = "238c9fa8-0aad-41ed-83f4-97be242c8f20"; $set = "bd3b718a-0680-4d9d-8ab2-e1d2b4ac806d"
  powercfg /setacvalueindex SCHEME_CURRENT $sub $set 1 | Out-Null
  powercfg /setdcvalueindex SCHEME_CURRENT $sub $set 1 | Out-Null
  powercfg /setactive SCHEME_CURRENT | Out-Null
  W "wake timers enabled (power plan)"
} catch { W "could not change wake-timer power setting (non-fatal)" }

$cfg = Get-Content (Join-Path $Root "config.json") -Raw | ConvertFrom-Json
$pw = (Get-Command powershell).Source
$count = 0
foreach ($a in $cfg.alarms) {
  if (-not $a.enabled) { W "skip (disabled): $($a.label) @ $($a.time)"; continue }
  try {
    $at = [datetime]::ParseExact($a.time, "HH:mm", $null)
  } catch { W "BAD TIME '$($a.time)' for $($a.label) - skipped"; continue }

  $argline = "-NoProfile -Sta -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$Root\engine.ps1`" -AlarmId $($a.id)"
  $action = New-ScheduledTaskAction -Execute $pw -Argument $argline -WorkingDirectory $Root
  $trigger = New-ScheduledTaskTrigger -Daily -At $at
  $settings = New-ScheduledTaskSettingsSet -WakeToRun -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 45)
  $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited
  Register-ScheduledTask -TaskName "$prefix$($a.id)" -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force | Out-Null
  $count++
  W "ARMED  $($a.label)  daily @ $($a.time)  (rings $($a.durationMin)m)"
}
W "DONE. $count alarm(s) armed."
