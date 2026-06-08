param(
  [switch]$Ring,            # fire ONE ephemeral ring for -AlarmId, then exit (scheduled task)
  [string]$AlarmId = "",
  [switch]$Arm,             # register OVERRIDE_V2_* scheduled tasks from config.json
  [switch]$Disarm,          # remove all OVERRIDE_V2_* tasks
  [switch]$Unlock,          # safety: restore Task Manager (and drop any hook), then exit
  [switch]$DryRun,          # list armed tasks, then exit
  [switch]$SelfTest,        # print sample questions, then exit
  [switch]$TestNow,         # open a ring preview now (no lockdown, Esc-escapable)
  [int]$TestWindowSec = 30,
  [switch]$Quiet,           # test helper: no sound / no volume change
  [switch]$Probe,           # internal: write a marker file and exit (verifies task firing)
  [int]$PanelTestSec = 0,   # internal: auto-close the control panel after N seconds (tests)
  [switch]$LockTest         # internal: exercise the REAL lockdown path with a short window (tests)
)
# OVERRIDE v2 (redesign) // WAKE PROTOCOL
# - Alarms fire via Windows Scheduled Tasks -> ephemeral ring. 0 CPU between alarms.
# - Ring: vibrant matrix-rain math gate, unclosable, volume-locked, gives up after 3 min.
# - MAXIMUM lockdown on real alarms: low-level keyboard hook (Win/Alt-Tab/Ctrl-Esc/
#   Ctrl-Shift-Esc) + DisableTaskMgr, with multiple auto-release safety nets.
# - Standalone themed GUI control panel for the user (add/edit/delete/arm/disarm/test).

$ErrorActionPreference = "Stop"
$script:root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }

# ---- config ----------------------------------------------------------------
$script:cfgPath = Join-Path $script:root "config.json"
function Load-Config { $script:cfg = Get-Content $script:cfgPath -Raw | ConvertFrom-Json }
Load-Config
$script:numQ = if ($script:cfg.numQuestions) { [int]$script:cfg.numQuestions } else { 3 }
$script:diff = if ($script:cfg.difficulty) { [string]$script:cfg.difficulty } else { "hard" }
$script:answerWin = if ($script:cfg.answerWindowSec) { [int]$script:cfg.answerWindowSec } else { 180 }
$script:lockVolCfg = $true
if ($script:cfg.PSObject.Properties.Name -contains 'lockVolume') { $script:lockVolCfg = [bool]$script:cfg.lockVolume }

# ---- assemblies + native -------------------------------------------------
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

$lockSrc = @"
using System; using System.Runtime.InteropServices;
public static class Lockdown {
  const int WH_KEYBOARD_LL = 13, WM_KEYDOWN = 0x100, WM_SYSKEYDOWN = 0x104;
  [StructLayout(LayoutKind.Sequential)] public struct KB { public uint vk; public uint sc; public uint fl; public uint tm; public IntPtr ex; }
  public delegate IntPtr Proc(int code, IntPtr w, IntPtr l);
  static Proc _proc = Hook;            // kept alive (static) so the GC never collects the callback
  static IntPtr _h = IntPtr.Zero;
  [DllImport("user32.dll")] static extern IntPtr SetWindowsHookEx(int id, Proc cb, IntPtr hMod, uint th);
  [DllImport("user32.dll")] static extern bool UnhookWindowsHookEx(IntPtr h);
  [DllImport("user32.dll")] static extern IntPtr CallNextHookEx(IntPtr h, int code, IntPtr w, IntPtr l);
  [DllImport("kernel32.dll", CharSet=CharSet.Auto)] static extern IntPtr GetModuleHandle(string n);
  [DllImport("user32.dll")] static extern short GetAsyncKeyState(int v);
  static bool Dn(int v){ return (GetAsyncKeyState(v) & 0x8000) != 0; }
  public static bool Active { get { return _h != IntPtr.Zero; } }
  public static void Install(){ if(_h==IntPtr.Zero){ _h = SetWindowsHookEx(WH_KEYBOARD_LL, _proc, GetModuleHandle(null), 0); } }
  public static void Remove(){ if(_h!=IntPtr.Zero){ UnhookWindowsHookEx(_h); _h=IntPtr.Zero; } }
  static IntPtr Hook(int code, IntPtr w, IntPtr l){
    if(code>=0){
      int m = w.ToInt32();
      if(m==WM_KEYDOWN || m==WM_SYSKEYDOWN){
        KB k = (KB)Marshal.PtrToStructure(l, typeof(KB));
        int vk = (int)k.vk;
        bool alt=Dn(0x12), ctrl=Dn(0x11), shift=Dn(0x10);
        bool block=false;
        if(vk==0x5B||vk==0x5C) block=true;                 // LWin / RWin
        else if(vk==0x09 && alt) block=true;                // Alt+Tab
        else if(vk==0x1B && (ctrl||alt)) block=true;        // Ctrl+Esc / Alt+Esc
        else if(vk==0x1B && ctrl && shift) block=true;      // Ctrl+Shift+Esc (Task Manager)
        if(block) return (IntPtr)1;
      }
    }
    return CallNextHookEx(_h, code, w, l);
  }
}
"@
try { Add-Type -TypeDefinition $lockSrc -Language CSharp } catch {}

# ---- lockdown helpers ------------------------------------------------------
function Set-TaskMgrDisabled([bool]$on) {
  # Best-effort: greys out Task Manager via the HKCU policy value. On machines where
  # the Policies key is ACL-locked (managed/hardened, no admin), this is denied and we
  # silently rely on the keyboard hook + the Task Manager window-suppressor instead.
  try {
    $sub = 'Software\Microsoft\Windows\CurrentVersion\Policies\System'
    if ($on) {
      $k = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($sub)
      if ($k) { $k.SetValue('DisableTaskMgr', 1, [Microsoft.Win32.RegistryValueKind]::DWord); $k.Close() }
    } else {
      $k = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($sub, $true)
      if ($k) { try { $k.DeleteValue('DisableTaskMgr', $false) } catch {}; $k.Close() }
    }
  } catch {}
}
function Test-RingActive {
  try {
    $m = New-Object System.Threading.Mutex($false, 'Local\OVERRIDE_V2_ring_lock')
    $got = $m.WaitOne(0)
    if ($got) { $m.ReleaseMutex(); $m.Dispose(); return $false }
    $m.Dispose(); return $true
  } catch { return $false }
}
function Invoke-Unlock { Set-TaskMgrDisabled $false; try { [Lockdown]::Remove() } catch {} }

