param([switch]$NoArm)
# One-shot setup: make the logo, drop a desktop shortcut, and arm the alarms.
$here = $PSScriptRoot

# 1) icon
$ico = Join-Path $here "override.ico"
& (Join-Path $here "make_icon.ps1") -Out $ico

# 2) desktop shortcut with the logo
$bat = Join-Path $here "override.bat"
$desktop = [Environment]::GetFolderPath("Desktop")
$lnkPath = Join-Path $desktop "OVERRIDE.lnk"
$wsh = New-Object -ComObject WScript.Shell
$lnk = $wsh.CreateShortcut($lnkPath)
$lnk.TargetPath = $bat
$lnk.WorkingDirectory = $here
$lnk.IconLocation = "$ico,0"
$lnk.WindowStyle = 1
$lnk.Description = "OVERRIDE - the alarm you cannot snooze your way out of"
$lnk.Save()
Write-Host ("desktop shortcut: " + $lnkPath) -ForegroundColor Green

# 3) arm the alarms (the guarantee: Windows fires them even with no window open)
if (-not $NoArm) { & (Join-Path $here "override.ps1") -Arm }
