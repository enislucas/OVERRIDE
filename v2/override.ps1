param(
  [switch]$Ring,            # fire ONE ephemeral ring for -AlarmId, then exit (used by the scheduled task)
  [string]$AlarmId = "",
  [switch]$Arm,             # register the Windows scheduled tasks for all enabled alarms
  [switch]$Disarm,          # remove all OVERRIDE v2 scheduled tasks
  [switch]$DryRun,          # list the armed tasks + next run times, then exit
  [switch]$SelfTest,        # print sample questions, then exit
  [switch]$TestNow,         # open the ring window right now (a preview)
  [int]$TestWindowSec = 30, # how long the preview / ring waits before giving up
  [switch]$Quiet,           # test helper: no sound, no volume change (silent preview)
  [switch]$Probe            # internal: write a marker file and exit (verifies task firing)
)
# OVERRIDE v2 // WAKE PROTOCOL
# Design goals: (1) the 3 alarms ALWAYS fire at the right time, app open or not;
# (2) ~0 CPU between alarms; (3) NO crashes.
#
# How it meets them:
#  - Each alarm is one Windows Scheduled Task (WakeToRun) that launches this script
#    in -Ring mode at the right minute. Between alarms NOTHING runs -> 0 CPU, and the
#    OS wakes the PC, so firing does not depend on a window being left open.
#  - A ring is ONE short-lived process: it shows an unclosable math gate, rings, and
#    locks volume for at most 3 minutes, then exits. NO watchdog, NO respawn, NO
#    mutual-guard loop (those were what made v1 pile up and crash). A single mutex
#    means there is never more than one ring at a time, and the task's 5-minute
#    ExecutionTimeLimit is a hard backstop.

$ErrorActionPreference = "Stop"
$script:root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }

# ---- config ----------------------------------------------------------------
$cfgPath = Join-Path $script:root "config.json"
$script:cfg = Get-Content $cfgPath -Raw | ConvertFrom-Json
$script:numQ = if ($script:cfg.numQuestions) { [int]$script:cfg.numQuestions } else { 3 }
$script:diff = if ($script:cfg.difficulty) { [string]$script:cfg.difficulty } else { "hard" }
$script:answerWin = if ($script:cfg.answerWindowSec) { [int]$script:cfg.answerWindowSec } else { 180 }
$script:lockVolCfg = $true
if ($script:cfg.PSObject.Properties.Name -contains 'lockVolume') { $script:lockVolCfg = [bool]$script:cfg.lockVolume }

# ---- assemblies + native helpers ------------------------------------------
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
try { Add-Type -AssemblyName System.Speech } catch {}