# ---- arithmetic ------------------------------------------------------------
function New-Question {
  param([string]$Diff = "hard")
  $mult = [char]0x00D7
  $t = Get-Random -Minimum 0 -Maximum 3
  $a = 0; $b = 0; $op = "+"; $ans = 0
  if ($Diff -eq "easy") {
    switch ($t) {
      0 { $a = Get-Random -Minimum 1  -Maximum 10;  $b = Get-Random -Minimum 1  -Maximum 10;  $op = "+";   $ans = $a + $b }
      1 { $a = Get-Random -Minimum 10 -Maximum 19;  $b = Get-Random -Minimum 1  -Maximum 10;  $op = "-";   $ans = $a - $b }
      2 { $a = Get-Random -Minimum 2  -Maximum 6;   $b = Get-Random -Minimum 2  -Maximum 6;   $op = $mult; $ans = $a * $b }
    }
  } elseif ($Diff -eq "hard") {
    switch ($t) {
      0 { $a = Get-Random -Minimum 23 -Maximum 90;  $b = Get-Random -Minimum 23 -Maximum 90;  $op = "+";   $ans = $a + $b }
      1 { $a = Get-Random -Minimum 40 -Maximum 100; $b = Get-Random -Minimum 11 -Maximum 40;  $op = "-";   $ans = $a - $b }
      2 { $a = Get-Random -Minimum 6  -Maximum 16;  $b = Get-Random -Minimum 3  -Maximum 13;  $op = $mult; $ans = $a * $b }
    }
  } else {
    switch ($t) {
      0 { $a = Get-Random -Minimum 8  -Maximum 30;  $b = Get-Random -Minimum 8  -Maximum 30;  $op = "+";   $ans = $a + $b }
      1 { $a = Get-Random -Minimum 15 -Maximum 41;  $b = Get-Random -Minimum 2  -Maximum 15;  $op = "-";   $ans = $a - $b }
      2 { $a = Get-Random -Minimum 3  -Maximum 8;   $b = Get-Random -Minimum 3  -Maximum 8;   $op = $mult; $ans = $a * $b }
    }
  }
  [pscustomobject]@{ Text = ("{0} {1} {2} =" -f $a, $op, $b); Answer = [int]$ans }
}

# ---- matrix rain (shared, fps-capped, double-buffered) ---------------------
function Update-RainSize($p) {
  $st = $p.Tag
  $w = [math]::Max(1, $p.ClientSize.Width); $h = [math]::Max(1, $p.ClientSize.Height)
  if ($st.bmp -and $st.bmp.Width -eq $w -and $st.bmp.Height -eq $h) { return }
  if ($st.bmp) { $st.bmp.Dispose() }
  $st.bmp = New-Object System.Drawing.Bitmap $w, $h
  $g = [System.Drawing.Graphics]::FromImage($st.bmp); $g.Clear([System.Drawing.Color]::Black); $g.Dispose()
  $st.cols = [int][math]::Ceiling($w / $st.fh)
  $d = New-Object 'int[]' $st.cols
  for ($i = 0; $i -lt $st.cols; $i++) { $d[$i] = $st.rng.Next(0, [int]($h / $st.fh) + 1) }
  $st.drops = $d
  if ($st.scan) { $st.scan.Dispose() }
  $st.scan = New-Object System.Drawing.Bitmap $w, $h
  $sg = [System.Drawing.Graphics]::FromImage($st.scan); $sg.Clear([System.Drawing.Color]::FromArgb(0,0,0,0))
  $pen = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(45,0,0,0))
  for ($y = 0; $y -lt $h; $y += 3) { $sg.DrawLine($pen, 0, $y, $w, $y) }
  $pen.Dispose(); $sg.Dispose()
}
function Step-Rain($p) {
  $st = $p.Tag
  if (-not $st.bmp) { Update-RainSize $p }
  if (-not $st.bmp) { return }
  $g = [System.Drawing.Graphics]::FromImage($st.bmp)
  $w = $st.bmp.Width; $h = $st.bmp.Height
  $g.FillRectangle($st.fade, 0, 0, $w, $h)
  $n = $st.chars.Length
  for ($i = 0; $i -lt $st.cols; $i++) {
    $ch = [string]$st.chars[$st.rng.Next(0, $n)]
    $x = $i * $st.fh; $y = $st.drops[$i] * $st.fh
    $g.DrawString($ch, $st.font, $st.body, [single]$x, [single]$y)
    if (($st.drops[$i] * $st.fh) -gt $h -and $st.rng.NextDouble() -gt 0.975) { $st.drops[$i] = 0 }
    else { $st.drops[$i] = $st.drops[$i] + 1 }
  }
  $g.DrawImageUnscaled($st.scan, 0, 0)
  $g.Dispose()
  $p.Invalidate()
}
function New-RainBackground {
  param([int]$Fps = 12, [int]$FontSize = 20)
  $panel = New-Object System.Windows.Forms.Panel
  $panel.Dock = 'Fill'; $panel.BackColor = [System.Drawing.Color]::Black
  try {
    $bf = [System.Reflection.BindingFlags]([System.Reflection.BindingFlags]::Instance -bor [System.Reflection.BindingFlags]::NonPublic)
    $panel.GetType().GetProperty('DoubleBuffered', $bf).SetValue($panel, $true, $null)
  } catch {}
  $st = @{
    bmp = $null; scan = $null; drops = $null; cols = 0; fh = $FontSize
    font = (New-Object System.Drawing.Font('Consolas', $FontSize, [System.Drawing.FontStyle]::Bold))
    chars = '0123456789ABCDEF#$%*+=<>/\|'
    fade = (New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(40,0,0,0)))
    body = (New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(0,255,102)))
    rng = (New-Object System.Random)
  }
  $panel.Tag = $st
  $panel.Add_Paint({ param($s,$e) $stt = $s.Tag; if ($stt.bmp) { $e.Graphics.DrawImageUnscaled($stt.bmp, 0, 0) } })
  $panel.Add_Resize({ param($s,$e) Update-RainSize $s })
  $timer = New-Object System.Windows.Forms.Timer
  $timer.Interval = [int](1000 / $Fps); $timer.Tag = $panel
  $timer.Add_Tick({ param($s,$e) Step-Rain $s.Tag })
  [pscustomobject]@{ Panel = $panel; Timer = $timer }
}

