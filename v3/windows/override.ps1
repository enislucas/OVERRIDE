param(
  [switch]$Ring, [string]$AlarmId = "", [switch]$TestNow,
  [switch]$Arm, [switch]$Disarm, [switch]$Unlock,
  [switch]$DryRun, [switch]$Probe, [int]$PanelTestSec = 0, [switch]$AutoDeploy
)
# OVERRIDE v3 // WAKE PROTOCOL — Windows engine
# - Alarms fire via Windows Scheduled Tasks -> ONE ephemeral ring process. 0 CPU between alarms.
#   No watchdog/respawn cascade (v1's crash), no foreground-steal loops / window manhandling
#   (v2's early black-screen bugs). The quiz gets a gentle topmost nudge only.
# - The ring drives the SHARED quiz (..\quiz\quiz.hta -> core.js: 12 subjects). The engine adds
#   escalating sound, un-mutable volume, keyboard lockdown, relaunch-if-closed and the narrator.
# - Task namespace: OVERRIDE_V3_*. Arming v3 also removes OVERRIDE_V2_* tasks (it replaces v2);
#   it NEVER touches OVERRIDE_LIVE_*. The ring mutex is shared with v2 so the two engines can
#   never ring on top of each other.
# - Survival rule #1: a broken config.json must NEVER stop the alarm. Load-Config falls back to
#   built-in defaults, and the ring runs even if the quiz file is missing (sound still fires).

$ErrorActionPreference = "Stop"
$script:eng = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$script:root = Split-Path -Parent $script:eng          # v3 root: session files + config live here
$script:cfgPath = Join-Path $script:root "config.json"
$script:quizHta = Join-Path $script:root "quiz\quiz.hta"
$script:CATS = @('arithmetic','derivatives','vectors','matrices','capitals',
                 'equations','percentages','powers','sequences','integrals','binary','elements')

function New-DefaultConfig {
  $cats = [ordered]@{}; foreach ($c in $script:CATS) { $cats[$c] = ($c -eq 'arithmetic') }
  [pscustomobject]@{ version = 4
    defaults = [pscustomobject]@{ difficulty='hard'; numQuestions=3; durationMin=3; lockVolume=$true; narrator=$true; matrixRain=$false; categories=[pscustomobject]$cats }
    alarms   = @() }
}
function Load-Config {
  # survival rule #1: never die on a bad/missing config — alarms must still fire
  $script:cfg = $null
  try { if (Test-Path $script:cfgPath) { $script:cfg = Get-Content $script:cfgPath -Raw | ConvertFrom-Json } } catch { $script:cfg = $null }
  if (-not $script:cfg -or -not $script:cfg.defaults) {
    $bak = "$($script:cfgPath).bak"
    if (Test-Path $bak) { try { $script:cfg = Get-Content $bak -Raw | ConvertFrom-Json } catch { $script:cfg = $null } }
  }
  if (-not $script:cfg -or -not $script:cfg.defaults) { $script:cfg = New-DefaultConfig }
  if ($null -eq $script:cfg.alarms) { $script:cfg | Add-Member -NotePropertyName alarms -NotePropertyValue @() -Force }
}
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
        bool alt=Dn(0x12), ctrl=Dn(0x11);
        bool block=false;
        if(vk==0x5B||vk==0x5C) block=true;                 // LWin / RWin (incl. Win+D/Tab/L combos)
        else if(vk==0x09 && alt) block=true;               // Alt+Tab
        else if(vk==0x1B && (ctrl||alt)) block=true;       // Ctrl+Esc / Alt+Esc / Ctrl+Shift+Esc
        else if(vk==0x73 && alt) block=true;               // Alt+F4
        else if(vk==0x20 && alt) block=true;               // Alt+Space (system menu -> Close)
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
  static readonly IntPtr HWND_TOPMOST = new IntPtr(-1);
  const uint GENTLE = 0x0001 | 0x0002 | 0x0010;   // SWP_NOSIZE | SWP_NOMOVE | SWP_NOACTIVATE
  // z-order nudge ONLY: never moves/resizes the window, never steals focus in a loop.
  // (v2 history: fullscreen-resize + AttachThreadInput retry loops black-screened the PC.)
  public static void TopMost(IntPtr h){ if (h == IntPtr.Zero) return; SetWindowPos(h, HWND_TOPMOST, 0, 0, 0, 0, GENTLE); }
  public static void Raise(IntPtr h){ if (h == IntPtr.Zero) return; SetWindowPos(h, HWND_TOPMOST, 0, 0, 0, 0, GENTLE); SetForegroundWindow(h); }
}
"@
try { Add-Type -TypeDefinition $winSrc -Language CSharp } catch {}

# minimal wav synth: only used when sounds/ is missing, so the alarm is NEVER silent
$sndSrc = @"
using System; using System.IO;
public static class FallbackSound {
  const int SR = 22050;
  public static void Warble(string path, double dur){
    int n=(int)(SR*dur); var s=new double[n];
    for(int i=0;i<n;i++){ double t=(double)i/SR; double f=((int)(t*4)%2==0)?600:850;
      s[i]=0.5*(Math.Sin(2*Math.PI*f*t)>=0?1.0:-1.0); }
    int fade=300; for(int i=0;i<fade && i<n;i++){ double k=(double)i/fade; s[i]*=k; s[n-1-i]*=k; }
    using(var fs=new FileStream(path,FileMode.Create)) using(var bw=new BinaryWriter(fs)){
      int data=n*2;
      bw.Write(new char[]{'R','I','F','F'}); bw.Write(36+data); bw.Write(new char[]{'W','A','V','E'});
      bw.Write(new char[]{'f','m','t',' '}); bw.Write(16); bw.Write((short)1); bw.Write((short)1);
      bw.Write(SR); bw.Write(SR*2); bw.Write((short)2); bw.Write((short)16);
      bw.Write(new char[]{'d','a','t','a'}); bw.Write(data);
      for(int i=0;i<n;i++){ double v=s[i]*1.8; if(v>1)v=1; if(v<-1)v=-1; bw.Write((short)(v*32000)); }
    }
  }
}
"@
try { Add-Type -TypeDefinition $sndSrc -Language CSharp } catch {}

