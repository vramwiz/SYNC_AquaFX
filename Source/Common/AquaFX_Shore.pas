unit AquaFX_Shore;

// Copyright (c) 2026 VRAMの魔術師
// SPDX-License-Identifier: GPL-3.0-only

// 平面の水際・薄い海水・取り残された泡を、時刻とシードから直接評価する。
// 入力画像やホストのポインターを保持せず、逆シークでも履歴に依存しない。

interface

uses
  AquaFX_Settings;

type
  TAquaShoreColumn = record
    U, Front, Peak, Phase, BreakerOffset: Double;
  end;

  TAquaShoreSample = record
    Water, Foam, Wet, Depth: Double;
    // 水面色へ水際の透明度と泡を重ね、ストレートRGBと合成アルファを返す。
    // EffectsOnlyでは海水と濡れた砂の色を除き、泡だけを返す。
    procedure Composite(var R, G, B, Mask, Light: Single; EffectsOnly: Boolean);
    // 海水・泡・濡れ色を重ねた0～1の被覆率。保存値や画素は変更しない。
    function Coverage: Double;
  end;

  TAquaShore = record
  private
    FCycle, FReach, FRoughness, FWaterOpacity, FFoam, FPersistence: Double;
    FSeed, FDriftX, FDriftY, FTravel: Double;
  public
    // 保存設定を値として借用し、このフレームだけで有効な評価器を返す。
    class function Create(const Settings: TAquaSettings; Time: Double): TAquaShore; static;
    // 岸に沿うUから、このフレームの水際位置と位相を返す。
    // 同じUの列内で再利用できる。次のフレームへ持ち越さない。
    function PrepareColumn(U: Double): TAquaShoreColumn;
    // Vの正方向が砂浜側。Edgeはアンチエイリアス幅、Columnは同じUの評価値。
    // 位置・回転・拡縮は呼出側の共通投影を使用し、RGBAの成分を返す。
    function Sample(U, V, Edge: Double; const Column: TAquaShoreColumn): TAquaShoreSample;
  end;

implementation

uses
  System.Math;

function Clamp01(X: Double): Double; inline;
begin
  Result := Max(0.0, Min(1.0, X));
end;

function Smooth(A, B, X: Double): Double; inline;
begin
  Result := Clamp01((X - A) / (B - A));
  Result := Result * Result * (3 - 2 * Result);
end;

// 整数ハッシュだけは意図的に32ビットを循環させる。他の描画は検査設定を維持する。
{$IFOPT Q+}{$DEFINE SHORE_RESTORE_Q}{$Q-}{$ENDIF}
{$IFOPT R+}{$DEFINE SHORE_RESTORE_R}{$R-}{$ENDIF}
function Hash(X, Y: Integer): Double; inline;
var
  H: Cardinal;
begin
  H := Cardinal(X) * $9E3779B1 xor Cardinal(Y) * $85EBCA77;
  H := (H xor (H shr 16)) * $7FEB352D;
  H := (H xor (H shr 15)) * $846CA68B;
  H := H xor (H shr 16);
  Result := H / 4294967295.0;
end;
{$IFDEF SHORE_RESTORE_Q}{$Q+}{$UNDEF SHORE_RESTORE_Q}{$ENDIF}
{$IFDEF SHORE_RESTORE_R}{$R+}{$UNDEF SHORE_RESTORE_R}{$ENDIF}

function Noise(X, Y: Double): Double;
var
  IX, IY: Integer;
  FX, FY, A, B: Double;
begin
  IX := Floor(X); IY := Floor(Y);
  FX := X - IX; FY := Y - IY;
  FX := FX * FX * (3 - 2 * FX); FY := FY * FY * (3 - 2 * FY);
  A := Hash(IX, IY); A := A + (Hash(IX + 1, IY) - A) * FX;
  B := Hash(IX, IY + 1); B := B + (Hash(IX + 1, IY + 1) - B) * FX;
  Result := A + (B - A) * FY;
