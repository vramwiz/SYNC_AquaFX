unit AquaFX_Settings;

// Copyright (c) 2026 VRAMの魔術師
// SPDX-License-Identifier: GPL-3.0-only

// プリセットは共通パラメータの初期値だけを定義する。描画方式は分岐しない。
// 数値は標準パラメータの単位。描画実装時に見た目と負荷を確認して調整する。

interface

type
  TAquaDisplayMode = (adBackground, adImage, adEffectsOnly, adOilOverlay, adWaveOverlay,
    adWaterOverlay);
  TAquaShape = (asPlane, asRectangle, asEllipse, asImage, asShore,
    asRoundedRectangle, asFlush);
  TAquaPreset = (apSea, apCoast, apRiver, apPond, apLake, apPuddle,
    apBath, apPool, apRamen, apMiso, apMilk, apCoffee, apOil, apMagic, apVortex,
    apDropRipples, apShore, apDrain, apFlush);
  TAquaTrack = (atWaveStrength, atWaveSpeed, atWaveDetail,
    atFlowDirection, atFlowSpeed, atRippleAmount, atRippleSize,
    atRippleSpeed, atViscosity, atReflection, atHighlight, atFoam,
    atTilt, atRotation, atPerspective, atSeed,
    atX, atY, atZ, atCenterX, atCenterY, atCenterZ,
    atRotateX, atRotateY, atRotateZ, atZoom, atAspect, atTransparency,
    atOilAmount, atOilSize, atOilGloss,
    atVortexStrength, atVortexSpeed, atVortexRadius, atImageShading,
    atRippleScatter, atRippleAspect,
    atShoreReach, atShorePeriod, atShoreRoughness, atShoreWaterOpacity, atShoreFoamLife,
    atVortexCenterX, atVortexCenterY, atVortexDepth, atVortexPull, atDrainAmount,
    atCornerRoundness, atFlushAmount, atFlushWidth, atFlushStop);

  TAquaTrackDefinition = record
    Name: PWideChar;
    MinValue, MaxValue, Step: Double;
  end;

  TAquaSettings = record
    DisplayMode: TAquaDisplayMode;
    Shape: TAquaShape;
    ColorRGB: Cardinal; // $RRGGBB
    OilColorRGB: Cardinal; // 下地とは独立した浮遊油膜の色。
    Tracks: array[TAquaTrack] of Double;
  end;