# ---- lockdown helpers ------------------------------------------------------
function Set-TaskMgrDisabled([bool]$on) {
  # best-effort only (needs a non-ACL-locked HKCU policy key); the keyboard hook is the real anti-kill
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

# ---- narrator --------------------------------------------------------------
$script:NAG_LINES = @(
  "Solve it. Wake up.","Still horizontal? Pathetic.","I can do this all morning.",
  "Your blanket will not save you.","Recompute. Now.",
  "The questions are not going to solve themselves.",
  "Your future self is watching. They are not impressed.",
  "Sleep is a subscription you cannot afford right now.",
  "I have nowhere else to be. You, however, do.",
  "The snooze button does not exist. I made sure of it.",
  "Your pillow is lying to you.","Math now. Existential dread later.",
  "You installed me. Think about that.",
  "The bed is lava. The bed has always been lava.",
  "Coffee is on the other side of this quiz.",
  "I believe in you. Unfortunately for you.",
  "Day not seized detected. Deploying countermeasures.",
  "This alarm is powered by your regret.")
$script:START_LINES = @(
  "Wake up. Solve to disable the alarm.",
  "Good morning, subject. Identity verification required.",
  "Initiating wake protocol. Resistance is adorable.",
  "Rise and shine. The machine demands proof of consciousness.",
  "Attention. Horizontal mode has been deprecated.",
  "Boot sequence started. Human, verify you are not a vegetable.")
function Speak-Line([string]$t) {
  if (-not $script:rg_voice) { return }
  try {
    if ($script:rg_voiceNames.Count -gt 1) { $script:rg_voice.SelectVoice(($script:rg_voiceNames | Get-Random)) }
    $script:rg_voice.Rate = Get-Random -Minimum -1 -Maximum 3
    [void]$script:rg_voice.SpeakAsync($t)
  } catch {}
}

# ---- settings helpers ------------------------------------------------------
function Convert-Cats($catObj) {
  $h = [ordered]@{}
  foreach ($c in $script:CATS) { $v = $false; if ($catObj -and ($catObj.PSObject.Properties.Name -contains $c)) { $v = [bool]$catObj.$c }; $h[$c] = $v }
  $h
}
function Get-Prop($obj, [string]$name, $default) {
  if ($obj -and ($obj.PSObject.Properties.Name -contains $name)) { return $obj.$name }
  return $default
}
function Get-AlarmSettings($id) {
  Load-Config
  $d = $script:cfg.defaults
  $a = $script:cfg.alarms | Where-Object { $_.id -eq $id } | Select-Object -First 1
  $diff = [string](Get-Prop $a 'difficulty'   (Get-Prop $d 'difficulty' 'hard'))
  $nq   = [int]   (Get-Prop $a 'numQuestions' (Get-Prop $d 'numQuestions' 3))
  $dur  = [int]   (Get-Prop $a 'durationMin'  (Get-Prop $d 'durationMin' 3))
  $lv   = [bool]  (Get-Prop $a 'lockVolume'   (Get-Prop $d 'lockVolume' $true))
  $nar  = [bool]  (Get-Prop $a 'narrator'     (Get-Prop $d 'narrator' $true))
  $mr   = [bool]  (Get-Prop $a 'matrixRain'   (Get-Prop $d 'matrixRain' $false))
  $catO =         (Get-Prop $a 'categories'   (Get-Prop $d 'categories' $null))
  $lbl  = [string](Get-Prop $a 'label' 'WAKE UP')
  if ($dur -lt 1) { $dur = 1 }
  return @{ Label=$lbl; Diff=$diff; NumQ=$nq; Cats=(Convert-Cats $catO); DurationSec=($dur*60); LockVol=$lv; Narrator=$nar; MatrixRain=$mr; Lockdown=$true; Relaunch=$true; Quiet=$false }
}
function Get-TestSettings {
  $p = Join-Path $script:root 'session.testcfg'
  $diff='hard'; $nq=3; $cats=(Convert-Cats (Get-Prop $script:cfg.defaults 'categories' $null)); $dur=45; $lv=$true; $mr=$false; $nar=$true; $quiet=$false; $rel=$false
  if (Test-Path $p) { try { $t = Get-Content $p -Raw | ConvertFrom-Json
    if ($t.difficulty) { $diff=[string]$t.difficulty }
    if ($t.numQuestions) { $nq=[int]$t.numQuestions }
    if ($t.categories) { $cats=Convert-Cats $t.categories }
    if ($t.PSObject.Properties.Name -contains 'lockVolume') { $lv=[bool]$t.lockVolume }
    if ($t.PSObject.Properties.Name -contains 'matrixRain') { $mr=[bool]$t.matrixRain }
    if ($t.PSObject.Properties.Name -contains 'narrator')   { $nar=[bool]$t.narrator }
    if ($t.PSObject.Properties.Name -contains 'durationSec'){ $dur=[int]$t.durationSec; if ($dur -lt 5) { $dur = 5 } }
    if ($t.PSObject.Properties.Name -contains 'quiet')      { $quiet=[bool]$t.quiet }
    if ($t.PSObject.Properties.Name -contains 'relaunch')   { $rel=[bool]$t.relaunch }   # test the anti-thrash relaunch path
  } catch {} }
  if ($quiet) { $lv = $false; $nar = $false }    # automated tests: no sound, no voice, no volume grab
  return @{ Label='TEST'; Diff=$diff; NumQ=$nq; Cats=$cats; DurationSec=$dur; LockVol=$lv; Narrator=$nar; MatrixRain=$mr; Lockdown=$false; Relaunch=$rel; Quiet=$quiet }
}

# ---- the ring engine -------------------------------------------------------
function Remove-RingFiles {
  foreach ($f in 'UNLOCK','PANIC','session.beat','session.key','session.deadline','session.deadlinems','session.start','session.label','session.quizcfg') {
    $p = Join-Path $script:root $f; if (Test-Path $p) { try { [System.IO.File]::Delete($p) } catch {} }
  }
}
function Launch-HTA {
  # launch-grace anchor: never re-evaluate "alive / relaunch" for rg_launchGrace seconds after
  # a launch. Fix for the relaunch-thrash bug (bug museum #17): mshta hands the HTA off to a
  # different process, so the launched PID's HasExited lies almost immediately -> the old code
  # relaunched every ~0.5s and the window was never solvable (3 forced shutdowns).
  $script:rg_launchAt = Get-Date
  try {
    if (-not (Test-Path $script:quizHta)) { $script:rg_mshta = $null; return }
    $exe = Join-Path $env:WINDIR 'System32\mshta.exe'
    $hta = '"' + $script:quizHta + '"'
    $script:rg_mshta = Start-Process $exe -ArgumentList $hta -PassThru
  } catch { $script:rg_mshta = $null }
}
function Test-QuizPresent {
  # truth, not the launched PID: is an mshta hosting our quiz actually running?
  try {
    return (@(Get-CimInstance Win32_Process -Filter "Name='mshta.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -match 'quiz' }).Count -gt 0)
  } catch { return $true }   # uncertain -> assume alive; never thrash
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
  # deadline / panic escape-hatch file
  if ($now -ge $script:rg_deadline -or (Test-Path (Join-Path $script:root 'PANIC'))) { End-Ring; return }
  # ensure the quiz is alive + on top (gently: z-order only, no focus loops)
  $script:rg_tk++
  if ($script:rg_relaunch) {
    # REAL alarm: relaunch ONLY if the quiz is genuinely gone (verified by process presence, NOT
    # the lying launched PID), and only after the launch grace. Checked at most every 2s. Cannot
    # thrash: worst case one relaunch per grace window, and each relaunch re-anchors the grace.
    if ((($now - $script:rg_launchAt).TotalSeconds -ge $script:rg_launchGrace) -and (($script:rg_tk % 4) -eq 0)) {
      if (-not (Test-QuizPresent)) { Launch-HTA; $script:rg_pinnedH = [IntPtr]::Zero }
    }
    try {
      if ($script:rg_mshta -and -not $script:rg_mshta.HasExited) {
        $script:rg_mshta.Refresh(); $h = $script:rg_mshta.MainWindowHandle
        if ($h -ne [IntPtr]::Zero) {
          if ($h -ne $script:rg_pinnedH) { [Win]::Raise($h); $script:rg_pinnedH = $h }   # once: topmost + single soft focus
          elseif (($script:rg_tk % 4) -eq 0) { [Win]::TopMost($h) }                       # then z-order nudge only (~2s)
        }
      }
    } catch {}
  } else {
    # TEST ring: closing the quiz ends the test.
    if (($null -eq $script:rg_mshta) -or $script:rg_mshta.HasExited) { End-Ring; return }
  }
  if ($script:rg_lockdown -and (($script:rg_tk % 6) -eq 0)) { try { Get-Process -Name Taskmgr -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue } catch {} }
  if ($script:rg_narrator -and ($now -ge $script:rg_nagAt)) { Speak-Line ($script:NAG_LINES | Get-Random); $script:rg_nagAt = $now.AddSeconds(22) }
}
function Resolve-Sounds {
  # v3/sounds first, then sibling v2/sounds; if neither, synthesize one wav so the alarm is NEVER silent
  $t1=@(); $t2=@(); $t3=@()
  foreach ($sf in @((Join-Path $script:root 'sounds'), (Join-Path (Split-Path -Parent $script:root) 'v2\sounds'))) {
    if (-not (Test-Path $sf)) { continue }
    foreach ($w in @(Get-ChildItem $sf -File | Where-Object { $_.Extension -match '(?i)\.wav$' })) {
      if ($w.Name -like 't2_*') { $t2 += $w.FullName } elseif ($w.Name -like 't3_*') { $t3 += $w.FullName } else { $t1 += $w.FullName } }
    if ((@($t1).Count + @($t2).Count + @($t3).Count) -gt 0) { break }
  }
  if ((@($t1).Count + @($t2).Count + @($t3).Count) -eq 0) {
    $fb = Join-Path $env:TEMP 'override_v3_fallback.wav'
    try { if (-not (Test-Path $fb)) { [FallbackSound]::Warble($fb, 6.0) }; $t1 = @($fb) } catch {}
  }
  if (@($t1).Count -eq 0) { $t1 = $t2 }; if (@($t2).Count -eq 0) { $t2 = $t1 }; if (@($t3).Count -eq 0) { $t3 = $t2 }
  $script:rg_tierA=@($t1); $script:rg_tierB=@($t2); $script:rg_tierC=@($t3); $script:rg_haveSnd=(@($t1).Count -gt 0)
}
function Run-Ring {
  param([hashtable]$S)
  $script:rg_exiting = $false
  foreach ($f in 'UNLOCK','PANIC','session.beat') { $q = Join-Path $script:root $f; if (Test-Path $q) { try { [System.IO.File]::Delete($q) } catch {} } }
  $key = [guid]::NewGuid().ToString('N')
  $start = Get-Date; $script:rg_deadline = $start.AddSeconds($S.DurationSec); $script:rg_key = $key
  Set-Content -Path (Join-Path $script:root 'session.key')      -Value $key -Encoding ASCII
  Set-Content -Path (Join-Path $script:root 'session.deadline') -Value ($script:rg_deadline.ToString('o')) -Encoding ASCII
  $dlMs = [DateTimeOffset]::new($script:rg_deadline).ToUnixTimeMilliseconds()
  Set-Content -Path (Join-Path $script:root 'session.deadlinems') -Value $dlMs -Encoding ASCII
  Set-Content -Path (Join-Path $script:root 'session.start')    -Value ($start.ToString('o')) -Encoding ASCII
  Set-Content -Path (Join-Path $script:root 'session.label')    -Value $S.Label -Encoding ASCII
  $qc = [ordered]@{ numQuestions = $S.NumQ; difficulty = $S.Diff; categories = $S.Cats; matrixRain = $S.MatrixRain }
  ($qc | ConvertTo-Json -Compress) | Set-Content -Path (Join-Path $script:root 'session.quizcfg') -Encoding ASCII

  $script:rg_relaunch = $S.Relaunch; $script:rg_lockdown = $S.Lockdown; $script:rg_lockVol = $S.LockVol; $script:rg_narrator = $S.Narrator
  $script:rg_mshta = $null; $script:rg_sndIdx = 0; $script:rg_nagAt = $start.AddSeconds(16); $script:rg_tk = 0; $script:rg_pinnedH = [IntPtr]::Zero
  $script:rg_launchGrace = 12; $script:rg_launchAt = $start   # anti-thrash (bug museum #17)

  if ($S.Quiet) { $script:rg_haveSnd = $false; $script:rg_tierA=@(); $script:rg_tierB=@(); $script:rg_tierC=@() }
  else { Resolve-Sounds }
  $script:rg_player = New-Object System.Media.SoundPlayer
  $script:rg_voice = $null; $script:rg_voiceNames = @()
  if ($S.Narrator) {
    try {
      $script:rg_voice = New-Object System.Speech.Synthesis.SpeechSynthesizer; $script:rg_voice.Volume = 100
      $script:rg_voiceNames = @($script:rg_voice.GetInstalledVoices() | Where-Object { $_.Enabled } | ForEach-Object { $_.VoiceInfo.Name })
    } catch { $script:rg_voice = $null }
  }
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
  if ($script:rg_narrator) { Speak-Line ($script:START_LINES | Get-Random) }
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
    try { Get-CimInstance Win32_Process -Filter "Name='mshta.exe'" | Where-Object { $_.CommandLine -match 'quiz\.hta' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue } } catch {}
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
  # removes v3 tasks AND legacy v2 tasks (v3 replaces v2). NEVER touches OVERRIDE_LIVE_*.
  Get-ScheduledTask -ErrorAction SilentlyContinue |
    Where-Object { ($_.TaskName -like 'OVERRIDE_V3_*' -or $_.TaskName -like 'OVERRIDE_V2_*') -and $_.TaskName -notlike 'OVERRIDE_LIVE*' } |
    ForEach-Object { Unregister-ScheduledTask -TaskName $_.TaskName -Confirm:$false -ErrorAction SilentlyContinue }
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
    $durMin = [int](Get-Prop $a 'durationMin' (Get-Prop $script:cfg.defaults 'durationMin' 3))
    if ($durMin -lt 1) { $durMin = 1 }
    $arg = "-NoProfile -Sta -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$($script:eng)\override.ps1`" -Ring -AlarmId $($a.id)"
    $action = New-ScheduledTaskAction -Execute $pw -Argument $arg -WorkingDirectory $script:eng
    $settings = New-ScheduledTaskSettingsSet -WakeToRun -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes ($durMin + 4)) -MultipleInstances IgnoreNew
    $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited
    Register-ScheduledTask -TaskName "OVERRIDE_V3_$($a.id)" -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force | Out-Null
    $safeArg = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$($script:eng)\override.ps1`" -Unlock"
    $safeAction = New-ScheduledTaskAction -Execute $pw -Argument $safeArg -WorkingDirectory $script:eng
    $safeSettings = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 2) -MultipleInstances IgnoreNew
    Register-ScheduledTask -TaskName "OVERRIDE_V3_safe_$($a.id)" -Action $safeAction -Trigger $safeTrigger -Settings $safeSettings -Principal $principal -Force | Out-Null
    Write-Host "  armed  $($a.label)  $desc" -ForegroundColor Green; $n++
  }
  Write-Host "$n alarm(s) armed (v3). Legacy OVERRIDE_V2_* tasks were replaced." -ForegroundColor Green
}
function Get-ArmedCount {
  # only count tasks that will actually fire (a past one-time task lingers as 'Ready' with no next run)
  $n = 0
  foreach ($t in @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -like 'OVERRIDE_V3_*' -and $_.TaskName -notlike '*_safe_*' })) {
    try { $i = $t | Get-ScheduledTaskInfo; if ($i.NextRunTime -and $i.NextRunTime -gt (Get-Date)) { $n++ } } catch {}
  }
  $n
}
function Show-Tasks {
  $tasks = @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -like 'OVERRIDE_V3_*' -and $_.TaskName -notlike '*_safe_*' })
  if ($tasks.Count -eq 0) { Write-Host "   (no v3 alarms armed)" -ForegroundColor DarkYellow; return }
  foreach ($t in ($tasks | Sort-Object TaskName)) { $i = $t | Get-ScheduledTaskInfo; Write-Host ("    {0,-10} next: {1,-22} [{2}]" -f ($t.TaskName -replace '^OVERRIDE_V3_',''), $i.NextRunTime, $t.State) -ForegroundColor Green }
}

# ---- matrix rain (panel ambient; opt-in, fps-capped, double-buffered) ------
function Update-RainSize($p) {
  $st = $p.Tag
  $dw = [math]::Max(1,$p.ClientSize.Width); $dh = [math]::Max(1,$p.ClientSize.Height)
  $st.dispW = $dw; $st.dispH = $dh
  $w = $dw; $h = $dh
  if ($w -gt 900) { $sf = 900.0 / $w; $w = 900; $h = [math]::Max(1,[int]($h * $sf)) }   # render-res cap
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
  param([int]$Fps = 8, [int]$FontSize = 18)
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
    Diff=[string](Get-Prop $d 'difficulty' 'hard'); NumQ=[int](Get-Prop $d 'numQuestions' 3); DurationMin=[int](Get-Prop $d 'durationMin' 3)
    LockVol=[bool](Get-Prop $d 'lockVolume' $true); Narrator=[bool](Get-Prop $d 'narrator' $true); Cats=(Convert-Cats (Get-Prop $d 'categories' $null)) }
}
function Import-V2Config {
  # first run: adopt the alarms you already had in v2 (their 5 subjects map 1:1 onto v3 keys)
  $v2 = Join-Path (Split-Path -Parent $script:root) 'v2\config.json'
  if (-not (Test-Path $v2)) { return $false }
  try {
    $old = Get-Content $v2 -Raw | ConvertFrom-Json
    if (-not $old.alarms) { return $false }
    $script:cfg = New-DefaultConfig
    $imported = @()
    foreach ($a in $old.alarms) {
      $imported += [pscustomobject]@{
        id=[string]$a.id; label=[string]$a.label; time=[string]$a.time
        date=[string](Get-Prop $a 'date' ''); rhythm=[bool](Get-Prop $a 'rhythm' $false); enabled=[bool](Get-Prop $a 'enabled' $true)
        difficulty=[string](Get-Prop $a 'difficulty' 'hard'); numQuestions=[int](Get-Prop $a 'numQuestions' 3)
        durationMin=[int](Get-Prop $a 'durationMin' 3); lockVolume=[bool](Get-Prop $a 'lockVolume' $true)
        narrator=$true; categories=[pscustomobject](Convert-Cats (Get-Prop $a 'categories' $null)) }
    }
    $script:cfg.alarms = $imported
    Save-Config
    return $true
  } catch { return $false }
}
function Save-Config {
  try { if (Test-Path $script:cfgPath) { Copy-Item $script:cfgPath "$($script:cfgPath).bak" -Force } } catch {}
  ($script:cfg | ConvertTo-Json -Depth 8) | Out-File -FilePath $script:cfgPath -Encoding utf8
}
function Panel-LoadAlarms {
  $script:pn_alarms = @(); $d = $script:cfg.defaults
  foreach ($a in $script:cfg.alarms) {
    $dt=''; if (($a.PSObject.Properties.Name -contains 'date') -and $a.date) { $dt=[string]$a.date }
    $script:pn_alarms += [pscustomobject]@{
      Id=[string]$a.id; Label=[string]$a.label; Time=[string]$a.time; Date=$dt
      Rhythm=(($a.PSObject.Properties.Name -contains 'rhythm') -and [bool]$a.rhythm); Enabled=[bool]$a.enabled
      Diff=[string](Get-Prop $a 'difficulty' (Get-Prop $d 'difficulty' 'hard'))
      NumQ=[int](Get-Prop $a 'numQuestions' (Get-Prop $d 'numQuestions' 3))
      DurationMin=[int](Get-Prop $a 'durationMin' (Get-Prop $d 'durationMin' 3))
      LockVol=[bool](Get-Prop $a 'lockVolume' (Get-Prop $d 'lockVolume' $true))
      Narrator=[bool](Get-Prop $a 'narrator' (Get-Prop $d 'narrator' $true))
      Cats=(Convert-Cats (Get-Prop $a 'categories' (Get-Prop $d 'categories' $null)))
    }
  }
}
function Cats-Summary($cats) {
  $on = @(); foreach ($c in $script:CATS) { if ($cats[$c]) { $on += $c.Substring(0,3) } }
  if ($on.Count -eq 0) { return 'ari' }
  if ($on.Count -gt 5) { return ($on[0..4] -join ',') + "+$($on.Count-5)" }
  return ($on -join ',')
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
    $ll = New-Object System.Windows.Forms.Label; $ll.Text=$al.Label; $ll.Left=100; $ll.Top=9; $ll.Width=190; $ll.ForeColor=$dim; $ll.Font=$script:pn_rowFonts.N
    $when = if ($al.Rhythm) { 'daily (rhythm)' } elseif ($al.Date) { $w = Resolve-When $al.Time $al.Date $false; if ($w) { $al.Date } else { "$($al.Date) (past)" } } else { 'next' }
    $ld = New-Object System.Windows.Forms.Label; $ld.Text=$when; $ld.Left=296; $ld.Top=9; $ld.Width=160; $ld.ForeColor=[System.Drawing.Color]::FromArgb(110,200,150); $ld.Font=$script:pn_rowFonts.N
    $ls = New-Object System.Windows.Forms.Label; $ls.Text=("{0} x{1} [{2}]" -f $al.Diff,$al.NumQ,(Cats-Summary $al.Cats)); $ls.Left=462; $ls.Top=9; $ls.Width=330; $ls.ForeColor=[System.Drawing.Color]::FromArgb(90,180,130); $ls.Font=$script:pn_rowFonts.N
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
  $script:pn_eRhythm.Checked = $al.Rhythm; $script:pn_eLockVol.Checked = $al.LockVol; $script:pn_eNarr.Checked = $al.Narrator
  $script:pn_eDate.Enabled = -not $al.Rhythm
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
  $dateOut = if ($rhythm) { "" } else { $d }          # rhythm overrides any leftover date (was confusing in v2)
  if (-not $rhythm -and $dateOut -eq "") { $w = Resolve-When $t "" $false; if ($w) { $dateOut = $w.ToString('yyyy-MM-dd') } }
  [pscustomobject]@{ Id=$id; Label=$lab; Time=$t; Date=$dateOut; Rhythm=$rhythm; Enabled=$true
    Diff=[string]$script:pn_eDiff.SelectedItem; NumQ=[int]$script:pn_eNumQ.SelectedItem; DurationMin=$dur
    LockVol=[bool]$script:pn_eLockVol.Checked; Narrator=[bool]$script:pn_eNarr.Checked; Cats=$cats }
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
  foreach ($al in $script:pn_alarms) { $alist += [ordered]@{ id=$al.Id; label=$al.Label; time=$al.Time; date=$al.Date; rhythm=$al.Rhythm; enabled=$al.Enabled; difficulty=$al.Diff; numQuestions=$al.NumQ; durationMin=$al.DurationMin; lockVolume=$al.LockVol; narrator=$al.Narrator; categories=$al.Cats } }
  $obj = [ordered]@{ version=4; defaults=$script:cfg.defaults; alarms=$alist }
  try { if (Test-Path $script:cfgPath) { Copy-Item $script:cfgPath "$($script:cfgPath).bak" -Force } } catch {}
  ($obj | ConvertTo-Json -Depth 8) | Out-File -FilePath $script:cfgPath -Encoding utf8
  Load-Config
}
function Panel-Persist { Panel-SaveConfig; try { Register-Alarms } catch { Panel-Log ("arm error: " + $_.Exception.Message) } }
function Panel-RefreshArmed {
  $armed = Get-ArmedCount
  if ($armed -gt 0) { $script:pn_armed.Text = "ARMED ($armed)"; $script:pn_armed.ForeColor = [System.Drawing.Color]::FromArgb(0,255,102) } else { $script:pn_armed.Text = "NOT ARMED"; $script:pn_armed.ForeColor = [System.Drawing.Color]::FromArgb(255,140,0) }
}
function Panel-UpdateStatus {
  $next = $null
  foreach ($al in $script:pn_alarms) { if (-not $al.Enabled) { continue }; $w = Resolve-When $al.Time $al.Date $al.Rhythm; if ($w -and ((-not $next) -or ($w -lt $next))) { $next = $w } }
  if ($next) { $script:pn_status.Text = ("next: {0}   in {1}" -f $next.ToString('ddd HH:mm'), (Format-Span ($next - (Get-Date)))) } else { $script:pn_status.Text = "no upcoming alarms" }
}
function Panel-Test {
  $a = Panel-CollectEditor; if (-not $a) { return }
  $tc = [ordered]@{ numQuestions=$a.NumQ; difficulty=$a.Diff; categories=$a.Cats; lockVolume=$a.LockVol; narrator=$a.Narrator }
  ($tc | ConvertTo-Json -Compress) | Out-File -FilePath (Join-Path $script:root 'session.testcfg') -Encoding ascii
  Panel-Log "launching test ring (solve it or wait 45s to end)..."
  try { Start-Process (Get-Command powershell).Source -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -Sta -WindowStyle Hidden -File "{0}\override.ps1" -Ring -TestNow' -f $script:eng) | Out-Null } catch { Panel-Log ("test error: " + $_.Exception.Message) }
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
  if (-not (Test-RingActive)) { Set-TaskMgrDisabled $false }   # self-heal if a past ring died hard
  if (-not (Test-Path $script:cfgPath)) { if (Import-V2Config) { } }
  Panel-LoadAlarms
  $script:pn_mr = [bool](Get-Prop $script:cfg.defaults 'matrixRain' $false)
  $green=[System.Drawing.Color]::FromArgb(0,255,102); $dim=[System.Drawing.Color]::FromArgb(124,255,176); $boxBg=[System.Drawing.Color]::FromArgb(0,26,10)
  $fL=New-Object System.Drawing.Font('Consolas',10); $fLb=New-Object System.Drawing.Font('Consolas',10,[System.Drawing.FontStyle]::Bold)

  $script:pn_form = New-Object System.Windows.Forms.Form
  $script:pn_form.Text = "OVERRIDE // CONTROL v3"; $script:pn_form.FormBorderStyle = 'Sizable'; $script:pn_form.MaximizeBox = $true
  $script:pn_form.StartPosition = 'CenterScreen'; $script:pn_form.MinimumSize = New-Object System.Drawing.Size(1040,820)
  $script:pn_form.WindowState = 'Maximized'; $script:pn_form.BackColor = [System.Drawing.Color]::Black
  $ico = Join-Path $script:eng 'override.ico'; if (Test-Path $ico) { try { $script:pn_form.Icon = New-Object System.Drawing.Icon $ico } catch {} }

  $script:pn_rain = New-RainBackground -Fps 8 -FontSize 18
  $script:pn_form.Controls.Add($script:pn_rain.Panel)

  $script:pn_box = New-Object System.Windows.Forms.Panel; $script:pn_box.Width=1000; $script:pn_box.Height=780; $script:pn_box.BackColor=[System.Drawing.Color]::FromArgb(0,12,5)
  $script:pn_box.Add_Paint({ param($s,$e) $r=$s.ClientRectangle; $pen=New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(0,255,102)),2; $e.Graphics.DrawRectangle($pen,1,1,$r.Width-3,$r.Height-3); $pen.Dispose() })
  $script:pn_form.Controls.Add($script:pn_box); $script:pn_rain.Panel.SendToBack()

  $hdr = New-Object System.Windows.Forms.Label; $hdr.Text=("OVERRIDE // CONTROL   "+[char]0x03A9); $hdr.Left=18; $hdr.Top=14; $hdr.Width=640; $hdr.Height=40; $hdr.ForeColor=$green; $hdr.BackColor=[System.Drawing.Color]::Transparent; $hdr.Font=New-Object System.Drawing.Font('Consolas',22,[System.Drawing.FontStyle]::Bold); $script:pn_box.Controls.Add($hdr)
  $script:pn_armed = New-Object System.Windows.Forms.Label; $script:pn_armed.Left=760; $script:pn_armed.Top=22; $script:pn_armed.Width=220; $script:pn_armed.Height=26; $script:pn_armed.TextAlign='MiddleRight'; $script:pn_armed.BackColor=[System.Drawing.Color]::Transparent; $script:pn_armed.Font=New-Object System.Drawing.Font('Consolas',13,[System.Drawing.FontStyle]::Bold); $script:pn_box.Controls.Add($script:pn_armed)

  $lh = New-Object System.Windows.Forms.Label; $lh.Text="ALARMS"; $lh.Left=20; $lh.Top=60; $lh.Width=200; $lh.ForeColor=$dim; $lh.BackColor=[System.Drawing.Color]::Transparent; $lh.Font=$fLb; $script:pn_box.Controls.Add($lh)
  $script:pn_list = New-Object System.Windows.Forms.Panel; $script:pn_list.Left=12; $script:pn_list.Top=84; $script:pn_list.Width=976; $script:pn_list.Height=200; $script:pn_list.AutoScroll=$true; $script:pn_list.BackColor=[System.Drawing.Color]::FromArgb(0,8,3); $script:pn_box.Controls.Add($script:pn_list)

  $eh = New-Object System.Windows.Forms.Label; $eh.Text="EDIT / ADD ALARM"; $eh.Left=20; $eh.Top=296; $eh.Width=300; $eh.ForeColor=$dim; $eh.BackColor=[System.Drawing.Color]::Transparent; $eh.Font=$fLb; $script:pn_box.Controls.Add($eh)

  function NewTb($x,$y,$w) { $t=New-Object System.Windows.Forms.TextBox; $t.Left=$x; $t.Top=$y; $t.Width=$w; $t.BackColor=$boxBg; $t.ForeColor=$dim; $t.BorderStyle='FixedSingle'; $t.Font=New-Object System.Drawing.Font('Consolas',12); $script:pn_box.Controls.Add($t); $t }
  function NewLbl($txt,$x,$y,$w,$small) { $l=New-Object System.Windows.Forms.Label; $l.Text=$txt; $l.Left=$x; $l.Top=$y; $l.Width=$w; $l.ForeColor=$(if($small) { [System.Drawing.Color]::FromArgb(80,150,110) } else { $dim }); $l.BackColor=[System.Drawing.Color]::Transparent; $l.Font=$(if($small) { New-Object System.Drawing.Font('Consolas',8) } else { $fL }); $script:pn_box.Controls.Add($l); $l }

  $r1 = 328
  $script:pn_eTime = NewTb 24 $r1 80;   (NewLbl "HH:MM" 24 ($r1+26) 80 $true) | Out-Null
  $script:pn_eLabel = NewTb 120 $r1 240; (NewLbl "label" 120 ($r1+26) 100 $true) | Out-Null
  $script:pn_eDate = NewTb 372 $r1 140;  (NewLbl "YYYY-MM-DD (blank=next)" 372 ($r1+26) 220 $true) | Out-Null
  $script:pn_eRhythm = New-Object System.Windows.Forms.CheckBox; $script:pn_eRhythm.Text="Rhythm (every day)"; $script:pn_eRhythm.Left=560; $script:pn_eRhythm.Top=($r1+2); $script:pn_eRhythm.Width=220; $script:pn_eRhythm.ForeColor=$green; $script:pn_eRhythm.BackColor=[System.Drawing.Color]::Transparent; $script:pn_eRhythm.Font=$fL; $script:pn_box.Controls.Add($script:pn_eRhythm)
  $script:pn_eRhythm.Add_CheckedChanged({ $script:pn_eDate.Enabled = -not $script:pn_eRhythm.Checked; if ($script:pn_eRhythm.Checked) { $script:pn_eDate.Text = '' } })

  $r2 = 382
  (NewLbl "difficulty" 24 ($r2+4) 76 $false) | Out-Null
  $script:pn_eDiff = New-Object System.Windows.Forms.ComboBox; $script:pn_eDiff.Left=104; $script:pn_eDiff.Top=$r2; $script:pn_eDiff.Width=110; $script:pn_eDiff.DropDownStyle='DropDownList'; $script:pn_eDiff.Items.AddRange(@('easy','medium','hard')); $script:pn_box.Controls.Add($script:pn_eDiff)
  (NewLbl "questions" 234 ($r2+4) 82 $false) | Out-Null
  $script:pn_eNumQ = New-Object System.Windows.Forms.ComboBox; $script:pn_eNumQ.Left=320; $script:pn_eNumQ.Top=$r2; $script:pn_eNumQ.Width=60; $script:pn_eNumQ.DropDownStyle='DropDownList'; $script:pn_eNumQ.Items.AddRange(@(1,2,3,4,5,6)); $script:pn_box.Controls.Add($script:pn_eNumQ)
  (NewLbl "duration" 400 ($r2+4) 70 $false) | Out-Null
  $script:pn_eDur = NewTb 472 $r2 50; (NewLbl "min" 526 ($r2+4) 40 $false) | Out-Null
  $script:pn_eLockVol = New-Object System.Windows.Forms.CheckBox; $script:pn_eLockVol.Text="lock volume @100%"; $script:pn_eLockVol.Left=580; $script:pn_eLockVol.Top=($r2+2); $script:pn_eLockVol.Width=190; $script:pn_eLockVol.ForeColor=$dim; $script:pn_eLockVol.BackColor=[System.Drawing.Color]::Transparent; $script:pn_eLockVol.Font=$fL; $script:pn_box.Controls.Add($script:pn_eLockVol)
  $script:pn_eNarr = New-Object System.Windows.Forms.CheckBox; $script:pn_eNarr.Text="narrator voice"; $script:pn_eNarr.Left=780; $script:pn_eNarr.Top=($r2+2); $script:pn_eNarr.Width=170; $script:pn_eNarr.ForeColor=$dim; $script:pn_eNarr.BackColor=[System.Drawing.Color]::Transparent; $script:pn_eNarr.Font=$fL; $script:pn_box.Controls.Add($script:pn_eNarr)

  $r3 = 426
  (NewLbl "subjects" 24 ($r3+2) 80 $false) | Out-Null
  $script:pn_eCats = @{}
  $colW = 215; $col = 0; $rowI = 0
  foreach ($c in $script:CATS) {
    $chk = New-Object System.Windows.Forms.CheckBox; $chk.Text=$c; $chk.Left=(104 + $col*$colW); $chk.Top=($r3 + $rowI*28); $chk.Width=200
    $chk.ForeColor=$green; $chk.BackColor=[System.Drawing.Color]::Transparent; $chk.Font=$fL
    $script:pn_box.Controls.Add($chk); $script:pn_eCats[$c]=$chk
    $col++; if ($col -ge 4) { $col = 0; $rowI++ }
  }

  $r4 = 526
  $script:pn_saveBtn = New-Object System.Windows.Forms.Button; $script:pn_saveBtn.Text='DEPLOY ALARM'; $script:pn_saveBtn.Left=24; $script:pn_saveBtn.Top=$r4; $script:pn_saveBtn.Width=200; $script:pn_saveBtn.Height=36; $script:pn_saveBtn.FlatStyle='Flat'; $script:pn_saveBtn.ForeColor=$green; $script:pn_saveBtn.BackColor=[System.Drawing.Color]::FromArgb(0,33,15); $script:pn_saveBtn.Font=$fLb; $script:pn_saveBtn.Add_Click({ Panel-SaveAlarm }); $script:pn_box.Controls.Add($script:pn_saveBtn)
  $newBtn = New-Object System.Windows.Forms.Button; $newBtn.Text='NEW / CLEAR'; $newBtn.Left=234; $newBtn.Top=$r4; $newBtn.Width=140; $newBtn.Height=36; $newBtn.FlatStyle='Flat'; $newBtn.ForeColor=$dim; $newBtn.BackColor=[System.Drawing.Color]::FromArgb(0,24,11); $newBtn.Font=$fL; $newBtn.Add_Click({ Panel-LoadEditor $null; Panel-Log "editor cleared" }); $script:pn_box.Controls.Add($newBtn)

  $r5 = 588
  $testBtn = New-Object System.Windows.Forms.Button; $testBtn.Text="TEST RING"; $testBtn.Left=24; $testBtn.Top=$r5; $testBtn.Width=180; $testBtn.Height=46; $script:pn_box.Controls.Add($testBtn)
  $armBtn  = New-Object System.Windows.Forms.Button; $armBtn.Text=">> RE-DEPLOY ALL"; $armBtn.Left=214; $armBtn.Top=$r5; $armBtn.Width=200; $armBtn.Height=46; $script:pn_box.Controls.Add($armBtn)
  $disBtn  = New-Object System.Windows.Forms.Button; $disBtn.Text="DISARM ALL"; $disBtn.Left=424; $disBtn.Top=$r5; $disBtn.Width=170; $disBtn.Height=46; $script:pn_box.Controls.Add($disBtn)
  foreach ($b in @($testBtn,$armBtn,$disBtn)) { $b.FlatStyle='Flat'; $b.ForeColor=$green; $b.BackColor=[System.Drawing.Color]::FromArgb(0,33,15); $b.Font=New-Object System.Drawing.Font('Consolas',13,[System.Drawing.FontStyle]::Bold) }
  $testBtn.Add_Click({ Panel-Test })
  $armBtn.Add_Click({ Panel-Deploy })
  $disBtn.Add_Click({ foreach ($al in $script:pn_alarms) { $al.Enabled = $false }; Panel-SaveConfig; Remove-Alarms; Panel-RenderRows; Panel-RefreshArmed; Panel-UpdateStatus; Panel-Log "all alarms disarmed + disabled" })

  $script:pn_status = New-Object System.Windows.Forms.Label; $script:pn_status.Left=24; $script:pn_status.Top=652; $script:pn_status.Width=640; $script:pn_status.Height=24; $script:pn_status.ForeColor=[System.Drawing.Color]::FromArgb(120,220,160); $script:pn_status.BackColor=[System.Drawing.Color]::Transparent; $script:pn_status.Font=New-Object System.Drawing.Font('Consolas',12); $script:pn_box.Controls.Add($script:pn_status)
  $script:pn_log = New-Object System.Windows.Forms.Label; $script:pn_log.Left=24; $script:pn_log.Top=680; $script:pn_log.Width=956; $script:pn_log.Height=22; $script:pn_log.ForeColor=[System.Drawing.Color]::FromArgb(90,170,120); $script:pn_log.BackColor=[System.Drawing.Color]::Transparent; $script:pn_log.Font=$fL; $script:pn_box.Controls.Add($script:pn_log)
  $hint = New-Object System.Windows.Forms.Label; $hint.Text="blank date = next occurrence  |  Rhythm = every day  |  12 subjects, each alarm independent  |  0% CPU between alarms"; $hint.Left=24; $hint.Top=706; $hint.Width=956; $hint.Height=20; $hint.ForeColor=[System.Drawing.Color]::FromArgb(70,130,95); $hint.BackColor=[System.Drawing.Color]::Transparent; $hint.Font=New-Object System.Drawing.Font('Consolas',9); $script:pn_box.Controls.Add($hint)

  $script:pn_statusTimer = New-Object System.Windows.Forms.Timer; $script:pn_statusTimer.Interval = 1000; $script:pn_statusTimer.Add_Tick({ Panel-UpdateStatus; if ($script:pn_mr) { $script:pn_tick++; if (($script:pn_tick % 11) -eq 0) { Panel-Glitch } } })
  $script:pn_form.Add_Activated({ try { if ($script:pn_mr -and $script:pn_form.WindowState -ne 'Minimized') { $script:pn_rain.Timer.Start() } } catch {} })
  $script:pn_form.Add_Deactivate({ try { $script:pn_rain.Timer.Stop() } catch {} })
  $script:pn_form.Add_Resize({ Panel-Reposition; try { if ($script:pn_form.WindowState -eq 'Minimized') { $script:pn_rain.Timer.Stop() } elseif ($script:pn_mr) { $script:pn_rain.Timer.Start() } } catch {} })
  $script:pn_form.Add_Shown({
    Panel-LoadEditor $null; Panel-RenderRows; Panel-RefreshArmed; Panel-UpdateStatus; Panel-Reposition
    if ($script:pn_mr) { $script:pn_rain.Timer.Start() }; $script:pn_statusTimer.Start()
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
if ($Disarm) { Write-Host "OVERRIDE v3 // disarming..." -ForegroundColor Yellow; Remove-Alarms; return }
if ($Arm)    { Write-Host "OVERRIDE v3 // arming..." -ForegroundColor Green; Register-Alarms; return }
if ($DryRun) { Write-Host ("OVERRIDE v3 schedule  ({0})" -f (Get-Date)) -ForegroundColor Green; Show-Tasks; return }

if ($Ring) {
  # same mutex name as v2 ON PURPOSE: during migration both sets of tasks may exist
  # for one night — the mutex guarantees only ONE ring ever runs at a time.
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
