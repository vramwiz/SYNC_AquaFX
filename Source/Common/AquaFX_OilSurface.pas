unit AquaFX_OilSurface;

// Copyright (c) 2026 VRAMの魔術師
// SPDX-License-Identifier: GPL-3.0-only

// 下地から分離した浮遊油膜を、連続した模様・縁の明暗・暖色の光沢で描く。
// 時刻とシードから直接評価し、乱数状態や前フレームを保持しない。

interface

uses
  AquaFX_Settings;

type
  TAquaOilSample = record
    R, G, B, Alpha: Single; // ストレートRGBと油膜の被覆率。すべて0～1。
    Shine, Shadow: Single; // 元画像へ色を塗り込まず合成するための照りと縁の陰。
  end;
  TAquaOilSurface = record
  private
    FAmount, FScale, FGloss, FOffsetX, FOffsetY, FTime, FSeedX, FSeedY: Double;
    FR, FG, FB: Double;
  public
    // 設定と秒単位の時刻を値として保持する。ホストや保存設定は変更しない。
    class function Create(const Settings: TAquaSettings; Time, FlowU, FlowV: Double): TAquaOilSurface; static;
    // 水面の局所座標と波の傾きから、その場所の油膜色・被覆率を返す。
    function Sample(U, V, GradU, GradV, Highlight: Double): TAquaOilSample;
  end;

implementation

uses
  System.Math;

const
  NOISE_SIZE = 128;
  NOISE_MASK = NOISE_SIZE - 1;

var
  // DLL初期化時に生成し、その後は全描画器から読み取り専用で共有する。
  NoiseTable: array[0..NOISE_SIZE - 1, 0..NOISE_SIZE - 1] of Single;

function Clamp(Value: Double): Double; inline;
begin
  if Value < 0 then Exit(0);
  if Value > 1 then Exit(1);
  Result := Value;
end;

function SmoothStep(Low, High, Value: Double): Double; inline;
begin
  Result := Clamp((Value - Low) / (High - Low));
  Result := Result * Result * (3 - 2 * Result);
end;

function SmoothNoise(X, Y: Double; out DX, DY: Double): Double;
var
  IX, IY, NX, NY: Integer;
  FloorX, FloorY: Int64;
  FX, FY, SX, SY, A, B, C, D, AB, CD: Double;
begin
  FloorX := Floor(X); FloorY := Floor(Y);
  FX := X - FloorX; FY := Y - FloorY;
  IX := FloorX and NOISE_MASK; IY := FloorY and NOISE_MASK;
  NX := (IX + 1) and NOISE_MASK; NY := (IY + 1) and NOISE_MASK;
  A := NoiseTable[IY, IX]; B := NoiseTable[IY, NX];
  C := NoiseTable[NY, IX]; D := NoiseTable[NY, NX];
  SX := FX * FX * (3 - 2 * FX); SY := FY * FY * (3 - 2 * FY);
  AB := A + (B - A) * SX; CD := C + (D - C) * SX;
  Result := AB + (CD - AB) * SY;
  DX := 6 * FX * (1 - FX) * ((B - A) + ((D - C) - (B - A)) * SY);
  DY := 6 * FY * (1 - FY) * (CD - AB);
end;

class function TAquaOilSurface.Create(const Settings: TAquaSettings;
  Time, FlowU, FlowV: Double): TAquaOilSurface;
begin
  Result := Default(TAquaOilSurface);
  Result.FAmount := Settings.Tracks[atOilAmount] * 0.01;
  Result.FScale := 1.3 + (100 - Settings.Tracks[atOilSize]) * 0.055;
  Result.FGloss := Settings.Tracks[atOilGloss] * 0.01;
  Result.FTime := Time * 0.06 / (1 + Settings.Tracks[atViscosity] * 0.02);
  Result.FOffsetX := FlowU * 0.7 + Sin(Result.FTime) * 0.14;
  Result.FOffsetY := FlowV * 0.7 + Cos(Result.FTime * 0.83) * 0.12;
  Result.FSeedX := Round(Settings.Tracks[atSeed]) and NOISE_MASK;
  Result.FSeedY := (Round(Settings.Tracks[atSeed]) shr 7) and NOISE_MASK;
  Result.FR := ((Settings.OilColorRGB shr 16) and $FF) / 255;
  Result.FG := ((Settings.OilColorRGB shr 8) and $FF) / 255;
  Result.FB := (Settings.OilColorRGB and $FF) / 255;
