param([switch]$Arm)
# Setup: make the logo + a desktop shortcut that opens the standalone GUI control panel
# (no console window). Arming is done from inside the app now, so this does NOT arm by
# default. Pass -Arm to also arm whatever is in config.json.
$here = $PSScriptRoot

# 1) icon
$ico = Join-Path $here "override.ico"
& (Join-Path $here "make_icon.ps1") -Out $ico

# 2) desktop shortcut -> hidden powershell that launches the GUI panel (clean, no console)
$ps = (Get-Command powershell).Source
$desktop = [Environment]::GetFolderPath("Desktop")
$lnkPath = Join-Path $desktop "OVERRIDE.lnk"
$wsh = New-Object -ComObject WScript.Shell
$lnk = $wsh.CreateShortcut($lnkPath)
$lnk.TargetPath = $ps
$lnk.Arguments = ('-NoProfile -ExecutionPolicy Bypass -Sta -WindowStyle Hidden -File "{0}\override.ps1"' -f $here)
$lnk.WorkingDirectory = $here
$lnk.IconLocation = "$ico,0"
$lnk.WindowStyle = 1
$lnk.Description = "OVERRIDE - the alarm you cannot snooze your way out of"
$lnk.Save()
Write-Host ("desktop shortcut: " + $lnkPath) -ForegroundColor Green

# 3) (optional) arm
if ($Arm) { & (Join-Path $here "override.ps1") -Arm }
