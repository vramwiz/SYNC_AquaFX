param(
    [string]$PluginPath = 'C:\ProgramData\aviutl2\Plugin\SYNC_AquaFX\SYNC_AquaFX.auf2',
    [string]$ImageDirectory,
    [switch]$PreviewsOnly,
    [switch]$ShorePreview,
    [switch]$DrainPreview,
    [switch]$Benchmark,
    [string]$BenchmarkImage = (Join-Path $PSScriptRoot '..\Sample\ramen.png'),
    [string]$BenchmarkCase,
    [string]$BenchmarkAlias
)

# 本番AUF2を読み込む検査EXEをビルド・実行する。追加プラグインは作成しない。
# 生成物と確認画像はプロジェクト内のWin64\Verificationが所有する。

$ErrorActionPreference = 'Stop'
$projectDir = Split-Path -Parent $PSScriptRoot
$outputDir = Join-Path $projectDir 'Win64\Verification'
$dcuDir = Join-Path $outputDir 'DCU'
if (-not $ImageDirectory) { $ImageDirectory = Join-Path $outputDir 'Images' }
New-Item -ItemType Directory -Path $dcuDir -Force | Out-Null
$compiler = (Get-Command dcc64.exe -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
$studioDir = Split-Path -Parent (Split-Path -Parent $compiler)
$libraryDir = Join-Path $studioDir 'lib\Win64\release'
Push-Location $PSScriptRoot
try {
    & $compiler '--no-config' '-B' '-Q' '-TX.exe' '-$R+' '-$Q+' '-NSSystem;Winapi;Vcl' `
        "-U$libraryDir;$libraryDir\JA" "-E$outputDir" "-NU$dcuDir" 'AquaFX_RenderTests.dpr'
    if ($LASTEXITCODE -ne 0) { throw 'Verification build failed.' }
    $testArguments = @($PluginPath, $ImageDirectory)
    if ($Benchmark) { $testArguments += @('--benchmark', $BenchmarkImage) }
    elseif ($PreviewsOnly) { $testArguments += '--previews-only' }
    elseif ($ShorePreview) { $testArguments += '--shore-preview' }
    elseif ($DrainPreview) { $testArguments += '--drain-preview' }
    if ($Benchmark -and $BenchmarkCase) { $testArguments += $BenchmarkCase }
    if ($Benchmark -and $BenchmarkAlias) {
        if (-not $BenchmarkCase) { throw 'BenchmarkAlias requires BenchmarkCase.' }
        $testArguments += $BenchmarkAlias
    }
    & (Join-Path $outputDir 'AquaFX_RenderTests.exe') @testArguments
    if ($LASTEXITCODE -ne 0) { throw 'Render regression tests failed.' }
}
finally { Pop-Location }
