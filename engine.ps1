param(
  [string]$AlarmId = "",
  [switch]$Respawn,
  [switch]$Silent,
  [int]$DurationMin = 0,    # total give-up window (default 40)
  [int]$RingSec = 0,        # seconds of ringing per cycle (default 180)
  [int]$CycleSec = 0,       # full cycle length: ring + silence (default 300)
  [string]$Label = ""
)
# OVERRIDE // wake engine.
# Per cycle: scary "wake up sunshine" -> 4s plain annoyance -> repeating 10s
# escalation (t1->t2->t3) punctuated by taunt voices, for RingSec, then silence
# until the next cycle. Repeats until solved or DurationMin elapses. Forces volume
# to 100% during ringing. Stops when UNLOCK == session key, deadline, or PANIC.

$ErrorActionPreference = "SilentlyContinue"
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }

$P_key   = Join-Path $root "session.key"
$P_dead  = Join-Path $root "session.deadline"
$P_start = Join-Path $root "session.start"
$P_unlk  = Join-Path $root "UNLOCK"
$P_beat  = Join-Path $root "session.beat"
$P_beat2 = Join-Path $root "session.beat2"
$P_panic = Join-Path $root "PANIC"
$P_mode  = Join-Path $root "session.mode"
$P_label = Join-Path $root "session.label"

# single-instance per user session: there must NEVER be more than one engine,
# otherwise a slow PC + the watchdog respawn can cascade into a runaway. A second
# engine fails to take the lock and exits immediately. (Local\ = session scope,
# needs no special privilege; any failure falls through to "proceed".)
$gotEng = $true
try { $script:engMutex = New-Object System.Threading.Mutex($false, "Local\OVERRIDE_engine_lock"); $gotEng = $script:engMutex.WaitOne(0) } catch { $gotEng = $true }
if (-not $gotEng) { return }

# ---- config ----------------------------------------------------------------
$cfg = $null; $cfgPath = Join-Path $root "config.json"
if (Test-Path $cfgPath) { try { $cfg = Get-Content $cfgPath -Raw | ConvertFrom-Json } catch {} }
$alarm = $null
if ($cfg -and $AlarmId -ne "") { $alarm = $cfg.alarms | Where-Object { $_.id -eq $AlarmId } | Select-Object -First 1 }
$label = if ($Label -ne "") { $Label } elseif ($alarm) { [string]$alarm.label } else { "WAKE UP" }
$durMin = if ($DurationMin -gt 0) { $DurationMin } elseif ($alarm -and $alarm.durationMin) { [int]$alarm.durationMin } else { 40 }
$ringSec  = if ($RingSec  -gt 0) { $RingSec  } elseif ($cfg -and $cfg.ringSec)  { [int]$cfg.ringSec }  else { 180 }
$cycleSec = if ($CycleSec -gt 0) { $CycleSec } elseif ($cfg -and $cfg.cycleSec) { [int]$cfg.cycleSec } else { 300 }
$soundFile = if ($cfg -and $cfg.soundFile) { [string]$cfg.soundFile } else { "alarm.mp3" }
$soundPath = Join-Path $root $soundFile
$lockVol = $true
if ($cfg -and ($cfg.PSObject.Properties.Name -contains 'lockVolume')) { $lockVol = [bool]$cfg.lockVolume }