$volSrc = @"
using System; using System.Runtime.InteropServices;
[Guid("5CDF2C82-841E-4546-9722-0CF74078229A"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IAudioEndpointVolume {
  int RegisterControlChangeNotify(IntPtr n); int UnregisterControlChangeNotify(IntPtr n); int GetChannelCount(out uint c);
  int SetMasterVolumeLevel(float l, ref Guid e); int SetMasterVolumeLevelScalar(float l, ref Guid e);
  int GetMasterVolumeLevel(out float l); int GetMasterVolumeLevelScalar(out float l);
  int SetChannelVolumeLevel(uint i, float l, ref Guid e); int SetChannelVolumeLevelScalar(uint i, float l, ref Guid e);
  int GetChannelVolumeLevel(uint i, out float l); int GetChannelVolumeLevelScalar(uint i, out float l);
  int SetMute([MarshalAs(UnmanagedType.Bool)] bool m, ref Guid e); int GetMute([MarshalAs(UnmanagedType.Bool)] out bool m);
  int GetVolumeStepInfo(out uint s, out uint sc); int VolumeStepUp(ref Guid e); int VolumeStepDown(ref Guid e);
  int QueryHardwareSupport(out uint hw); int GetVolumeRange(out float min, out float max, out float inc);
}
[Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IMMDevice { int Activate(ref Guid iid, int ctx, IntPtr p, [MarshalAs(UnmanagedType.IUnknown)] out object o); }
[Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IMMDeviceEnumerator { int EnumAudioEndpoints(int f, int m, out IntPtr d); int GetDefaultAudioEndpoint(int f, int r, out IMMDevice d); }
[ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")] public class MMDeviceEnumeratorComObject { }
public static class Vol {
  static IAudioEndpointVolume _v; static Guid _e = Guid.Empty;
  public static void Init() { var en=(IMMDeviceEnumerator)(new MMDeviceEnumeratorComObject());
    IMMDevice dev; en.GetDefaultAudioEndpoint(0,0,out dev);
    Guid iid=new Guid("5CDF2C82-841E-4546-9722-0CF74078229A"); object o; dev.Activate(ref iid,23,IntPtr.Zero,out o); _v=(IAudioEndpointVolume)o; }
  public static void Force() { _v.SetMasterVolumeLevelScalar(1f, ref _e); _v.SetMute(false, ref _e); }
}
"@
try { Add-Type -TypeDefinition $volSrc -Language CSharp } catch {}

# ---- arithmetic generator (mirrors v1 'hard') ------------------------------
function New-Question {
  param([string]$Diff = "hard")
  $mult = [char]0x00D7
  $t = Get-Random -Minimum 0 -Maximum 3
  $a = 0; $b = 0; $op = "+"; $ans = 0
  if ($Diff -eq "easy") {
    switch ($t) {
      0 { $a = Get-Random -Minimum 1  -Maximum 10;  $b = Get-Random -Minimum 1  -Maximum 10;  $op = "+";    $ans = $a + $b }
      1 { $a = Get-Random -Minimum 10 -Maximum 19;  $b = Get-Random -Minimum 1  -Maximum 10;  $op = "-";    $ans = $a - $b }
      2 { $a = Get-Random -Minimum 2  -Maximum 6;   $b = Get-Random -Minimum 2  -Maximum 6;   $op = $mult;  $ans = $a * $b }
    }
  } elseif ($Diff -eq "hard") {
    switch ($t) {
      0 { $a = Get-Random -Minimum 23 -Maximum 90;  $b = Get-Random -Minimum 23 -Maximum 90;  $op = "+";    $ans = $a + $b }
      1 { $a = Get-Random -Minimum 40 -Maximum 100; $b = Get-Random -Minimum 11 -Maximum 40;  $op = "-";    $ans = $a - $b }
      2 { $a = Get-Random -Minimum 6  -Maximum 16;  $b = Get-Random -Minimum 3  -Maximum 13;  $op = $mult;  $ans = $a * $b }
    }
  } else {
    switch ($t) {
      0 { $a = Get-Random -Minimum 8  -Maximum 30;  $b = Get-Random -Minimum 8  -Maximum 30;  $op = "+";    $ans = $a + $b }
      1 { $a = Get-Random -Minimum 15 -Maximum 41;  $b = Get-Random -Minimum 2  -Maximum 15;  $op = "-";    $ans = $a - $b }
      2 { $a = Get-Random -Minimum 3  -Maximum 8;   $b = Get-Random -Minimum 3  -Maximum 8;   $op = $mult;  $ans = $a * $b }
    }
  }
  [pscustomobject]@{ Text = ("{0} {1} {2} =" -f $a, $op, $b); Answer = [int]$ans }
}

# ---- the ring: an unclosable, self-expiring math gate ----------------------
function Show-Ring {
  param(
    [string]$Label = "WAKE UP",
    [int]$N = 3,
    [string]$Diff = "hard",
    [bool]$LockVol = $true,
    [int]$WindowSec = 180,
    [bool]$Quiet = $false,
    [bool]$TestMode = $false
  )

  $script:solved     = $false
  $script:allowClose = $false
  $script:elapsed    = 0
  $script:sndIdx     = 0
  $script:lockVol    = ($LockVol -and -not $Quiet)
  $script:windowSec  = $WindowSec
  $script:ringDiff   = $Diff
  $script:ringN      = $N
  $script:nags = @("Solve it. Wake up.","Still horizontal? Pathetic.","I can do this all morning.","Your blanket will not save you.","Recompute. Now.")

  # sounds grouped by escalation tier (t1 -> t2 -> t3)
  $t1 = @(); $t2 = @(); $t3 = @()
  if (-not $Quiet) {
    $sfolder = Join-Path $script:root "sounds"
    if (Test-Path $sfolder) {
      foreach ($w in @(Get-ChildItem $sfolder -File | Where-Object { $_.Extension -match '(?i)\.wav$' })) {
        if     ($w.Name -like 't2_*') { $t2 += $w.FullName }
        elseif ($w.Name -like 't3_*') { $t3 += $w.FullName }
        else                          { $t1 += $w.FullName }
      }
    }
  }
  if (@($t1).Count -eq 0) { $t1 = $t2 }
  if (@($t2).Count -eq 0) { $t2 = $t1 }
  if (@($t3).Count -eq 0) { $t3 = $t2 }
  $script:tierA = @($t1); $script:tierB = @($t2); $script:tierC = @($t3)
  $script:haveSnd = (@($t1).Count -gt 0)

  $green = [System.Drawing.Color]::FromArgb(0,255,102)
  $dim   = [System.Drawing.Color]::FromArgb(124,255,176)
  $bg    = [System.Drawing.Color]::FromArgb(0,8,3)
  $boxBg = [System.Drawing.Color]::FromArgb(0,26,10)

  $sb = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
  $cx = [int]($sb.Width / 2)

  $script:form = New-Object System.Windows.Forms.Form
  $script:form.FormBorderStyle = 'None'
  $script:form.WindowState = 'Maximized'
  $script:form.TopMost = $true
  $script:form.BackColor = $bg
  $script:form.ControlBox = $false
  $script:form.KeyPreview = $true
  $script:form.ShowInTaskbar = $false

  $h1 = New-Object System.Windows.Forms.Label
  $h1.AutoSize = $false; $h1.Left = 0; $h1.Top = 70; $h1.Width = $sb.Width; $h1.Height = 70
  $h1.TextAlign = 'MiddleCenter'; $h1.ForeColor = $green
  $h1.Font = New-Object System.Drawing.Font("Consolas", 34, [System.Drawing.FontStyle]::Bold)
  $h1.Text = "IDENTITY VERIFICATION"
  $script:h1 = $h1; $script:form.Controls.Add($h1)

  $sub = New-Object System.Windows.Forms.Label
  $sub.AutoSize = $false; $sub.Left = 0; $sub.Top = 148; $sub.Width = $sb.Width; $sub.Height = 30
  $sub.TextAlign = 'MiddleCenter'; $sub.ForeColor = $dim
  $sub.Font = New-Object System.Drawing.Font("Consolas", 14)
  $sub.Text = "[ $Label ]   solve all $N to disable the alarm"
  $script:form.Controls.Add($sub)

  $cd = New-Object System.Windows.Forms.Label
  $cd.AutoSize = $false; $cd.Width = 280; $cd.Height = 28; $cd.Left = $sb.Width - 300; $cd.Top = 24
  $cd.TextAlign = 'MiddleRight'; $cd.ForeColor = $dim
  $cd.Font = New-Object System.Drawing.Font("Consolas", 13)
  $script:countdown = $cd; $script:form.Controls.Add($cd)

  $script:rows = @()
  for ($i = 0; $i -lt $N; $i++) {
    $lbl = New-Object System.Windows.Forms.Label
    $lbl.AutoSize = $false; $lbl.Width = 380; $lbl.Height = 46; $lbl.TextAlign = 'MiddleRight'
    $lbl.ForeColor = $green; $lbl.Font = New-Object System.Drawing.Font("Consolas", 26, [System.Drawing.FontStyle]::Bold)
    $lbl.Left = $cx - 430; $lbl.Top = 230 + $i * 76
    $tb = New-Object System.Windows.Forms.TextBox
    $tb.Width = 230; $tb.Font = New-Object System.Drawing.Font("Consolas", 24)
    $tb.BackColor = $boxBg; $tb.ForeColor = [System.Drawing.Color]::FromArgb(174,255,210); $tb.BorderStyle = 'FixedSingle'
    $tb.Left = $cx - 20; $tb.Top = 228 + $i * 76; $tb.TabIndex = $i
    $script:form.Controls.Add($lbl); $script:form.Controls.Add($tb)
    $script:rows += [pscustomobject]@{ Label = $lbl; Box = $tb; Ans = 0 }
  }

  $go = New-Object System.Windows.Forms.Button
  $go.Text = "> AUTHENTICATE"; $go.Width = 300; $go.Height = 52
  $go.Left = $cx - 150; $go.Top = 230 + $N * 76 + 8
  $go.FlatStyle = 'Flat'; $go.ForeColor = $green; $go.BackColor = [System.Drawing.Color]::FromArgb(0,33,15)
  $go.Font = New-Object System.Drawing.Font("Consolas", 16, [System.Drawing.FontStyle]::Bold)
  $script:form.Controls.Add($go); $script:form.AcceptButton = $go

  $msg = New-Object System.Windows.Forms.Label
  $msg.AutoSize = $false; $msg.Left = 0; $msg.Width = $sb.Width; $msg.Height = 34; $msg.Top = 230 + $N * 76 + 74
  $msg.TextAlign = 'MiddleCenter'; $msg.ForeColor = [System.Drawing.Color]::FromArgb(255,59,59)
  $msg.Font = New-Object System.Drawing.Font("Consolas", 16)
  $script:msg = $msg; $script:form.Controls.Add($msg)

  $script:refill = {
    for ($i = 0; $i -lt $script:ringN; $i++) {
      $q = New-Question -Diff $script:ringDiff
      $script:rows[$i].Label.Text = $q.Text
      $script:rows[$i].Ans = $q.Answer
      $script:rows[$i].Box.Text = ""
      $script:rows[$i].Box.BackColor = [System.Drawing.Color]::FromArgb(0,26,10)
    }
    try { $script:rows[0].Box.Focus() } catch {}
  }

  $script:grant = {
    $script:solved = $true; $script:allowClose = $true
    try { $script:player.Stop() } catch {}
    try { $script:mainTimer.Stop(); $script:sndTimer.Stop() } catch {}
    $script:h1.Text = ([char]0x2713 + " ACCESS GRANTED")
    $script:h1.ForeColor = [System.Drawing.Color]::FromArgb(0,255,136)
    $script:msg.ForeColor = [System.Drawing.Color]::FromArgb(124,255,176)
    $script:msg.Text = "Alarm disabled. You beat the machine. Go win the day."
    $script:closeTimer = New-Object System.Windows.Forms.Timer
    $script:closeTimer.Interval = 2500
    $script:closeTimer.Add_Tick({ $script:closeTimer.Stop(); try { $script:form.Close() } catch {} })
    $script:closeTimer.Start()
  }

  $script:check = {
    $ok = $true
    for ($i = 0; $i -lt $script:ringN; $i++) {
      $v = ([string]$script:rows[$i].Box.Text).Trim()
      $parsed = 0
      $hit = ([int]::TryParse($v, [ref]$parsed)) -and ($parsed -eq $script:rows[$i].Ans)
      if ($hit) { $script:rows[$i].Box.BackColor = [System.Drawing.Color]::FromArgb(0,46,18) }
      else      { $script:rows[$i].Box.BackColor = [System.Drawing.Color]::FromArgb(60,0,0); $ok = $false }
    }
    if ($ok) { & $script:grant }
    else { $script:msg.Text = "> ACCESS DENIED -- recompute. WAKE UP."; & $script:refill }
  }

  $go.Add_Click({ & $script:check })
  $script:form.Add_FormClosing({ param($s,$e) if (-not $script:allowClose) { $e.Cancel = $true } })
  if ($TestMode) {
    $script:form.Add_KeyDown({ param($s,$e)
      if ($e.KeyCode -eq 'Escape') {
        $script:allowClose = $true
        try { $script:mainTimer.Stop(); $script:sndTimer.Stop() } catch {}
        try { $script:player.Stop() } catch {}
        try { $script:form.Close() } catch {}
      }
    })
  }

  $script:player = New-Object System.Media.SoundPlayer
  if ($script:lockVol) { try { [Vol]::Init() } catch {} }
  $script:voice = $null
  if (-not $Quiet) { try { $script:voice = New-Object System.Speech.Synthesis.SpeechSynthesizer; $script:voice.Volume = 100 } catch {} }

  $script:mainTimer = New-Object System.Windows.Forms.Timer
  $script:mainTimer.Interval = 1000
  $script:mainTimer.Add_Tick({
    $script:elapsed++
    try { $script:form.TopMost = $true; $script:form.Activate() } catch {}
    if ($script:lockVol -and (($script:elapsed % 3) -eq 0)) { try { [Vol]::Force() } catch {} }
    $rem = $script:windowSec - $script:elapsed; if ($rem -lt 0) { $rem = 0 }
    try { $script:countdown.Text = ("gives up in {0}s" -f $rem) } catch {}
    if ($script:voice -and (($script:elapsed % 20) -eq 0)) { try { [void]$script:voice.SpeakAsync(($script:nags | Get-Random)) } catch {} }
    if (($script:elapsed -ge $script:windowSec) -and (-not $script:solved)) {
      $script:allowClose = $true
      try { $script:player.Stop() } catch {}
      try { $script:mainTimer.Stop(); $script:sndTimer.Stop() } catch {}
      try { $script:form.Close() } catch {}
    }
  })

  $script:sndTimer = New-Object System.Windows.Forms.Timer
  $script:sndTimer.Interval = 4000
  $script:sndTimer.Add_Tick({
    if (-not $script:haveSnd) { return }
    $script:sndIdx = ($script:sndIdx + 1) % 3
    $arr = switch ($script:sndIdx) { 0 { $script:tierA } 1 { $script:tierB } default { $script:tierC } }
    $arr = @($arr); if ($arr.Count -eq 0) { return }
    $pick = $arr | Get-Random
    try { $script:player.Stop(); $script:player.SoundLocation = $pick; $script:player.Load(); $script:player.PlayLooping() } catch {}
  })

  $script:form.Add_Shown({
    & $script:refill
    if ($script:lockVol) { try { [Vol]::Force() } catch {} }
    if ($script:haveSnd) {
      $arr = @($script:tierA)
      if ($arr.Count -gt 0) { $p = $arr | Get-Random; try { $script:player.SoundLocation = $p; $script:player.Load(); $script:player.PlayLooping() } catch {} }
    }
    if ($script:voice) { try { [void]$script:voice.SpeakAsync("Wake up. Solve to disable the alarm.") } catch {} }
    $script:mainTimer.Start(); $script:sndTimer.Start()
    try { $script:rows[0].Box.Focus() } catch {}
  })

  [void]$script:form.ShowDialog()

  try { $script:mainTimer.Stop(); $script:mainTimer.Dispose() } catch {}
  try { $script:sndTimer.Stop(); $script:sndTimer.Dispose() } catch {}
  try { if ($script:closeTimer) { $script:closeTimer.Dispose() } } catch {}
  try { $script:player.Stop(); $script:player.Dispose() } catch {}
  try { if ($script:voice) { $script:voice.Dispose() } } catch {}
  try { $script:form.Dispose() } catch {}
  return $script:solved
}

# ---- scheduling (the guarantee + the 0-CPU-idle mechanism) -----------------
function Remove-Alarms {
  Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -like 'OVERRIDE_V2_*' } | ForEach-Object {
    Unregister-ScheduledTask -TaskName $_.TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Write-Host ("  removed " + $_.TaskName) -ForegroundColor DarkGray
  }
}

function Register-Alarms {
  Remove-Alarms
  # let a sleeping PC wake for the alarm (best effort, no admin needed)
  try {
    $sub = "238c9fa8-0aad-41ed-83f4-97be242c8f20"; $set = "bd3b718a-0680-4d9d-8ab2-e1d2b4ac806d"
    powercfg /setacvalueindex SCHEME_CURRENT $sub $set 1 | Out-Null
    powercfg /setdcvalueindex SCHEME_CURRENT $sub $set 1 | Out-Null
    powercfg /setactive SCHEME_CURRENT | Out-Null
  } catch {}

  $pw = (Get-Command powershell).Source
  $n = 0
  foreach ($a in $script:cfg.alarms) {
    if (-not $a.enabled) { continue }
    $dateStr = ""
    if (($a.PSObject.Properties.Name -contains 'date') -and $a.date) { $dateStr = ([string]$a.date).Trim() }
    if ($dateStr -ne "") {
      try { $when = [datetime]::ParseExact("$dateStr $($a.time)", "yyyy-MM-dd HH:mm", $null) }
      catch { Write-Host "  bad date for $($a.label) - skipped" -ForegroundColor DarkYellow; continue }
      if ($when -le (Get-Date)) { Write-Host "  skip (in the past): $($a.label) $dateStr $($a.time)" -ForegroundColor DarkYellow; continue }
      $trigger = New-ScheduledTaskTrigger -Once -At $when
      $desc = "once $dateStr at $($a.time)"
    } else {
      try { $at = [datetime]::ParseExact($a.time, "HH:mm", $null) }
      catch { Write-Host "  bad time for $($a.label) - skipped" -ForegroundColor DarkYellow; continue }
      $trigger = New-ScheduledTaskTrigger -Daily -At $at
      $desc = "daily at $($a.time)"
    }
    $arg = "-NoProfile -Sta -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$($script:root)\override.ps1`" -Ring -AlarmId $($a.id)"
    $action    = New-ScheduledTaskAction -Execute $pw -Argument $arg -WorkingDirectory $script:root
    $settings  = New-ScheduledTaskSettingsSet -WakeToRun -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 5) -MultipleInstances IgnoreNew
    $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited
    Register-ScheduledTask -TaskName "OVERRIDE_V2_$($a.id)" -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force | Out-Null
    Write-Host "  armed  $($a.label)  $desc" -ForegroundColor Green
    $n++
  }
  Write-Host "$n alarm(s) armed." -ForegroundColor Green
}

function Show-Tasks {
  $tasks = @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -like 'OVERRIDE_V2_*' })
  if ($tasks.Count -eq 0) { Write-Host "   (no alarms armed)" -ForegroundColor DarkYellow; return }
  foreach ($t in ($tasks | Sort-Object TaskName)) {
    $info = $t | Get-ScheduledTaskInfo
    $nm = $t.TaskName -replace '^OVERRIDE_V2_', ''
    Write-Host ("    {0,-6} next: {1,-22} [{2}]" -f $nm, $info.NextRunTime, $t.State) -ForegroundColor Green
  }
}

# ---- control panel (the desktop app window; optional, ~0 CPU) --------------
function Show-Panel {
  while ($true) {
    Clear-Host
    Write-Host ""
    Write-Host "   OVERRIDE  v2   // WAKE PROTOCOL" -ForegroundColor Green
    Write-Host "   ===================================" -ForegroundColor DarkGreen
    Write-Host ""
    Write-Host "   ARMED alarms (fired by Windows even if this window is closed):" -ForegroundColor Gray
    Write-Host ""
    Show-Tasks
    Write-Host ""
    Write-Host "   Idle CPU: ~0 - nothing runs between alarms." -ForegroundColor DarkGray
    Write-Host "   Each alarm opens an unclosable math gate for up to 3 minutes." -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "   override.bat test     preview the alarm now" -ForegroundColor DarkGray
    Write-Host "   override.bat arm      re-arm from config.json" -ForegroundColor DarkGray
    Write-Host "   override.bat disarm   remove all alarms" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "   (close this window any time - the alarms stay armed)" -ForegroundColor DarkGray
    Start-Sleep -Seconds 15
  }
}

# ---- dispatch --------------------------------------------------------------
if ($Probe) {
  Set-Content -Path (Join-Path $script:root "probe.ok") -Value ((Get-Date).ToString("o")) -Encoding ASCII
  return
}

if ($SelfTest) {
  Write-Host ("sample {0} arithmetic questions:" -f $script:diff) -ForegroundColor Green
  1..6 | ForEach-Object { $q = New-Question -Diff $script:diff; "   {0,-12} {1}" -f $q.Text, $q.Answer }
  return
}

if ($Disarm) { Write-Host "OVERRIDE v2 // disarming..." -ForegroundColor Yellow; Remove-Alarms; return }
if ($Arm)    { Write-Host "OVERRIDE v2 // arming..." -ForegroundColor Green;  Register-Alarms; return }
if ($DryRun) { Write-Host ("OVERRIDE v2 schedule  ({0})" -f (Get-Date)) -ForegroundColor Green; Show-Tasks; return }

if ($TestNow) {
  Write-Host "TEST: opening the ring window (Esc closes it in test mode)..." -ForegroundColor Yellow
  [void](Show-Ring -Label "TEST" -N $script:numQ -Diff $script:diff -LockVol $script:lockVolCfg -WindowSec $TestWindowSec -Quiet:$Quiet -TestMode $true)
  Write-Host "TEST: window closed cleanly." -ForegroundColor Green
  return
}

if ($Ring) {
  # one ephemeral ring, launched by a scheduled task. Single-instance: never two at once.
  $mtx = New-Object System.Threading.Mutex($false, "Local\OVERRIDE_V2_ring_lock")
  $got = $true
  try { $got = $mtx.WaitOne(0) } catch { $got = $true }
  if (-not $got) { return }
  $label = "WAKE UP"
  if ($AlarmId -ne "") {
    $a = $script:cfg.alarms | Where-Object { $_.id -eq $AlarmId } | Select-Object -First 1
    if ($a) { $label = [string]$a.label }
  }
  [void](Show-Ring -Label $label -N $script:numQ -Diff $script:diff -LockVol $script:lockVolCfg -WindowSec $script:answerWin)
  try { $mtx.ReleaseMutex() } catch {}
  return
}

# default: the control-panel window
Show-Panel