const
  // プリセットを適用しても、利用者が決めた配置・変形・透明度は維持する。
  AQUA_PLACEMENT_TRACKS = [atX..atTransparency];
  AQUA_VORTEX_PLACEMENT_TRACKS = [atVortexCenterX, atVortexCenterY];
  AQUA_PRESET_COUNT = Ord(High(TAquaPreset)) + 1;
  AQUA_PRESET_NAMES: array[TAquaPreset] of PWideChar = (
    '海', '海岸', '川', '池', '湖', '水たまり', 'お風呂', 'プール',
    'ラーメンスープ', '味噌汁', '牛乳', 'コーヒー', '油', '魔法液体', '渦', '落水の波紋',
    '海岸の寄せ返し', '栓を抜く', 'トイレの水を流す');
  AQUA_DISPLAY_NAMES: array[TAquaDisplayMode] of PWideChar = (
    '背景あり', 'ユーザー画像', '背景なし', '画像に油膜', '画像に波', '画像に水面');
  AQUA_SHAPE_NAMES: array[TAquaShape] of PWideChar = (
    '平面', '長方形', '円形・楕円形', '画像形状', '海岸', '角丸の四角', 'トイレの流水');

  AQUA_TRACK_DEFINITIONS: array[TAquaTrack] of TAquaTrackDefinition = (
    (Name: '波の強さ'; MinValue: 0; MaxValue: 100; Step: 1),
    (Name: '波の速度'; MinValue: 0; MaxValue: 10; Step: 0.01),
    (Name: '波の細かさ'; MinValue: 1; MaxValue: 100; Step: 1),
    (Name: '流れる方向'; MinValue: -360; MaxValue: 360; Step: 0.1),
    (Name: '流速'; MinValue: 0; MaxValue: 100; Step: 1),
    (Name: '波紋の量'; MinValue: 0; MaxValue: 100; Step: 1),
    (Name: '波紋の大きさ'; MinValue: 1; MaxValue: 100; Step: 1),
    (Name: '波紋の速度'; MinValue: 0; MaxValue: 10; Step: 0.01),
    (Name: '粘度'; MinValue: 0; MaxValue: 100; Step: 1),
    (Name: '反射の強さ'; MinValue: 0; MaxValue: 100; Step: 1),
    (Name: 'ハイライトの強さ'; MinValue: 0; MaxValue: 100; Step: 1),
    (Name: '泡の量'; MinValue: 0; MaxValue: 100; Step: 1),
    (Name: '3D傾斜角度'; MinValue: -89; MaxValue: 89; Step: 0.1),
    (Name: '水平回転'; MinValue: -360; MaxValue: 360; Step: 0.1),
    (Name: '遠近感'; MinValue: 0; MaxValue: 100; Step: 1),
    (Name: 'シード'; MinValue: 0; MaxValue: 1000000; Step: 1),
    (Name: 'X'; MinValue: -100000; MaxValue: 100000; Step: 0.01),
    (Name: 'Y'; MinValue: -100000; MaxValue: 100000; Step: 0.01),
    (Name: 'Z'; MinValue: -100000; MaxValue: 100000; Step: 0.01),
    (Name: '中心X'; MinValue: -100000; MaxValue: 100000; Step: 0.01),
    (Name: '中心Y'; MinValue: -100000; MaxValue: 100000; Step: 0.01),
    (Name: '中心Z'; MinValue: -100000; MaxValue: 100000; Step: 0.01),
    (Name: 'X軸回転'; MinValue: -360; MaxValue: 360; Step: 0.01),
    (Name: 'Y軸回転'; MinValue: -360; MaxValue: 360; Step: 0.01),
    (Name: 'Z軸回転'; MinValue: -360; MaxValue: 360; Step: 0.01),
    (Name: '拡大率'; MinValue: 0; MaxValue: 1000; Step: 0.001),
    (Name: '縦横比'; MinValue: -100; MaxValue: 100; Step: 0.001),
    (Name: '透明度'; MinValue: 0; MaxValue: 100; Step: 0.01),
    (Name: '油膜の量'; MinValue: 0; MaxValue: 100; Step: 1),
    (Name: '油膜サイズ'; MinValue: 1; MaxValue: 100; Step: 1),
    (Name: '油膜光沢'; MinValue: 0; MaxValue: 100; Step: 1),
    (Name: '渦の強さ'; MinValue: -100; MaxValue: 100; Step: 1),
    (Name: '渦の速さ'; MinValue: 0; MaxValue: 10; Step: 0.01),
    (Name: '渦の広がり'; MinValue: 1; MaxValue: 100; Step: 1),
    (Name: '画像の陰影'; MinValue: 0; MaxValue: 100; Step: 1),
    (Name: '波紋の散らばり'; MinValue: 0; MaxValue: 100; Step: 1),
    (Name: '波紋の縦横比'; MinValue: -200; MaxValue: 200; Step: 1),
    (Name: '波の到達幅'; MinValue: 0; MaxValue: 100; Step: 1),
    (Name: '寄せ返しの周期'; MinValue: 0.5; MaxValue: 30; Step: 0.01),
    (Name: '水際の不規則さ'; MinValue: 0; MaxValue: 100; Step: 1),
    (Name: '海水の不透明度'; MinValue: 0; MaxValue: 100; Step: 1),
    (Name: '泡の残り'; MinValue: 0; MaxValue: 100; Step: 1),
    (Name: '渦中心X'; MinValue: -100000; MaxValue: 100000; Step: 0.01),
    (Name: '渦中心Y'; MinValue: -100000; MaxValue: 100000; Step: 0.01),
    (Name: '渦の凹み'; MinValue: 0; MaxValue: 100; Step: 1),
    (Name: '渦の吸い込み'; MinValue: 0; MaxValue: 100; Step: 1),
    (Name: '排水の量'; MinValue: 0; MaxValue: 100; Step: 1),
    (Name: '角の丸み'; MinValue: 0; MaxValue: 100; Step: 1),
    (Name: '流水の量'; MinValue: 0; MaxValue: 100; Step: 1),
    (Name: '流水の幅'; MinValue: 5; MaxValue: 100; Step: 1),
    (Name: '給水終了'; MinValue: 5; MaxValue: 90; Step: 1));

