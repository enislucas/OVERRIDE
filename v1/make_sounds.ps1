param([string]$Root = "")
# Generates 10 synthesized, royalty-free, maximally-irritating alarm clips into sounds/.
# Tiers by filename prefix: t1_ = annoying, t2_ = harsh, t3_ = rage.
if ($Root -eq "") { $Root = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path } }
$dir = Join-Path $Root "sounds"
New-Item -ItemType Directory -Force -Path $dir | Out-Null

$cs = @"
using System; using System.IO;
public static class SoundGen {
  const int SR = 22050;
  static void WriteWav(string path, double[] s){
    using(var fs=new FileStream(path,FileMode.Create)) using(var bw=new BinaryWriter(fs)){
      int n=s.Length; int data=n*2;
      bw.Write(new char[]{'R','I','F','F'}); bw.Write(36+data); bw.Write(new char[]{'W','A','V','E'});
      bw.Write(new char[]{'f','m','t',' '}); bw.Write(16); bw.Write((short)1); bw.Write((short)1);
      bw.Write(SR); bw.Write(SR*2); bw.Write((short)2); bw.Write((short)16);
      bw.Write(new char[]{'d','a','t','a'}); bw.Write(data);
      for(int i=0;i<n;i++){ double v=s[i]*1.8; if(v>1)v=1; if(v<-1)v=-1; bw.Write((short)(v*32000)); }
    }
  }
  static void Fade(double[] s){ int f=300; for(int i=0;i<f && i<s.Length;i++){ double k=(double)i/f; s[i]*=k; s[s.Length-1-i]*=k; } }
  static double sq(double x){ return Math.Sin(x)>=0?1.0:-1.0; }
  public static void Gen(string type, string path, double dur){
    int n=(int)(SR*dur); var s=new double[n]; var rnd=new Random(98765);
    for(int i=0;i<n;i++){
      double t=(double)i/SR; double v=0;
      switch(type){
        case "throb":   v=0.5*(Math.Sin(2*Math.PI*220*t)+Math.Sin(2*Math.PI*224.5*t)); break;
        case "warble":  { double f=((int)(t*4)%2==0)?600:850; v=0.5*sq(2*Math.PI*f*t); } break;
        case "klaxon":  { double g=((int)(t*2.5)%2==0)?1:0; v=0.55*sq(2*Math.PI*400*t)*g; } break;
        case "tritone": { double f=((int)(t*5)%2==0)?440:622; v=0.5*sq(2*Math.PI*f*t); } break;
        case "chirp":   { double p=t%1.0; double b=(p<0.10||(p>=0.16&&p<0.26)||(p>=0.32&&p<0.42))?1:0; v=0.6*Math.Sin(2*Math.PI*3200*t)*b; } break;
        case "airraid": { double f=300+600*(0.5+0.5*Math.Sin(2*Math.PI*0.15*t)); v=0.5*Math.Sin(2*Math.PI*f*t); } break;
        case "siren":   { double ph=t*0.7; double fr=ph-Math.Floor(ph); double f=500+1500*fr; v=0.45*sq(2*Math.PI*f*t); } break;
        case "mosquito":{ double f=4000+70*Math.Sin(2*Math.PI*6*t); v=0.4*Math.Sin(2*Math.PI*f*t); } break;
        case "accel":   { double rate=2+t*3.0; double p=(t*rate)%1.0; double b=(p<0.5)?1:0; v=0.5*sq(2*Math.PI*1300*t)*b; } break;
        case "glitch":  { v=(rnd.NextDouble()<0.4)?(rnd.NextDouble()*2-1)*0.7:0; } break;
      }
      s[i]=v;
    }
    Fade(s); WriteWav(path,s);
  }
}
"@
Add-Type -TypeDefinition $cs -Language CSharp

$map = @(
  @("t1_throb.wav","throb"), @("t1_warble.wav","warble"), @("t1_klaxon.wav","klaxon"),
  @("t2_tritone.wav","tritone"), @("t2_chirp.wav","chirp"), @("t2_airraid.wav","airraid"),
  @("t3_siren.wav","siren"), @("t3_mosquito.wav","mosquito"), @("t3_accel.wav","accel"), @("t3_glitch.wav","glitch")
)
foreach ($m in $map) { [SoundGen]::Gen($m[1], (Join-Path $dir $m[0]), 6.0); "made $($m[0])" }
"DONE -> $dir"
