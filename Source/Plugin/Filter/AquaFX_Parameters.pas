unit AquaFX_Parameters;

// Copyright (c) 2026 VRAMの魔術師
// SPDX-License-Identifier: GPL-3.0-only

// 最上段のプリセットと設定ボタンから、下の標準パラメータへ一括反映する。
// SYNC_ParticleFX と同じ編集APIを使い、個別調整可能な値として保存する。

interface

uses
  AquaFX_Settings;

// SetupPluginTableの後に呼び、DLL所有の項目を登録する。項目を呼出側で解放しない。
procedure RegisterAquaFXParameters;
// ホストが設定した現在値を範囲内の設定へ複製する。ホスト項目や保存値は変更しない。
function ReadAquaFXSettings: TAquaSettings;

implementation

uses
  System.Math, System.SysUtils, Winapi.Windows,
  AviUtl2FilterTypes, PluginFilterTable;

type
  TAquaSelect = (slPreset, slDisplayMode, slShape);

var
  Selects: array[TAquaSelect] of TFILTER_ITEM_SELECT;
  Options: array[TAquaSelect, 0..AQUA_PRESET_COUNT] of TFILTER_ITEM_SELECT_ITEM;
  Tracks: array[TAquaTrack] of TFILTER_ITEM_TRACK;
  LiquidColor, OilColor: TFILTER_ITEM_COLOR;
  SettingsButton: TFILTER_ITEM_BUTTON;
  PlacementGroup, PlacementGroupEnd: TFILTER_ITEM_GROUP;
  OilGroup, OilGroupEnd: TFILTER_ITEM_GROUP;
  VortexGroup, VortexGroupEnd: TFILTER_ITEM_GROUP;
  ShoreGroup, ShoreGroupEnd: TFILTER_ITEM_GROUP;
  DrainGroup, DrainGroupEnd: TFILTER_ITEM_GROUP;

procedure ApplyPreset(Edit: PEDIT_SECTION; Obj: OBJECT_HANDLE;
  Effect, Item: PWideChar); cdecl;
var
  Preset: TAquaSettings;
  Track: TAquaTrack;
  TargetEffect: string;
  Text: UTF8String;

  procedure SetItem(Name: PWideChar; const Value: UTF8String);
  begin
    if not Edit^.SetObjectItemValue(Obj, PWideChar(TargetEffect), Name,
      PAnsiChar(Value)) then
      raise EInvalidOp.CreateFmt('Preset item could not be set: %s', [string(Name)]);
  end;

begin
  if (Edit = nil) or (Obj = nil) or (Effect = nil) then Exit;
  if not Assigned(Edit^.SetObjectItemValue) then Exit;
  try
    // SDKから渡された対象名を使い、同じフィルターの2個目以降も区別する。
    TargetEffect := Effect;
    Preset := AquaPresetSettings(TAquaPreset(EnsureRange(
      Selects[slPreset].Value, Ord(Low(TAquaPreset)), Ord(High(TAquaPreset)))));

    // 選択項目の編集APIは数値IDではなく、保存形式と同じ選択肢名を受け取る。
    SetItem(Selects[slShape].Name, UTF8String(AQUA_SHAPE_NAMES[Preset.Shape]));
    Selects[slShape].Value := Ord(Preset.Shape);
    SetItem(LiquidColor.Name, UTF8String(IntToHex(Preset.ColorRGB, 6)));
    LiquidColor.R := Byte((Preset.ColorRGB shr 16) and $FF);
    LiquidColor.G := Byte((Preset.ColorRGB shr 8) and $FF);
    LiquidColor.B := Byte(Preset.ColorRGB and $FF);
    SetItem(OilColor.Name, UTF8String(IntToHex(Preset.OilColorRGB, 6)));
    OilColor.R := Byte((Preset.OilColorRGB shr 16) and $FF);
    OilColor.G := Byte((Preset.OilColorRGB shr 8) and $FF);
    OilColor.B := Byte(Preset.OilColorRGB and $FF);

    for Track := Low(TAquaTrack) to High(TAquaTrack) do
    begin
      // 乱数の再現条件、表示モード、利用者の配置はプリセットで変更しない。
      if (Track = atSeed) or (Track in AQUA_PLACEMENT_TRACKS) or
        (Track in AQUA_VORTEX_PLACEMENT_TRACKS) then Continue;
      Text := UTF8String(FloatToStr(Preset.Tracks[Track], TFormatSettings.Invariant));
      SetItem(Tracks[Track].Name, Text);
      Tracks[Track].Value := Preset.Tracks[Track];
    end;
  except
    on E: Exception do
      OutputDebugString(PWideChar('SYNC_AquaFX settings: ' + E.Message));
  end;
end;

procedure RegisterSelect(Item: TAquaSelect; Name: PWideChar;
  const Names: array of PWideChar; InitialValue: Integer);
var
  I: Integer;
begin
  if Length(Names) >= Length(Options[Item]) then
    raise ERangeError.Create('Selection options exceed the reserved terminator');
  FillChar(Options[Item], SizeOf(Options[Item]), 0);
  for I := 0 to High(Names) do
  begin
    Options[Item, I].Name := Names[I];
    Options[Item, I].Value := I;
  end;
  AddSelect(Selects[Item], Name, InitialValue, @Options[Item, 0]);
end;

procedure RegisterAquaFXParameters;
var
  Settings: TAquaSettings;
  Track: TAquaTrack;