// プリセットを何度適用しても、同じ基準値を返す。
// 戻り値は独立した設定値で、ホスト項目や現在の保存設定は変更しない。
function AquaPresetSettings(Preset: TAquaPreset): TAquaSettings;

implementation

// 利用者が水らしいと評価した「魔法液体」の動きと光沢を共通の基準にする。
// 色・形状・配置は変更せず、返す設定値を組み立てる際だけ使用する。
procedure ApplyWaterMotion(var Settings: TAquaSettings);
begin
  Settings.Tracks[atWaveStrength] := 55;
  Settings.Tracks[atWaveSpeed] := 1.4;
  Settings.Tracks[atWaveDetail] := 70;
  Settings.Tracks[atFlowDirection] := 45;
  Settings.Tracks[atFlowSpeed] := 30;
  Settings.Tracks[atRippleAmount] := 60;
  Settings.Tracks[atRippleSize] := 18;
  Settings.Tracks[atRippleSpeed] := 1.5;
  Settings.Tracks[atViscosity] := 35;
  Settings.Tracks[atReflection] := 60;
  Settings.Tracks[atHighlight] := 100;
  Settings.Tracks[atFoam] := 35;
  Settings.Tracks[atTilt] := 35;
  Settings.Tracks[atPerspective] := 25;
end;

