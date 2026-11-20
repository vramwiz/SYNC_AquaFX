unit SYNC_AquaFX_FilterPlugin;

// Copyright (c) 2026 VRAMの魔術師
// SPDX-License-Identifier: GPL-3.0-only

// 水面生成とフィルターの登録。描画資源はエフェクトごとに保持する。

interface

uses
  AviUtl2FilterTypes;

// 初回に標準項目とコールバックを登録し、DLL所有のテーブルを返す。呼出側で解放しない。
function GetAquaFXFilterTable: PFILTER_PLUGIN_TABLE;

const
  AQUAFX_REQUIRED_VERSION = 2011600;

implementation

uses
  System.SysUtils, System.SyncObjs, Winapi.Windows,
  PluginFilterTable, AquaFX_Parameters, AquaFX_Renderer, AquaFX_Settings, AquaFX_VortexSurface
  {$IFDEF DEBUG}, AquaFX_Profiling{$ENDIF};

const
  EFFECT_NAME = '水面演出';
  EFFECT_GROUP = 'SYNC';

var
  PluginTableInitialized: Boolean;

type
  TAquaSession = class
  private
    FLock: TCriticalSection;
    FRenderer: TAquaRenderer;
    FInput, FOutput: TAquaPixels;
  public
    // エフェクト1個分のロックと描画器を所有し、破棄時に全バッファを解放する。
    constructor Create;
    destructor Destroy; override;
    // Videoは呼出中だけ借用する。画像を書き戻すが、ホスト所有ポインターは保存しない。
    procedure Render(Video: PFILTER_PROC_VIDEO);
  end;

constructor TAquaSession.Create;
begin
  inherited;
  FLock := TCriticalSection.Create;
  FRenderer := TAquaRenderer.Create;
end;

destructor TAquaSession.Destroy;
begin
  FRenderer.Free;
  FLock.Free;
  inherited;
end;

procedure TAquaSession.Render(Video: PFILTER_PROC_VIDEO);
var
  Width, Height: Integer;
  FilterObject: Boolean;
  Settings: TAquaSettings;
  {$IFDEF DEBUG}
  Profile: TAquaFrameProfile;
  {$ENDIF}
begin
  if not Assigned(Video^.SetImageData) then Exit;
  FilterObject := (Video^.Object_^.Flag and OBJECT_FLAG_FILTER_OBJECT) <> 0;
  Width := Video^.Object_^.Width; Height := Video^.Object_^.Height;
  if FilterObject and ((Width <= 0) or (Height <= 0)) then
  begin
    if Video^.Scene = nil then Exit;
    Width := Video^.Scene^.Width; Height := Video^.Scene^.Height;
  end;
  if (Width <= 0) or (Height <= 0) or (Width > 8192) or (Height > 8192) or
    (Int64(Width) * Height > AQUA_MAX_PIXELS) then Exit;
  {$IFDEF DEBUG}
  Profile := Default(TAquaFrameProfile);
  Profile.Started := AquaProfileTick;
  {$ENDIF}
  FLock.Acquire;
  try
    {$IFDEF DEBUG}Profile.Locked := AquaProfileTick;{$ENDIF}
    if Assigned(Video^.GetImageData) and
      (Video^.Object_^.Width = Width) and (Video^.Object_^.Height = Height) then
    begin
      SetLength(FInput, Width * Height);
      Video^.GetImageData(@FInput[0]);
    end else
      SetLength(FInput, 0);
    {$IFDEF DEBUG}Profile.InputDone := AquaProfileTick;{$ENDIF}
    Settings := ReadAquaFXSettings;
    {$IFDEF DEBUG}Profile.SettingsDone := AquaProfileTick;{$ENDIF}
    FRenderer.Render(FInput, Width, Height, Video^.Object_^.Time,
      Settings, not FilterObject, FOutput, AquaObjectProgress(Video^.Object_^));
    {$IFDEF DEBUG}
    Profile.RenderDone := AquaProfileTick;
    Profile.Renderer := FRenderer.LastProfile;
    {$ENDIF}
    if Length(FOutput) = Width * Height then
      Video^.SetImageData(@FOutput[0], Width, Height);
    {$IFDEF DEBUG}Profile.OutputDone := AquaProfileTick;{$ENDIF}
  finally
    FLock.Release;
  end;
  {$IFDEF DEBUG}
  WriteAquaProfile(Profile, Width, Height, Ord(Settings.DisplayMode), Ord(Settings.Shape));
  {$ENDIF}
end;

function AquaFXProcVideo(Video: PFILTER_PROC_VIDEO): Byte; cdecl;
begin
  Result := 1;
  try
    if (Video = nil) or (Video^.Object_ = nil) or (Video^.UserData = nil) then Exit;
    TAquaSession(Video^.UserData).Render(Video);
  except
    on E: Exception do
      OutputDebugString(PWideChar('SYNC_AquaFX render: ' + E.Message));
  end;
end;

function AquaFXCreate(EffectID: Int64): Pointer; cdecl;
begin
  Result := nil;
  try
    Result := TAquaSession.Create;
  except
    // 確保失敗時は入力画像を維持する。
  end;
end;

procedure AquaFXDestroy(EffectID: Int64; UserData: Pointer); cdecl;
begin
  try
    TAquaSession(UserData).Free;
  except
    // DLL境界へ例外を漏らさない。
  end;
end;

function GetAquaFXFilterTable: PFILTER_PLUGIN_TABLE;
begin
  if not PluginTableInitialized then
  begin
    SetupPluginTable(FILTER_FLAG_VIDEO or FILTER_FLAG_FILTER or FILTER_FLAG_USERDATA,
      EFFECT_NAME, EFFECT_GROUP, '水面演出 / SYNC_AquaFX v0.6.0', AquaFXProcVideo, nil);
    RegisterAquaFXParameters;
    GetPluginTable^.Func_Create := AquaFXCreate;
    GetPluginTable^.Func_Destroy := AquaFXDestroy;
    PluginTableInitialized := True;
  end;
  Result := GetPluginTable;
end;

end.