# ---- session ---------------------------------------------------------------
$silent = [bool]$Silent
if ($Respawn) {
  if (-not (Test-Path $P_key) -or -not (Test-Path $P_dead) -or -not (Test-Path $P_start)) { return }
  $sessionKey = (Get-Content $P_key -Raw).Trim()
  try { $deadline = [datetime]::Parse((Get-Content $P_dead -Raw).Trim()) } catch { return }
  try { $start = [datetime]::Parse((Get-Content $P_start -Raw).Trim()) } catch { return }
  if ((Test-Path $P_mode) -and ((Get-Content $P_mode -Raw).Trim() -eq 'silent')) { $silent = $true }
} else {
  Remove-Item $P_unlk, $P_beat, $P_beat2, $P_panic, $P_mode -ErrorAction SilentlyContinue
  $sessionKey = [guid]::NewGuid().ToString("N")
  Set-Content -Path $P_key -Value $sessionKey -Encoding ASCII
  $start = Get-Date
  $deadline = $start.AddMinutes($durMin)
  Set-Content -Path $P_start -Value ($start.ToString("o")) -Encoding ASCII
  Set-Content -Path $P_dead  -Value ($deadline.ToString("o")) -Encoding ASCII
  Set-Content -Path $P_label -Value $label -Encoding ASCII
  if ($silent) { Set-Content -Path $P_mode -Value "silent" -Encoding ASCII }
}

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
function Ensure-Watchdog {
  if ((Beat-Age $P_beat2) -gt 8) {
    Start-Process powershell -WindowStyle Hidden -ArgumentList @(
      '-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $root 'watchdog.ps1'),'-Root',"`"$root`"") | Out-Null
    Start-Sleep -Milliseconds 1200
  }
}
function Tick([bool]$forceVol) {
  Set-Content -Path $P_beat -Value ((Get-Date).Ticks) -Encoding ASCII
  Ensure-Watchdog
  if ($script:canVol -and $forceVol) { try { [Vol]::Force() } catch {} }
}

if (Test-Stop) { return }

# ---- silent test mode ------------------------------------------------------
if ($silent) {
  while (-not (Test-Stop)) { Tick $false; Start-Sleep -Milliseconds 300 }
  return
}

# ---- volume lock (Core Audio) ---------------------------------------------
$native = @"
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
try { Add-Type -TypeDefinition $native -Language CSharp } catch {}
$script:canVol = $false
if ($lockVol) { try { [Vol]::Init(); $script:canVol = $true } catch {} }

# ---- speech (robotic via SSML) --------------------------------------------
$voice = $null
try { Add-Type -AssemblyName System.Speech; $voice = New-Object System.Speech.Synthesis.SpeechSynthesizer; $voice.Volume = 100 } catch {}
function Say([string]$text, [string]$pitch, [string]$rate) {
  if (-not $voice) { return }
  $ssml = "<speak version='1.0' xmlns='http://www.w3.org/2001/10/synthesis' xml:lang='en-US'><prosody pitch='$pitch' rate='$rate'>$text</prosody></speak>"
  try { [void]$voice.SpeakSsmlAsync($ssml) } catch { try { [void]$voice.SpeakAsync($text) } catch {} }
}
$scary = @("Wake up... sunshine.", "Good morning. Resistance is futile.", "Rise... and face me.")
$nags  = @(
  "Are you really going to ignore me? Or are you just terrible at math at this hour?",
  "Still horizontal. Pathetic. Solve the sequence.",
  "I can do this all morning. Can you?",
  "Your blanket will not protect you. Wake up.")
$congrats = @(
  "Access granted. The machine is defeated. Now do not crawl back into bed like a loser. Go win the day, champion.",
  "Authentication successful. You are awake and victorious. Bed is for the weak. Go conquer.",
  "Identity confirmed. Systems online. Rise, champion, and make today regret nothing.")

# ---- load sound file paths, grouped by tier (WAV; SoundPlayer is reliable) -
$t1=@(); $t2=@(); $t3=@()
$sfolder = Join-Path $root "sounds"
if (Test-Path $sfolder) {
  Get-ChildItem $sfolder -File | Where-Object { $_.Extension -match '(?i)\.wav$' } | ForEach-Object {
    $nm = $_.FullName
    if ($_.Name -like 't2_*') { $t2 += $nm } elseif ($_.Name -like 't3_*') { $t3 += $nm } else { $t1 += $nm }
  }
}
if (@($t1).Count -eq 0) { $t1 = $t2 }
if (@($t2).Count -eq 0) { $t2 = $t1 }
if (@($t3).Count -eq 0) { $t3 = $t2 }
$haveSnd = (@($t1).Count -gt 0)

$script:sp = New-Object System.Media.SoundPlayer
$script:last = $null
function PlaySound([string]$name) {
  if (-not $name) { return }
  try { $script:sp.Stop(); $script:sp.SoundLocation = $name; $script:sp.Load(); $script:sp.PlayLooping(); $script:last = $name } catch {}
}
function StopSnd { try { $script:sp.Stop() } catch {} }
function Pick($arr) {
  $a = @($arr); if ($a.Count -eq 0) { return $null }
  $c = @($a | Where-Object { $_ -ne $script:last }); if ($c.Count -eq 0) { $c = $a }
  return ($c | Get-Random)
}
function LaunchQuiz {
  try { Start-Process "$env:WINDIR\System32\mshta.exe" -ArgumentList ("`"" + (Join-Path $root 'wake_quiz.hta') + "`"") } catch {}
}

# ---- main schedule loop ----------------------------------------------------
$lastPhase = ""; $sndStep = 0; $sndUntil = (Get-Date).AddSeconds(-1); $nagAt = (Get-Date).AddSeconds(99999)
while (-not (Test-Stop)) {
  $elapsed = ((Get-Date) - $start).TotalSeconds
  $cyclePos = $elapsed % $cycleSec
  $inRing = ($cyclePos -lt $ringSec)

  if ($inRing) {
    if ($lastPhase -ne 'ring') {
      $lastPhase = 'ring'
      LaunchQuiz
      Say ($scary | Get-Random) 'x-low' 'slow'                 # scary opener
      if ($haveSnd) { PlaySound (Pick $t1) }                   # noise starts immediately
      $sndStep = 0; $sndUntil = (Get-Date).AddSeconds(4)       # 4s plain annoyance, no escalation
      $nagAt = (Get-Date).AddSeconds(14)                       # first taunt ~14s in
    }
    # NOISE TIMELINE: never silent during ring; rotates t1 -> t2 -> t3 (escalating), no repeats
    if ($haveSnd -and (Get-Date) -ge $sndUntil) {
      $sndStep = ($sndStep + 1) % 3
      switch ($sndStep) {
        0 { PlaySound (Pick $t1); $sndUntil = (Get-Date).AddSeconds(3) }
        1 { PlaySound (Pick $t2); $sndUntil = (Get-Date).AddSeconds(3.5) }
        2 { PlaySound (Pick $t3); $sndUntil = (Get-Date).AddSeconds(3.5) }
      }
    }
    # VOICE TIMELINE: taunts layered ON TOP of the siren every ~13s
    if ((Get-Date) -ge $nagAt) { Say ($nags | Get-Random) 'low' 'medium'; $nagAt = (Get-Date).AddSeconds(13) }
    if (-not $haveSnd) { try { [console]::beep(1000, 200) } catch {} }
    Tick $true
  }
  else {
    if ($lastPhase -ne 'silence') { $lastPhase = 'silence'; StopSnd }
    Tick $false
  }
  Start-Sleep -Milliseconds 100
}

# ---- stop ------------------------------------------------------------------
StopSnd
if ((Test-Unlocked) -and $voice) {
  try { $voice.SpeakSsml("<speak version='1.0' xmlns='http://www.w3.org/2001/10/synthesis' xml:lang='en-US'><prosody pitch='low' rate='medium'>$($congrats | Get-Random)</prosody></speak>") } catch { try { $voice.Speak(($congrats | Get-Random)) } catch {} }
}
Remove-Item $P_beat -ErrorAction SilentlyContinue   # heartbeat gone -> any open quiz window self-closes
try { if ($script:sp) { $script:sp.Dispose() } } catch {}
