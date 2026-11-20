param([int]$StartFrame=2340,[int]$Length=240)

# 確認済みの画像・標準描画エイリアスから、便器の水2層の完全な保存値を作る。
# AviUtl2への適用は行わない。生成後はAI MIRAIで現在の全項目と照合してから配置する。
$ErrorActionPreference='Stop'
$sampleDir=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\Sample'))
$original=[IO.File]::ReadAllText((Join-Path $sampleDir 'bathtub_drain_alias.txt'))
$upperValues=@{
    'プリセット'='トイレの水を流す';'表示モード'='背景あり';'水面形状'='トイレの流水';'液体色'='83c5d2'
    'X'='-2.00';'Y'='10.00';'拡大率'='74.000';'縦横比'='-12.000';'透明度'='0.00'
    '波の強さ'='9';'波の速度'='0.80';'波の細かさ'='55';'反射の強さ'='20';'ハイライトの強さ'='25';'泡の量'='8'
    '渦の強さ'='50';'渦の速さ'='1.40';'渦の広がり'='95';'渦中心X'='-7.00';'渦中心Y'='-97.00'
    '渦の凹み'='0';'渦の吸い込み'='0';'排水の量'='0'
}
$lowerValues=@{
    'プリセット'='栓を抜く';'表示モード'='画像に水面';'水面形状'='角丸の四角';'液体色'='83c5d2'
    'X'='-2.00';'Y'='65.00';'拡大率'='39.000';'縦横比'='-45.000';'透明度'='55.00'
    '渦中心X'='-7.00';'渦中心Y'='-97.00'
}
for($layer=0;$layer -le 1;$layer++) {
    $values=$lowerValues;$amount=0;$file='toilet_pool_alias.txt'
    if($layer -eq 1){$values=$upperValues;$amount=100;$file='toilet_flush_alias.txt'}
    $section='';$lines=[Collections.Generic.List[string]]::new()
    foreach($line in ($original -split '\r?\n')) {
        if($line -match '^\[(.+)\]$'){$section=$Matches[1]}
        if($line -match '^([^=]+)=(.*)$') {
            $key=$Matches[1]
            if($section -eq '0') {
                if($key -eq 'layer'){$line="layer=$layer"}
                if($key -eq 'frame'){$line='frame={0},{1}' -f $StartFrame,($StartFrame+$Length-1)}
            }
            if($section -eq '0.0' -and $key -eq 'ファイル'){$line='ファイル='+ (Join-Path $sampleDir 'toilet_empty.png')}
            if($section -eq '0.1' -and $key -eq '拡大率'){$line='拡大率=82.000'}
            if($section -eq '0.2' -and $values.ContainsKey($key)){$line=$key+'='+$values[$key]}
        }
        if($line.Length -gt 0){$lines.Add($line)}
    }
    $lines.Add('角の丸み=65');$lines.Add("流水の量=$amount");$lines.Add('流水の幅=65');$lines.Add('給水終了=65')
    [IO.File]::WriteAllText((Join-Path $sampleDir $file),($lines -join "`r`n")+"`r`n",[Text.UTF8Encoding]::new($false))
    Write-Output (Join-Path $sampleDir $file)
}