begin
  Settings := AquaPresetSettings(apSea);

  // 折りたたみグループの外で、常に最上段へ登録する。
  RegisterSelect(slPreset, 'プリセット', AQUA_PRESET_NAMES, Ord(apSea));
  AddButton(SettingsButton, '設定', ApplyPreset);

  RegisterSelect(slDisplayMode, '表示モード', AQUA_DISPLAY_NAMES,
    Ord(Settings.DisplayMode));
  RegisterSelect(slShape, '水面形状', AQUA_SHAPE_NAMES, Ord(Settings.Shape));
  AddColor(LiquidColor, '液体色', Byte(Settings.ColorRGB and $FF),
    Byte((Settings.ColorRGB shr 8) and $FF),
    Byte((Settings.ColorRGB shr 16) and $FF));

  AddGroup(PlacementGroup, '座標・変形', 1);
  for Track := atX to atTransparency do
    AddTrack(Tracks[Track], AQUA_TRACK_DEFINITIONS[Track].Name,
      Settings.Tracks[Track], AQUA_TRACK_DEFINITIONS[Track].MinValue,
      AQUA_TRACK_DEFINITIONS[Track].MaxValue, AQUA_TRACK_DEFINITIONS[Track].Step);
  AddGroup(PlacementGroupEnd, '', 1);

  for Track := Low(TAquaTrack) to atSeed do
    AddTrack(Tracks[Track], AQUA_TRACK_DEFINITIONS[Track].Name,
      Settings.Tracks[Track], AQUA_TRACK_DEFINITIONS[Track].MinValue,
      AQUA_TRACK_DEFINITIONS[Track].MaxValue,
      AQUA_TRACK_DEFINITIONS[Track].Step);

  AddTrack(Tracks[atImageShading], AQUA_TRACK_DEFINITIONS[atImageShading].Name,
    Settings.Tracks[atImageShading], 0, 100, 1);
  for Track := atRippleScatter to atRippleAspect do
    AddTrack(Tracks[Track], AQUA_TRACK_DEFINITIONS[Track].Name,
      Settings.Tracks[Track], AQUA_TRACK_DEFINITIONS[Track].MinValue,
      AQUA_TRACK_DEFINITIONS[Track].MaxValue, AQUA_TRACK_DEFINITIONS[Track].Step);

  AddGroup(VortexGroup, '渦', 1);
  for Track := atVortexStrength to atVortexRadius do
    AddTrack(Tracks[Track], AQUA_TRACK_DEFINITIONS[Track].Name,
      Settings.Tracks[Track], AQUA_TRACK_DEFINITIONS[Track].MinValue,
      AQUA_TRACK_DEFINITIONS[Track].MaxValue, AQUA_TRACK_DEFINITIONS[Track].Step);
  AddGroup(VortexGroupEnd, '', 1);

  AddGroup(OilGroup, '表面の油', 1);
  AddColor(OilColor, '油膜色', Byte(Settings.OilColorRGB and $FF),
    Byte((Settings.OilColorRGB shr 8) and $FF), Byte((Settings.OilColorRGB shr 16) and $FF));
  for Track := atOilAmount to atOilGloss do
    AddTrack(Tracks[Track], AQUA_TRACK_DEFINITIONS[Track].Name,
      Settings.Tracks[Track], AQUA_TRACK_DEFINITIONS[Track].MinValue,
      AQUA_TRACK_DEFINITIONS[Track].MaxValue, AQUA_TRACK_DEFINITIONS[Track].Step);
  AddGroup(OilGroupEnd, '', 1);
  AddGroup(ShoreGroup, '海岸の寄せ返し', 1);
  for Track := atShoreReach to atShoreFoamLife do
    AddTrack(Tracks[Track], AQUA_TRACK_DEFINITIONS[Track].Name,
      Settings.Tracks[Track], AQUA_TRACK_DEFINITIONS[Track].MinValue,
      AQUA_TRACK_DEFINITIONS[Track].MaxValue, AQUA_TRACK_DEFINITIONS[Track].Step);
  AddGroup(ShoreGroupEnd, '', 1);
  // 既存項目の登録順を維持し、新しい保存項目は末尾へ追加する。
  AddGroup(DrainGroup, '渦の凹み・排水', 1);
  for Track := atVortexCenterX to atDrainAmount do
    AddTrack(Tracks[Track], AQUA_TRACK_DEFINITIONS[Track].Name,
      Settings.Tracks[Track], AQUA_TRACK_DEFINITIONS[Track].MinValue,
      AQUA_TRACK_DEFINITIONS[Track].MaxValue, AQUA_TRACK_DEFINITIONS[Track].Step);
  AddGroup(DrainGroupEnd, '', 1);
end;

function ReadAquaFXSettings: TAquaSettings;
var
  Track: TAquaTrack;
  Value: Double;
begin
  Result := AquaPresetSettings(apSea);
  Result.DisplayMode := TAquaDisplayMode(EnsureRange(Selects[slDisplayMode].Value,
    Ord(Low(TAquaDisplayMode)), Ord(High(TAquaDisplayMode))));
  Result.Shape := TAquaShape(EnsureRange(Selects[slShape].Value,
    Ord(Low(TAquaShape)), Ord(High(TAquaShape))));
  Result.ColorRGB := (Cardinal(LiquidColor.R) shl 16) or
    (Cardinal(LiquidColor.G) shl 8) or Cardinal(LiquidColor.B);
  Result.OilColorRGB := (Cardinal(OilColor.R) shl 16) or
    (Cardinal(OilColor.G) shl 8) or Cardinal(OilColor.B);
  for Track := Low(TAquaTrack) to High(TAquaTrack) do
  begin
    Value := Tracks[Track].Value;
    if IsNan(Value) or IsInfinite(Value) then Continue;
    Result.Tracks[Track] := EnsureRange(Value,
      AQUA_TRACK_DEFINITIONS[Track].MinValue, AQUA_TRACK_DEFINITIONS[Track].MaxValue);
  end;
end;

end.
