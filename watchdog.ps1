param([string]$Root = "")
# OVERRIDE // watchdog. Keeps the engine alive: if the engine process is killed,
# this relaunches it within ~1s. The engine likewise relaunches this watchdog, so
# killing either one brings it back. Both stop instantly when the session is
# unlocked (quiz solved), the deadline passes, or a PANIC file appears.

$ErrorActionPreference = "SilentlyContinue"
if ($Root -eq "") { $Root = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path } }

$P_key   = Join-Path $Root "session.key"
$P_dead  = Join-Path $Root "session.deadline"
$P_unlk  = Join-Path $Root "UNLOCK"
$P_beat  = Join-Path $Root "session.beat"
$P_beat2 = Join-Path $Root "session.beat2"
$P_panic = Join-Path $Root "PANIC"

if (-not (Test-Path $P_key) -or -not (Test-Path $P_dead)) { return }
$sessionKey = (Get-Content $P_key -Raw).Trim()
try { $deadline = [datetime]::Parse((Get-Content $P_dead -Raw).Trim()) } catch { return }

function Test-Unlocked {
  if (-not (Test-Path $P_unlk)) { return $false }
  $c = Get-Content $P_unlk -Raw; if ($c) { $c = $c.Trim() }
  return ($c -eq $sessionKey)
}
function Test-Stop { return ((Test-Unlocked) -or ((Get-Date) -ge $deadline) -or (Test-Path $P_panic)) }
function Beat-Age([string]$p) {
  if (-not (Test-Path $p)) { return 9999 }
  try { $t = [long]((Get-Content $p -Raw).Trim()); return (((Get-Date).Ticks - $t) / 10000000.0) } catch { return 9999 }
}

while (-not (Test-Stop)) {
  Set-Content -Path $P_beat2 -Value ((Get-Date).Ticks) -Encoding ASCII
  if ((Beat-Age $P_beat) -gt 4) {
    Start-Process powershell -WindowStyle Hidden -ArgumentList @(
      '-NoProfile','-Sta','-ExecutionPolicy','Bypass','-File',(Join-Path $Root 'engine.ps1'),'-Respawn') | Out-Null
    Start-Sleep -Seconds 2
  }
  Start-Sleep -Milliseconds 800
}
