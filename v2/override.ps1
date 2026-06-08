param(
  [switch]$Ring, [string]$AlarmId = "", [switch]$TestNow,
  [switch]$Arm, [switch]$Disarm, [switch]$Unlock,
  [switch]$DryRun, [switch]$Probe, [int]$PanelTestSec = 0, [switch]$AutoDeploy
)
# OVERRIDE v2 (clean) // WAKE PROTOCOL
# - Alarms fire via Windows Scheduled Tasks -> ephemeral ring process. 0 CPU between alarms.
# - The ring drives v1's EXACT quiz (wake_quiz.hta): matrix rain, fake errors, all 5 subjects
#   (arithmetic, derivatives, vectors, matrices, capitals). The engine adds: escalating sound,
#   un-mutable volume (~5x/sec), keyboard lockdown, fullscreen pin, and relaunch-if-closed.
# - NO watchdog/respawn cascade (that was v1's CPU/crash); one ephemeral process, mutex-guarded,
#   self-ends at the per-alarm duration.
# - Standalone GUI control panel with PER-ALARM settings (difficulty / # questions / subjects /
#   duration / rhythm-daily). Blank date => next occurrence; Rhythm => every day.

$ErrorActionPreference = "Stop"
$script:root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$script:cfgPath = Join-Path $script:root "config.json"
$script:CATS = @('arithmetic','derivatives','vectors','matrices','capitals')

function Load-Config { $script:cfg = Get-Content $script:cfgPath -Raw | ConvertFrom-Json }
Load-Config

# ---- assemblies + native ---------------------------------------------------
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
  static Proc _proc = Hook;
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
        else if(vk==0x1B && ctrl && shift) block=true;      // Ctrl+Shift+Esc
        else if(vk==0x73 && alt) block=true;                // Alt+F4
        if(block) return (IntPtr)1;
      }
    }
    return CallNextHookEx(_h, code, w, l);
  }
}
"@
try { Add-Type -TypeDefinition $lockSrc -Language CSharp } catch {}

