param(
    [string]$FramesDirectory = (Join-Path $PSScriptRoot '..\Win64\Shore\Frames')
)

# 本番AUF2が出した透過PNGを、固定の砂浜または透過確認用の市松へ重ねる。
# 砂浜は検査用の手続き的な模様。プラグインやユーザーのAUP2には保存しない。
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationCore,WindowsBase,System.Drawing
$sampleDir = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\Sample'))
$frames = @(Get-ChildItem -LiteralPath $FramesDirectory -Filter 'shore_*.png' -File | Sort-Object Name)
if ($frames.Count -ne 72) { throw 'Expected 72 production AUF2 frames.' }

Add-Type -ReferencedAssemblies System.Drawing -TypeDefinition @'
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
public static class ShorePreviewTexture {
    public static Bitmap Sand(int w, int h) {
        Bitmap image = new Bitmap(w,h,PixelFormat.Format32bppArgb);
        byte[] pixels = new byte[w*h*4];
        Random random = new Random(2761);
        for(int y=0;y<h;y++) for(int x=0;x<w;x++) {
            double broad = Math.Sin(x*0.008+y*0.014)*2 + Math.Sin(x*0.024-y*0.011)*1.5;
            double grain = (random.NextDouble()-0.5)*16;
            if(random.NextDouble()<0.012) grain -= 26;
            int i=(y*w+x)*4;
            pixels[i]=(byte)Math.Max(0,Math.Min(255,157+broad+grain));
            pixels[i+1]=(byte)Math.Max(0,Math.Min(255,194+broad+grain));
            pixels[i+2]=(byte)Math.Max(0,Math.Min(255,217+broad+grain));
            pixels[i+3]=255;
        }
        BitmapData data=image.LockBits(new Rectangle(0,0,w,h),ImageLockMode.WriteOnly,PixelFormat.Format32bppArgb);
        Marshal.Copy(pixels,0,data.Scan0,pixels.Length);image.UnlockBits(data);
        return image;
    }
}
'@

function New-Checker([int]$Width,[int]$Height) {
    $image = [Drawing.Bitmap]::new($Width,$Height)
    $graphics = [Drawing.Graphics]::FromImage($image)
    $light = [Drawing.SolidBrush]::new([Drawing.Color]::FromArgb(225,228,230))
    $dark = [Drawing.SolidBrush]::new([Drawing.Color]::FromArgb(183,189,193))
    try {
        for($y=0;$y -lt $Height;$y+=24) {
            for($x=0;$x -lt $Width;$x+=24) {
                $brush = $light
                if (([int]($x/24)+[int]($y/24)) % 2) { $brush=$dark }
                $graphics.FillRectangle($brush,$x,$y,24,24)
            }
        }
    } finally { $graphics.Dispose();$light.Dispose();$dark.Dispose() }
    return $image
}

function Get-Composite([Drawing.Bitmap]$Background,[string]$OverlayPath) {
    $result = [Drawing.Bitmap]$Background.Clone()
    $overlay = [Drawing.Bitmap]::FromFile($OverlayPath)
    $graphics = [Drawing.Graphics]::FromImage($result)
    try { $graphics.DrawImageUnscaled($overlay,0,0) }
    finally { $graphics.Dispose();$overlay.Dispose() }
    return $result
}

function Add-GifFrame($Encoder,[Drawing.Bitmap]$Image) {
    $stream = [IO.MemoryStream]::new()
    try {
        $Image.Save($stream,[Drawing.Imaging.ImageFormat]::Png);$stream.Position=0
        $source = [Windows.Media.Imaging.BitmapImage]::new()
        $source.BeginInit();$source.CacheOption=[Windows.Media.Imaging.BitmapCacheOption]::OnLoad
        $source.StreamSource=$stream;$source.EndInit();$source.Freeze()
        $Encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($source))
    } finally { $stream.Dispose() }
}

