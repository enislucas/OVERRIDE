param([switch]$Arm)
# OVERRIDE v3 // Windows setup
# - reuses the v2 icon (or regenerates it), copies/generates the alarm sounds,
#   and drops a desktop shortcut that opens the v3 control panel (no console).
# - does NOT arm anything by default; arming is done inside the panel (or pass -Arm).
$here = $PSScriptRoot
$v3root = Split-Path -Parent $here
$repo = Split-Path -Parent $v3root

# 1) icon (reuse v2's, else regenerate via v2/make_icon.ps1)
$ico = Join-Path $here "override.ico"
if (-not (Test-Path $ico)) {
  $v2ico = Join-Path $repo "v2\override.ico"
  if (Test-Path $v2ico) { Copy-Item $v2ico $ico }
  else { $mk = Join-Path $repo "v2\make_icon.ps1"; if (Test-Path $mk) { & $mk -Out $ico } }
}

# 2) sounds (copy v2's, else synthesize fresh ones)
$snd = Join-Path $v3root "sounds"
if (-not (Test-Path $snd) -or @(Get-ChildItem $snd -Filter *.wav -ErrorAction SilentlyContinue).Count -eq 0) {
  $v2snd = Join-Path $repo "v2\sounds"
  if (Test-Path $v2snd) {
    New-Item -ItemType Directory -Force -Path $snd | Out-Null
    Copy-Item (Join-Path $v2snd "*.wav") $snd -Force
    Write-Host "sounds: copied from v2" -ForegroundColor Green
  } else {
    & (Join-Path $here "make_sounds.ps1") -Root $v3root
  }
}

# 3) desktop shortcut -> hidden powershell that opens the v3 GUI panel
$ps = (Get-Command powershell).Source
$desktop = [Environment]::GetFolderPath("Desktop")
$lnkPath = Join-Path $desktop "OVERRIDE.lnk"
$wsh = New-Object -ComObject WScript.Shell
$lnk = $wsh.CreateShortcut($lnkPath)
$lnk.TargetPath = $ps
$lnk.Arguments = ('-NoProfile -ExecutionPolicy Bypass -Sta -WindowStyle Hidden -File "{0}\override.ps1"' -f $here)
$lnk.WorkingDirectory = $here
if (Test-Path $ico) { $lnk.IconLocation = "$ico,0" }
$lnk.WindowStyle = 1
$lnk.Description = "OVERRIDE v3 - the alarm you cannot snooze your way out of"
$lnk.Save()
Write-Host ("desktop shortcut: " + $lnkPath) -ForegroundColor Green

# 4) (optional) arm everything in config.json
if ($Arm) { & (Join-Path $here "override.ps1") -Arm }