$winSrc = @"
using System; using System.Runtime.InteropServices;
public static class Win {
  [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h, IntPtr a, int x, int y, int cx, int cy, uint f);
  [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int n);
  [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] static extern bool AttachThreadInput(uint a, uint b, bool f);
  [DllImport("user32.dll")] static extern bool BringWindowToTop(IntPtr h);
  [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
  static readonly IntPtr HWND_TOPMOST = new IntPtr(-1);
  public static void Pin(IntPtr h, int x, int y, int w, int hh) {   // once: bring up + take foreground
    if (h == IntPtr.Zero) return;
    ShowWindow(h, 5);                                       // SW_SHOW
    SetWindowPos(h, HWND_TOPMOST, x, y, w, hh, 0x0040);     // SWP_SHOWWINDOW
    SetForegroundWindow(h);
  }
  public static void Top(IntPtr h, int x, int y, int w, int hh) {   // maintain: topmost + position only, NO focus-steal
    if (h == IntPtr.Zero) return;
    SetWindowPos(h, HWND_TOPMOST, x, y, w, hh, 0x0040);
  }
  public static bool IsForeground(IntPtr h){ return GetForegroundWindow() == h; }
  public static void Force(IntPtr h, int x, int y, int w, int hh){   // reliably bring h ON TOP + focused over the current foreground app (e.g. Edge)
    if (h == IntPtr.Zero) return;
    ShowWindow(h, 5);
    SetWindowPos(h, HWND_TOPMOST, x, y, w, hh, 0x0040);
    uint pid; uint fg = GetWindowThreadProcessId(GetForegroundWindow(), out pid);
    uint cur = GetCurrentThreadId();
    if (fg != cur) AttachThreadInput(cur, fg, true);
    BringWindowToTop(h); SetForegroundWindow(h);
    if (fg != cur) AttachThreadInput(cur, fg, false);
  }
}
"@
try { Add-Type -TypeDefinition $winSrc -Language CSharp } catch {}

# ---- lockdown helpers ------------------------------------------------------
function Set-TaskMgrDisabled([bool]$on) {
  try {
    $sub = 'Software\Microsoft\Windows\CurrentVersion\Policies\System'
    if ($on) { $k = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($sub); if ($k) { $k.SetValue('DisableTaskMgr',1,[Microsoft.Win32.RegistryValueKind]::DWord); $k.Close() } }
    else { $k = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($sub,$true); if ($k) { try { $k.DeleteValue('DisableTaskMgr',$false) } catch {}; $k.Close() } }
  } catch {}
}
function Invoke-Unlock { Set-TaskMgrDisabled $false; try { [Lockdown]::Remove() } catch {} }
function Test-RingActive {
  try { $m = New-Object System.Threading.Mutex($false,'Local\OVERRIDE_V2_ring_lock'); $g = $m.WaitOne(0); if ($g) { $m.ReleaseMutex(); $m.Dispose(); return $false }; $m.Dispose(); return $true } catch { return $false }
}

# ---- settings helpers ------------------------------------------------------
function Convert-Cats($catObj) {
  $h = [ordered]@{}
  foreach ($c in $script:CATS) { $v = $false; if ($catObj -and ($catObj.PSObject.Properties.Name -contains $c)) { $v = [bool]$catObj.$c }; $h[$c] = $v }
  $h
}
function Get-AlarmSettings($id) {
  Load-Config
  $d = $script:cfg.defaults
  $a = $script:cfg.alarms | Where-Object { $_.id -eq $id } | Select-Object -First 1
  if (-not $a) { return @{ Label='WAKE UP'; Diff=[string]$d.difficulty; NumQ=[int]$d.numQuestions; Cats=(Convert-Cats $d.categories); DurationSec=([int]$d.durationMin*60); LockVol=[bool]$d.lockVolume; Lockdown=$true; Relaunch=$true } }
  $diff = if ($a.PSObject.Properties.Name -contains 'difficulty') { [string]$a.difficulty } else { [string]$d.difficulty }
  $nq   = if ($a.PSObject.Properties.Name -contains 'numQuestions') { [int]$a.numQuestions } else { [int]$d.numQuestions }
  $dur  = if ($a.PSObject.Properties.Name -contains 'durationMin') { [int]$a.durationMin } else { [int]$d.durationMin }
  $lv   = if ($a.PSObject.Properties.Name -contains 'lockVolume') { [bool]$a.lockVolume } else { [bool]$d.lockVolume }
  $cats = if ($a.PSObject.Properties.Name -contains 'categories') { Convert-Cats $a.categories } else { Convert-Cats $d.categories }
  if ($dur -lt 1) { $dur = 1 }
  return @{ Label=[string]$a.label; Diff=$diff; NumQ=$nq; Cats=$cats; DurationSec=($dur*60); LockVol=$lv; Lockdown=$true; Relaunch=$true }
}
function Get-TestSettings {
  $p = Join-Path $script:root 'session.testcfg'
  $diff='hard'; $nq=3; $cats=(Convert-Cats $script:cfg.defaults.categories); $dur=45; $lv=$true
  if (Test-Path $p) { try { $t = Get-Content $p -Raw | ConvertFrom-Json
    if ($t.difficulty) { $diff=[string]$t.difficulty }
    if ($t.numQuestions) { $nq=[int]$t.numQuestions }
    if ($t.categories) { $cats=Convert-Cats $t.categories }
    if ($t.PSObject.Properties.Name -contains 'lockVolume') { $lv=[bool]$t.lockVolume }
  } catch {} }
  return @{ Label='TEST'; Diff=$diff; NumQ=$nq; Cats=$cats; DurationSec=$dur; LockVol=$lv; Lockdown=$false; Relaunch=$false }
}

# ---- the ring engine -------------------------------------------------------
function Remove-RingFiles {
  foreach ($f in 'UNLOCK','PANIC','session.beat','session.key','session.deadline','session.start','session.label','session.quizcfg') {
    $p = Join-Path $script:root $f; if (Test-Path $p) { try { [System.IO.File]::Delete($p) } catch {} }
  }
}
function Launch-HTA {
  try {
    $exe = Join-Path $env:WINDIR 'System32\mshta.exe'
    $hta = '"' + (Join-Path $script:root 'wake_quiz.hta') + '"'
    $script:rg_mshta = Start-Process $exe -ArgumentList $hta -PassThru
  } catch { $script:rg_mshta = $null }
}
function End-Ring {
  if ($script:rg_exiting) { return }
  $script:rg_exiting = $true
  try { $script:rg_mainTimer.Stop(); $script:rg_sndTimer.Stop(); $script:rg_volTimer.Stop() } catch {}
  try { $script:rg_player.Stop() } catch {}
  try { [System.Windows.Forms.Application]::ExitThread() } catch {}
}
function Ring-Tick {
  $now = Get-Date
  try { Set-Content -Path (Join-Path $script:root 'session.beat') -Value ($now.Ticks) -Encoding ASCII } catch {}
  # solved?
  $unlk = Join-Path $script:root 'UNLOCK'
  if (Test-Path $unlk) { $c = (Get-Content $unlk -Raw); if ($c) { $c = $c.Trim() }; if ($c -eq $script:rg_key) { $script:rg_solved = $true; End-Ring; return } }
  # deadline / panic
  if ($now -ge $script:rg_deadline -or (Test-Path (Join-Path $script:root 'PANIC'))) { End-Ring; return }
  # ensure the HTA is alive + pinned fullscreen on top
  $script:rg_tk++
  $alive = ($null -ne $script:rg_mshta) -and (-not $script:rg_mshta.HasExited)
  if (-not $alive) {
    if ($script:rg_relaunch) { Launch-HTA; $script:rg_pinnedH = [IntPtr]::Zero } else { End-Ring; return }
  } else {
    try {
      $script:rg_mshta.Refresh(); $h = $script:rg_mshta.MainWindowHandle
      if ($h -ne [IntPtr]::Zero) {
        if ($h -ne $script:rg_pinnedH) { $script:rg_pinnedH = $h; $script:rg_fgTries = 0 }
        if ($script:rg_fgTries -lt 10 -and -not [Win]::IsForeground($h)) { [Win]::Force($h, 0, 0, $script:rg_sw, $script:rg_sh); $script:rg_fgTries++ }  # keep pulling it on top+focus until it wins (first ~5s)
        elseif (($script:rg_tk % 6) -eq 0) { [Win]::Top($h, 0, 0, $script:rg_sw, $script:rg_sh) }                                                        # then just hold topmost, no focus-steal -> no freeze
      }
    } catch {}
  }
  if ($script:rg_lockdown -and (($script:rg_tk % 6) -eq 0)) { try { Get-Process -Name Taskmgr -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue } catch {} }
  if ($script:rg_voice -and ($now -ge $script:rg_nagAt)) { try { [void]$script:rg_voice.SpeakAsync(($script:rg_nags | Get-Random)) } catch {}; $script:rg_nagAt = $now.AddSeconds(13) }
}
function Run-Ring {
  param([hashtable]$S)
  $script:rg_exiting = $false
  # session files
  foreach ($f in 'UNLOCK','PANIC','session.beat') { $q = Join-Path $script:root $f; if (Test-Path $q) { try { [System.IO.File]::Delete($q) } catch {} } }
  $key = [guid]::NewGuid().ToString('N')
  $start = Get-Date; $script:rg_deadline = $start.AddSeconds($S.DurationSec); $script:rg_key = $key
  Set-Content -Path (Join-Path $script:root 'session.key')      -Value $key -Encoding ASCII
  Set-Content -Path (Join-Path $script:root 'session.deadline') -Value ($script:rg_deadline.ToString('o')) -Encoding ASCII
  Set-Content -Path (Join-Path $script:root 'session.start')    -Value ($start.ToString('o')) -Encoding ASCII
  Set-Content -Path (Join-Path $script:root 'session.label')    -Value $S.Label -Encoding ASCII
  $qc = [ordered]@{ numQuestions = $S.NumQ; difficulty = $S.Diff; categories = $S.Cats }
  ($qc | ConvertTo-Json -Compress) | Set-Content -Path (Join-Path $script:root 'session.quizcfg') -Encoding ASCII

  $script:rg_relaunch = $S.Relaunch; $script:rg_lockdown = $S.Lockdown; $script:rg_lockVol = $S.LockVol
  $script:rg_mshta = $null; $script:rg_sndIdx = 0; $script:rg_nagAt = $start.AddSeconds(14); $script:rg_tk = 0; $script:rg_pinnedH = [IntPtr]::Zero; $script:rg_fgTries = 0
  $sb = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds; $script:rg_sw = $sb.Width; $script:rg_sh = $sb.Height
  $script:rg_nags = @("Solve it. Wake up.","Still horizontal? Pathetic.","I can do this all morning.","Your blanket will not save you.","Recompute. Now.")

  # sounds
  $t1=@(); $t2=@(); $t3=@()
  $sf = Join-Path $script:root 'sounds'
  if (Test-Path $sf) { foreach ($w in @(Get-ChildItem $sf -File | Where-Object { $_.Extension -match '(?i)\.wav$' })) {
    if ($w.Name -like 't2_*') { $t2 += $w.FullName } elseif ($w.Name -like 't3_*') { $t3 += $w.FullName } else { $t1 += $w.FullName } } }
  if (@($t1).Count -eq 0) { $t1 = $t2 }; if (@($t2).Count -eq 0) { $t2 = $t1 }; if (@($t3).Count -eq 0) { $t3 = $t2 }
  $script:rg_tierA=@($t1); $script:rg_tierB=@($t2); $script:rg_tierC=@($t3); $script:rg_haveSnd=(@($t1).Count -gt 0)
  $script:rg_player = New-Object System.Media.SoundPlayer
  $script:rg_voice = $null
  try { $script:rg_voice = New-Object System.Speech.Synthesis.SpeechSynthesizer; $script:rg_voice.Volume = 100 } catch {}
  if ($script:rg_lockVol) { try { [Vol]::Init() } catch {} }

  $script:rg_volTimer = New-Object System.Windows.Forms.Timer; $script:rg_volTimer.Interval = 200
  $script:rg_volTimer.Add_Tick({ if ($script:rg_lockVol) { try { [Vol]::Force() } catch {} } })
  $script:rg_mainTimer = New-Object System.Windows.Forms.Timer; $script:rg_mainTimer.Interval = 500
  $script:rg_mainTimer.Add_Tick({ Ring-Tick })
  $script:rg_sndTimer = New-Object System.Windows.Forms.Timer; $script:rg_sndTimer.Interval = 3500
  $script:rg_sndTimer.Add_Tick({
    if (-not $script:rg_haveSnd) { return }
    $script:rg_sndIdx = ($script:rg_sndIdx + 1) % 3
    $arr = switch ($script:rg_sndIdx) { 0 { $script:rg_tierA } 1 { $script:rg_tierB } default { $script:rg_tierC } }
    $arr = @($arr); if ($arr.Count -eq 0) { return }
    $pick = $arr | Get-Random
    try { $script:rg_player.Stop(); $script:rg_player.SoundLocation = $pick; $script:rg_player.Load(); $script:rg_player.PlayLooping() } catch {}
  })

  if ($script:rg_lockdown) { try { [Lockdown]::Install() } catch {}; Set-TaskMgrDisabled $true }
  Launch-HTA
  if ($script:rg_haveSnd) { $arr = @($script:rg_tierA); if ($arr.Count -gt 0) { $pp = $arr | Get-Random; try { $script:rg_player.SoundLocation = $pp; $script:rg_player.Load(); $script:rg_player.PlayLooping() } catch {} } }
  if ($script:rg_lockVol) { try { [Vol]::Force() } catch {} }
  if ($script:rg_voice) { try { [void]$script:rg_voice.SpeakAsync("Wake up. Solve to disable the alarm.") } catch {} }
  $script:rg_volTimer.Start(); $script:rg_mainTimer.Start(); $script:rg_sndTimer.Start()

  try { [System.Windows.Forms.Application]::Run() }
  finally {
    try { $script:rg_volTimer.Stop(); $script:rg_volTimer.Dispose() } catch {}
    try { $script:rg_mainTimer.Stop(); $script:rg_mainTimer.Dispose() } catch {}
    try { $script:rg_sndTimer.Stop(); $script:rg_sndTimer.Dispose() } catch {}
    if ($script:rg_lockdown) { try { [Lockdown]::Remove() } catch {}; Set-TaskMgrDisabled $false }
    try { $script:rg_player.Stop(); $script:rg_player.Dispose() } catch {}
    try { if ($script:rg_voice) { $script:rg_voice.Dispose() } } catch {}
    try { if ($script:rg_mshta -and -not $script:rg_mshta.HasExited) { $script:rg_mshta.Kill() } } catch {}
    try { Get-CimInstance Win32_Process -Filter "Name='mshta.exe'" | Where-Object { $_.CommandLine -match 'wake_quiz\.hta' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue } } catch {}
    Remove-RingFiles
  }
}

# ---- scheduling ------------------------------------------------------------
function Resolve-When([string]$time, [string]$date, [bool]$rhythm) {
  try {
    $tt = [datetime]::ParseExact($time, 'HH:mm', $null)
    if ($rhythm) { $w = (Get-Date).Date.AddHours($tt.Hour).AddMinutes($tt.Minute); if ($w -le (Get-Date)) { $w = $w.AddDays(1) }; return $w }
    if ($date -ne '') { $w = [datetime]::ParseExact("$date $time", 'yyyy-MM-dd HH:mm', $null); if ($w -le (Get-Date)) { return $null }; return $w }
    $w = (Get-Date).Date.AddHours($tt.Hour).AddMinutes($tt.Minute); if ($w -le (Get-Date)) { $w = $w.AddDays(1) }; return $w
  } catch { return $null }
}
function Remove-Alarms {
  Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -like 'OVERRIDE_V2_*' } | ForEach-Object { Unregister-ScheduledTask -TaskName $_.TaskName -Confirm:$false -ErrorAction SilentlyContinue }
}
function Register-Alarms {
  Load-Config; Remove-Alarms
  try { $sub="238c9fa8-0aad-41ed-83f4-97be242c8f20"; $set="bd3b718a-0680-4d9d-8ab2-e1d2b4ac806d"
    powercfg /setacvalueindex SCHEME_CURRENT $sub $set 1 | Out-Null; powercfg /setdcvalueindex SCHEME_CURRENT $sub $set 1 | Out-Null; powercfg /setactive SCHEME_CURRENT | Out-Null } catch {}
  $pw = (Get-Command powershell).Source; $n = 0
  foreach ($a in $script:cfg.alarms) {
    if (-not $a.enabled) { continue }
    $time = [string]$a.time
    $rhythm = ($a.PSObject.Properties.Name -contains 'rhythm') -and [bool]$a.rhythm
    $dateStr = ""; if (($a.PSObject.Properties.Name -contains 'date') -and $a.date) { $dateStr = ([string]$a.date).Trim() }
    try { $tt = [datetime]::ParseExact($time, 'HH:mm', $null) } catch { Write-Host "  skip (bad time): $($a.label) $time" -ForegroundColor Red; continue }
    if ($rhythm) {
      $trigger = New-ScheduledTaskTrigger -Daily -At $tt; $safeTrigger = New-ScheduledTaskTrigger -Daily -At $tt.AddMinutes(6); $desc = "rhythm: daily at $time"
    } elseif ($dateStr -ne "") {
      try { $when = [datetime]::ParseExact("$dateStr $time", 'yyyy-MM-dd HH:mm', $null) } catch { Write-Host "  skip (bad date): $($a.label) $dateStr" -ForegroundColor Red; continue }
      if ($when -le (Get-Date)) { Write-Host "  skip (past): $($a.label) $dateStr $time" -ForegroundColor DarkYellow; continue }
      $trigger = New-ScheduledTaskTrigger -Once -At $when; $safeTrigger = New-ScheduledTaskTrigger -Once -At $when.AddMinutes(6); $desc = "once $dateStr at $time"
    } else {
      $when = Resolve-When $time '' $false; if (-not $when) { continue }
      $trigger = New-ScheduledTaskTrigger -Once -At $when; $safeTrigger = New-ScheduledTaskTrigger -Once -At $when.AddMinutes(6); $desc = "next $($when.ToString('ddd HH:mm'))"
    }
    $durMin = if ($a.PSObject.Properties.Name -contains 'durationMin') { [int]$a.durationMin } else { [int]$script:cfg.defaults.durationMin }
    if ($durMin -lt 1) { $durMin = 1 }
    $arg = "-NoProfile -Sta -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$($script:root)\override.ps1`" -Ring -AlarmId $($a.id)"
    $action = New-ScheduledTaskAction -Execute $pw -Argument $arg -WorkingDirectory $script:root
    $settings = New-ScheduledTaskSettingsSet -WakeToRun -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes ($durMin + 4)) -MultipleInstances IgnoreNew
    $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited
    Register-ScheduledTask -TaskName "OVERRIDE_V2_$($a.id)" -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force | Out-Null
    $safeArg = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$($script:root)\override.ps1`" -Unlock"
    $safeAction = New-ScheduledTaskAction -Execute $pw -Argument $safeArg -WorkingDirectory $script:root
    $safeSettings = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 2) -MultipleInstances IgnoreNew
    Register-ScheduledTask -TaskName "OVERRIDE_V2_safe_$($a.id)" -Action $safeAction -Trigger $safeTrigger -Settings $safeSettings -Principal $principal -Force | Out-Null
    Write-Host "  armed  $($a.label)  $desc" -ForegroundColor Green; $n++
  }
  Write-Host "$n alarm(s) armed." -ForegroundColor Green
}
function Show-Tasks {
  $tasks = @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -like 'OVERRIDE_V2_*' -and $_.TaskName -notlike '*_safe_*' })
  if ($tasks.Count -eq 0) { Write-Host "   (no alarms armed)" -ForegroundColor DarkYellow; return }
  foreach ($t in ($tasks | Sort-Object TaskName)) { $i = $t | Get-ScheduledTaskInfo; Write-Host ("    {0,-8} next: {1,-22} [{2}]" -f ($t.TaskName -replace '^OVERRIDE_V2_',''), $i.NextRunTime, $t.State) -ForegroundColor Green }
}

# ---- matrix rain (shared, fps-capped, double-buffered) ---------------------
function Update-RainSize($p) {
  $st = $p.Tag
  $dw = [math]::Max(1,$p.ClientSize.Width); $dh = [math]::Max(1,$p.ClientSize.Height)
  $st.dispW = $dw; $st.dispH = $dh
  # cap internal render resolution (scale up on paint) so cost does NOT grow with screen size
  $w = $dw; $h = $dh
  if ($w -gt 900) { $sf = 900.0 / $w; $w = 900; $h = [math]::Max(1,[int]($h * $sf)) }
  if ($st.bmp -and $st.bmp.Width -eq $w -and $st.bmp.Height -eq $h) { return }
  if ($st.bmp) { $st.bmp.Dispose() }
  $st.bmp = New-Object System.Drawing.Bitmap $w, $h
  $g = [System.Drawing.Graphics]::FromImage($st.bmp); $g.Clear([System.Drawing.Color]::Black); $g.Dispose()
  $st.cols = [int][math]::Ceiling($w / $st.fh)
  $d = New-Object 'int[]' $st.cols; for ($i=0;$i -lt $st.cols;$i++) { $d[$i] = $st.rng.Next(0,[int]($h/$st.fh)+1) }; $st.drops = $d
  if ($st.scan) { $st.scan.Dispose() }
  $st.scan = New-Object System.Drawing.Bitmap $w, $h
  $sg = [System.Drawing.Graphics]::FromImage($st.scan); $sg.Clear([System.Drawing.Color]::FromArgb(0,0,0,0))
  $pen = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(45,0,0,0)); for ($y=0;$y -lt $h;$y+=3) { $sg.DrawLine($pen,0,$y,$w,$y) }; $pen.Dispose(); $sg.Dispose()
}
function Step-Rain($p) {
  $st = $p.Tag; if (-not $st.bmp) { Update-RainSize $p }; if (-not $st.bmp) { return }
  $g = [System.Drawing.Graphics]::FromImage($st.bmp); $w = $st.bmp.Width; $h = $st.bmp.Height
  $g.FillRectangle($st.fade, 0, 0, $w, $h); $n = $st.chars.Length
  for ($i=0;$i -lt $st.cols;$i++) {
    $ch = [string]$st.chars[$st.rng.Next(0,$n)]; $x = $i*$st.fh; $y = $st.drops[$i]*$st.fh
    $g.DrawString($ch, $st.font, $st.body, [single]$x, [single]$y)
    if (($st.drops[$i]*$st.fh) -gt $h -and $st.rng.NextDouble() -gt 0.975) { $st.drops[$i] = 0 } else { $st.drops[$i] = $st.drops[$i] + 1 }
  }
  $g.DrawImageUnscaled($st.scan, 0, 0); $g.Dispose(); $p.Invalidate()
}
function New-RainBackground {
  param([int]$Fps = 12, [int]$FontSize = 16)
  $panel = New-Object System.Windows.Forms.Panel; $panel.Dock = 'Fill'; $panel.BackColor = [System.Drawing.Color]::Black
  try { $bf = [System.Reflection.BindingFlags]([System.Reflection.BindingFlags]::Instance -bor [System.Reflection.BindingFlags]::NonPublic); $panel.GetType().GetProperty('DoubleBuffered',$bf).SetValue($panel,$true,$null) } catch {}
  $st = @{ bmp=$null; scan=$null; drops=$null; cols=0; fh=$FontSize
    font=(New-Object System.Drawing.Font('Consolas',$FontSize,[System.Drawing.FontStyle]::Bold))
    chars='0123456789ABCDEF#$%*+=<>/\|'; fade=(New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(38,0,0,0)))
    body=(New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(0,255,102))); rng=(New-Object System.Random); dispW=0; dispH=0 }
  $panel.Tag = $st
  $panel.Add_Paint({ param($s,$e) $stt = $s.Tag; if ($stt.bmp) { $e.Graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::NearestNeighbor; $e.Graphics.DrawImage($stt.bmp, 0, 0, [int]$stt.dispW, [int]$stt.dispH) } })
  $panel.Add_Resize({ param($s,$e) Update-RainSize $s })
  $timer = New-Object System.Windows.Forms.Timer; $timer.Interval = [int](1000/$Fps); $timer.Tag = $panel
  $timer.Add_Tick({ param($s,$e) Step-Rain $s.Tag })
  [pscustomobject]@{ Panel=$panel; Timer=$timer }
}

# ---- control panel ---------------------------------------------------------
function Format-Span($ts) {
  if ($ts.TotalSeconds -lt 0) { $ts = New-TimeSpan -Seconds 0 }
  if ($ts.Days -gt 0) { return ("{0}d {1:00}:{2:00}:{3:00}" -f $ts.Days,$ts.Hours,$ts.Minutes,$ts.Seconds) }
  return ("{0:00}:{1:00}:{2:00}" -f $ts.Hours,$ts.Minutes,$ts.Seconds)
}
function Panel-Log([string]$m) { try { $script:pn_log.Text = $m } catch {} }
function New-Alarm { param($d)
  [pscustomobject]@{ Id=("a"+[guid]::NewGuid().ToString('N').Substring(0,6)); Label='WAKE UP'; Time=''; Date=''; Rhythm=$false; Enabled=$true
    Diff=[string]$d.difficulty; NumQ=[int]$d.numQuestions; DurationMin=[int]$d.durationMin; LockVol=[bool]$d.lockVolume; Cats=(Convert-Cats $d.categories) }
}
function Panel-LoadAlarms {
  $script:pn_alarms = @(); $d = $script:cfg.defaults
  foreach ($a in $script:cfg.alarms) {
    $dt=''; if (($a.PSObject.Properties.Name -contains 'date') -and $a.date) { $dt=[string]$a.date }
    $script:pn_alarms += [pscustomobject]@{
      Id=[string]$a.id; Label=[string]$a.label; Time=[string]$a.time; Date=$dt
      Rhythm=(($a.PSObject.Properties.Name -contains 'rhythm') -and [bool]$a.rhythm); Enabled=[bool]$a.enabled
      Diff=$(if($a.PSObject.Properties.Name -contains 'difficulty') { [string]$a.difficulty } else { [string]$d.difficulty })
      NumQ=$(if($a.PSObject.Properties.Name -contains 'numQuestions') { [int]$a.numQuestions } else { [int]$d.numQuestions })
      DurationMin=$(if($a.PSObject.Properties.Name -contains 'durationMin') { [int]$a.durationMin } else { [int]$d.durationMin })
      LockVol=$(if($a.PSObject.Properties.Name -contains 'lockVolume') { [bool]$a.lockVolume } else { [bool]$d.lockVolume })
      Cats=$(if($a.PSObject.Properties.Name -contains 'categories') { Convert-Cats $a.categories } else { Convert-Cats $d.categories })
    }
  }
}
function Cats-Summary($cats) {
  $on = @(); foreach ($c in $script:CATS) { if ($cats[$c]) { $on += $c.Substring(0,3) } }
  if ($on.Count -eq 0) { return 'arith' }; return ($on -join ',')
}
function Panel-RenderRows {
  $script:pn_list.Controls.Clear()
  if (-not $script:pn_rowFonts) { $script:pn_rowFonts = @{ T=(New-Object System.Drawing.Font('Consolas',13,[System.Drawing.FontStyle]::Bold)); N=(New-Object System.Drawing.Font('Consolas',11)); B=(New-Object System.Drawing.Font('Consolas',9,[System.Drawing.FontStyle]::Bold)) } }
  $green=[System.Drawing.Color]::FromArgb(0,255,102); $dim=[System.Drawing.Color]::FromArgb(150,220,180)
  $y = 4
  foreach ($al in $script:pn_alarms) {
    $row = New-Object System.Windows.Forms.Panel; $row.Width=980; $row.Height=34; $row.Left=2; $row.Top=$y; $row.BackColor=[System.Drawing.Color]::FromArgb(0,20,9)
    $cb = New-Object System.Windows.Forms.CheckBox; $cb.Checked=$al.Enabled; $cb.Left=8; $cb.Top=8; $cb.Width=18; $cb.Tag=$al.Id
    $cb.Add_CheckedChanged({ param($s,$e) $t = $script:pn_alarms | Where-Object { $_.Id -eq $s.Tag } | Select-Object -First 1; if ($t) { $t.Enabled = $s.Checked }; Panel-Persist; Panel-RefreshArmed; Panel-UpdateStatus })
    $lt = New-Object System.Windows.Forms.Label; $lt.Text=$al.Time; $lt.Left=32; $lt.Top=8; $lt.Width=60; $lt.ForeColor=$green; $lt.Font=$script:pn_rowFonts.T
    $ll = New-Object System.Windows.Forms.Label; $ll.Text=$al.Label; $ll.Left=100; $ll.Top=9; $ll.Width=200; $ll.ForeColor=$dim; $ll.Font=$script:pn_rowFonts.N
    $when = if ($al.Rhythm) { 'daily (rhythm)' } elseif ($al.Date) { $al.Date } else { 'next' }
    $ld = New-Object System.Windows.Forms.Label; $ld.Text=$when; $ld.Left=308; $ld.Top=9; $ld.Width=150; $ld.ForeColor=[System.Drawing.Color]::FromArgb(110,200,150); $ld.Font=$script:pn_rowFonts.N
    $ls = New-Object System.Windows.Forms.Label; $ls.Text=("{0} x{1} [{2}]" -f $al.Diff,$al.NumQ,(Cats-Summary $al.Cats)); $ls.Left=466; $ls.Top=9; $ls.Width=320; $ls.ForeColor=[System.Drawing.Color]::FromArgb(90,180,130); $ls.Font=$script:pn_rowFonts.N
    $ed = New-Object System.Windows.Forms.Button; $ed.Text='EDIT'; $ed.Left=800; $ed.Top=4; $ed.Width=80; $ed.Height=26; $ed.Tag=$al.Id; $ed.FlatStyle='Flat'; $ed.ForeColor=$green; $ed.BackColor=[System.Drawing.Color]::FromArgb(0,33,15); $ed.Font=$script:pn_rowFonts.B
    $ed.Add_Click({ param($s,$e) $a = $script:pn_alarms | Where-Object { $_.Id -eq $s.Tag } | Select-Object -First 1; if ($a) { Panel-LoadEditor $a } })
    $del = New-Object System.Windows.Forms.Button; $del.Text='DELETE'; $del.Left=888; $del.Top=4; $del.Width=86; $del.Height=26; $del.Tag=$al.Id; $del.FlatStyle='Flat'; $del.ForeColor=[System.Drawing.Color]::FromArgb(255,90,90); $del.BackColor=[System.Drawing.Color]::FromArgb(30,0,0); $del.Font=$script:pn_rowFonts.B
    $del.Add_Click({ param($s,$e) $script:pn_alarms = @($script:pn_alarms | Where-Object { $_.Id -ne $s.Tag }); if ($script:pn_editId -eq $s.Tag) { Panel-LoadEditor $null }; Panel-Persist; Panel-RenderRows; Panel-RefreshArmed; Panel-UpdateStatus; Panel-Log "deleted" })
    $row.Controls.AddRange(@($cb,$lt,$ll,$ld,$ls,$ed,$del)); $script:pn_list.Controls.Add($row); $y += 38
  }
}
function Panel-LoadEditor($al) {
  if (-not $al) { $al = New-Alarm $script:cfg.defaults; $script:pn_editId = $null; $script:pn_saveBtn.Text = 'DEPLOY ALARM' }
  else { $script:pn_editId = $al.Id; $script:pn_saveBtn.Text = 'SAVE CHANGES' }
  $script:pn_eTime.Text = $al.Time; $script:pn_eLabel.Text = $al.Label; $script:pn_eDate.Text = $al.Date
  $script:pn_eRhythm.Checked = $al.Rhythm; $script:pn_eLockVol.Checked = $al.LockVol
  $script:pn_eDur.Text = [string]$al.DurationMin
  $script:pn_eDiff.SelectedItem = $al.Diff; if ($null -eq $script:pn_eDiff.SelectedItem) { $script:pn_eDiff.SelectedItem = 'hard' }
  $script:pn_eNumQ.SelectedItem = $al.NumQ; if ($null -eq $script:pn_eNumQ.SelectedItem) { $script:pn_eNumQ.SelectedItem = 3 }
  foreach ($c in $script:CATS) { $script:pn_eCats[$c].Checked = [bool]$al.Cats[$c] }
}
function Panel-CollectEditor {
  $t = ([string]$script:pn_eTime.Text).Trim()
  if ($t -notmatch '^([01]\d|2[0-3]):[0-5]\d$') { Panel-Log "bad time - use HH:MM (24h)"; return $null }
  $d = ([string]$script:pn_eDate.Text).Trim()
  if ($d -ne "") { $pd=[datetime]::MinValue; if (-not [datetime]::TryParseExact($d,'yyyy-MM-dd',[System.Globalization.CultureInfo]::InvariantCulture,[System.Globalization.DateTimeStyles]::None,[ref]$pd)) { Panel-Log "bad date - YYYY-MM-DD or blank"; return $null } }
  $lab = ([string]$script:pn_eLabel.Text).Trim(); if (-not $lab) { $lab = 'WAKE UP' }
  $dur = 3; [int]::TryParse(([string]$script:pn_eDur.Text).Trim(), [ref]$dur) | Out-Null; if ($dur -lt 1) { $dur = 1 }; if ($dur -gt 60) { $dur = 60 }
  $cats = [ordered]@{}; $anyCat = $false; foreach ($c in $script:CATS) { $cats[$c] = [bool]$script:pn_eCats[$c].Checked; if ($cats[$c]) { $anyCat = $true } }
  if (-not $anyCat) { $cats['arithmetic'] = $true }
  $id = if ($script:pn_editId) { $script:pn_editId } else { "a"+[guid]::NewGuid().ToString('N').Substring(0,6) }
  $rhythm = [bool]$script:pn_eRhythm.Checked
  $dateOut = $d
  # blank date (and not a daily Rhythm) -> bake in the concrete next-occurrence date now
  if (-not $rhythm -and $dateOut -eq "") { $w = Resolve-When $t "" $false; if ($w) { $dateOut = $w.ToString('yyyy-MM-dd') } }
  [pscustomobject]@{ Id=$id; Label=$lab; Time=$t; Date=$dateOut; Rhythm=$rhythm; Enabled=$true
    Diff=[string]$script:pn_eDiff.SelectedItem; NumQ=[int]$script:pn_eNumQ.SelectedItem; DurationMin=$dur; LockVol=[bool]$script:pn_eLockVol.Checked; Cats=$cats }
}
function Panel-SaveAlarm {
  $a = Panel-CollectEditor; if (-not $a) { return }
  if ($script:pn_editId) { $script:pn_alarms = @($script:pn_alarms | ForEach-Object { if ($_.Id -eq $script:pn_editId) { $a } else { $_ } }) }
  else { $script:pn_alarms += $a }
  Panel-Persist
  Panel-LoadEditor $null; Panel-RenderRows; Panel-RefreshArmed; Panel-UpdateStatus
  $whenTxt = if ($a.Rhythm) { 'every day' } else { $a.Date }
  Panel-Log "saved + armed: $($a.Time) $($a.Label) ($whenTxt)"
}
function Panel-SaveConfig {
  $alist = @()
  foreach ($al in $script:pn_alarms) { $alist += [ordered]@{ id=$al.Id; label=$al.Label; time=$al.Time; date=$al.Date; rhythm=$al.Rhythm; enabled=$al.Enabled; difficulty=$al.Diff; numQuestions=$al.NumQ; durationMin=$al.DurationMin; lockVolume=$al.LockVol; categories=$al.Cats } }
  $obj = [ordered]@{ version=3; defaults=$script:cfg.defaults; alarms=$alist }
  ($obj | ConvertTo-Json -Depth 8) | Out-File -FilePath $script:cfgPath -Encoding utf8
  Load-Config
}
function Panel-Persist { Panel-SaveConfig; try { Register-Alarms } catch { Panel-Log ("arm error: " + $_.Exception.Message) } }
function Panel-RefreshArmed {
  $armed = @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -like 'OVERRIDE_V2_*' -and $_.TaskName -notlike '*_safe_*' }).Count
  if ($armed -gt 0) { $script:pn_armed.Text = "ARMED ($armed)"; $script:pn_armed.ForeColor = [System.Drawing.Color]::FromArgb(0,255,102) } else { $script:pn_armed.Text = "NOT ARMED"; $script:pn_armed.ForeColor = [System.Drawing.Color]::FromArgb(255,140,0) }
}
function Panel-UpdateStatus {
  $next = $null
  foreach ($al in $script:pn_alarms) { if (-not $al.Enabled) { continue }; $w = Resolve-When $al.Time $al.Date $al.Rhythm; if ($w -and ((-not $next) -or ($w -lt $next))) { $next = $w } }
  if ($next) { $script:pn_status.Text = ("next: {0}   in {1}" -f $next.ToString('ddd HH:mm'), (Format-Span ($next - (Get-Date)))) } else { $script:pn_status.Text = "no upcoming alarms" }
}
function Panel-Test {
  $a = Panel-CollectEditor; if (-not $a) { return }
  $tc = [ordered]@{ numQuestions=$a.NumQ; difficulty=$a.Diff; categories=$a.Cats; lockVolume=$a.LockVol }
  ($tc | ConvertTo-Json -Compress) | Out-File -FilePath (Join-Path $script:root 'session.testcfg') -Encoding ascii
  Panel-Log "launching test ring (Alt+F4 or solve to end)..."
  try { Start-Process (Get-Command powershell).Source -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -Sta -WindowStyle Hidden -File "{0}\override.ps1" -Ring -TestNow' -f $script:root) | Out-Null } catch { Panel-Log ("test error: " + $_.Exception.Message) }
}
function Panel-Reposition {
  try { $cx = [int](($script:pn_form.ClientSize.Width - $script:pn_box.Width)/2); if ($cx -lt 0) { $cx = 0 }; $cy = [int](($script:pn_form.ClientSize.Height - $script:pn_box.Height)/2); if ($cy -lt 0) { $cy = 0 }; $script:pn_box.Left = $cx; $script:pn_box.Top = $cy } catch {}
}
function Collect-TextCtrls($parent, $list) {
  foreach ($c in $parent.Controls) {
    if (($c -is [System.Windows.Forms.Label]) -or ($c -is [System.Windows.Forms.Button])) { [void]$list.Add($c) }
    if ($c.Controls.Count -gt 0) { Collect-TextCtrls $c $list }
  }
}
function Rand-CJK($len) {
  if (-not $script:pn_grng) { $script:pn_grng = New-Object System.Random }
  if ($len -lt 2) { $len = 2 }; if ($len -gt 18) { $len = 18 }
  $sb = New-Object System.Text.StringBuilder
  for ($i=0; $i -lt $len; $i++) { [void]$sb.Append([char](0x4E00 + $script:pn_grng.Next(0,0x4DBF))) }
  $sb.ToString()
}
function Panel-Glitch {
  if (-not $script:pn_grng) { $script:pn_grng = New-Object System.Random }
  if ($script:pn_glitchBusy) { return }
  $script:pn_glitchBusy = $true; $script:pn_gN = 0; $script:pn_gHome = $script:pn_box.Location
  $script:pn_gTimer = New-Object System.Windows.Forms.Timer; $script:pn_gTimer.Interval = 40
  $script:pn_gTimer.Add_Tick({
    $script:pn_gN++
    if ($script:pn_gN -gt 8) { try { $script:pn_gTimer.Stop(); $script:pn_gTimer.Dispose() } catch {}; $script:pn_box.Location = $script:pn_gHome; $script:pn_glitchBusy = $false; return }
    $script:pn_box.Location = New-Object System.Drawing.Point (($script:pn_gHome.X + $script:pn_grng.Next(-6,7)),($script:pn_gHome.Y + $script:pn_grng.Next(-6,7)))
  })
  $script:pn_gTimer.Start()
}
function Panel-VanishTick {
  $script:pn_vStep++; $s = $script:pn_vStep
  if ($s -le 26) { foreach ($c in $script:pn_vCtrls) { $o = [string]$script:pn_vOrigText[$c]; $c.Text = Rand-CJK ([int][math]::Min(18,[math]::Max(2,$o.Length))) } }
  elseif ($s -le 40) { $script:pn_form.Opacity = [math]::Max(0.06, 1 - (($s-26)/14.0)); if ($s -eq 34) { Panel-Persist } }
  elseif ($s -le 54) { $script:pn_form.Opacity = [math]::Min(1.0, 0.06 + (($s-40)/14.0)) }
  else {
    foreach ($c in $script:pn_vCtrls) { try { $c.Font = $script:pn_vOrigFont[$c]; $c.Text = [string]$script:pn_vOrigText[$c] } catch {} }
    $script:pn_form.Opacity = 1.0; try { $script:pn_vTimer.Stop(); $script:pn_vTimer.Dispose() } catch {}
    $script:pn_vanishBusy = $false; Panel-RenderRows; Panel-RefreshArmed; Panel-UpdateStatus; Panel-Log "DEPLOYED. alarms fire even if this window is closed."
  }
}
function Panel-Deploy {
  if ($script:pn_vanishBusy) { return }
  $script:pn_vanishBusy = $true; Panel-Glitch
  $list = New-Object System.Collections.ArrayList; Collect-TextCtrls $script:pn_box $list; $script:pn_vCtrls = $list
  $script:pn_vOrigText = @{}; $script:pn_vOrigFont = @{}
  $cjk = $null; try { $cjk = New-Object System.Drawing.Font('MS Gothic',11) } catch {}
  foreach ($c in $list) { $script:pn_vOrigText[$c] = $c.Text; $script:pn_vOrigFont[$c] = $c.Font; if ($cjk) { try { $c.Font = $cjk } catch {} } }
  $script:pn_vStep = 0
  $script:pn_vTimer = New-Object System.Windows.Forms.Timer; $script:pn_vTimer.Interval = 55; $script:pn_vTimer.Add_Tick({ Panel-VanishTick }); $script:pn_vTimer.Start()
}
function Show-PanelGui {
  if (-not (Test-RingActive)) { Set-TaskMgrDisabled $false }
  Panel-LoadAlarms
  $green=[System.Drawing.Color]::FromArgb(0,255,102); $dim=[System.Drawing.Color]::FromArgb(124,255,176); $boxBg=[System.Drawing.Color]::FromArgb(0,26,10)
  $fL=New-Object System.Drawing.Font('Consolas',10); $fLb=New-Object System.Drawing.Font('Consolas',10,[System.Drawing.FontStyle]::Bold)

  $script:pn_form = New-Object System.Windows.Forms.Form
  $script:pn_form.Text = "OVERRIDE // CONTROL"; $script:pn_form.FormBorderStyle = 'Sizable'; $script:pn_form.MaximizeBox = $true
  $script:pn_form.StartPosition = 'CenterScreen'; $script:pn_form.MinimumSize = New-Object System.Drawing.Size(1040,760)
  $script:pn_form.WindowState = 'Maximized'; $script:pn_form.BackColor = [System.Drawing.Color]::Black
  $ico = Join-Path $script:root 'override.ico'; if (Test-Path $ico) { try { $script:pn_form.Icon = New-Object System.Drawing.Icon $ico } catch {} }

  $script:pn_rain = New-RainBackground -Fps 8 -FontSize 18
  $script:pn_form.Controls.Add($script:pn_rain.Panel)

  $script:pn_box = New-Object System.Windows.Forms.Panel; $script:pn_box.Width=1000; $script:pn_box.Height=720; $script:pn_box.BackColor=[System.Drawing.Color]::FromArgb(0,12,5)
  $script:pn_box.Add_Paint({ param($s,$e) $r=$s.ClientRectangle; $pen=New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(0,255,102)),2; $e.Graphics.DrawRectangle($pen,1,1,$r.Width-3,$r.Height-3); $pen.Dispose() })
  $script:pn_form.Controls.Add($script:pn_box); $script:pn_rain.Panel.SendToBack()

  $hdr = New-Object System.Windows.Forms.Label; $hdr.Text=("OVERRIDE // CONTROL   "+[char]0x03A9); $hdr.Left=18; $hdr.Top=14; $hdr.Width=640; $hdr.Height=40; $hdr.ForeColor=$green; $hdr.BackColor=[System.Drawing.Color]::Transparent; $hdr.Font=New-Object System.Drawing.Font('Consolas',22,[System.Drawing.FontStyle]::Bold); $script:pn_box.Controls.Add($hdr)
  $script:pn_armed = New-Object System.Windows.Forms.Label; $script:pn_armed.Left=760; $script:pn_armed.Top=22; $script:pn_armed.Width=220; $script:pn_armed.Height=26; $script:pn_armed.TextAlign='MiddleRight'; $script:pn_armed.BackColor=[System.Drawing.Color]::Transparent; $script:pn_armed.Font=New-Object System.Drawing.Font('Consolas',13,[System.Drawing.FontStyle]::Bold); $script:pn_box.Controls.Add($script:pn_armed)

  $lh = New-Object System.Windows.Forms.Label; $lh.Text="ALARMS"; $lh.Left=20; $lh.Top=60; $lh.Width=200; $lh.ForeColor=$dim; $lh.BackColor=[System.Drawing.Color]::Transparent; $lh.Font=$fLb; $script:pn_box.Controls.Add($lh)
  $script:pn_list = New-Object System.Windows.Forms.Panel; $script:pn_list.Left=12; $script:pn_list.Top=84; $script:pn_list.Width=976; $script:pn_list.Height=210; $script:pn_list.AutoScroll=$true; $script:pn_list.BackColor=[System.Drawing.Color]::FromArgb(0,8,3); $script:pn_box.Controls.Add($script:pn_list)

  $eh = New-Object System.Windows.Forms.Label; $eh.Text="EDIT / ADD ALARM"; $eh.Left=20; $eh.Top=306; $eh.Width=300; $eh.ForeColor=$dim; $eh.BackColor=[System.Drawing.Color]::Transparent; $eh.Font=$fLb; $script:pn_box.Controls.Add($eh)

  function NewTb($x,$y,$w) { $t=New-Object System.Windows.Forms.TextBox; $t.Left=$x; $t.Top=$y; $t.Width=$w; $t.BackColor=$boxBg; $t.ForeColor=$dim; $t.BorderStyle='FixedSingle'; $t.Font=New-Object System.Drawing.Font('Consolas',12); $script:pn_box.Controls.Add($t); $t }
  function NewLbl($txt,$x,$y,$w,$small) { $l=New-Object System.Windows.Forms.Label; $l.Text=$txt; $l.Left=$x; $l.Top=$y; $l.Width=$w; $l.ForeColor=$(if($small) { [System.Drawing.Color]::FromArgb(80,150,110) } else { $dim }); $l.BackColor=[System.Drawing.Color]::Transparent; $l.Font=$(if($small) { New-Object System.Drawing.Font('Consolas',8) } else { $fL }); $script:pn_box.Controls.Add($l); $l }

  $r1 = 338
  $script:pn_eTime = NewTb 24 $r1 80;   (NewLbl "HH:MM" 24 ($r1+26) 80 $true) | Out-Null
  $script:pn_eLabel = NewTb 120 $r1 240; (NewLbl "label" 120 ($r1+26) 100 $true) | Out-Null
  $script:pn_eDate = NewTb 372 $r1 140;  (NewLbl "YYYY-MM-DD (blank=next)" 372 ($r1+26) 220 $true) | Out-Null
  $script:pn_eRhythm = New-Object System.Windows.Forms.CheckBox; $script:pn_eRhythm.Text="Rhythm (every day)"; $script:pn_eRhythm.Left=560; $script:pn_eRhythm.Top=($r1+2); $script:pn_eRhythm.Width=220; $script:pn_eRhythm.ForeColor=$green; $script:pn_eRhythm.BackColor=[System.Drawing.Color]::Transparent; $script:pn_eRhythm.Font=$fL; $script:pn_box.Controls.Add($script:pn_eRhythm)

  $r2 = 392
  (NewLbl "difficulty" 24 ($r2+4) 76 $false) | Out-Null
  $script:pn_eDiff = New-Object System.Windows.Forms.ComboBox; $script:pn_eDiff.Left=104; $script:pn_eDiff.Top=$r2; $script:pn_eDiff.Width=110; $script:pn_eDiff.DropDownStyle='DropDownList'; $script:pn_eDiff.Items.AddRange(@('easy','medium','hard')); $script:pn_box.Controls.Add($script:pn_eDiff)
  (NewLbl "questions" 234 ($r2+4) 82 $false) | Out-Null
  $script:pn_eNumQ = New-Object System.Windows.Forms.ComboBox; $script:pn_eNumQ.Left=320; $script:pn_eNumQ.Top=$r2; $script:pn_eNumQ.Width=60; $script:pn_eNumQ.DropDownStyle='DropDownList'; $script:pn_eNumQ.Items.AddRange(@(1,2,3,4,5,6)); $script:pn_box.Controls.Add($script:pn_eNumQ)
  (NewLbl "duration" 400 ($r2+4) 70 $false) | Out-Null
  $script:pn_eDur = NewTb 472 $r2 50; (NewLbl "min" 526 ($r2+4) 40 $false) | Out-Null
  $script:pn_eLockVol = New-Object System.Windows.Forms.CheckBox; $script:pn_eLockVol.Text="lock volume @100%"; $script:pn_eLockVol.Left=600; $script:pn_eLockVol.Top=($r2+2); $script:pn_eLockVol.Width=220; $script:pn_eLockVol.ForeColor=$dim; $script:pn_eLockVol.BackColor=[System.Drawing.Color]::Transparent; $script:pn_eLockVol.Font=$fL; $script:pn_box.Controls.Add($script:pn_eLockVol)

  $r3 = 436
  (NewLbl "subjects" 24 ($r3+2) 80 $false) | Out-Null
  $script:pn_eCats = @{}; $cx = 104
  foreach ($c in $script:CATS) { $chk = New-Object System.Windows.Forms.CheckBox; $chk.Text=$c; $chk.Left=$cx; $chk.Top=$r3; $chk.Width=([int]($c.Length*9)+40); $chk.ForeColor=$green; $chk.BackColor=[System.Drawing.Color]::Transparent; $chk.Font=$fL; $script:pn_box.Controls.Add($chk); $script:pn_eCats[$c]=$chk; $cx += ([int]($c.Length*9)+50) }

  $r4 = 478
  $script:pn_saveBtn = New-Object System.Windows.Forms.Button; $script:pn_saveBtn.Text='DEPLOY ALARM'; $script:pn_saveBtn.Left=24; $script:pn_saveBtn.Top=$r4; $script:pn_saveBtn.Width=200; $script:pn_saveBtn.Height=36; $script:pn_saveBtn.FlatStyle='Flat'; $script:pn_saveBtn.ForeColor=$green; $script:pn_saveBtn.BackColor=[System.Drawing.Color]::FromArgb(0,33,15); $script:pn_saveBtn.Font=$fLb; $script:pn_saveBtn.Add_Click({ Panel-SaveAlarm }); $script:pn_box.Controls.Add($script:pn_saveBtn)
  $newBtn = New-Object System.Windows.Forms.Button; $newBtn.Text='NEW / CLEAR'; $newBtn.Left=234; $newBtn.Top=$r4; $newBtn.Width=140; $newBtn.Height=36; $newBtn.FlatStyle='Flat'; $newBtn.ForeColor=$dim; $newBtn.BackColor=[System.Drawing.Color]::FromArgb(0,24,11); $newBtn.Font=$fL; $newBtn.Add_Click({ Panel-LoadEditor $null; Panel-Log "editor cleared" }); $script:pn_box.Controls.Add($newBtn)

  $r5 = 540
  $testBtn = New-Object System.Windows.Forms.Button; $testBtn.Text="TEST RING"; $testBtn.Left=24; $testBtn.Top=$r5; $testBtn.Width=180; $testBtn.Height=46; $script:pn_box.Controls.Add($testBtn)
  $armBtn  = New-Object System.Windows.Forms.Button; $armBtn.Text=">> RE-DEPLOY ALL"; $armBtn.Left=214; $armBtn.Top=$r5; $armBtn.Width=200; $armBtn.Height=46; $script:pn_box.Controls.Add($armBtn)
  $disBtn  = New-Object System.Windows.Forms.Button; $disBtn.Text="DISARM ALL"; $disBtn.Left=424; $disBtn.Top=$r5; $disBtn.Width=170; $disBtn.Height=46; $script:pn_box.Controls.Add($disBtn)
  foreach ($b in @($testBtn,$armBtn,$disBtn)) { $b.FlatStyle='Flat'; $b.ForeColor=$green; $b.BackColor=[System.Drawing.Color]::FromArgb(0,33,15); $b.Font=New-Object System.Drawing.Font('Consolas',13,[System.Drawing.FontStyle]::Bold) }
  $testBtn.Add_Click({ Panel-Test })
  $armBtn.Add_Click({ Panel-Deploy })
  $disBtn.Add_Click({ foreach ($al in $script:pn_alarms) { $al.Enabled = $false }; Panel-SaveConfig; Remove-Alarms; Panel-RenderRows; Panel-RefreshArmed; Panel-UpdateStatus; Panel-Log "all alarms disarmed + disabled" })

  $script:pn_status = New-Object System.Windows.Forms.Label; $script:pn_status.Left=24; $script:pn_status.Top=600; $script:pn_status.Width=640; $script:pn_status.Height=24; $script:pn_status.ForeColor=[System.Drawing.Color]::FromArgb(120,220,160); $script:pn_status.BackColor=[System.Drawing.Color]::Transparent; $script:pn_status.Font=New-Object System.Drawing.Font('Consolas',12); $script:pn_box.Controls.Add($script:pn_status)
  $script:pn_log = New-Object System.Windows.Forms.Label; $script:pn_log.Left=24; $script:pn_log.Top=628; $script:pn_log.Width=956; $script:pn_log.Height=22; $script:pn_log.ForeColor=[System.Drawing.Color]::FromArgb(90,170,120); $script:pn_log.BackColor=[System.Drawing.Color]::Transparent; $script:pn_log.Font=$fL; $script:pn_box.Controls.Add($script:pn_log)
  $hint = New-Object System.Windows.Forms.Label; $hint.Text="blank date = next occurrence  |  Rhythm = every day  |  each alarm has its own subjects/difficulty  |  0% CPU between alarms"; $hint.Left=24; $hint.Top=654; $hint.Width=956; $hint.Height=20; $hint.ForeColor=[System.Drawing.Color]::FromArgb(70,130,95); $hint.BackColor=[System.Drawing.Color]::Transparent; $hint.Font=New-Object System.Drawing.Font('Consolas',9); $script:pn_box.Controls.Add($hint)

  $script:pn_statusTimer = New-Object System.Windows.Forms.Timer; $script:pn_statusTimer.Interval = 1000; $script:pn_statusTimer.Add_Tick({ Panel-UpdateStatus; $script:pn_tick++; if (($script:pn_tick % 11) -eq 0) { Panel-Glitch } })
  $script:pn_form.Add_Activated({ try { if ($script:pn_form.WindowState -ne 'Minimized') { $script:pn_rain.Timer.Start() } } catch {} })
  $script:pn_form.Add_Deactivate({ try { $script:pn_rain.Timer.Stop() } catch {} })
  $script:pn_form.Add_Resize({ Panel-Reposition; try { if ($script:pn_form.WindowState -eq 'Minimized') { $script:pn_rain.Timer.Stop() } else { $script:pn_rain.Timer.Start() } } catch {} })
  $script:pn_form.Add_Shown({
    Panel-LoadEditor $null; Panel-RenderRows; Panel-RefreshArmed; Panel-UpdateStatus; Panel-Reposition
    $script:pn_rain.Timer.Start(); $script:pn_statusTimer.Start()
    if ($script:pn_testSec -gt 0) { $script:pn_auto = New-Object System.Windows.Forms.Timer; $script:pn_auto.Interval = ($script:pn_testSec*1000); $script:pn_auto.Add_Tick({ $script:pn_auto.Stop(); $script:pn_form.Close() }); $script:pn_auto.Start() }
    if ($script:pn_autoDeploy) { $script:pn_dt = New-Object System.Windows.Forms.Timer; $script:pn_dt.Interval = 1500; $script:pn_dt.Add_Tick({ $script:pn_dt.Stop(); Panel-Deploy }); $script:pn_dt.Start() }
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
if ($Disarm) { Write-Host "OVERRIDE v2 // disarming..." -ForegroundColor Yellow; Remove-Alarms; return }
if ($Arm)    { Write-Host "OVERRIDE v2 // arming..." -ForegroundColor Green; Register-Alarms; return }
if ($DryRun) { Write-Host ("OVERRIDE v2 schedule  ({0})" -f (Get-Date)) -ForegroundColor Green; Show-Tasks; return }

if ($Ring) {
  $mtx = New-Object System.Threading.Mutex($false, "Local\OVERRIDE_V2_ring_lock")
  $got = $true; try { $got = $mtx.WaitOne(0) } catch { $got = $true }
  if (-not $got) { return }
  try {
    if ($TestNow) { $S = Get-TestSettings } else { $S = Get-AlarmSettings $AlarmId }
    if ($S) { Run-Ring $S }
  } finally { Invoke-Unlock; try { $mtx.ReleaseMutex() } catch {} }
  return
}

# default: the standalone control panel
$script:pn_testSec = $PanelTestSec
$script:pn_autoDeploy = $AutoDeploy
Show-PanelGui
