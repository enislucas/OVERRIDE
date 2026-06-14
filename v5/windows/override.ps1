param(
  [switch]$Ring, [string]$AlarmId = "", [switch]$TestNow,
  [switch]$Arm, [switch]$Disarm, [switch]$Unlock,
  [switch]$DryRun, [switch]$Probe, [int]$PanelTestSec = 0, [switch]$AutoDeploy
)
# OVERRIDE v5 // WAKE PROTOCOL — Windows engine (THEMED edition, started as a frozen copy of v4)
# v5 = the optimization/code-improvement line. v4 is the frozen rollback (tag v4-stable).
# Same architecture as v3 (scheduled tasks -> one ephemeral ring, 0 CPU between alarms),
# plus:
#  - PRIMARY renderer: Edge kiosk showing quiz/quiz.html (GPU-composited, modern CSS,
#    4-theme menu: green/red/cyber/crt + roulette). Own --user-data-dir profile so we
#    NEVER touch the user's real browser; cleanup kills only that profile's processes.
#  - SOLVED/heartbeat from the browser arrive as image beacons on a raw TcpListener
#    (127.0.0.1, first free port 8741-8749). TcpListener needs no admin/URLACL —
#    HttpListener does, which is why we don't use it.
#  - FALLBACK renderer: if Edge is missing or fails, the v3-style mshta quiz.hta runs
#    (session files + UNLOCK file), so the alarm rings on any Windows box regardless.
# Invariants (see v3/MAINTENANCE.md, all still binding): the alarm must fire no matter
# what; 0 CPU between alarms; never manhandle windows; lockdown always releases.

$ErrorActionPreference = "Stop"
$script:eng = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$script:root = Split-Path -Parent $script:eng          # v4 root: session files + config live here
$script:cfgPath = Join-Path $script:root "config.json"
$script:quizHta  = Join-Path $script:root "quiz\quiz.hta"
$script:quizHtml = Join-Path $script:root "quiz\quiz.html"
$script:CATS = @('arithmetic','derivatives','vectors','matrices','capitals',
                 'equations','percentages','powers','sequences','integrals','binary','elements')
$script:THEMES = @('green','red','cyber','crt','roulette')