# ---- the ring --------------------------------------------------------------
function Show-Ring {
  param(
    [string]$Label = "WAKE UP", [int]$N = 3, [string]$Diff = "hard", [bool]$LockVol = $true,
    [int]$WindowSec = 180, [bool]$Quiet = $false, [bool]$TestMode = $false, [bool]$Lockdown = $false
  )
  $script:rg_solved = $false; $script:rg_allowClose = $false; $script:rg_elapsed = 0; $script:rg_sndIdx = 0
  $script:rg_lockVol = ($LockVol -and -not $Quiet); $script:rg_windowSec = $WindowSec
  $script:rg_diff = $Diff; $script:rg_N = $N; $script:rg_lockdown = $Lockdown
  $script:rg_rng2 = New-Object System.Random
  $script:rg_shakeTimer = $null; $script:rg_closeTimer = $null; $script:rg_voice = $null
  $script:rg_nags = @("Solve it. Wake up.","Still horizontal? Pathetic.","I can do this all morning.","Your blanket will not save you.","Recompute. Now.")

  $t1=@(); $t2=@(); $t3=@()
  if (-not $Quiet) {
    $sf = Join-Path $script:root 'sounds'
    if (Test-Path $sf) {
      foreach ($w in @(Get-ChildItem $sf -File | Where-Object { $_.Extension -match '(?i)\.wav$' })) {
        if ($w.Name -like 't2_*') { $t2 += $w.FullName } elseif ($w.Name -like 't3_*') { $t3 += $w.FullName } else { $t1 += $w.FullName }
      }
    }
  }
  if (@($t1).Count -eq 0) { $t1 = $t2 }; if (@($t2).Count -eq 0) { $t2 = $t1 }; if (@($t3).Count -eq 0) { $t3 = $t2 }
  $script:rg_tierA = @($t1); $script:rg_tierB = @($t2); $script:rg_tierC = @($t3); $script:rg_haveSnd = (@($t1).Count -gt 0)

  $green = [System.Drawing.Color]::FromArgb(0,255,102); $dim = [System.Drawing.Color]::FromArgb(124,255,176)
  $sb = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds

  $script:rg_form = New-Object System.Windows.Forms.Form
  $script:rg_form.FormBorderStyle = 'None'; $script:rg_form.WindowState = 'Maximized'; $script:rg_form.TopMost = $true
  $script:rg_form.BackColor = [System.Drawing.Color]::Black; $script:rg_form.ControlBox = $false
  $script:rg_form.KeyPreview = $true; $script:rg_form.ShowInTaskbar = $false

  $script:rg_rain = New-RainBackground -Fps 12 -FontSize 20
  $script:rg_form.Controls.Add($script:rg_rain.Panel)

  $Wc = 800; $Hc = 200 + $N * 76 + 110
  $box = New-Object System.Windows.Forms.Panel
  $box.Width = $Wc; $box.Height = $Hc; $box.Left = [int](($sb.Width - $Wc)/2); $box.Top = [int](($sb.Height - $Hc)/2)
  $box.BackColor = [System.Drawing.Color]::FromArgb(0,12,5)
  $box.Add_Paint({ param($s,$e)
    $r = $s.ClientRectangle
    $pen = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(0,255,102)), 2
    $e.Graphics.DrawRectangle($pen, 1, 1, $r.Width-3, $r.Height-3); $pen.Dispose()
  })
  $script:rg_box = $box
  $script:rg_form.Controls.Add($box)
  $script:rg_rain.Panel.SendToBack()

  $h1 = New-Object System.Windows.Forms.Label
  $h1.AutoSize=$false; $h1.Left=0; $h1.Top=22; $h1.Width=$Wc; $h1.Height=52; $h1.TextAlign='MiddleCenter'
  $h1.ForeColor=$green; $h1.BackColor=[System.Drawing.Color]::Transparent
  $h1.Font=New-Object System.Drawing.Font('Consolas',30,[System.Drawing.FontStyle]::Bold); $h1.Text='IDENTITY VERIFICATION'
  $box.Controls.Add($h1); $script:rg_h1 = $h1

  $sub = New-Object System.Windows.Forms.Label
  $sub.AutoSize=$false; $sub.Left=0; $sub.Top=78; $sub.Width=$Wc; $sub.Height=26; $sub.TextAlign='MiddleCenter'
  $sub.ForeColor=$dim; $sub.BackColor=[System.Drawing.Color]::Transparent
  $sub.Font=New-Object System.Drawing.Font('Consolas',13); $sub.Text="[ $Label ]   prove consciousness to disable the alarm"
  $box.Controls.Add($sub)

  $cd = New-Object System.Windows.Forms.Label
  $cd.AutoSize=$false; $cd.Width=220; $cd.Height=24; $cd.Left=$Wc-238; $cd.Top=16; $cd.TextAlign='MiddleRight'
  $cd.ForeColor=$dim; $cd.BackColor=[System.Drawing.Color]::Transparent; $cd.Font=New-Object System.Drawing.Font('Consolas',12)
  $box.Controls.Add($cd); $script:rg_cd = $cd

  $script:rg_rows = @()
  $cxb = [int]($Wc/2)
  for ($i = 0; $i -lt $N; $i++) {
    $lbl = New-Object System.Windows.Forms.Label
    $lbl.AutoSize=$false; $lbl.Width=300; $lbl.Height=44; $lbl.TextAlign='MiddleRight'; $lbl.BackColor=[System.Drawing.Color]::Transparent
    $lbl.ForeColor=$green; $lbl.Font=New-Object System.Drawing.Font('Consolas',24,[System.Drawing.FontStyle]::Bold)
    $lbl.Left=$cxb-330; $lbl.Top=128 + $i*72
    $tb = New-Object System.Windows.Forms.TextBox
    $tb.Width=210; $tb.Font=New-Object System.Drawing.Font('Consolas',22)
    $tb.BackColor=[System.Drawing.Color]::FromArgb(0,26,10); $tb.ForeColor=[System.Drawing.Color]::FromArgb(174,255,210); $tb.BorderStyle='FixedSingle'
    $tb.Left=$cxb-10; $tb.Top=126 + $i*72; $tb.TabIndex=$i
    $box.Controls.Add($lbl); $box.Controls.Add($tb)
    $script:rg_rows += [pscustomobject]@{ Label=$lbl; Box=$tb; Ans=0 }
  }

  $go = New-Object System.Windows.Forms.Button
  $go.Text='> AUTHENTICATE'; $go.Width=280; $go.Height=48; $go.Left=$cxb-140; $go.Top=128 + $N*72 + 12
  $go.FlatStyle='Flat'; $go.ForeColor=$green; $go.BackColor=[System.Drawing.Color]::FromArgb(0,33,15)
  $go.FlatAppearance.BorderColor=$green; $go.Font=New-Object System.Drawing.Font('Consolas',15,[System.Drawing.FontStyle]::Bold)
  $box.Controls.Add($go); $script:rg_form.AcceptButton=$go

  $msg = New-Object System.Windows.Forms.Label
  $msg.AutoSize=$false; $msg.Left=0; $msg.Width=$Wc; $msg.Height=30; $msg.Top=128 + $N*72 + 70; $msg.TextAlign='MiddleCenter'
  $msg.ForeColor=[System.Drawing.Color]::FromArgb(255,59,59); $msg.BackColor=[System.Drawing.Color]::Transparent
  $msg.Font=New-Object System.Drawing.Font('Consolas',15); $box.Controls.Add($msg); $script:rg_msg = $msg

  $script:rg_refill = {
    for ($i = 0; $i -lt $script:rg_N; $i++) {
      $q = New-Question -Diff $script:rg_diff
      $script:rg_rows[$i].Label.Text = $q.Text; $script:rg_rows[$i].Ans = $q.Answer
      $script:rg_rows[$i].Box.Text = ""; $script:rg_rows[$i].Box.BackColor = [System.Drawing.Color]::FromArgb(0,26,10)
    }
    try { $script:rg_rows[0].Box.Focus() } catch {}
  }
  $script:rg_shake = {
    if ($script:rg_shakeTimer) { try { $script:rg_shakeTimer.Stop(); $script:rg_box.Location = $script:rg_boxHome; $script:rg_shakeTimer.Dispose() } catch {} }
    $script:rg_shakeN = 0; $script:rg_boxHome = $script:rg_box.Location
    $script:rg_shakeTimer = New-Object System.Windows.Forms.Timer; $script:rg_shakeTimer.Interval = 28
    $script:rg_shakeTimer.Add_Tick({
      $script:rg_shakeN++
      if ($script:rg_shakeN -gt 10) { $script:rg_shakeTimer.Stop(); $script:rg_box.Location = $script:rg_boxHome; return }
      $dx = $script:rg_rng2.Next(-7,8); $dy = $script:rg_rng2.Next(-7,8)
      $script:rg_box.Location = New-Object System.Drawing.Point (($script:rg_boxHome.X + $dx), ($script:rg_boxHome.Y + $dy))
    })
    $script:rg_shakeTimer.Start()
  }
  $script:rg_grant = {
    $script:rg_solved = $true; $script:rg_allowClose = $true
    try { $script:rg_player.Stop() } catch {}
    try { $script:rg_mainTimer.Stop(); $script:rg_sndTimer.Stop(); $script:rg_volTimer.Stop() } catch {}
    $script:rg_h1.Text = ([char]0x2713 + " ACCESS GRANTED"); $script:rg_h1.ForeColor = [System.Drawing.Color]::FromArgb(0,255,136)
    $script:rg_msg.ForeColor = [System.Drawing.Color]::FromArgb(124,255,176); $script:rg_msg.Text = "Alarm disabled. You beat the machine. Go win the day."
    $script:rg_closeTimer = New-Object System.Windows.Forms.Timer; $script:rg_closeTimer.Interval = 2500
    $script:rg_closeTimer.Add_Tick({ $script:rg_closeTimer.Stop(); try { $script:rg_form.Close() } catch {} })
    $script:rg_closeTimer.Start()
  }
  $script:rg_check = {
    $ok = $true
    for ($i = 0; $i -lt $script:rg_N; $i++) {
      $v = ([string]$script:rg_rows[$i].Box.Text).Trim(); $parsed = 0
      $hit = ([int]::TryParse($v, [ref]$parsed)) -and ($parsed -eq $script:rg_rows[$i].Ans)
      if ($hit) { $script:rg_rows[$i].Box.BackColor = [System.Drawing.Color]::FromArgb(0,46,18) }
      else { $script:rg_rows[$i].Box.BackColor = [System.Drawing.Color]::FromArgb(60,0,0); $ok = $false }
    }
    if ($ok) { & $script:rg_grant } else { $script:rg_msg.Text = "> ACCESS DENIED -- recompute. WAKE UP."; & $script:rg_shake; & $script:rg_refill }
  }
  $go.Add_Click({ & $script:rg_check })
  $script:rg_form.Add_FormClosing({ param($s,$e) if (-not $script:rg_allowClose) { $e.Cancel = $true } })
  if ($TestMode) {
    $script:rg_form.Add_KeyDown({ param($s,$e)
      if ($e.KeyCode -eq 'Escape') { $script:rg_allowClose = $true; try { $script:rg_mainTimer.Stop(); $script:rg_sndTimer.Stop(); $script:rg_volTimer.Stop() } catch {}; try { $script:rg_player.Stop() } catch {}; try { $script:rg_form.Close() } catch {} }
    })
  }

  $script:rg_player = New-Object System.Media.SoundPlayer
  if ($script:rg_lockVol) { try { [Vol]::Init() } catch {} }
  if (-not $Quiet) { try { $script:rg_voice = New-Object System.Speech.Synthesis.SpeechSynthesizer; $script:rg_voice.Volume = 100 } catch {} }

  $script:rg_mainTimer = New-Object System.Windows.Forms.Timer; $script:rg_mainTimer.Interval = 1000
  $script:rg_mainTimer.Add_Tick({
    $script:rg_elapsed++
    try { $script:rg_form.TopMost = $true; $script:rg_form.Activate() } catch {}
    if ($script:rg_lockdown) { try { Get-Process -Name Taskmgr -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue } catch {} }
    if ($script:rg_lockVol -and (($script:rg_elapsed % 3) -eq 0)) { try { [Vol]::Force() } catch {} }
    $rem = $script:rg_windowSec - $script:rg_elapsed; if ($rem -lt 0) { $rem = 0 }
    try { $script:rg_cd.Text = ("gives up in {0}s" -f $rem) } catch {}
    if ($script:rg_voice -and (($script:rg_elapsed % 20) -eq 0)) { try { [void]$script:rg_voice.SpeakAsync(($script:rg_nags | Get-Random)) } catch {} }
    if (($script:rg_elapsed -ge $script:rg_windowSec) -and (-not $script:rg_solved)) {
      $script:rg_allowClose = $true
      try { $script:rg_player.Stop() } catch {}
      try { $script:rg_mainTimer.Stop(); $script:rg_sndTimer.Stop(); $script:rg_volTimer.Stop() } catch {}
      try { $script:rg_form.Close() } catch {}
    }
  })
  # aggressive volume lock: re-assert 100% + unmute ~5x/sec so a manual mute can't stick (cheap COM call)
  $script:rg_volTimer = New-Object System.Windows.Forms.Timer; $script:rg_volTimer.Interval = 200
  $script:rg_volTimer.Add_Tick({ if ($script:rg_lockVol) { try { [Vol]::Force() } catch {} } })
  $script:rg_sndTimer = New-Object System.Windows.Forms.Timer; $script:rg_sndTimer.Interval = 4000
  $script:rg_sndTimer.Add_Tick({
    if (-not $script:rg_haveSnd) { return }
    $script:rg_sndIdx = ($script:rg_sndIdx + 1) % 3
    $arr = switch ($script:rg_sndIdx) { 0 { $script:rg_tierA } 1 { $script:rg_tierB } default { $script:rg_tierC } }
    $arr = @($arr); if ($arr.Count -eq 0) { return }
    $pick = $arr | Get-Random
    try { $script:rg_player.Stop(); $script:rg_player.SoundLocation = $pick; $script:rg_player.Load(); $script:rg_player.PlayLooping() } catch {}
  })

  $script:rg_form.Add_Shown({
    & $script:rg_refill
    if ($script:rg_lockdown) { try { [Lockdown]::Install() } catch {}; Set-TaskMgrDisabled $true }
    if ($script:rg_lockVol) { try { [Vol]::Force() } catch {} }
    if ($script:rg_haveSnd) { $arr = @($script:rg_tierA); if ($arr.Count -gt 0) { $p = $arr | Get-Random; try { $script:rg_player.SoundLocation = $p; $script:rg_player.Load(); $script:rg_player.PlayLooping() } catch {} } }
    if ($script:rg_voice) { try { [void]$script:rg_voice.SpeakAsync("Wake up. Solve to disable the alarm.") } catch {} }
    $script:rg_rain.Timer.Start(); $script:rg_mainTimer.Start(); $script:rg_sndTimer.Start(); $script:rg_volTimer.Start()
    try { $script:rg_rows[0].Box.Focus() } catch {}
  })

  try {
    [void]$script:rg_form.ShowDialog()
  } finally {
    if ($script:rg_lockdown) { try { [Lockdown]::Remove() } catch {}; Set-TaskMgrDisabled $false }
    try { $script:rg_rain.Timer.Stop(); $script:rg_rain.Timer.Dispose() } catch {}
    try { $st = $script:rg_rain.Panel.Tag; if ($st) { foreach ($kk in 'bmp','scan','font','fade','body') { if ($st[$kk]) { $st[$kk].Dispose() } } } } catch {}
    try { $script:rg_mainTimer.Stop(); $script:rg_mainTimer.Dispose() } catch {}
    try { $script:rg_sndTimer.Stop(); $script:rg_sndTimer.Dispose() } catch {}
    try { $script:rg_volTimer.Stop(); $script:rg_volTimer.Dispose() } catch {}
    try { if ($script:rg_shakeTimer) { $script:rg_shakeTimer.Stop(); $script:rg_shakeTimer.Dispose() } } catch {}
    try { if ($script:rg_closeTimer) { $script:rg_closeTimer.Dispose() } } catch {}
    try { $script:rg_player.Stop(); $script:rg_player.Dispose() } catch {}
    try { if ($script:rg_voice) { $script:rg_voice.Dispose() } } catch {}
    try { $script:rg_form.Dispose() } catch {}
  }
  return $script:rg_solved
}