function AquaPresetSettings(Preset: TAquaPreset): TAquaSettings;
begin
  Result := Default(TAquaSettings);
  Result.DisplayMode := adBackground;
  Result.Shape := asPlane;
  Result.ColorRGB := $18669B;
  Result.OilColorRGB := $E5B64A;
  Result.Tracks[atWaveStrength] := 55;
  Result.Tracks[atWaveSpeed] := 1;
  Result.Tracks[atWaveDetail] := 45;
  Result.Tracks[atFlowDirection] := 90;
  Result.Tracks[atFlowSpeed] := 10;
  Result.Tracks[atRippleAmount] := 15;
  Result.Tracks[atRippleSize] := 30;
  Result.Tracks[atRippleSpeed] := 1;
  Result.Tracks[atViscosity] := 0;
  Result.Tracks[atReflection] := 60;
  Result.Tracks[atHighlight] := 65;
  Result.Tracks[atFoam] := 10;
  Result.Tracks[atTilt] := 60;
  Result.Tracks[atRotation] := 0;
  Result.Tracks[atPerspective] := 65;
  Result.Tracks[atSeed] := 1;
  Result.Tracks[atZoom] := 100;
  Result.Tracks[atOilSize] := 60;
  Result.Tracks[atOilGloss] := 65;
  Result.Tracks[atVortexSpeed] := 1;
  Result.Tracks[atVortexRadius] := 70;
  Result.Tracks[atImageShading] := 100;
  Result.Tracks[atRippleScatter] := 100;
  Result.Tracks[atShoreReach] := 55;
  Result.Tracks[atShorePeriod] := 6;
  Result.Tracks[atShoreRoughness] := 50;
  Result.Tracks[atShoreWaterOpacity] := 85;
  Result.Tracks[atShoreFoamLife] := 70;
  Result.Tracks[atFlushWidth] := 65;
  Result.Tracks[atFlushStop] := 65;

  // 器の液体は楕円・俯瞰を基準にする。
  if Preset in [apRamen, apMiso, apMilk, apCoffee, apOil, apMagic] then
  begin
    Result.Shape := asEllipse;
    Result.Tracks[atWaveStrength] := 10;
    Result.Tracks[atWaveSpeed] := 0.4;
    Result.Tracks[atFlowSpeed] := 3;
    Result.Tracks[atRippleSize] := 18;
    Result.Tracks[atRippleSpeed] := 0.6;
    Result.Tracks[atTilt] := 35;
    Result.Tracks[atPerspective] := 25;
  end;

  if (Preset in [apSea..apPool]) or (Preset = apMagic) then ApplyWaterMotion(Result);

  case Preset of
    apSea:
      begin
        Result.Tracks[atFlowDirection] := 90;
        Result.Tracks[atRippleAmount] := 35;
        Result.Tracks[atRippleSize] := 30;
        Result.Tracks[atReflection] := 75;
        Result.Tracks[atFoam] := 18;
        Result.Tracks[atPerspective] := 35;
      end;
    apCoast:
      begin
        Result.ColorRGB := $2390B1;
        Result.Tracks[atWaveStrength] := 65;
        Result.Tracks[atFlowDirection] := 90;
        Result.Tracks[atFlowSpeed] := 45;
        Result.Tracks[atRippleAmount] := 25;
        Result.Tracks[atRippleSize] := 35;
        Result.Tracks[atReflection] := 65;
        Result.Tracks[atFoam] := 65;
        Result.Tracks[atTilt] := 40;
        Result.Tracks[atPerspective] := 40;
      end;
    apRiver:
      begin
        Result.ColorRGB := $307E85;
        Result.Tracks[atWaveStrength] := 50;
        Result.Tracks[atWaveSpeed] := 1.6;
        Result.Tracks[atFlowDirection] := 0;
        Result.Tracks[atFlowSpeed] := 70;
        Result.Tracks[atRippleAmount] := 45;
        Result.Tracks[atViscosity] := 30;
        Result.Tracks[atFoam] := 20;
        Result.Tracks[atTilt] := 30;
      end;
    apPond:
      begin
        Result.ColorRGB := $326855;
        Result.Tracks[atWaveStrength] := 35;
        Result.Tracks[atWaveSpeed] := 1;
        Result.Tracks[atFlowSpeed] := 12;
        Result.Tracks[atRippleSpeed] := 1.2;
        Result.Tracks[atReflection] := 65;
        Result.Tracks[atFoam] := 5;
        Result.Tracks[atTilt] := 30;
        Result.Tracks[atPerspective] := 20;
      end;
    apLake:
      begin
        Result.ColorRGB := $26699B;
        Result.Tracks[atWaveStrength] := 45;
        Result.Tracks[atWaveSpeed] := 1.2;
        Result.Tracks[atFlowSpeed] := 20;
        Result.Tracks[atRippleAmount] := 40;
        Result.Tracks[atRippleSize] := 25;
        Result.Tracks[atRippleSpeed] := 1.2;
        Result.Tracks[atReflection] := 80;
        Result.Tracks[atFoam] := 8;
        Result.Tracks[atPerspective] := 30;
      end;
    apPuddle:
      begin
        Result.Shape := asEllipse;
        Result.ColorRGB := $485B6B;
        Result.Tracks[atWaveStrength] := 30;
        Result.Tracks[atWaveSpeed] := 1.1;
        Result.Tracks[atFlowSpeed] := 8;
        Result.Tracks[atRippleAmount] := 65;
        Result.Tracks[atRippleSize] := 20;
        Result.Tracks[atFoam] := 0;
        Result.Tracks[atRippleSpeed] := 1.3;
        Result.Tracks[atTilt] := 25;
        Result.Tracks[atPerspective] := 15;
      end;
    apBath:
      begin
        Result.Shape := asRectangle;
        Result.ColorRGB := $65BECB;
        Result.Tracks[atWaveStrength] := 40;
        Result.Tracks[atWaveSpeed] := 1.2;
        Result.Tracks[atFlowSpeed] := 15;
        Result.Tracks[atRippleSpeed] := 1.3;
        Result.Tracks[atReflection] := 65;
        Result.Tracks[atFoam] := 25;
        Result.Tracks[atTilt] := 30;
      end;
    apPool:
      begin
        Result.Shape := asRectangle;
        Result.ColorRGB := $1EA8D7;
        Result.Tracks[atWaveStrength] := 45;
        Result.Tracks[atWaveSpeed] := 1.3;
        Result.Tracks[atFlowSpeed] := 20;
        Result.Tracks[atRippleAmount] := 50;
        Result.Tracks[atRippleSpeed] := 1.4;
        Result.Tracks[atReflection] := 75;
        Result.Tracks[atFoam] := 5;
      end;
    apRamen:
      begin
        Result.ColorRGB := $9E581D;
        Result.Tracks[atWaveStrength] := 8;
        Result.Tracks[atViscosity] := 60;
        Result.Tracks[atReflection] := 50;
        Result.Tracks[atHighlight] := 55;
        Result.Tracks[atFoam] := 15;
      end;
    apMiso:
      begin
        Result.ColorRGB := $916F43;
        Result.Tracks[atWaveStrength] := 7;
        Result.Tracks[atViscosity] := 40;
        Result.Tracks[atReflection] := 20;
        Result.Tracks[atHighlight] := 20;
        Result.Tracks[atFoam] := 8;
      end;
    apMilk:
      begin
        Result.Tracks[atImageShading] := 15;
        Result.ColorRGB := $EFEDDE;
        Result.Tracks[atWaveStrength] := 12;
        Result.Tracks[atWaveSpeed] := 0.5;
        Result.Tracks[atViscosity] := 45;
        Result.Tracks[atReflection] := 20;
        Result.Tracks[atHighlight] := 40;
        Result.Tracks[atFoam] := 20;
      end;
    apCoffee:
      begin
        Result.ColorRGB := $412315;
        Result.Tracks[atWaveStrength] := 28;
        Result.Tracks[atWaveSpeed] := 0.7;
        Result.Tracks[atRippleAmount] := 45;
        Result.Tracks[atViscosity] := 20;
        Result.Tracks[atReflection] := 65;
        Result.Tracks[atHighlight] := 90;
        Result.Tracks[atFoam] := 15;
      end;
    apOil:
      begin
        Result.ColorRGB := $BC941F;
        Result.OilColorRGB := $F3B934;
        Result.Tracks[atWaveStrength] := 22;
        Result.Tracks[atWaveSpeed] := 0.7;
        Result.Tracks[atWaveDetail] := 50;
        Result.Tracks[atFlowSpeed] := 10;
        Result.Tracks[atRippleAmount] := 15;
        Result.Tracks[atRippleSize] := 24;
        Result.Tracks[atRippleSpeed] := 0.55;
        Result.Tracks[atViscosity] := 45;
        Result.Tracks[atReflection] := 40;
        Result.Tracks[atHighlight] := 85;
        Result.Tracks[atFoam] := 0;
        Result.Tracks[atTilt] := 25;
        Result.Tracks[atPerspective] := 20;
        Result.Tracks[atOilAmount] := 48;
        Result.Tracks[atOilSize] := 48;
        Result.Tracks[atOilGloss] := 75;
      end;
    apMagic:
      begin
        Result.ColorRGB := $5B25B9;
      end;
    apVortex:
      begin
        ApplyWaterMotion(Result);
        Result.Shape := asEllipse;
        Result.ColorRGB := $237B91;
        Result.Tracks[atFlowSpeed] := 0;
        Result.Tracks[atTilt] := 25;
        Result.Tracks[atPerspective] := 20;
        Result.Tracks[atVortexStrength] := 70;
        Result.Tracks[atVortexSpeed] := 1.2;
        Result.Tracks[atVortexRadius] := 90;
        Result.Tracks[atWaveStrength] := 24;
        Result.Tracks[atWaveDetail] := 40;
        Result.Tracks[atRippleAmount] := 0;
        Result.Tracks[atReflection] := 40;
        Result.Tracks[atHighlight] := 50;
        Result.Tracks[atFoam] := 0;
        Result.Tracks[atVortexDepth] := 45;
        Result.Tracks[atVortexPull] := 55;
      end;
    apDropRipples:
      begin
        Result.Shape := asRectangle;
        Result.ColorRGB := $65BECB;
        Result.Tracks[atWaveStrength] := 0;
        Result.Tracks[atFlowSpeed] := 0;
        Result.Tracks[atRippleAmount] := 85;
        Result.Tracks[atRippleSize] := 45;
        Result.Tracks[atRippleSpeed] := 0.9;
        Result.Tracks[atRippleScatter] := 0;
        Result.Tracks[atViscosity] := 10;
        Result.Tracks[atReflection] := 55;
        Result.Tracks[atHighlight] := 80;
        Result.Tracks[atFoam] := 0;
        Result.Tracks[atTilt] := 0;
        Result.Tracks[atPerspective] := 0;
      end;
    apShore:
      begin
        Result.Shape := asShore;
        Result.ColorRGB := $238B9D;
        Result.Tracks[atWaveStrength] := 16;
        Result.Tracks[atWaveSpeed] := 0.5;
        Result.Tracks[atWaveDetail] := 40;
        Result.Tracks[atFlowSpeed] := 8;
        Result.Tracks[atRippleAmount] := 0;
        Result.Tracks[atReflection] := 35;
        Result.Tracks[atHighlight] := 30;
        Result.Tracks[atFoam] := 90;
        Result.Tracks[atTilt] := 0;
        Result.Tracks[atPerspective] := 0;
      end;
    apFlush:
      begin
        Result.Shape := asFlush;
        Result.ColorRGB := $83C5D2;
        Result.Tracks[atWaveStrength] := 9;
        Result.Tracks[atWaveSpeed] := 0.8;
        Result.Tracks[atWaveDetail] := 55;
        Result.Tracks[atFlowSpeed] := 0;
        Result.Tracks[atRippleAmount] := 0;
        Result.Tracks[atReflection] := 20;
        Result.Tracks[atHighlight] := 25;
        Result.Tracks[atFoam] := 8;
        Result.Tracks[atTilt] := 0;
        Result.Tracks[atPerspective] := 0;
        Result.Tracks[atVortexStrength] := 50;
        Result.Tracks[atVortexSpeed] := 1.4;
        Result.Tracks[atVortexRadius] := 95;
        Result.Tracks[atCornerRoundness] := 65;
        Result.Tracks[atFlushAmount] := 100;
      end;
    apDrain:
      begin
        Result.Shape := asRectangle;
        Result.ColorRGB := $65BECB;
        Result.Tracks[atWaveStrength] := 6;
        Result.Tracks[atWaveSpeed] := 0.55;
        Result.Tracks[atWaveDetail] := 40;
        Result.Tracks[atFlowSpeed] := 0;
        Result.Tracks[atRippleAmount] := 0;
        Result.Tracks[atReflection] := 25;
        Result.Tracks[atHighlight] := 35;
        Result.Tracks[atFoam] := 0;
        Result.Tracks[atTilt] := 0;
        Result.Tracks[atPerspective] := 0;
        Result.Tracks[atVortexStrength] := 75;
        Result.Tracks[atVortexSpeed] := 1.2;
        Result.Tracks[atVortexRadius] := 70;
        Result.Tracks[atVortexDepth] := 90;
        Result.Tracks[atVortexPull] := 95;
        Result.Tracks[atDrainAmount] := 100;
      end;
  end;
end;

end.