end;

function TAquaOilSurface.Sample(U, V, GradU, GradV, Highlight: Double): TAquaOilSample;
var
  X, Y, N1, N2, DX1, DY1, DX2, DY2, Field, Threshold, Cover: Double;
  Edge, Direction, EdgeLight, EdgeShade, Thickness, Shine, Shade: Double;
  OilDX, OilDY, InvNormal, Specular: Double;
begin
  Result := Default(TAquaOilSample);
  if FAmount <= 0 then Exit;
  X := (U - FOffsetX) * FScale + FSeedX + GradU * 0.08;
  Y := (V - FOffsetY) * FScale + FSeedY + GradV * 0.08;
  N1 := SmoothNoise(X, Y, DX1, DY1);
  N2 := SmoothNoise(X * 2.7 + 37 - FTime * 0.4, Y * 2.7 + 19 + FTime * 0.3, DX2, DY2);
  Field := N1 * 0.78 + N2 * 0.22;
  Threshold := 0.84 - FAmount * 0.6;
  Cover := SmoothStep(Threshold - 0.02, Threshold + 0.02, Field);
  if Cover <= 0 then Exit;
  Edge := 1 - SmoothStep(0.012, 0.06, Abs(Field - Threshold));
  Direction := (DX1 * 0.78 + DX2 * 0.22 * 2.7) * -0.6 +
    (DY1 * 0.78 + DY2 * 0.22 * 2.7) * -0.8;
  EdgeLight := Edge * (0.12 + Clamp(Direction) * 0.8);
  EdgeShade := Edge * Clamp(-Direction) * 0.45;
  Thickness := Clamp((Field - Threshold) * 2);
  // 膜の縁の盛り上がりを法線へ加え、黄色同士でも暗い縁と白い照りを出す。
  OilDX := GradU * 0.35 + (DX1 * 0.78 + DX2 * 0.594) * (0.08 + Edge * 0.9);
  OilDY := GradV * 0.35 + (DY1 * 0.78 + DY2 * 0.594) * (0.08 + Edge * 0.9);
  InvNormal := 1 / Sqrt(1 + Sqr(OilDX) + Sqr(OilDY));
  Specular := Clamp((OilDX * 0.24 + OilDY * 0.32 + 0.916515) * InvNormal);
  Specular := Sqr(Sqr(Sqr(Sqr(Specular))));
  Specular := Sqr(Specular) * (0.7 + N2 * 0.3);
  Shine := (EdgeLight * 0.9 + Specular * 0.9 + Highlight * 0.18) * FGloss;
  Shade := 0.9 + Thickness * 0.12 - EdgeShade;
  Result.R := Clamp(FR * Shade + Shine);
  Result.G := Clamp(FG * Shade + Shine * 0.98);
  Result.B := Clamp(FB * Shade + Shine * 0.88);
  Result.Alpha := Cover * (0.22 + FGloss * 0.4);
  Result.Shine := Clamp(Shine);
  Result.Shadow := EdgeShade;
end;

procedure InitializeTables;
var
  X, Y: Integer;
  State: Cardinal;
begin
  State := $6D2B79F5;
  for Y := 0 to NOISE_SIZE - 1 do
    for X := 0 to NOISE_SIZE - 1 do
    begin
      State := State xor (State shl 13);
      State := State xor (State shr 17);
      State := State xor (State shl 5);
      NoiseTable[Y, X] := (State and $FFFF) / 65535;
    end;
end;

initialization
  InitializeTables;

end.