# ---- scheduling ------------------------------------------------------------
function Resolve-When([string]$time, [string]$date) {
  try {
    if ($date -ne "") {
      $w = [datetime]::ParseExact("$date $time", 'yyyy-MM-dd HH:mm', $null)
      if ($w -le (Get-Date)) { return $null }
      return $w
    } else {
      $tt = [datetime]::ParseExact($time, 'HH:mm', $null)
      $w = (Get-Date).Date.AddHours($tt.Hour).AddMinutes($tt.Minute)
      if ($w -le (Get-Date)) { $w = $w.AddDays(1) }
      return $w
    }
  } catch { return $null }
}
function Remove-Alarms {
  Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -like 'OVERRIDE_V2_*' } | ForEach-Object {
    Unregister-ScheduledTask -TaskName $_.TaskName -Confirm:$false -ErrorAction SilentlyContinue
  }
}
function Register-Alarms {
  Load-Config
  Remove-Alarms
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
      try { $when = [datetime]::ParseExact("$dateStr $($a.time)", "yyyy-MM-dd HH:mm", $null) } catch { Write-Host "  skip (bad date/time): $($a.label) $dateStr $($a.time)" -ForegroundColor Red; continue }
      if ($when -le (Get-Date)) { Write-Host "  skip (past): $($a.label) $dateStr $($a.time)" -ForegroundColor DarkYellow; continue }
      $trigger = New-ScheduledTaskTrigger -Once -At $when
      $safeAt = $when.AddMinutes(6)
      $safeTrigger = New-ScheduledTaskTrigger -Once -At $safeAt
      $desc = "once $dateStr at $($a.time)"
    } else {
      try { $at = [datetime]::ParseExact($a.time, "HH:mm", $null) } catch { Write-Host "  skip (bad time): $($a.label) $($a.time)" -ForegroundColor Red; continue }
      $trigger = New-ScheduledTaskTrigger -Daily -At $at
      $safeTrigger = New-ScheduledTaskTrigger -Daily -At $at.AddMinutes(6)
      $desc = "daily at $($a.time)"
    }
    $arg = "-NoProfile -Sta -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$($script:root)\override.ps1`" -Ring -AlarmId $($a.id)"
    $action = New-ScheduledTaskAction -Execute $pw -Argument $arg -WorkingDirectory $script:root
    $settings = New-ScheduledTaskSettingsSet -WakeToRun -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 5) -MultipleInstances IgnoreNew
    $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited
    Register-ScheduledTask -TaskName "OVERRIDE_V2_$($a.id)" -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force | Out-Null
    # safety net: restore Task Manager 6 min after the alarm, in case the ring was force-killed
    $safeArg = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$($script:root)\override.ps1`" -Unlock"
    $safeAction = New-ScheduledTaskAction -Execute $pw -Argument $safeArg -WorkingDirectory $script:root
    $safeSettings = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 2) -MultipleInstances IgnoreNew
    Register-ScheduledTask -TaskName "OVERRIDE_V2_safe_$($a.id)" -Action $safeAction -Trigger $safeTrigger -Settings $safeSettings -Principal $principal -Force | Out-Null
    Write-Host "  armed  $($a.label)  $desc" -ForegroundColor Green
    $n++
  }
  Write-Host "$n alarm(s) armed." -ForegroundColor Green
}
function Show-Tasks {
  $tasks = @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -like 'OVERRIDE_V2_a*' })
  if ($tasks.Count -eq 0) { Write-Host "   (no alarms armed)" -ForegroundColor DarkYellow; return }
  foreach ($t in ($tasks | Sort-Object TaskName)) {
    $info = $t | Get-ScheduledTaskInfo
    Write-Host ("    {0,-6} next: {1,-22} [{2}]" -f ($t.TaskName -replace '^OVERRIDE_V2_',''), $info.NextRunTime, $t.State) -ForegroundColor Green
  }
}

# ---- control panel (themed GUI; the standalone app) ------------------------
function Format-Span($ts) {
  if ($ts.TotalSeconds -lt 0) { $ts = New-TimeSpan -Seconds 0 }
  if ($ts.Days -gt 0) { return ("{0}d {1:00}:{2:00}:{3:00}" -f $ts.Days, $ts.Hours, $ts.Minutes, $ts.Seconds) }
  return ("{0:00}:{1:00}:{2:00}" -f $ts.Hours, $ts.Minutes, $ts.Seconds)
}
function Panel-Log([string]$m) { try { $script:pn_log.Text = $m } catch {} }
function Panel-LoadAlarms {
  $script:pn_alarms = @()
  foreach ($a in $script:cfg.alarms) {
    $dt = ""; if (($a.PSObject.Properties.Name -contains 'date') -and $a.date) { $dt = [string]$a.date }
    $script:pn_alarms += [pscustomobject]@{ Id=[string]$a.id; Label=[string]$a.label; Time=[string]$a.time; Date=$dt; Enabled=[bool]$a.enabled }
  }
}
function Panel-RenderRows {
  $script:pn_list.Controls.Clear()
  if (-not $script:pn_rowFonts) {
    $script:pn_rowFonts = @{
      Time = New-Object System.Drawing.Font('Consolas',13,[System.Drawing.FontStyle]::Bold)
      Text = New-Object System.Drawing.Font('Consolas',11)
      Del  = New-Object System.Drawing.Font('Consolas',9,[System.Drawing.FontStyle]::Bold)
    }
  }
  $y = 4
  foreach ($al in $script:pn_alarms) {
    $row = New-Object System.Windows.Forms.Panel; $row.Width=830; $row.Height=34; $row.Left=2; $row.Top=$y; $row.BackColor=[System.Drawing.Color]::FromArgb(0,18,8)
    $cb = New-Object System.Windows.Forms.CheckBox; $cb.Checked=$al.Enabled; $cb.Left=8; $cb.Top=8; $cb.Width=18; $cb.Tag=$al.Id
    $cb.Add_CheckedChanged({ param($s,$e) $t = $script:pn_alarms | Where-Object { $_.Id -eq $s.Tag } | Select-Object -First 1; if ($t) { $t.Enabled = $s.Checked }; Panel-UpdateStatus })
    $lt = New-Object System.Windows.Forms.Label; $lt.Text=$al.Time; $lt.Left=32; $lt.Top=8; $lt.Width=64; $lt.ForeColor=[System.Drawing.Color]::FromArgb(0,255,102); $lt.Font=$script:pn_rowFonts.Time
    $ll = New-Object System.Windows.Forms.Label; $ll.Text=$al.Label; $ll.Left=104; $ll.Top=9; $ll.Width=250; $ll.ForeColor=[System.Drawing.Color]::FromArgb(174,255,210); $ll.Font=$script:pn_rowFonts.Text
    $dtxt = "daily"; if ($al.Date) { $dtxt = $al.Date }
    $ld = New-Object System.Windows.Forms.Label; $ld.Text=$dtxt; $ld.Left=360; $ld.Top=9; $ld.Width=150; $ld.ForeColor=[System.Drawing.Color]::FromArgb(110,200,150); $ld.Font=$script:pn_rowFonts.Text
    $del = New-Object System.Windows.Forms.Button; $del.Text='DELETE'; $del.Left=730; $del.Top=4; $del.Width=90; $del.Height=26; $del.Tag=$al.Id
    $del.FlatStyle='Flat'; $del.ForeColor=[System.Drawing.Color]::FromArgb(255,90,90); $del.BackColor=[System.Drawing.Color]::FromArgb(30,0,0); $del.Font=$script:pn_rowFonts.Del
    $del.Add_Click({ param($s,$e) $script:pn_alarms = @($script:pn_alarms | Where-Object { $_.Id -ne $s.Tag }); Panel-RenderRows; Panel-UpdateStatus; Panel-Log "deleted alarm" })
    $row.Controls.AddRange(@($cb,$lt,$ll,$ld,$del))
    $script:pn_list.Controls.Add($row)
    $y += 38
  }
}
function Panel-AddAlarm {
  $t = ([string]$script:pn_inTime.Text).Trim()
  if ($t -notmatch '^([01]\d|2[0-3]):[0-5]\d$') { Panel-Log "bad time - use HH:MM (24h)"; return }
  $lab = ([string]$script:pn_inLabel.Text).Trim(); if (-not $lab) { $lab = "WAKE UP" }
  $d = ([string]$script:pn_inDate.Text).Trim()
  if ($d -ne "") {
    $parsed = [datetime]::MinValue
    if (-not [datetime]::TryParseExact($d, 'yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$parsed)) {
      Panel-Log "bad date - use a real YYYY-MM-DD (e.g. 2026-06-09) or leave blank"; return
    }
  }
  $id = "a" + ([guid]::NewGuid().ToString('N').Substring(0,6))
  $script:pn_alarms += [pscustomobject]@{ Id=$id; Label=$lab; Time=$t; Date=$d; Enabled=$true }
  $script:pn_inTime.Text=""; $script:pn_inLabel.Text=""; $script:pn_inDate.Text=""
  Panel-RenderRows; Panel-UpdateStatus; Panel-Log "added $t  $lab"
}
function Panel-SaveConfig {
  $alist = @()
  foreach ($al in $script:pn_alarms) { $alist += [ordered]@{ id=$al.Id; label=$al.Label; time=$al.Time; date=$al.Date; enabled=$al.Enabled } }
  $obj = [ordered]@{
    version = 2
    numQuestions = [int]$script:pn_numQ.SelectedItem
    difficulty = [string]$script:pn_diff.SelectedItem
    categories = [ordered]@{ arithmetic = $true }
    lockVolume = [bool]$script:pn_lockVol.Checked
    answerWindowSec = $script:answerWin
    alarms = $alist
  }
  ($obj | ConvertTo-Json -Depth 6) | Out-File -FilePath $script:cfgPath -Encoding utf8
  Load-Config
}
function Panel-RefreshArmed {
  $armed = @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -like 'OVERRIDE_V2_a*' }).Count
  if ($armed -gt 0) { $script:pn_armed.Text = "ARMED ($armed)"; $script:pn_armed.ForeColor = [System.Drawing.Color]::FromArgb(0,255,102) }
  else { $script:pn_armed.Text = "NOT ARMED"; $script:pn_armed.ForeColor = [System.Drawing.Color]::FromArgb(255,140,0) }
}
function Panel-UpdateStatus {
  $next = $null
  foreach ($al in $script:pn_alarms) {
    if (-not $al.Enabled) { continue }
    $w = Resolve-When $al.Time $al.Date
    if ($w -and ((-not $next) -or ($w -lt $next))) { $next = $w }
  }
  if ($next) { $script:pn_status.Text = ("next: {0}   in {1}" -f $next.ToString('ddd HH:mm'), (Format-Span ($next - (Get-Date)))) }
  else { $script:pn_status.Text = "no upcoming alarms" }
}
function Show-PanelGui {
  if (-not (Test-RingActive)) { Set-TaskMgrDisabled $false }   # self-heal lockdown if a ring was force-killed
  Panel-LoadAlarms
  $green = [System.Drawing.Color]::FromArgb(0,255,102); $dim = [System.Drawing.Color]::FromArgb(124,255,176)

  $script:pn_form = New-Object System.Windows.Forms.Form
  $script:pn_form.Text = "OVERRIDE // CONTROL"; $script:pn_form.FormBorderStyle = 'FixedSingle'; $script:pn_form.MaximizeBox = $false
  $script:pn_form.StartPosition = 'CenterScreen'; $script:pn_form.ClientSize = New-Object System.Drawing.Size(900,650)
  $script:pn_form.BackColor = [System.Drawing.Color]::Black
  $icoPath = Join-Path $script:root 'override.ico'
  if (Test-Path $icoPath) { try { $script:pn_form.Icon = New-Object System.Drawing.Icon $icoPath } catch {} }

  $script:pn_rain = New-RainBackground -Fps 12 -FontSize 16
  $script:pn_form.Controls.Add($script:pn_rain.Panel)

  $box = New-Object System.Windows.Forms.Panel; $box.Left=14; $box.Top=14; $box.Width=872; $box.Height=622; $box.BackColor=[System.Drawing.Color]::FromArgb(0,12,5)
  $box.Add_Paint({ param($s,$e) $r=$s.ClientRectangle; $pen=New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(0,255,102)),2; $e.Graphics.DrawRectangle($pen,1,1,$r.Width-3,$r.Height-3); $pen.Dispose() })
  $script:pn_form.Controls.Add($box); $script:pn_rain.Panel.SendToBack()

  $hdr = New-Object System.Windows.Forms.Label; $hdr.Text=("OVERRIDE // CONTROL   " + [char]0x03A9); $hdr.Left=18; $hdr.Top=14; $hdr.Width=560; $hdr.Height=40
  $hdr.ForeColor=$green; $hdr.BackColor=[System.Drawing.Color]::Transparent; $hdr.Font=New-Object System.Drawing.Font('Consolas',22,[System.Drawing.FontStyle]::Bold); $box.Controls.Add($hdr)
  $script:pn_armed = New-Object System.Windows.Forms.Label; $script:pn_armed.Left=640; $script:pn_armed.Top=22; $script:pn_armed.Width=210; $script:pn_armed.Height=26; $script:pn_armed.TextAlign='MiddleRight'
  $script:pn_armed.BackColor=[System.Drawing.Color]::Transparent; $script:pn_armed.Font=New-Object System.Drawing.Font('Consolas',13,[System.Drawing.FontStyle]::Bold); $box.Controls.Add($script:pn_armed)

  $lh = New-Object System.Windows.Forms.Label; $lh.Text="ALARMS"; $lh.Left=20; $lh.Top=62; $lh.Width=200; $lh.ForeColor=$dim; $lh.BackColor=[System.Drawing.Color]::Transparent; $lh.Font=New-Object System.Drawing.Font('Consolas',11,[System.Drawing.FontStyle]::Bold); $box.Controls.Add($lh)
  $script:pn_list = New-Object System.Windows.Forms.Panel; $script:pn_list.Left=18; $script:pn_list.Top=86; $script:pn_list.Width=836; $script:pn_list.Height=250; $script:pn_list.AutoScroll=$true; $script:pn_list.BackColor=[System.Drawing.Color]::FromArgb(0,8,3); $box.Controls.Add($script:pn_list)

  # add row
  $ay = 348
  $alab = New-Object System.Windows.Forms.Label; $alab.Text="ADD:"; $alab.Left=20; $alab.Top=($ay+4); $alab.Width=46; $alab.ForeColor=$green; $alab.BackColor=[System.Drawing.Color]::Transparent; $alab.Font=New-Object System.Drawing.Font('Consolas',11,[System.Drawing.FontStyle]::Bold); $box.Controls.Add($alab)
  $script:pn_inTime = New-Object System.Windows.Forms.TextBox; $script:pn_inTime.Left=66; $script:pn_inTime.Top=$ay; $script:pn_inTime.Width=70; $script:pn_inTime.Text=""; $script:pn_inTime.BackColor=[System.Drawing.Color]::FromArgb(0,26,10); $script:pn_inTime.ForeColor=$dim; $script:pn_inTime.BorderStyle='FixedSingle'; $script:pn_inTime.Font=New-Object System.Drawing.Font('Consolas',12)
  $tph = New-Object System.Windows.Forms.Label; $tph.Text="HH:MM"; $tph.Left=66; $tph.Top=($ay+26); $tph.Width=70; $tph.ForeColor=[System.Drawing.Color]::FromArgb(80,150,110); $tph.BackColor=[System.Drawing.Color]::Transparent; $tph.Font=New-Object System.Drawing.Font('Consolas',8)
  $script:pn_inLabel = New-Object System.Windows.Forms.TextBox; $script:pn_inLabel.Left=146; $script:pn_inLabel.Top=$ay; $script:pn_inLabel.Width=210; $script:pn_inLabel.BackColor=[System.Drawing.Color]::FromArgb(0,26,10); $script:pn_inLabel.ForeColor=$dim; $script:pn_inLabel.BorderStyle='FixedSingle'; $script:pn_inLabel.Font=New-Object System.Drawing.Font('Consolas',12)
  $lph = New-Object System.Windows.Forms.Label; $lph.Text="label"; $lph.Left=146; $lph.Top=($ay+26); $lph.Width=120; $lph.ForeColor=[System.Drawing.Color]::FromArgb(80,150,110); $lph.BackColor=[System.Drawing.Color]::Transparent; $lph.Font=New-Object System.Drawing.Font('Consolas',8)
  $script:pn_inDate = New-Object System.Windows.Forms.TextBox; $script:pn_inDate.Left=366; $script:pn_inDate.Top=$ay; $script:pn_inDate.Width=130; $script:pn_inDate.BackColor=[System.Drawing.Color]::FromArgb(0,26,10); $script:pn_inDate.ForeColor=$dim; $script:pn_inDate.BorderStyle='FixedSingle'; $script:pn_inDate.Font=New-Object System.Drawing.Font('Consolas',12)
  $dph = New-Object System.Windows.Forms.Label; $dph.Text="YYYY-MM-DD (blank=daily)"; $dph.Left=366; $dph.Top=($ay+26); $dph.Width=240; $dph.ForeColor=[System.Drawing.Color]::FromArgb(80,150,110); $dph.BackColor=[System.Drawing.Color]::Transparent; $dph.Font=New-Object System.Drawing.Font('Consolas',8)
  $addBtn = New-Object System.Windows.Forms.Button; $addBtn.Text="+ ADD"; $addBtn.Left=520; $addBtn.Top=($ay-2); $addBtn.Width=110; $addBtn.Height=30; $addBtn.FlatStyle='Flat'; $addBtn.ForeColor=$green; $addBtn.BackColor=[System.Drawing.Color]::FromArgb(0,33,15); $addBtn.Font=New-Object System.Drawing.Font('Consolas',11,[System.Drawing.FontStyle]::Bold); $addBtn.Add_Click({ Panel-AddAlarm })
  $box.Controls.AddRange(@($script:pn_inTime,$tph,$script:pn_inLabel,$lph,$script:pn_inDate,$dph,$addBtn))

  # settings row
  $sy = 410
  $sd = New-Object System.Windows.Forms.Label; $sd.Text="difficulty"; $sd.Left=20; $sd.Top=($sy+4); $sd.Width=80; $sd.ForeColor=$dim; $sd.BackColor=[System.Drawing.Color]::Transparent; $sd.Font=New-Object System.Drawing.Font('Consolas',10); $box.Controls.Add($sd)
  $script:pn_diff = New-Object System.Windows.Forms.ComboBox; $script:pn_diff.Left=104; $script:pn_diff.Top=$sy; $script:pn_diff.Width=110; $script:pn_diff.DropDownStyle='DropDownList'; $script:pn_diff.Items.AddRange(@('easy','medium','hard')); $script:pn_diff.SelectedItem = $script:diff; $box.Controls.Add($script:pn_diff)
  $sq = New-Object System.Windows.Forms.Label; $sq.Text="questions"; $sq.Left=232; $sq.Top=($sy+4); $sq.Width=82; $sq.ForeColor=$dim; $sq.BackColor=[System.Drawing.Color]::Transparent; $sq.Font=New-Object System.Drawing.Font('Consolas',10); $box.Controls.Add($sq)
  $script:pn_numQ = New-Object System.Windows.Forms.ComboBox; $script:pn_numQ.Left=318; $script:pn_numQ.Top=$sy; $script:pn_numQ.Width=60; $script:pn_numQ.DropDownStyle='DropDownList'; $script:pn_numQ.Items.AddRange(@(1,2,3,4,5,6)); $script:pn_numQ.SelectedItem = $script:numQ; if ($null -eq $script:pn_numQ.SelectedItem) { $script:pn_numQ.SelectedItem = 3 }; $box.Controls.Add($script:pn_numQ)
  $script:pn_lockVol = New-Object System.Windows.Forms.CheckBox; $script:pn_lockVol.Text="lock volume @100%"; $script:pn_lockVol.Left=400; $script:pn_lockVol.Top=($sy+2); $script:pn_lockVol.Width=210; $script:pn_lockVol.Checked=$script:lockVolCfg; $script:pn_lockVol.ForeColor=$dim; $script:pn_lockVol.BackColor=[System.Drawing.Color]::Transparent; $script:pn_lockVol.Font=New-Object System.Drawing.Font('Consolas',10); $box.Controls.Add($script:pn_lockVol)

  # action buttons
  $by = 470
  $testBtn = New-Object System.Windows.Forms.Button; $testBtn.Text="TEST RING"; $testBtn.Left=20; $testBtn.Top=$by; $testBtn.Width=160; $testBtn.Height=44; $box.Controls.Add($testBtn)
  $armBtn  = New-Object System.Windows.Forms.Button; $armBtn.Text="SAVE & ARM"; $armBtn.Left=200; $armBtn.Top=$by; $armBtn.Width=200; $armBtn.Height=44; $box.Controls.Add($armBtn)
  $disBtn  = New-Object System.Windows.Forms.Button; $disBtn.Text="DISARM ALL"; $disBtn.Left=420; $disBtn.Top=$by; $disBtn.Width=160; $disBtn.Height=44; $box.Controls.Add($disBtn)
  foreach ($b in @($testBtn,$armBtn,$disBtn)) { $b.FlatStyle='Flat'; $b.ForeColor=$green; $b.BackColor=[System.Drawing.Color]::FromArgb(0,33,15); $b.Font=New-Object System.Drawing.Font('Consolas',13,[System.Drawing.FontStyle]::Bold) }

  $script:pn_status = New-Object System.Windows.Forms.Label; $script:pn_status.Left=20; $script:pn_status.Top=534; $script:pn_status.Width=560; $script:pn_status.Height=24; $script:pn_status.ForeColor=[System.Drawing.Color]::FromArgb(120,220,160); $script:pn_status.BackColor=[System.Drawing.Color]::Transparent; $script:pn_status.Font=New-Object System.Drawing.Font('Consolas',12); $box.Controls.Add($script:pn_status)
  $script:pn_log = New-Object System.Windows.Forms.Label; $script:pn_log.Left=20; $script:pn_log.Top=560; $script:pn_log.Width=836; $script:pn_log.Height=22; $script:pn_log.ForeColor=[System.Drawing.Color]::FromArgb(90,170,120); $script:pn_log.BackColor=[System.Drawing.Color]::Transparent; $script:pn_log.Font=New-Object System.Drawing.Font('Consolas',10); $box.Controls.Add($script:pn_log)
  $hint = New-Object System.Windows.Forms.Label; $hint.Text="alarms fire via Windows even if this window is closed  |  0% CPU between alarms"; $hint.Left=20; $hint.Top=586; $hint.Width=836; $hint.Height=20; $hint.ForeColor=[System.Drawing.Color]::FromArgb(70,130,95); $hint.BackColor=[System.Drawing.Color]::Transparent; $hint.Font=New-Object System.Drawing.Font('Consolas',9); $box.Controls.Add($hint)

  $testBtn.Add_Click({
    try { $script:pn_rain.Timer.Stop() } catch {}
    try { $script:pn_statusTimer.Stop() } catch {}
    try {
      [void](Show-Ring -Label "TEST" -N ([int]$script:pn_numQ.SelectedItem) -Diff ([string]$script:pn_diff.SelectedItem) -LockVol ([bool]$script:pn_lockVol.Checked) -WindowSec 30 -TestMode $true -Lockdown $false)
    } catch { Panel-Log ("test ring error: " + $_.Exception.Message) }
    finally {
      try { $script:pn_rain.Timer.Start() } catch {}
      try { $script:pn_statusTimer.Start() } catch {}
    }
    Panel-Log "test ring closed"
  })
  $armBtn.Add_Click({
    Panel-SaveConfig; Panel-Log "saving + arming..."; $script:pn_form.Refresh()
    try { Register-Alarms } catch { Panel-Log ("arm error: " + $_.Exception.Message) }
    Panel-RefreshArmed; Panel-UpdateStatus; Panel-Log "armed. alarms will fire even if you close this window."
  })
  $disBtn.Add_Click({ Remove-Alarms; Panel-RefreshArmed; Panel-UpdateStatus; Panel-Log "all alarms disarmed." })

  $script:pn_statusTimer = New-Object System.Windows.Forms.Timer; $script:pn_statusTimer.Interval = 1000
  $script:pn_statusTimer.Add_Tick({ Panel-UpdateStatus })
  # pause animation when the window is not in focus (fan-safe)
  $script:pn_form.Add_Activated({ try { if ($script:pn_form.WindowState -ne 'Minimized') { $script:pn_rain.Timer.Start() } } catch {} })
  $script:pn_form.Add_Deactivate({ try { $script:pn_rain.Timer.Stop() } catch {} })
  $script:pn_form.Add_Resize({ try { if ($script:pn_form.WindowState -eq 'Minimized') { $script:pn_rain.Timer.Stop() } else { $script:pn_rain.Timer.Start() } } catch {} })

  $script:pn_form.Add_Shown({
    Panel-RenderRows; Panel-RefreshArmed; Panel-UpdateStatus
    $script:pn_rain.Timer.Start(); $script:pn_statusTimer.Start()
    if ($script:pn_testSec -gt 0) {
      $script:pn_auto = New-Object System.Windows.Forms.Timer; $script:pn_auto.Interval = ($script:pn_testSec * 1000)
      $script:pn_auto.Add_Tick({ $script:pn_auto.Stop(); $script:pn_form.Close() }); $script:pn_auto.Start()
    }
  })

  try { [void]$script:pn_form.ShowDialog() }
  finally {
    try { $script:pn_rain.Timer.Stop(); $script:pn_rain.Timer.Dispose() } catch {}
    try { $script:pn_statusTimer.Stop(); $script:pn_statusTimer.Dispose() } catch {}
    try { if ($script:pn_auto) { $script:pn_auto.Dispose() } } catch {}
    try { $st = $script:pn_rain.Panel.Tag; if ($st) { foreach ($kk in 'bmp','scan','font','fade','body') { if ($st[$kk]) { $st[$kk].Dispose() } } } } catch {}
    try { $script:pn_form.Dispose() } catch {}
  }
}

# ---- dispatch --------------------------------------------------------------
if ($Probe)  { Set-Content -Path (Join-Path $script:root "probe.ok") -Value ((Get-Date).ToString("o")) -Encoding ASCII; return }
if ($Unlock) { Invoke-Unlock; return }
if ($SelfTest) {
  Write-Host ("sample {0} arithmetic questions:" -f $script:diff) -ForegroundColor Green
  1..6 | ForEach-Object { $q = New-Question -Diff $script:diff; "   {0,-12} {1}" -f $q.Text, $q.Answer }
  return
}
if ($Disarm) { Write-Host "OVERRIDE v2 // disarming..." -ForegroundColor Yellow; Remove-Alarms; return }
if ($Arm)    { Write-Host "OVERRIDE v2 // arming..." -ForegroundColor Green; Register-Alarms; return }
if ($DryRun) { Write-Host ("OVERRIDE v2 schedule  ({0})" -f (Get-Date)) -ForegroundColor Green; Show-Tasks; return }

if ($LockTest) {
  # internal: exercise the REAL lockdown path (hook + DisableTaskMgr) with an Esc hatch + timeout
  [void](Show-Ring -Label "LOCKTEST" -N $script:numQ -Diff $script:diff -LockVol $false -WindowSec $TestWindowSec -Quiet:$true -TestMode $true -Lockdown $true)
  return
}

if ($TestNow) {
  Write-Host "TEST: opening the ring (Esc closes it; no lockdown in test)..." -ForegroundColor Yellow
  [void](Show-Ring -Label "TEST" -N $script:numQ -Diff $script:diff -LockVol $script:lockVolCfg -WindowSec $TestWindowSec -Quiet:$Quiet -TestMode $true -Lockdown $false)
  Write-Host "TEST: closed cleanly." -ForegroundColor Green
  return
}

if ($Ring) {
  $mtx = New-Object System.Threading.Mutex($false, "Local\OVERRIDE_V2_ring_lock")
  $got = $true
  try { $got = $mtx.WaitOne(0) } catch { $got = $true }
  if (-not $got) { return }
  try {
    $label = "WAKE UP"
    if ($AlarmId -ne "") { $a = $script:cfg.alarms | Where-Object { $_.id -eq $AlarmId } | Select-Object -First 1; if ($a) { $label = [string]$a.label } }
    [void](Show-Ring -Label $label -N $script:numQ -Diff $script:diff -LockVol $script:lockVolCfg -WindowSec $script:answerWin -Lockdown $true)
  } finally {
    Invoke-Unlock                      # belt-and-suspenders: ensure lockdown is released
    try { $mtx.ReleaseMutex() } catch {}
  }
  return
}

# default: standalone control panel
$script:pn_testSec = $PanelTestSec
Show-PanelGui