end;

function TAquaShoreSample.Coverage: Double;
begin
  Result := 1 - (1 - Water) * (1 - Foam) * (1 - Wet);
end;

procedure TAquaShoreSample.Composite(var R, G, B, Mask, Light: Single;
  EffectsOnly: Boolean);
var
  A, WR, WG, WB, WaterWeight, FoamWeight, WetWeight: Double;
begin
  if EffectsOnly then
  begin
    R := 0.94; G := 0.98; B := 0.97;
    Mask := Foam; Light := 1;
    Exit;
  end;
  A := Coverage;
  if A <= 0 then begin Mask := 0; Exit; end;
  // 浅瀬ほど明るく透ける。白い泡は海水の透明度から独立させる。
  WR := R * (0.82 + Depth * 0.18) + (1 - Depth) * 0.10;
  WG := G * (0.88 + Depth * 0.12) + (1 - Depth) * 0.16;
  WB := B * (0.90 + Depth * 0.10) + (1 - Depth) * 0.13;
  WetWeight := Wet * (1 - Water) * (1 - Foam);
  WaterWeight := Water * (1 - Foam);
  FoamWeight := Foam;
  R := (0.22 * WetWeight + WR * WaterWeight + 0.94 * FoamWeight) / A;
  G := (0.20 * WetWeight + WG * WaterWeight + 0.98 * FoamWeight) / A;
  B := (0.16 * WetWeight + WB * WaterWeight + 0.97 * FoamWeight) / A;
  Mask := A;
  Light := Max(Light, Foam);
end;

class function TAquaShore.Create(const Settings: TAquaSettings;
  Time: Double): TAquaShore;
begin
  Result := Default(TAquaShore);
  Result.FCycle := Time / Max(0.5, Settings.Tracks[atShorePeriod]);
  Result.FReach := Settings.Tracks[atShoreReach] * 0.01;
  Result.FRoughness := Settings.Tracks[atShoreRoughness] * 0.01;
  Result.FWaterOpacity := Settings.Tracks[atShoreWaterOpacity] * 0.01;
  Result.FFoam := Settings.Tracks[atFoam] * 0.01;
  Result.FPersistence := Settings.Tracks[atShoreFoamLife] * 0.01;
  Result.FSeed := Settings.Tracks[atSeed] * 0.0137;
  Result.FDriftX := Sin(Time * 0.31) * 0.8;
  Result.FDriftY := Sin(Time * 0.23) * 0.6;
  Result.FTravel := Frac(Time / 9) * 2 * Pi;
end;

function TAquaShore.PrepareColumn(U: Double): TAquaShoreColumn;
var
  P, Rise, Ragged, Offset, Motion: Double;
begin
  Result.U := U;
  Offset := (Sin(U * 1.8 + FSeed) * 0.055 +
    Sin(U * 4.7 - FSeed * 0.7) * 0.024) * FRoughness;
  P := FCycle + Offset; P := P - Floor(P);
  // 寄せる時間を短く、引く時間を長くする。最大到達点では滑らかに減速する。
  if P < 0.36 then Rise := 0.5 - 0.5 * Cos(P / 0.36 * Pi)
  else Rise := 0.5 + 0.5 * Cos((P - 0.36) / 0.64 * Pi);
  Motion := Min(1.0, FReach * 5);
  Ragged := FRoughness * (0.095 * Sin(U * 3.2 + FSeed) +
    0.044 * Sin(U * 8.9 - FSeed) + 0.018 * Sin(U * 23.3 + Rise * 2.5 * Motion));
  Result.Front := 0.08 + (Rise * 2 - 1) * FReach + Ragged;
  // 残る泡の上限は実際の最大到達点に固定する。引き波の現在形状で動かさない。
  Result.Peak := 0.08 + FReach + FRoughness *
    (0.095 * Sin(U * 3.2 + FSeed) + 0.044 * Sin(U * 8.9 - FSeed) +
     0.018 * Sin(U * 23.3 + 2.5 * Motion)) + FRoughness * 0.018 *
    Sin(U * 51 + Sin(U * 17 + FSeed) * 2 + 4 * Motion);
  // 細かな舌状の先端を、岸の大きな輪郭に重ねる。
  Result.Front := Result.Front + FRoughness * 0.018 *
    Sin(U * 51 + Sin(U * 17 + FSeed) * 2 + Rise * 4 * Motion);
  Result.Phase := P;
  Result.BreakerOffset := Sin(U * 2.7 + FSeed) * 0.42;