function New-DefaultConfig {
  $cats = [ordered]@{}; foreach ($c in $script:CATS) { $cats[$c] = ($c -eq 'arithmetic') }
  [pscustomobject]@{ version = 5
    defaults = [pscustomobject]@{ difficulty='hard'; numQuestions=3; durationMin=3; lockVolume=$true; narrator=$true; matrixRain=$true; theme='green'; renderer='auto'; edgeMinFreeMB=900; categories=[pscustomobject]$cats }
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
        if(vk==0x5B||vk==0x5C) block=true;                 // LWin / RWin
        else if(vk==0x09 && alt) block=true;               // Alt+Tab
        else if(vk==0x1B && (ctrl||alt)) block=true;       // Ctrl+Esc / Alt+Esc / Ctrl+Shift+Esc
        else if(vk==0x73 && alt) block=true;               // Alt+F4
        else if(vk==0x20 && alt) block=true;               // Alt+Space
        else if(vk==0x57 && ctrl) block=true;              // Ctrl+W (closes a browser kiosk!)
        else if(vk==0x74 && ctrl) block=true;              // Ctrl+F5
        else if(vk==0x73 && ctrl) block=true;              // Ctrl+F4
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
  // z-order nudge ONLY — never moves/resizes/focus-loops (v2 black-screen history)
  public static void TopMost(IntPtr h){ if (h == IntPtr.Zero) return; SetWindowPos(h, HWND_TOPMOST, 0, 0, 0, 0, GENTLE); }
  public static void Raise(IntPtr h){ if (h == IntPtr.Zero) return; SetWindowPos(h, HWND_TOPMOST, 0, 0, 0, 0, GENTLE); SetForegroundWindow(h); }
}
"@
try { Add-Type -TypeDefinition $winSrc -Language CSharp } catch {}

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
function Resolve-Theme([string]$t) {
  if ($t -eq 'roulette' -or -not $t) { return @('green','red','cyber','crt') | Get-Random }
  if ($script:THEMES -contains $t) { return $t }
  return 'green'
}
function C([int]$r,[int]$g,[int]$b) { [System.Drawing.Color]::FromArgb($r,$g,$b) }
function Get-PanelPalette([string]$theme) {
  # the control panel wears the same skin as the quiz — driven by defaults.theme.
  # Accent2 = a vivid secondary used for headers/highlights so the panel doesn't read "pale".
  $t = $theme; if ($t -eq 'roulette' -or -not ($script:THEMES -contains $t)) { $t = 'green' }
  switch ($t) {
    'red'   { @{ Accent=(C 255 60 75);  Accent2=(C 255 120 60); Dim=(C 255 175 180); Box=(C 20 1 4);  Field=(C 40 2 8);   Row=(C 36 3 9);  Glow=(C 255 40 60);  Rain=(C 255 55 70);  Scan=(C 60 0 0) } }
    'cyber' { @{ Accent=(C 60 255 255); Accent2=(C 255 70 220); Dim=(C 210 180 255); Box=(C 10 7 30); Field=(C 18 14 46); Row=(C 20 14 44); Glow=(C 255 0 230);  Rain=(C 0 255 255);  Scan=(C 0 40 50) } }
    'crt'   { @{ Accent=(C 60 255 150); Accent2=(C 0 230 130);  Dim=(C 150 255 200); Box=(C 2 16 7);  Field=(C 0 30 13);  Row=(C 0 28 12); Glow=(C 0 255 120);  Rain=(C 60 255 150); Scan=(C 0 48 20) } }
    default { @{ Accent=(C 0 255 120);  Accent2=(C 120 255 90);  Dim=(C 150 255 195); Box=(C 0 16 7);  Field=(C 0 32 14);  Row=(C 0 28 12); Glow=(C 0 255 120);  Rain=(C 0 255 120);  Scan=(C 0 40 18) } }
  }
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
  $mr   = [bool]  (Get-Prop $a 'matrixRain'   (Get-Prop $d 'matrixRain' $true))
  $thm  = [string](Get-Prop $a 'theme'        (Get-Prop $d 'theme' 'green'))
  $catO =         (Get-Prop $a 'categories'   (Get-Prop $d 'categories' $null))
  $lbl  = [string](Get-Prop $a 'label' 'WAKE UP')
  $rend = [string](Get-Prop $a 'renderer'     (Get-Prop $d 'renderer' 'auto'))
  $emf  = [int]   (Get-Prop $a 'edgeMinFreeMB' (Get-Prop $d 'edgeMinFreeMB' 900))
  if ($dur -lt 1) { $dur = 1 }
  return @{ Label=$lbl; Diff=$diff; NumQ=$nq; Cats=(Convert-Cats $catO); DurationSec=($dur*60); LockVol=$lv; Narrator=$nar; MatrixRain=$mr; Theme=$thm; Renderer=$rend; EdgeMinFreeMB=$emf; Lockdown=$true; Relaunch=$true; Quiet=$false }
}
function Get-TestSettings {
  $p = Join-Path $script:root 'session.testcfg'
  $diff='hard'; $nq=3; $cats=(Convert-Cats (Get-Prop $script:cfg.defaults 'categories' $null)); $dur=45; $lv=$true; $mr=$true; $nar=$true; $quiet=$false; $rel=$false
  $thm=[string](Get-Prop $script:cfg.defaults 'theme' 'green')
  $rend=[string](Get-Prop $script:cfg.defaults 'renderer' 'auto'); $emf=[int](Get-Prop $script:cfg.defaults 'edgeMinFreeMB' 900)
  if (Test-Path $p) { try { $t = Get-Content $p -Raw | ConvertFrom-Json
    if ($t.difficulty) { $diff=[string]$t.difficulty }
    if ($t.numQuestions) { $nq=[int]$t.numQuestions }
    if ($t.categories) { $cats=Convert-Cats $t.categories }
    if ($t.PSObject.Properties.Name -contains 'lockVolume') { $lv=[bool]$t.lockVolume }
    if ($t.PSObject.Properties.Name -contains 'matrixRain') { $mr=[bool]$t.matrixRain }
    if ($t.PSObject.Properties.Name -contains 'narrator')   { $nar=[bool]$t.narrator }
    if ($t.PSObject.Properties.Name -contains 'theme')      { $thm=[string]$t.theme }
    if ($t.PSObject.Properties.Name -contains 'durationSec'){ $dur=[int]$t.durationSec; if ($dur -lt 5) { $dur = 5 } }
    if ($t.PSObject.Properties.Name -contains 'quiet')      { $quiet=[bool]$t.quiet }
    if ($t.PSObject.Properties.Name -contains 'relaunch')   { $rel=[bool]$t.relaunch }   # test the anti-thrash relaunch path
    if ($t.PSObject.Properties.Name -contains 'renderer')   { $rend=[string]$t.renderer }
    if ($t.PSObject.Properties.Name -contains 'edgeMinFreeMB'){ $emf=[int]$t.edgeMinFreeMB }
  } catch {} }
  if ($quiet) { $lv = $false; $nar = $false }
  return @{ Label='TEST'; Diff=$diff; NumQ=$nq; Cats=$cats; DurationSec=$dur; LockVol=$lv; Narrator=$nar; MatrixRain=$mr; Theme=$thm; Renderer=$rend; EdgeMinFreeMB=$emf; Lockdown=$false; Relaunch=$rel; Quiet=$quiet }
}

# ---- unlock/heartbeat listener (raw TCP: works without admin, unlike HttpListener) ----
function Start-Listener {
  $script:rg_tcp = $null; $script:rg_port = 0
  # a valid 43-byte 1x1 GIF returned to every beacon so the browser <img> fires onload
  $script:rg_gif = [byte[]]@(0x47,0x49,0x46,0x38,0x39,0x61,0x01,0x00,0x01,0x00,0x80,0x00,0x00,0x00,0x00,0x00,0xFF,0xFF,0xFF,0x21,0xF9,0x04,0x01,0x00,0x00,0x00,0x00,0x2C,0x00,0x00,0x00,0x00,0x01,0x00,0x01,0x00,0x00,0x02,0x02,0x44,0x01,0x00,0x3B)
  foreach ($p in 8741..8749) {
    try {
      $l = New-Object System.Net.Sockets.TcpListener ([System.Net.IPAddress]::Loopback, $p)
      $l.Start(); $script:rg_tcp = $l; $script:rg_port = $p; break
    } catch {}
  }
}
function Pump-Listener {
  if (-not $script:rg_tcp) { return }
  $guard = 0
  while ($script:rg_tcp.Pending() -and $guard -lt 20) {
    $guard++
    $client = $null
    try {
      $client = $script:rg_tcp.AcceptTcpClient()
      $script:rg_lastQuizSeen = Get-Date    # browser quiz is alive (it beats every 2s) -> never relaunch over it
      $client.ReceiveTimeout = 400
      $stream = $client.GetStream(); $stream.ReadTimeout = 400
      $buf = New-Object byte[] 2048
      $n = $stream.Read($buf, 0, $buf.Length)
      $req = [System.Text.Encoding]::ASCII.GetString($buf, 0, [Math]::Max(0,$n))
      if ($req -match '^GET\s+/unlock\?key=([0-9a-fA-F]+)') {
        $k = $Matches[1]
        if ($k -eq $script:rg_key) { Set-Content -Path (Join-Path $script:root 'UNLOCK') -Value $k -Encoding ASCII }
      }
      # a REAL 43-byte 1x1 GIF — must actually DECODE so the browser's <img> beacon fires onload
      # and resets its failure counter. Replying with the bare string "GIF89a" made every beat
      # fail to decode -> the quiz wrongly concluded "engine gone" and closed itself at ~12s.
      $body = $script:rg_gif
      $hdr = "HTTP/1.1 200 OK`r`nContent-Type: image/gif`r`nAccess-Control-Allow-Origin: *`r`nContent-Length: $($body.Length)`r`nConnection: close`r`n`r`n"
      $hb = [System.Text.Encoding]::ASCII.GetBytes($hdr)
      $stream.Write($hb, 0, $hb.Length); $stream.Write($body, 0, $body.Length); $stream.Flush()
    } catch {}
    finally { try { if ($client) { $client.Close() } } catch {} }
  }
}
function Stop-Listener { try { if ($script:rg_tcp) { $script:rg_tcp.Stop(); $script:rg_tcp = $null } } catch {} }

# ---- quiz launching: Edge kiosk primary, mshta fallback ---------------------
$script:EDGE_PROFILE = Join-Path $env:TEMP 'override_v5_profile'
function Find-Edge {
  foreach ($p in @("${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
                   "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe")) {
    if ($p -and (Test-Path $p)) { return $p }
  }
  try { $c = Get-Command msedge.exe -ErrorAction SilentlyContinue; if ($c) { return $c.Source } } catch {}
  return $null
}
function Get-QuizUrl {
  $catCsv = (@($script:rg_S.Cats.Keys | Where-Object { $script:rg_S.Cats[$_] }) -join ',')
  if (-not $catCsv) { $catCsv = 'arithmetic' }
  $pathUri = ([uri]$script:quizHtml).AbsoluteUri
  $qs = "key=$($script:rg_key)&port=$($script:rg_port)" +
        "&label=$([uri]::EscapeDataString($script:rg_S.Label))" +
        "&n=$($script:rg_S.NumQ)&diff=$($script:rg_S.Diff)&cats=$catCsv" +
        "&rain=$(if ($script:rg_S.MatrixRain) {1} else {0})" +
        "&deadline=$($script:rg_dlms)&theme=$($script:rg_theme)" +
        "&user=$([uri]::EscapeDataString($env:USERNAME))"
  "$pathUri`?$qs"
}
function Launch-Quiz {
  $script:rg_proc = $null
  # launch-grace anchor: NEVER re-evaluate "is the quiz alive / should I relaunch" for the next
  # rg_launchGrace seconds. This is the fix for the relaunch-thrash bug (bug museum #17): mshta
  # and Edge both hand off to a different process, so the launched PID's HasExited lies almost
  # immediately -> the old code relaunched every ~0.5s and the window was never solvable.
  $script:rg_launchAt = Get-Date
  $script:rg_lastQuizSeen = Get-Date
  if ($script:rg_useEdge) {
    try {
      $url = Get-QuizUrl
      $edgeArgs = @("--user-data-dir=`"$($script:EDGE_PROFILE)`"", '--no-first-run', '--disable-extensions',
                '--disable-sync', '--no-default-browser-check', '--disable-session-crashed-bubble',
                '--disk-cache-size=1048576', '--autoplay-policy=no-user-gesture-required',
                '--renderer-process-limit=2', '--disable-background-networking',   # low-RAM machine: keep the kiosk lean
                '--kiosk', "`"$url`"", '--edge-kiosk-type=fullscreen')
      $script:rg_proc = Start-Process (Find-Edge) -ArgumentList ($edgeArgs -join ' ') -PassThru
      return
    } catch { $script:rg_proc = $null; $script:rg_useEdge = $false }   # fall through to mshta
  }
  try {
    if (-not (Test-Path $script:quizHta)) { return }
    $exe = Join-Path $env:WINDIR 'System32\mshta.exe'
    $script:rg_proc = Start-Process $exe -ArgumentList ('"' + $script:quizHta + '"') -PassThru
  } catch { $script:rg_proc = $null }
}
function Test-QuizPresent {
  # robust "is the quiz still showing?" — NEVER trust the launched PID (mshta/Edge hand off).
  # (1) recent listener traffic = the browser quiz is beating; (2) else a hosting process exists.
  try { if (((Get-Date) - $script:rg_lastQuizSeen).TotalSeconds -lt 8) { return $true } } catch {}
  try {
    if ($script:rg_useEdge) {
      return (@(Get-CimInstance Win32_Process -Filter "Name='msedge.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -match 'override_v5_profile' }).Count -gt 0)
    } else {
      return (@(Get-CimInstance Win32_Process -Filter "Name='mshta.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -match 'quiz' }).Count -gt 0)
    }
  } catch { return $true }   # uncertain -> assume alive; better to under-relaunch than thrash
}
function Stop-QuizProcs {
  try { if ($script:rg_proc -and -not $script:rg_proc.HasExited) { $script:rg_proc.Kill() } } catch {}
  # targeted sweep: ONLY our kiosk profile's Edge processes + our quiz mshta. The user's
  # own browser windows are untouched (different user-data-dir / command line).
  try { Get-CimInstance Win32_Process -Filter "Name='msedge.exe'" |
        Where-Object { $_.CommandLine -match 'override_v5_profile' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue } } catch {}
  try { Get-CimInstance Win32_Process -Filter "Name='mshta.exe'" |
        Where-Object { $_.CommandLine -match 'quiz\.hta' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue } } catch {}
}

# ---- the ring engine -------------------------------------------------------
function Remove-RingFiles {
  foreach ($f in 'UNLOCK','PANIC','session.beat','session.key','session.deadline','session.deadlinems','session.start','session.label','session.quizcfg','session.render') {
    $p = Join-Path $script:root $f; if (Test-Path $p) { try { [System.IO.File]::Delete($p) } catch {} }
  }
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
  Pump-Listener
  $unlk = Join-Path $script:root 'UNLOCK'
  if (Test-Path $unlk) { $c = (Get-Content $unlk -Raw); if ($c) { $c = $c.Trim() }; if ($c -eq $script:rg_key) { $script:rg_solved = $true; End-Ring; return } }
  if ($now -ge $script:rg_deadline -or (Test-Path (Join-Path $script:root 'PANIC'))) { End-Ring; return }
  $script:rg_tk++
  if ($script:rg_relaunch) {
    # REAL alarm: relaunch ONLY if the quiz is genuinely gone, and only after the launch grace.
    # Checked at most every 2s (CIM is mildly expensive). This can no longer thrash: worst case
    # is one relaunch per grace window, and each relaunch re-anchors the grace.
    if ((($now - $script:rg_launchAt).TotalSeconds -ge $script:rg_launchGrace) -and (($script:rg_tk % 4) -eq 0)) {
      if (-not (Test-QuizPresent)) { Launch-Quiz; $script:rg_pinnedH = [IntPtr]::Zero }
    }
    # gentle topmost nudge while we still hold a live window handle (best-effort; Edge kiosk is
    # already topmost, mshta benefits). Never moves/resizes/focus-loops.
    try {
      if ($script:rg_proc -and -not $script:rg_proc.HasExited) {
        $script:rg_proc.Refresh(); $h = $script:rg_proc.MainWindowHandle
        if ($h -ne [IntPtr]::Zero) {
          if ($h -ne $script:rg_pinnedH) { [Win]::Raise($h); $script:rg_pinnedH = $h }
          elseif (($script:rg_tk % 4) -eq 0) { [Win]::TopMost($h) }
        }
      }
    } catch {}
  } else {
    # TEST ring (no relaunch): end when the single window closes.
    if (($null -eq $script:rg_proc) -or $script:rg_proc.HasExited) { End-Ring; return }
  }
  if ($script:rg_lockdown -and (($script:rg_tk % 6) -eq 0)) { try { Get-Process -Name Taskmgr -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue } catch {} }
  if ($script:rg_narrator -and ($now -ge $script:rg_nagAt)) { Speak-Line ($script:NAG_LINES | Get-Random); $script:rg_nagAt = $now.AddSeconds(22) }
}
function Resolve-Sounds {
  $t1=@(); $t2=@(); $t3=@()
  $up = Split-Path -Parent $script:root
  foreach ($sf in @((Join-Path $script:root 'sounds'), (Join-Path $up 'v3\sounds'), (Join-Path $up 'v2\sounds'))) {
    if (-not (Test-Path $sf)) { continue }
    foreach ($w in @(Get-ChildItem $sf -File | Where-Object { $_.Extension -match '(?i)\.wav$' })) {
      if ($w.Name -like 't2_*') { $t2 += $w.FullName } elseif ($w.Name -like 't3_*') { $t3 += $w.FullName } else { $t1 += $w.FullName } }
    if ((@($t1).Count + @($t2).Count + @($t3).Count) -gt 0) { break }
  }
  if ((@($t1).Count + @($t2).Count + @($t3).Count) -eq 0) {
    $fb = Join-Path $env:TEMP 'override_v5_fallback.wav'
    try { if (-not (Test-Path $fb)) { [FallbackSound]::Warble($fb, 6.0) }; $t1 = @($fb) } catch {}
  }
  if (@($t1).Count -eq 0) { $t1 = $t2 }; if (@($t2).Count -eq 0) { $t2 = $t1 }; if (@($t3).Count -eq 0) { $t3 = $t2 }
  $script:rg_tierA=@($t1); $script:rg_tierB=@($t2); $script:rg_tierC=@($t3); $script:rg_haveSnd=(@($t1).Count -gt 0)
}
function Run-Ring {
  param([hashtable]$S)
  $script:rg_exiting = $false
  $script:rg_S = $S
  foreach ($f in 'UNLOCK','PANIC','session.beat') { $q = Join-Path $script:root $f; if (Test-Path $q) { try { [System.IO.File]::Delete($q) } catch {} } }
  $key = [guid]::NewGuid().ToString('N')
  $start = Get-Date; $script:rg_deadline = $start.AddSeconds($S.DurationSec); $script:rg_key = $key
  $script:rg_theme = Resolve-Theme $S.Theme
  Set-Content -Path (Join-Path $script:root 'session.key')      -Value $key -Encoding ASCII
  Set-Content -Path (Join-Path $script:root 'session.deadline') -Value ($script:rg_deadline.ToString('o')) -Encoding ASCII
  $script:rg_dlms = [DateTimeOffset]::new($script:rg_deadline).ToUnixTimeMilliseconds()
  Set-Content -Path (Join-Path $script:root 'session.deadlinems') -Value $script:rg_dlms -Encoding ASCII
  Set-Content -Path (Join-Path $script:root 'session.start')    -Value ($start.ToString('o')) -Encoding ASCII
  Set-Content -Path (Join-Path $script:root 'session.label')    -Value $S.Label -Encoding ASCII
  $qc = [ordered]@{ numQuestions = $S.NumQ; difficulty = $S.Diff; categories = $S.Cats; matrixRain = $S.MatrixRain; theme = $script:rg_theme; user = $env:USERNAME }
  ($qc | ConvertTo-Json -Compress) | Set-Content -Path (Join-Path $script:root 'session.quizcfg') -Encoding ASCII

  $script:rg_relaunch = $S.Relaunch; $script:rg_lockdown = $S.Lockdown; $script:rg_lockVol = $S.LockVol; $script:rg_narrator = $S.Narrator
  $script:rg_proc = $null; $script:rg_sndIdx = 0; $script:rg_nagAt = $start.AddSeconds(16); $script:rg_tk = 0; $script:rg_pinnedH = [IntPtr]::Zero
  $script:rg_launchGrace = 12; $script:rg_launchAt = $start; $script:rg_lastQuizSeen = $start   # anti-thrash (bug museum #17)

  Start-Listener
  # ADAPTIVE RENDERER (v5): Edge kiosk is prettier but heavy (~9 procs / ~450 MB). On this
  # machine the user often runs heavy Edge + several VS Code/Claude instances, so at ring time
  # we check FREE RAM and fall back to the featherweight mshta renderer (~44 MB / 1 proc, still
  # themed) when memory is tight — never risk a low-memory crash for visual polish.
  #   defaults.renderer: 'auto' (default, RAM-based) | 'edge' (force) | 'mshta' (force light)
  #   defaults.edgeMinFreeMB: free-RAM floor for choosing Edge in auto mode (default 900)
  $rendPref = [string]$S.Renderer
  $edgeMinFree = [int]$S.EdgeMinFreeMB
  $edgeAvail = ($null -ne (Find-Edge)) -and (Test-Path $script:quizHtml) -and ($script:rg_port -gt 0)
  $freeMB = try { [int]((Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory/1KB) } catch { 999999 }
  $ramOk = ($freeMB -ge $edgeMinFree)
  $script:rg_useEdge = switch ($rendPref) {
    'edge'  { $edgeAvail }
    'mshta' { $false }
    default { $edgeAvail -and $ramOk }   # 'auto'
  }
  $script:rg_renderChoice = if ($script:rg_useEdge) { "edge" } else { "mshta" }
  try { Set-Content -Path (Join-Path $script:root 'session.render') -Value ("{0} (pref={1} freeMB={2} floor={3} edgeAvail={4})" -f $script:rg_renderChoice,$rendPref,$freeMB,$edgeMinFree,$edgeAvail) -Encoding ASCII } catch {}

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
  Launch-Quiz
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
    Stop-QuizProcs
    Stop-Listener
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
  # removes v4 + legacy v3/v2 tasks (v4 replaces them). NEVER touches OVERRIDE_LIVE_*.
  Get-ScheduledTask -ErrorAction SilentlyContinue |
    Where-Object { ($_.TaskName -like 'OVERRIDE_V5_*' -or $_.TaskName -like 'OVERRIDE_V4_*' -or $_.TaskName -like 'OVERRIDE_V3_*' -or $_.TaskName -like 'OVERRIDE_V2_*') -and $_.TaskName -notlike 'OVERRIDE_LIVE*' } |
    ForEach-Object { Unregister-ScheduledTask -TaskName $_.TaskName -Confirm:$false -ErrorAction SilentlyContinue }
}
function Register-Alarms {
  Load-Config; Remove-Alarms
  # enable wake-timers — only ONCE per process (the setting persists in the scheme; running the
  # 3 powercfg calls on every re-arm was part of the panel's per-action lag)
  if (-not $script:pn_powerDone) {
    try { $sub="238c9fa8-0aad-41ed-83f4-97be242c8f20"; $set="bd3b718a-0680-4d9d-8ab2-e1d2b4ac806d"
      powercfg /setacvalueindex SCHEME_CURRENT $sub $set 1 | Out-Null; powercfg /setdcvalueindex SCHEME_CURRENT $sub $set 1 | Out-Null; powercfg /setactive SCHEME_CURRENT | Out-Null } catch {}
    $script:pn_powerDone = $true
  }
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
    Register-ScheduledTask -TaskName "OVERRIDE_V5_$($a.id)" -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force | Out-Null
    $safeArg = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$($script:eng)\override.ps1`" -Unlock"
    $safeAction = New-ScheduledTaskAction -Execute $pw -Argument $safeArg -WorkingDirectory $script:eng
    $safeSettings = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 2) -MultipleInstances IgnoreNew
    Register-ScheduledTask -TaskName "OVERRIDE_V5_safe_$($a.id)" -Action $safeAction -Trigger $safeTrigger -Settings $safeSettings -Principal $principal -Force | Out-Null
    Write-Host "  armed  $($a.label)  $desc  [theme: $(Get-Prop $a 'theme' 'green')]" -ForegroundColor Green; $n++
  }
  Write-Host "$n alarm(s) armed (v5). Legacy OVERRIDE_V4_*/V3_*/V2_* tasks were replaced." -ForegroundColor Green
}
function Get-ArmedCount {
  $n = 0
  foreach ($t in @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -like 'OVERRIDE_V5_*' -and $_.TaskName -notlike '*_safe_*' })) {
    try { $i = $t | Get-ScheduledTaskInfo; if ($i.NextRunTime -and $i.NextRunTime -gt (Get-Date)) { $n++ } } catch {}
  }
  $n
}
function Show-Tasks {
  $tasks = @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -like 'OVERRIDE_V5_*' -and $_.TaskName -notlike '*_safe_*' })
  if ($tasks.Count -eq 0) { Write-Host "   (no v4 alarms armed)" -ForegroundColor DarkYellow; return }
  foreach ($t in ($tasks | Sort-Object TaskName)) { $i = $t | Get-ScheduledTaskInfo; Write-Host ("    {0,-10} next: {1,-22} [{2}]" -f ($t.TaskName -replace '^OVERRIDE_V5_',''), $i.NextRunTime, $t.State) -ForegroundColor Green }
}

# ---- matrix rain (panel ambient; opt-in, fps-capped, double-buffered) ------
function Update-RainSize($p) {
  $st = $p.Tag
  $dw = [math]::Max(1,$p.ClientSize.Width); $dh = [math]::Max(1,$p.ClientSize.Height)
  $st.dispW = $dw; $st.dispH = $dh
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
  param([int]$Fps = 8, [int]$FontSize = 18, $Color = $null)
  if (-not $Color) { $Color = [System.Drawing.Color]::FromArgb(0,255,102) }
  $panel = New-Object System.Windows.Forms.Panel; $panel.Dock = 'Fill'; $panel.BackColor = [System.Drawing.Color]::Black
  try { $bf = [System.Reflection.BindingFlags]([System.Reflection.BindingFlags]::Instance -bor [System.Reflection.BindingFlags]::NonPublic); $panel.GetType().GetProperty('DoubleBuffered',$bf).SetValue($panel,$true,$null) } catch {}
  $st = @{ bmp=$null; scan=$null; drops=$null; cols=0; fh=$FontSize
    font=(New-Object System.Drawing.Font('Consolas',$FontSize,[System.Drawing.FontStyle]::Bold))
    chars='0123456789ABCDEF#$%*+=<>/\|'; fade=(New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(38,0,0,0)))
    body=(New-Object System.Drawing.SolidBrush $Color); rng=(New-Object System.Random); dispW=0; dispH=0 }
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
    LockVol=[bool](Get-Prop $d 'lockVolume' $true); Narrator=[bool](Get-Prop $d 'narrator' $true)
    Rain=[bool](Get-Prop $d 'matrixRain' $true); Theme=[string](Get-Prop $d 'theme' 'green')
    Cats=(Convert-Cats (Get-Prop $d 'categories' $null)) }
}
function Import-PriorConfig {
  # first run: adopt alarms from v3 (preferred) or v2
  $up = Split-Path -Parent $script:root
  foreach ($prior in @((Join-Path $up 'v4\config.json'), (Join-Path $up 'v3\config.json'), (Join-Path $up 'v2\config.json'))) {
    if (-not (Test-Path $prior)) { continue }
    try {
      $old = Get-Content $prior -Raw | ConvertFrom-Json
      if (-not $old.alarms) { continue }
      $script:cfg = New-DefaultConfig
      $imported = @()
      foreach ($a in $old.alarms) {
        $imported += [pscustomobject]@{
          id=[string]$a.id; label=[string]$a.label; time=[string]$a.time
          date=[string](Get-Prop $a 'date' ''); rhythm=[bool](Get-Prop $a 'rhythm' $false); enabled=[bool](Get-Prop $a 'enabled' $true)
          difficulty=[string](Get-Prop $a 'difficulty' 'hard'); numQuestions=[int](Get-Prop $a 'numQuestions' 3)
          durationMin=[int](Get-Prop $a 'durationMin' 3); lockVolume=[bool](Get-Prop $a 'lockVolume' $true)
          narrator=[bool](Get-Prop $a 'narrator' $true); matrixRain=$true; theme='green'
          categories=[pscustomobject](Convert-Cats (Get-Prop $a 'categories' $null)) }
      }
      $script:cfg.alarms = $imported
      Save-Config
      return $true
    } catch { }
  }
  return $false
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
      Rain=[bool](Get-Prop $a 'matrixRain' (Get-Prop $d 'matrixRain' $true))
      Theme=[string](Get-Prop $a 'theme' (Get-Prop $d 'theme' 'green'))
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
  $pal = if ($script:pn_pal) { $script:pn_pal } else { Get-PanelPalette 'green' }
  $green=$pal.Accent; $dim=$pal.Dim; $rowBg=$pal.Row
  $y = 4
  foreach ($al in $script:pn_alarms) {
    $row = New-Object System.Windows.Forms.Panel; $row.Width=980; $row.Height=34; $row.Left=2; $row.Top=$y; $row.BackColor=$rowBg
    $cb = New-Object System.Windows.Forms.CheckBox; $cb.Checked=$al.Enabled; $cb.Left=8; $cb.Top=8; $cb.Width=18; $cb.Tag=$al.Id
    $cb.Add_CheckedChanged({ param($s,$e) $t = $script:pn_alarms | Where-Object { $_.Id -eq $s.Tag } | Select-Object -First 1; if ($t) { $t.Enabled = $s.Checked }; Panel-Persist; Panel-RefreshArmed; Panel-UpdateStatus })
    $lt = New-Object System.Windows.Forms.Label; $lt.Text=$al.Time; $lt.Left=32; $lt.Top=8; $lt.Width=60; $lt.ForeColor=$green; $lt.Font=$script:pn_rowFonts.T
    $ll = New-Object System.Windows.Forms.Label; $ll.Text=$al.Label; $ll.Left=100; $ll.Top=9; $ll.Width=170; $ll.ForeColor=$dim; $ll.Font=$script:pn_rowFonts.N
    $when = if ($al.Rhythm) { 'daily (rhythm)' } elseif ($al.Date) { $w = Resolve-When $al.Time $al.Date $false; if ($w) { $al.Date } else { "$($al.Date) (past)" } } else { 'next' }
    $ld = New-Object System.Windows.Forms.Label; $ld.Text=$when; $ld.Left=276; $ld.Top=9; $ld.Width=140; $ld.ForeColor=[System.Drawing.Color]::FromArgb(110,200,150); $ld.Font=$script:pn_rowFonts.N
    $ls = New-Object System.Windows.Forms.Label; $ls.Text=("{0} x{1} [{2}] ~{3}" -f $al.Diff,$al.NumQ,(Cats-Summary $al.Cats),$al.Theme); $ls.Left=420; $ls.Top=9; $ls.Width=372; $ls.ForeColor=[System.Drawing.Color]::FromArgb(90,180,130); $ls.Font=$script:pn_rowFonts.N
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
  $script:pn_eRain.Checked = $al.Rain
  $script:pn_eDate.Enabled = -not $al.Rhythm
  $script:pn_eDur.Text = [string]$al.DurationMin
  $script:pn_eDiff.SelectedItem = $al.Diff; if ($null -eq $script:pn_eDiff.SelectedItem) { $script:pn_eDiff.SelectedItem = 'hard' }
  $script:pn_eNumQ.SelectedItem = $al.NumQ; if ($null -eq $script:pn_eNumQ.SelectedItem) { $script:pn_eNumQ.SelectedItem = 3 }
  $script:pn_eTheme.SelectedItem = $al.Theme; if ($null -eq $script:pn_eTheme.SelectedItem) { $script:pn_eTheme.SelectedItem = 'green' }
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
  $dateOut = if ($rhythm) { "" } else { $d }
  if (-not $rhythm -and $dateOut -eq "") { $w = Resolve-When $t "" $false; if ($w) { $dateOut = $w.ToString('yyyy-MM-dd') } }
  [pscustomobject]@{ Id=$id; Label=$lab; Time=$t; Date=$dateOut; Rhythm=$rhythm; Enabled=$true
    Diff=[string]$script:pn_eDiff.SelectedItem; NumQ=[int]$script:pn_eNumQ.SelectedItem; DurationMin=$dur
    LockVol=[bool]$script:pn_eLockVol.Checked; Narrator=[bool]$script:pn_eNarr.Checked
    Rain=[bool]$script:pn_eRain.Checked; Theme=[string]$script:pn_eTheme.SelectedItem; Cats=$cats }
}
function Panel-SaveAlarm {
  $a = Panel-CollectEditor; if (-not $a) { return }
  if ($script:pn_editId) { $script:pn_alarms = @($script:pn_alarms | ForEach-Object { if ($_.Id -eq $script:pn_editId) { $a } else { $_ } }) }
  else { $script:pn_alarms += $a }
  Panel-Persist
  Panel-LoadEditor $null; Panel-RenderRows; Panel-RefreshArmed; Panel-UpdateStatus
  $whenTxt = if ($a.Rhythm) { 'every day' } else { $a.Date }
  Panel-Log "saved + armed: $($a.Time) $($a.Label) ($whenTxt, theme $($a.Theme))"
}
function Panel-SaveConfig {
  $alist = @()
  foreach ($al in $script:pn_alarms) { $alist += [ordered]@{ id=$al.Id; label=$al.Label; time=$al.Time; date=$al.Date; rhythm=$al.Rhythm; enabled=$al.Enabled; difficulty=$al.Diff; numQuestions=$al.NumQ; durationMin=$al.DurationMin; lockVolume=$al.LockVol; narrator=$al.Narrator; matrixRain=$al.Rain; theme=$al.Theme; categories=$al.Cats } }
  $obj = [ordered]@{ version=5; defaults=$script:cfg.defaults; alarms=$alist }
  try { if (Test-Path $script:cfgPath) { Copy-Item $script:cfgPath "$($script:cfgPath).bak" -Force } } catch {}
  ($obj | ConvertTo-Json -Depth 8) | Out-File -FilePath $script:cfgPath -Encoding utf8
  Load-Config
}
# Persist = save config INSTANTLY (fast), then DEBOUNCE the slow scheduled-task (re)arming.
# Registering Windows tasks takes ~1-2s and runs on the UI thread; doing it on every click was
# the "lag after every action + rain freezes" the user saw. Now clicks feel instant and the
# arming collapses into one pass 1.2s after you stop interacting.
function Panel-ScheduleArm {
  if (-not $script:pn_armTimer) {
    $script:pn_armTimer = New-Object System.Windows.Forms.Timer
    $script:pn_armTimer.Interval = 1200
    $script:pn_armTimer.Add_Tick({
      $script:pn_armTimer.Stop()
      try { $script:pn_log.Text = "arming..." } catch {}
      try { Register-Alarms } catch { Panel-Log ("arm error: " + $_.Exception.Message) }
      Panel-RefreshArmed
      try { if ($script:pn_log.Text -eq "arming...") { $script:pn_log.Text = "armed." } } catch {}
    })
  }
  $script:pn_armTimer.Stop(); $script:pn_armTimer.Start()
  try { $script:pn_armed.Text = "ARMING..."; $script:pn_armed.ForeColor = $script:pn_pal.Dim } catch {}
}
function Panel-Persist { Panel-SaveConfig; Panel-ScheduleArm }
function Panel-RefreshArmed {
  $armed = Get-ArmedCount
  $on = if ($script:pn_pal) { $script:pn_pal.Accent } else { [System.Drawing.Color]::FromArgb(0,255,102) }
  if ($armed -gt 0) { $script:pn_armed.Text = "ARMED ($armed)"; $script:pn_armed.ForeColor = $on } else { $script:pn_armed.Text = "NOT ARMED"; $script:pn_armed.ForeColor = [System.Drawing.Color]::FromArgb(255,140,0) }
}
function Panel-UpdateStatus {
  $next = $null
  foreach ($al in $script:pn_alarms) { if (-not $al.Enabled) { continue }; $w = Resolve-When $al.Time $al.Date $al.Rhythm; if ($w -and ((-not $next) -or ($w -lt $next))) { $next = $w } }
  if ($next) { $script:pn_status.Text = ("next: {0}   in {1}" -f $next.ToString('ddd HH:mm'), (Format-Span ($next - (Get-Date)))) } else { $script:pn_status.Text = "no upcoming alarms" }
}
function Panel-Test {
  $a = Panel-CollectEditor; if (-not $a) { return }
  $tc = [ordered]@{ numQuestions=$a.NumQ; difficulty=$a.Diff; categories=$a.Cats; lockVolume=$a.LockVol; narrator=$a.Narrator; matrixRain=$a.Rain; theme=$a.Theme }
  ($tc | ConvertTo-Json -Compress) | Out-File -FilePath (Join-Path $script:root 'session.testcfg') -Encoding ascii
  Panel-Log "launching test ring (solve it or wait 45s)... theme: $($a.Theme)"
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
  if (-not (Test-RingActive)) { Set-TaskMgrDisabled $false }
  if (-not (Test-Path $script:cfgPath)) { if (Import-PriorConfig) { } }
  Panel-LoadAlarms
  # the panel wears the same theme as the quiz (defaults.theme); rain on by default, themed
  $script:pn_theme = [string](Get-Prop $script:cfg.defaults 'theme' 'green')
  if ($script:pn_theme -eq 'roulette') { $script:pn_theme = 'green' }   # panel uses a stable skin
  $script:pn_pal = Get-PanelPalette $script:pn_theme
  $script:pn_mr = $true
  try { if ($script:cfg.defaults.PSObject.Properties.Name -contains 'panelRain') { $script:pn_mr = [bool]$script:cfg.defaults.panelRain } } catch {}
  $green=$script:pn_pal.Accent; $dim=$script:pn_pal.Dim; $boxBg=$script:pn_pal.Field
  $fL=New-Object System.Drawing.Font('Consolas',10); $fLb=New-Object System.Drawing.Font('Consolas',10,[System.Drawing.FontStyle]::Bold)

  $script:pn_form = New-Object System.Windows.Forms.Form
  $script:pn_form.Text = "OVERRIDE // CONTROL v5"; $script:pn_form.FormBorderStyle = 'Sizable'; $script:pn_form.MaximizeBox = $true
  $script:pn_form.StartPosition = 'CenterScreen'; $script:pn_form.MinimumSize = New-Object System.Drawing.Size(1040,860)
  $script:pn_form.WindowState = 'Maximized'; $script:pn_form.BackColor = [System.Drawing.Color]::Black
  $ico = Join-Path $script:eng 'override.ico'; if (Test-Path $ico) { try { $script:pn_form.Icon = New-Object System.Drawing.Icon $ico } catch {} }

  $script:pn_rain = New-RainBackground -Fps 6 -FontSize 20 -Color $script:pn_pal.Rain   # 6fps/larger glyphs = lighter on a busy machine
  $script:pn_form.Controls.Add($script:pn_rain.Panel)

  $script:pn_box = New-Object System.Windows.Forms.Panel; $script:pn_box.Width=1000; $script:pn_box.Height=820; $script:pn_box.BackColor=$script:pn_pal.Box
  # themed paint: faint CRT scanlines + a layered neon glow border (3 fading passes) in the accent
  $script:pn_box.Add_Paint({ param($s,$e)
    $r=$s.ClientRectangle; $g=$e.Graphics
    $sc=New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(26,$script:pn_pal.Scan.R,$script:pn_pal.Scan.G,$script:pn_pal.Scan.B))
    for ($y=0;$y -lt $r.Height;$y+=3) { $g.DrawLine($sc,0,$y,$r.Width,$y) }; $sc.Dispose()
    $a=$script:pn_pal.Accent; $gl=$script:pn_pal.Glow
    # outward glow: wide faint -> tighter brighter (simulated bloom)
    foreach ($p in @(@(10,26),@(7,40),@(4,70))) {
      $pen=New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb($p[1],$gl.R,$gl.G,$gl.B)),$p[0]
      $g.DrawRectangle($pen, [int]($p[0]/2)+1, [int]($p[0]/2)+1, $r.Width-$p[0]-2, $r.Height-$p[0]-2); $pen.Dispose()
    }
    $pen=New-Object System.Drawing.Pen $a,2; $g.DrawRectangle($pen,1,1,$r.Width-3,$r.Height-3); $pen.Dispose()
  })
  $script:pn_form.Controls.Add($script:pn_box); $script:pn_rain.Panel.SendToBack()

  $hdr = New-Object System.Windows.Forms.Label; $hdr.Text=("OVERRIDE // CONTROL   "+[char]0x03A9); $hdr.Left=18; $hdr.Top=12; $hdr.Width=680; $hdr.Height=42; $hdr.ForeColor=$script:pn_pal.Accent; $hdr.BackColor=[System.Drawing.Color]::Transparent; $hdr.Font=New-Object System.Drawing.Font('Consolas',24,[System.Drawing.FontStyle]::Bold); $script:pn_box.Controls.Add($hdr)
  $sub = New-Object System.Windows.Forms.Label; $sub.Text="WAKE PROTOCOL // v4"; $sub.Left=20; $sub.Top=52; $sub.Width=300; $sub.Height=18; $sub.ForeColor=$script:pn_pal.Dim; $sub.BackColor=[System.Drawing.Color]::Transparent; $sub.Font=New-Object System.Drawing.Font('Consolas',9); $script:pn_box.Controls.Add($sub)
  # APP THEME — skins THIS control panel (separate from each alarm's own ALARM THEME). Live re-skin.
  $appLbl = New-Object System.Windows.Forms.Label; $appLbl.Text="APP THEME"; $appLbl.Left=600; $appLbl.Top=52; $appLbl.Width=120; $appLbl.Height=20; $appLbl.TextAlign='MiddleRight'; $appLbl.ForeColor=$script:pn_pal.Accent2; $appLbl.BackColor=[System.Drawing.Color]::Transparent; $appLbl.Font=New-Object System.Drawing.Font('Consolas',10,[System.Drawing.FontStyle]::Bold); $script:pn_box.Controls.Add($appLbl)
  $script:pn_appTheme = New-Object System.Windows.Forms.ComboBox; $script:pn_appTheme.Left=728; $script:pn_appTheme.Top=49; $script:pn_appTheme.Width=130; $script:pn_appTheme.DropDownStyle='DropDownList'; $script:pn_appTheme.Items.AddRange(@('green','red','cyber','crt')); $script:pn_appTheme.BackColor=$script:pn_pal.Field; $script:pn_appTheme.ForeColor=$script:pn_pal.Accent; $script:pn_appTheme.Font=$fLb
  $script:pn_appTheme.SelectedItem = $script:pn_theme
  $script:pn_appTheme.Add_SelectedIndexChanged({
    $sel = [string]$script:pn_appTheme.SelectedItem
    if ($sel -and $sel -ne $script:pn_theme) {
      if ($script:cfg.defaults.PSObject.Properties.Name -contains 'theme') { $script:cfg.defaults.theme = $sel } else { $script:cfg.defaults | Add-Member -NotePropertyName theme -NotePropertyValue $sel -Force }
      Panel-SaveConfig
      $script:pn_restart = $true; $script:pn_form.Close()
    }
  })
  $script:pn_box.Controls.Add($script:pn_appTheme)
  $script:pn_armed = New-Object System.Windows.Forms.Label; $script:pn_armed.Left=760; $script:pn_armed.Top=22; $script:pn_armed.Width=220; $script:pn_armed.Height=26; $script:pn_armed.TextAlign='MiddleRight'; $script:pn_armed.BackColor=[System.Drawing.Color]::Transparent; $script:pn_armed.Font=New-Object System.Drawing.Font('Consolas',13,[System.Drawing.FontStyle]::Bold); $script:pn_box.Controls.Add($script:pn_armed)

  $lh = New-Object System.Windows.Forms.Label; $lh.Text="ALARMS"; $lh.Left=20; $lh.Top=60; $lh.Width=200; $lh.ForeColor=$dim; $lh.BackColor=[System.Drawing.Color]::Transparent; $lh.Font=$fLb; $script:pn_box.Controls.Add($lh)
  $script:pn_list = New-Object System.Windows.Forms.Panel; $script:pn_list.Left=12; $script:pn_list.Top=84; $script:pn_list.Width=976; $script:pn_list.Height=190; $script:pn_list.AutoScroll=$true; $script:pn_list.BackColor=[System.Drawing.Color]::FromArgb(0,8,3); $script:pn_box.Controls.Add($script:pn_list)

  $eh = New-Object System.Windows.Forms.Label; $eh.Text="EDIT / ADD ALARM"; $eh.Left=20; $eh.Top=286; $eh.Width=300; $eh.ForeColor=$dim; $eh.BackColor=[System.Drawing.Color]::Transparent; $eh.Font=$fLb; $script:pn_box.Controls.Add($eh)

  function NewTb($x,$y,$w) { $t=New-Object System.Windows.Forms.TextBox; $t.Left=$x; $t.Top=$y; $t.Width=$w; $t.BackColor=$boxBg; $t.ForeColor=$dim; $t.BorderStyle='FixedSingle'; $t.Font=New-Object System.Drawing.Font('Consolas',12); $script:pn_box.Controls.Add($t); $t }
  function NewLbl($txt,$x,$y,$w,$small) { $l=New-Object System.Windows.Forms.Label; $l.Text=$txt; $l.Left=$x; $l.Top=$y; $l.Width=$w; $l.ForeColor=$(if($small) { [System.Drawing.Color]::FromArgb(80,150,110) } else { $dim }); $l.BackColor=[System.Drawing.Color]::Transparent; $l.Font=$(if($small) { New-Object System.Drawing.Font('Consolas',8) } else { $fL }); $script:pn_box.Controls.Add($l); $l }

  $r1 = 318
  $script:pn_eTime = NewTb 24 $r1 80;   (NewLbl "HH:MM" 24 ($r1+26) 80 $true) | Out-Null
  $script:pn_eLabel = NewTb 120 $r1 240; (NewLbl "label" 120 ($r1+26) 100 $true) | Out-Null
  $script:pn_eDate = NewTb 372 $r1 140;  (NewLbl "YYYY-MM-DD (blank=next)" 372 ($r1+26) 220 $true) | Out-Null
  $script:pn_eRhythm = New-Object System.Windows.Forms.CheckBox; $script:pn_eRhythm.Text="Rhythm (every day)"; $script:pn_eRhythm.Left=560; $script:pn_eRhythm.Top=($r1+2); $script:pn_eRhythm.Width=220; $script:pn_eRhythm.ForeColor=$green; $script:pn_eRhythm.BackColor=[System.Drawing.Color]::Transparent; $script:pn_eRhythm.Font=$fL; $script:pn_box.Controls.Add($script:pn_eRhythm)
  $script:pn_eRhythm.Add_CheckedChanged({ $script:pn_eDate.Enabled = -not $script:pn_eRhythm.Checked; if ($script:pn_eRhythm.Checked) { $script:pn_eDate.Text = '' } })

  $r2 = 372
  (NewLbl "difficulty" 24 ($r2+4) 76 $false) | Out-Null
  $script:pn_eDiff = New-Object System.Windows.Forms.ComboBox; $script:pn_eDiff.Left=104; $script:pn_eDiff.Top=$r2; $script:pn_eDiff.Width=100; $script:pn_eDiff.DropDownStyle='DropDownList'; $script:pn_eDiff.Items.AddRange(@('easy','medium','hard')); $script:pn_box.Controls.Add($script:pn_eDiff)
  (NewLbl "questions" 220 ($r2+4) 80 $false) | Out-Null
  $script:pn_eNumQ = New-Object System.Windows.Forms.ComboBox; $script:pn_eNumQ.Left=302; $script:pn_eNumQ.Top=$r2; $script:pn_eNumQ.Width=56; $script:pn_eNumQ.DropDownStyle='DropDownList'; $script:pn_eNumQ.Items.AddRange(@(1,2,3,4,5,6)); $script:pn_box.Controls.Add($script:pn_eNumQ)
  (NewLbl "duration" 374 ($r2+4) 68 $false) | Out-Null
  $script:pn_eDur = NewTb 444 $r2 46; (NewLbl "min" 494 ($r2+4) 36 $false) | Out-Null
  $script:pn_eLockVol = New-Object System.Windows.Forms.CheckBox; $script:pn_eLockVol.Text="lock volume"; $script:pn_eLockVol.Left=544; $script:pn_eLockVol.Top=($r2+2); $script:pn_eLockVol.Width=130; $script:pn_eLockVol.ForeColor=$dim; $script:pn_eLockVol.BackColor=[System.Drawing.Color]::Transparent; $script:pn_eLockVol.Font=$fL; $script:pn_box.Controls.Add($script:pn_eLockVol)
  $script:pn_eNarr = New-Object System.Windows.Forms.CheckBox; $script:pn_eNarr.Text="narrator"; $script:pn_eNarr.Left=680; $script:pn_eNarr.Top=($r2+2); $script:pn_eNarr.Width=104; $script:pn_eNarr.ForeColor=$dim; $script:pn_eNarr.BackColor=[System.Drawing.Color]::Transparent; $script:pn_eNarr.Font=$fL; $script:pn_box.Controls.Add($script:pn_eNarr)
  $script:pn_eRain = New-Object System.Windows.Forms.CheckBox; $script:pn_eRain.Text="matrix rain"; $script:pn_eRain.Left=790; $script:pn_eRain.Top=($r2+2); $script:pn_eRain.Width=130; $script:pn_eRain.ForeColor=$dim; $script:pn_eRain.BackColor=[System.Drawing.Color]::Transparent; $script:pn_eRain.Font=$fL; $script:pn_box.Controls.Add($script:pn_eRain)

  $r2b = 416
  (NewLbl "ALARM THEME" 24 ($r2b+4) 110 $false) | Out-Null
  $script:pn_eTheme = New-Object System.Windows.Forms.ComboBox; $script:pn_eTheme.Left=140; $script:pn_eTheme.Top=$r2b; $script:pn_eTheme.Width=140; $script:pn_eTheme.DropDownStyle='DropDownList'; $script:pn_eTheme.Items.AddRange($script:THEMES); $script:pn_box.Controls.Add($script:pn_eTheme)
  (NewLbl "look of THIS alarm's ring  ( green=phosphor  red=alert  cyber=neon  crt=CRT  roulette=random each ring )" 294 ($r2b+5) 700 $true) | Out-Null

  $r3 = 460
  (NewLbl "subjects" 24 ($r3+2) 80 $false) | Out-Null
  $script:pn_eCats = @{}
  $colW = 215; $col = 0; $rowI = 0
  foreach ($c in $script:CATS) {
    $chk = New-Object System.Windows.Forms.CheckBox; $chk.Text=$c; $chk.Left=(104 + $col*$colW); $chk.Top=($r3 + $rowI*28); $chk.Width=200
    $chk.ForeColor=$green; $chk.BackColor=[System.Drawing.Color]::Transparent; $chk.Font=$fL
    $script:pn_box.Controls.Add($chk); $script:pn_eCats[$c]=$chk
    $col++; if ($col -ge 4) { $col = 0; $rowI++ }
  }

  $r4 = 560
  $script:pn_saveBtn = New-Object System.Windows.Forms.Button; $script:pn_saveBtn.Text='DEPLOY ALARM'; $script:pn_saveBtn.Left=24; $script:pn_saveBtn.Top=$r4; $script:pn_saveBtn.Width=200; $script:pn_saveBtn.Height=36; $script:pn_saveBtn.FlatStyle='Flat'; $script:pn_saveBtn.ForeColor=$green; $script:pn_saveBtn.BackColor=[System.Drawing.Color]::FromArgb(0,33,15); $script:pn_saveBtn.Font=$fLb; $script:pn_saveBtn.Add_Click({ Panel-SaveAlarm }); $script:pn_box.Controls.Add($script:pn_saveBtn)
  $newBtn = New-Object System.Windows.Forms.Button; $newBtn.Text='NEW / CLEAR'; $newBtn.Left=234; $newBtn.Top=$r4; $newBtn.Width=140; $newBtn.Height=36; $newBtn.FlatStyle='Flat'; $newBtn.ForeColor=$dim; $newBtn.BackColor=[System.Drawing.Color]::FromArgb(0,24,11); $newBtn.Font=$fL; $newBtn.Add_Click({ Panel-LoadEditor $null; Panel-Log "editor cleared" }); $script:pn_box.Controls.Add($newBtn)

  $r5 = 622
  $testBtn = New-Object System.Windows.Forms.Button; $testBtn.Text="TEST RING"; $testBtn.Left=24; $testBtn.Top=$r5; $testBtn.Width=180; $testBtn.Height=46; $script:pn_box.Controls.Add($testBtn)
  $armBtn  = New-Object System.Windows.Forms.Button; $armBtn.Text=">> RE-DEPLOY ALL"; $armBtn.Left=214; $armBtn.Top=$r5; $armBtn.Width=200; $armBtn.Height=46; $script:pn_box.Controls.Add($armBtn)
  $disBtn  = New-Object System.Windows.Forms.Button; $disBtn.Text="DISARM ALL"; $disBtn.Left=424; $disBtn.Top=$r5; $disBtn.Width=170; $disBtn.Height=46; $script:pn_box.Controls.Add($disBtn)
  foreach ($b in @($testBtn,$armBtn,$disBtn)) { $b.FlatStyle='Flat'; $b.ForeColor=$green; $b.BackColor=[System.Drawing.Color]::FromArgb(0,33,15); $b.Font=New-Object System.Drawing.Font('Consolas',13,[System.Drawing.FontStyle]::Bold) }
  $testBtn.Add_Click({ Panel-Test })
  $armBtn.Add_Click({ Panel-Deploy })
  $disBtn.Add_Click({ foreach ($al in $script:pn_alarms) { $al.Enabled = $false }; Panel-SaveConfig; Remove-Alarms; Panel-RenderRows; Panel-RefreshArmed; Panel-UpdateStatus; Panel-Log "all alarms disarmed + disabled" })

  $script:pn_status = New-Object System.Windows.Forms.Label; $script:pn_status.Left=24; $script:pn_status.Top=686; $script:pn_status.Width=640; $script:pn_status.Height=24; $script:pn_status.ForeColor=[System.Drawing.Color]::FromArgb(120,220,160); $script:pn_status.BackColor=[System.Drawing.Color]::Transparent; $script:pn_status.Font=New-Object System.Drawing.Font('Consolas',12); $script:pn_box.Controls.Add($script:pn_status)
  $script:pn_log = New-Object System.Windows.Forms.Label; $script:pn_log.Left=24; $script:pn_log.Top=714; $script:pn_log.Width=956; $script:pn_log.Height=22; $script:pn_log.ForeColor=[System.Drawing.Color]::FromArgb(90,170,120); $script:pn_log.BackColor=[System.Drawing.Color]::Transparent; $script:pn_log.Font=$fL; $script:pn_box.Controls.Add($script:pn_log)
  $hint = New-Object System.Windows.Forms.Label; $hint.Text="Edge kiosk renderer + mshta fallback  |  4 themes + roulette  |  12 subjects per alarm  |  0% CPU between alarms"; $hint.Left=24; $hint.Top=740; $hint.Width=956; $hint.Height=20; $hint.ForeColor=[System.Drawing.Color]::FromArgb(70,130,95); $hint.BackColor=[System.Drawing.Color]::Transparent; $hint.Font=New-Object System.Drawing.Font('Consolas',9); $script:pn_box.Controls.Add($hint)

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
    # if a debounced arm was still pending when the window closed, flush it now (synchronously)
    try { if ($script:pn_armTimer -and $script:pn_armTimer.Enabled) { $script:pn_armTimer.Stop(); Register-Alarms } } catch {}
    try { if ($script:pn_armTimer) { $script:pn_armTimer.Dispose(); $script:pn_armTimer = $null } } catch {}
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
if ($Disarm) { Write-Host "OVERRIDE v4 // disarming..." -ForegroundColor Yellow; Remove-Alarms; return }
if ($Arm)    { Write-Host "OVERRIDE v4 // arming..." -ForegroundColor Green; Register-Alarms; return }
if ($DryRun) { Write-Host ("OVERRIDE v4 schedule  ({0})" -f (Get-Date)) -ForegroundColor Green; Show-Tasks; return }

if ($Ring) {
  # same mutex as v2/v3 ON PURPOSE: during migration multiple task sets may exist for one
  # night — the mutex guarantees only ONE ring ever runs.
  $mtx = New-Object System.Threading.Mutex($false, "Local\OVERRIDE_V2_ring_lock")
  $got = $true; try { $got = $mtx.WaitOne(0) } catch { $got = $true }
  if (-not $got) { return }
  try {
    if ($TestNow) { $S = Get-TestSettings } else { $S = Get-AlarmSettings $AlarmId }
    if ($S) { Run-Ring $S }
  } finally { Invoke-Unlock; try { $mtx.ReleaseMutex() } catch {} }
  return
}

$script:pn_testSec = $PanelTestSec
$script:pn_autoDeploy = $AutoDeploy
# restart loop: changing the APP THEME sets pn_restart + closes the form -> rebuild with the new skin
do { $script:pn_restart = $false; Show-PanelGui; $script:pn_testSec = 0; $script:pn_autoDeploy = $false } while ($script:pn_restart)
