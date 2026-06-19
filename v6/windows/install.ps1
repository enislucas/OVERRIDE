param([switch]$Arm)
# OVERRIDE v6 // Windows setup — icon + sounds + desktop shortcut to the v6 panel.
# Does NOT arm anything by default (arming happens inside the panel, or pass -Arm).
$here = $PSScriptRoot
$v6root = Split-Path -Parent $here
$repo = Split-Path -Parent $v6root

# 1) icon (reuse v5's/v4's/v3's/v2's, else regenerate)
$ico = Join-Path $here "override.ico"
if (-not (Test-Path $ico)) {
  foreach ($src in @((Join-Path $repo "v5\windows\override.ico"), (Join-Path $repo "v4\windows\override.ico"), (Join-Path $repo "v3\windows\override.ico"), (Join-Path $repo "v2\override.ico"))) {
    if (Test-Path $src) { Copy-Item $src $ico; break }
  }
  if (-not (Test-Path $ico)) { $mk = Join-Path $repo "v2\make_icon.ps1"; if (Test-Path $mk) { & $mk -Out $ico } }
}

# 2) sounds (the engine also auto-falls back to v5/v4/v3/v2 sounds at ring time)
$snd = Join-Path $v6root "sounds"
if (-not (Test-Path $snd) -or @(Get-ChildItem $snd -Filter *.wav -ErrorAction SilentlyContinue).Count -eq 0) {
  $copied = $false
  foreach ($src in @((Join-Path $repo "v5\sounds"), (Join-Path $repo "v4\sounds"), (Join-Path $repo "v3\sounds"), (Join-Path $repo "v2\sounds"))) {
    if (Test-Path $src) {
      New-Item -ItemType Directory -Force -Path $snd | Out-Null
      Copy-Item (Join-Path $src "*.wav") $snd -Force; $copied = $true
      Write-Host "sounds: copied from $src" -ForegroundColor Green; break
    }
  }
  if (-not $copied) { & (Join-Path $here "make_sounds.ps1") -Root $v6root }
}

# 3) desktop shortcut -> hidden powershell opening the v6 GUI panel
# audit fix #24: WScript.Shell COM can be disabled by policy on managed machines. Don't let a
# failed shortcut abort setup — tell the user how to launch the app directly instead.
$ps = (Get-Command powershell).Source
try {
  $desktop = [Environment]::GetFolderPath("Desktop")
  $lnkPath = Join-Path $desktop "OVERRIDE.lnk"
  $wsh = New-Object -ComObject WScript.Shell
  $lnk = $wsh.CreateShortcut($lnkPath)
  $lnk.TargetPath = $ps
  $lnk.Arguments = ('-NoProfile -ExecutionPolicy Bypass -Sta -WindowStyle Hidden -File "{0}\override.ps1"' -f $here)
  $lnk.WorkingDirectory = $here
  if (Test-Path $ico) { $lnk.IconLocation = "$ico,0" }
  $lnk.WindowStyle = 1
  $lnk.Description = "OVERRIDE v6 - the alarm you cannot snooze your way out of"
  $lnk.Save()
  Write-Host ("desktop shortcut: " + $lnkPath) -ForegroundColor Green
} catch {
  Write-Warning ("could not create the desktop shortcut ({0})." -f $_.Exception.Message)
  Write-Host ("Launch the app directly instead:`n  {0} -NoProfile -ExecutionPolicy Bypass -Sta -File `"{1}\override.ps1`"" -f $ps, $here) -ForegroundColor Yellow
}

if ($Arm) { & (Join-Path $here "override.ps1") -Arm }
