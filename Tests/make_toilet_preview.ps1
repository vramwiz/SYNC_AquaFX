param([string]$FramesDirectory = (Join-Path $PSScriptRoot '..\Win64\Toilet\Frames'))

# 本番AUF2で2層を合成済みの96フレームを、確認用GIFと段階画像へまとめる。
# Windows PowerShell 5.1で実行し、AviUtl2の再生速度とは独立した12fpsプレビューを作る。
$ErrorActionPreference='Stop'
Add-Type -AssemblyName PresentationCore,WindowsBase,System.Drawing
$sampleDir=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\Sample'))
$files=@(Get-ChildItem -LiteralPath $FramesDirectory -Filter 'toilet_*.png' | Sort-Object Name)
if($files.Count -ne 96){throw 'Expected 96 toilet frames.'}
$encoder=[Windows.Media.Imaging.GifBitmapEncoder]::new()
$strip=[Drawing.Bitmap]::new(1536,1592)
$graphics=[Drawing.Graphics]::FromImage($strip)
$font=[Drawing.Font]::new('Segoe UI',18,[Drawing.FontStyle]::Regular,[Drawing.GraphicsUnit]::Pixel)
$selected=@(0,24,64,88)
try {
    $graphics.Clear([Drawing.Color]::FromArgb(26,30,34))
    for($i=0;$i -lt $files.Count;$i++) {
        $image=[Drawing.Bitmap]::FromFile($files[$i].FullName)
        try {
            if($selected -contains $i) {
                $slot=[Array]::IndexOf($selected,$i);$x=($slot%2)*768;$y=[int][math]::Floor($slot/2)*796
                $graphics.DrawString(('t = {0:0.00} s' -f ([math]::Round($i*239/95)/30)),$font,[Drawing.Brushes]::White,$x+12,$y+2)
                $graphics.DrawImageUnscaled($image,$x,$y+28)
            }
            if($i -eq 24){$image.Save((Join-Path $sampleDir 'toilet_flush_preview.png'),[Drawing.Imaging.ImageFormat]::Png)}
            $stream=[IO.MemoryStream]::new()
            try {
                $image.Save($stream,[Drawing.Imaging.ImageFormat]::Png);$stream.Position=0
                $source=[Windows.Media.Imaging.BitmapImage]::new()
                $source.BeginInit();$source.CacheOption=[Windows.Media.Imaging.BitmapCacheOption]::OnLoad
                $source.StreamSource=$stream;$source.EndInit();$source.Freeze()
                $small=[Windows.Media.Imaging.TransformedBitmap]::new($source,[Windows.Media.ScaleTransform]::new(0.625,0.625))
                $encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($small))
            } finally {$stream.Dispose()}
        } finally {$image.Dispose()}
    }
    $strip.Save((Join-Path $sampleDir 'toilet_flush_phases.png'),[Drawing.Imaging.ImageFormat]::Png)
    $memory=[IO.MemoryStream]::new()
    try {$encoder.Save($memory);$raw=$memory.ToArray()}finally{$memory.Dispose()}
    $header=13
    if($raw[10] -band 128){$header+=3*[int][math]::Pow(2,($raw[10] -band 7)+1)}
    $loop=[byte[]](33,255,11)+[Text.Encoding]::ASCII.GetBytes('NETSCAPE2.0')+[byte[]](3,1,0,0,0)
    $bytes=[byte[]]::new($raw.Length+$loop.Length)
    [Array]::Copy($raw,0,$bytes,0,$header);[Array]::Copy($loop,0,$bytes,$header,$loop.Length)
    [Array]::Copy($raw,$header,$bytes,$header+$loop.Length,$raw.Length-$header)
    $offset=$header;$frames=0;$timings=0
    while($offset -lt $bytes.Length) {
        $kind=$bytes[$offset];$offset++
        if($kind -eq 59){break}
        if($kind -eq 33) {
            $label=$bytes[$offset];$offset++
            if($label -eq 249 -and $bytes[$offset] -eq 4) {
                $bytes[$offset+1]=($bytes[$offset+1] -band 227) -bor 4
                $delay=[int]([math]::Round(($timings+1)*100/12)-[math]::Round($timings*100/12))
                if($timings -eq 95){$delay=100}
                $bytes[$offset+2]=[byte]$delay;$bytes[$offset+3]=0;$timings++
            }
        } elseif($kind -eq 44) {
            $frames++;$packed=$bytes[$offset+8];$offset+=9
            if($packed -band 128){$offset+=3*[int][math]::Pow(2,($packed -band 7)+1)}
            $offset++
        } else {throw 'Invalid GIF structure.'}
        do{$size=[int]$bytes[$offset];$offset++;$offset+=$size}while($size -gt 0 -and $offset -lt $bytes.Length)
    }
    if($frames -ne 96 -or $timings -ne 96){throw 'GIF frame count differs.'}
    $path=Join-Path $sampleDir 'toilet_flush_preview.gif';[IO.File]::WriteAllBytes($path,$bytes)
    $check=[Drawing.Image]::FromFile($path)
    try {if($check.GetFrameCount([Drawing.Imaging.FrameDimension]::Time) -ne 96){throw 'GIF decode failed.'}}finally{$check.Dispose()}
    Write-Output $path
} finally {$graphics.Dispose();$strip.Dispose();$font.Dispose()}
