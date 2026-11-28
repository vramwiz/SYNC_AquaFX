library SYNC_AquaFX;

// Copyright (c) 2026 VRAMの魔術師
// SPDX-License-Identifier: GPL-3.0-only

// 水面演出の AviUtl2 DLL 境界。登録と終了の入口を公開する。
// Delphi 例外は C コールバックの外へ漏らさない。

{$ALIGN 8}

uses
  AviUtl2FilterTypes in 'Source\Lib\AviUtl2FilterTypes.pas',
  PluginFilterTable in 'Source\Lib\FilterTable\PluginFilterTable.pas',
  AquaFX_Settings in 'Source\Common\AquaFX_Settings.pas',
  AquaFX_SurfaceShape in 'Source\Common\AquaFX_SurfaceShape.pas',
  AquaFX_Flush in 'Source\Common\AquaFX_Flush.pas',
  AquaFX_Weather in 'Source\Common\AquaFX_Weather.pas',
  AquaFX_WaterDepth in 'Source\Common\AquaFX_WaterDepth.pas',
  AquaFX_OilSurface in 'Source\Common\AquaFX_OilSurface.pas',
  AquaFX_Projection in 'Source\Common\AquaFX_Projection.pas',
  AquaFX_Flow in 'Source\Common\AquaFX_Flow.pas',
  AquaFX_VortexSurface in 'Source\Common\AquaFX_VortexSurface.pas',
  AquaFX_Shore in 'Source\Common\AquaFX_Shore.pas',
  AquaFX_Profiling in 'Source\Common\AquaFX_Profiling.pas',
  AquaFX_Renderer in 'Source\Common\AquaFX_Renderer.pas',
  AquaFX_Parameters in 'Source\Plugin\Filter\AquaFX_Parameters.pas',
  SYNC_AquaFX_FilterPlugin in 'Source\Plugin\Filter\SYNC_AquaFX_FilterPlugin.pas';

{$R *.res}

// ホストからSDK形式のVersionを受け取る。対応バージョンで登録に成功したら1、失敗時は0を返す。
function InitializePlugin(Version: Cardinal): Byte; cdecl;
begin
  Result := 0;
  try
    if Version < AQUAFX_REQUIRED_VERSION then Exit;
    GetAquaFXFilterTable;
    Result := 1;
  except
    // 初期化失敗は戻り値でホストへ伝える。
  end;
end;

// 終了通知を受ける。エフェクトの描画資源は個別のfunc_destroyで回収する。
procedure UninitializePlugin; cdecl;
begin
end;

// 公式SDK形式の本体バージョン番号を返す。
function RequiredVersion: Cardinal; cdecl;
begin
  Result := AQUAFX_REQUIRED_VERSION;
end;

// DLL が所有する登録テーブルを返す。取得失敗時は nil を返す。
function GetFilterPluginTable: PFILTER_PLUGIN_TABLE; cdecl;
begin
  Result := nil;
  try
    Result := GetAquaFXFilterTable;
  except
    // 登録失敗時はテーブルを返さずホスト側へ判断を委ねる。
  end;
end;

exports
  RequiredVersion name 'RequiredVersion',
  InitializePlugin name 'InitializePlugin',
  UninitializePlugin name 'UninitializePlugin',
  GetFilterPluginTable name 'GetFilterPluginTable';

begin
end.