end;

function TAquaShore.Sample(U, V, Edge: Double;
  const Column: TAquaShoreColumn): TAquaShoreSample;
var
  D, Grain, Cells, Lace, Band, Tip, Trail, Recede, FoamWidth, Wake, Crest: Double;
  Departed, Vacated: Double;
begin
  Result := Default(TAquaShoreSample);
  D := Column.Front - V;
  Result.Depth := Smooth(0, 0.95, D);
  Result.Water := Smooth(-Edge, Edge, D) * FWaterOpacity *
    (0.10 + 0.90 * Smooth(0, 0.65, Max(0.0, D)));
  if (D > 0.55) or (V > Column.Peak + 0.05) then Exit;
  if (FFoam <= 0) and ((Column.Phase <= 0.36) or (FPersistence <= 0)) then Exit;
  Grain := Noise(U * 65 + FSeed + FDriftX, V * 85 + FDriftY);
  Cells := Noise(U * 23 - FDriftX, V * 37 + FSeed - FDriftY);
  Lace := Smooth(0.62, 0.91, 1 - Abs(Cells * 2 - 1));
  Lace := Lace * (0.25 + 0.75 * Smooth(0.25, 0.75, Grain));
  FoamWidth := 0.065 + FRoughness * 0.045;
  Band := Smooth(-Edge, 0.012, D) * (1 - Smooth(0.015, FoamWidth, D));
  Tip := (1 - Smooth(Edge, Edge * 3 + 0.006, Abs(D))) *
    (0.40 + 0.60 * Smooth(0.25, 0.70, Grain));
  Result.Foam := FFoam * Clamp01(Tip * 0.90 + Band * Lace * 0.90);
  if (Column.Phase > 0.36) and (FPersistence > 0) then
  begin
    Recede := (Column.Phase - 0.36) / 0.64;
    // 位相の分岐だけで広い泡を出すと、列ごとの時差が縦の切れ目になる。
    // 水際が最大到達点を離れ、実際に水が引いた場所だけへ連続的に残す。
    Departed := Smooth(0, Max(Edge * 4, 0.04), Column.Peak - Column.Front);
    Vacated := Smooth(-Edge, Max(Edge * 2, 0.02), V - Column.Front);
    Wake := Smooth(-Edge, 0.025, Column.Peak - V) *
      (1 - Smooth(0.16, 0.55, Column.Peak - V)) * Departed * Vacated;
    Trail := Wake * (1 - Smooth(0, 0.25 + FPersistence * 0.70, Recede));
    Result.Wet := Trail * 0.18 * FPersistence * FWaterOpacity;
    Result.Foam := Max(Result.Foam, Trail * Lace * FFoam * FPersistence * 0.70);
  end;
  // 先端の少し沖にも、岸へ向かう途切れた砕波を重ねる。
  Crest := (V * 17 - FTravel + Column.BreakerOffset) / (2 * Pi);
  Crest := Abs(Crest - Floor(Crest) - 0.25);
  Result.Foam := Max(Result.Foam, (1 - Smooth(0.025, 0.07, Crest)) * Lace *
    Smooth(0.12, 0.25, D) * (1 - Smooth(0.35, 0.55, D)) * FFoam * 0.30);
end;

end.