function Save-Gif($Encoder,[string]$Path) {
    $stream=[IO.MemoryStream]::new()
    try { $Encoder.Save($stream);$original=$stream.ToArray() } finally { $stream.Dispose() }
    # この環境のWPFで落ちるフレーム時間をGIF制御ブロックへ補う。
    $header=13
    if($original[10] -band 128){$header+=3*[int][math]::Pow(2,($original[10] -band 7)+1)}
    $loop=[byte[]](33,255,11)+[Text.Encoding]::ASCII.GetBytes('NETSCAPE2.0')+[byte[]](3,1,0,0,0)
    $bytes=[byte[]]::new($original.Length+$loop.Length)
    [Array]::Copy($original,0,$bytes,0,$header)
    [Array]::Copy($loop,0,$bytes,$header,$loop.Length)
    [Array]::Copy($original,$header,$bytes,$header+$loop.Length,$original.Length-$header)
    $offset=$header;$count=0;$timings=0
    while($offset -lt $bytes.Length) {
        $kind=$bytes[$offset];$offset++
        if($kind -eq 59){break}
        if($kind -eq 33) {
            $label=$bytes[$offset];$offset++
            if($label -eq 249 -and $bytes[$offset] -eq 4) {
                $bytes[$offset+1]=($bytes[$offset+1] -band 227) -bor 4
                $delay=[int]([math]::Round(($timings+1)*100/12)-[math]::Round($timings*100/12))
                $bytes[$offset+2]=[byte]$delay;$bytes[$offset+3]=0;$timings++
            }
        } elseif($kind -eq 44) {
            $count++;$packed=$bytes[$offset+8];$offset+=9
            if($packed -band 128){$offset+=3*[int][math]::Pow(2,($packed -band 7)+1)}
            $offset++
        } else { throw 'Invalid GIF structure.' }
        do{$size=[int]$bytes[$offset];$offset++;$offset+=$size}while($size -gt 0 -and $offset -lt $bytes.Length)
    }
    if(($count -ne 72) -or ($timings -ne 72)){throw "GIF frame/timing count differs: $count/$timings"}
    [IO.File]::WriteAllBytes($Path,$bytes)
    $test=[Drawing.Image]::FromFile($Path)
    try { if($test.GetFrameCount([Drawing.Imaging.FrameDimension]::Time) -ne 72){throw 'GIF frame count differs.'} }
    finally { $test.Dispose() }
    Write-Output $Path
}

$sand=[ShorePreviewTexture]::Sand(768,432)
$checker=New-Checker 768 432
$sandEncoder=[Windows.Media.Imaging.GifBitmapEncoder]::new()
$alphaEncoder=[Windows.Media.Imaging.GifBitmapEncoder]::new()
$strip=[Drawing.Bitmap]::new(1536,916)
$stripGraphics=[Drawing.Graphics]::FromImage($strip)
$font=[Drawing.Font]::new('Segoe UI',14,[Drawing.FontStyle]::Regular,[Drawing.GraphicsUnit]::Pixel)
$selected=@(0,18,30,48)
try {
    $sand.Save((Join-Path $sampleDir 'shore_sand.png'),[Drawing.Imaging.ImageFormat]::Png)
    $stripGraphics.Clear([Drawing.Color]::FromArgb(26,30,34))
    for($i=0;$i -lt $frames.Count;$i++) {
        $a=Get-Composite $sand $frames[$i].FullName
        $b=Get-Composite $checker $frames[$i].FullName
        try {
            Add-GifFrame $sandEncoder $a
            Add-GifFrame $alphaEncoder $b
            if($selected -contains $i) {
                $slot=[Array]::IndexOf($selected,$i);$x=($slot % 2)*768;$y=[int][math]::Floor($slot/2)*458
                $stripGraphics.DrawString(('t = {0:0.00} s' -f ($i/12)),$font,[Drawing.Brushes]::White,$x+12,$y+1)
                $stripGraphics.DrawImageUnscaled($a,$x,$y+26)
            }
            if($i -eq 30) {$a.Save((Join-Path $sampleDir 'shore_preview.png'),[Drawing.Imaging.ImageFormat]::Png)}
        } finally { $a.Dispose();$b.Dispose() }
    }
    $strip.Save((Join-Path $sampleDir 'shore_phases.png'),[Drawing.Imaging.ImageFormat]::Png)
    Save-Gif $sandEncoder (Join-Path $sampleDir 'shore_sand_preview.gif')
    Save-Gif $alphaEncoder (Join-Path $sampleDir 'shore_alpha_preview.gif')
} finally { $sand.Dispose();$checker.Dispose();$stripGraphics.Dispose();$strip.Dispose();$font.Dispose() }
