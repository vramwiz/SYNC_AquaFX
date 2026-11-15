unit AquaFX_Renderer;

// Copyright (c) 2026 VRAMの魔術師
// SPDX-License-Identifier: GPL-3.0-only

// 時刻から直接計算する波面。履歴やグローバル乱数に依存しない。
// 波面を作業格子で評価し、出力解像度へ補間してCPU負荷を抑える。

interface

uses
  AviUtl2FilterTypes, AquaFX_Settings, AquaFX_OilSurface;

type
  TAquaPixels = array of TPIXEL_RGBA;
  TAquaSurfaceSample = record
    R, G, B, Mask, DX, DY, Shade, Light: Single;
  end;
  TAquaColumnSample = record
    Left, Right: Integer;
    Fraction: Double;
  end;
  TAquaRenderer = class
  private
    // インスタンス所有の作業格子。同じ描画器の並列呼び出しは呼出側で排他する。
    FGrid: array of TAquaSurfaceSample;
    // 画像・効果のみモードで使う油膜の格子。油膜なしでは確保・評価しない。
    FOilGrid: array of TAquaOilSample;
    FColumns: array of TAquaColumnSample;
  public
    // Inputは借用するストレートRGBA、Timeはオブジェクト先頭からの秒数。
    // Outputは呼出側所有の配列を指定サイズへ更新する。Inputや保存設定は変更しない。
    // ClipToInput=Trueでは投影後の入力アルファ内だけへ描き、無効サイズではOutputを空にする。
    // 「画像に油膜」は入力を移動せず油だけ合成する。透明度は油だけへ適用する。
    procedure Render(const Input: TAquaPixels; Width, Height: Integer;
      Time: Double; const Settings: TAquaSettings; ClipToInput: Boolean;
      var Output: TAquaPixels);
  end;

const
  AQUA_MAX_PIXELS = 16777216;

implementation

uses
  System.Math, AquaFX_Projection;

const
  LUT_SIZE = 8192;
  LUT_MASK = LUT_SIZE - 1;
  TAU = 2 * Pi;

var
  SinTable: array[0..LUT_SIZE - 1] of Single;

function Saturate(Value: Double): Double; inline;
begin
  if Value < 0 then Exit(0);
  if Value > 1 then Exit(1);
  Result := Value;
end;

function FastSin(Phase: Double): Double; inline;
begin
  Result := SinTable[Trunc(Phase * (LUT_SIZE / TAU)) and LUT_MASK];
end;

function Noise(ID: Int64; Salt: Integer; Seed: Double): Double;
var
  Value: Double;
begin
  Value := Sin(ID * 12.9898 + Salt * 78.233 + Seed * 0.153) * 43758.5453;
  Result := Value - Floor(Value);
end;

function ColorByte(Value: Double): Byte; inline;
begin
  Result := Round(Saturate(Value) * 255);
end;

function Lerp(A, B, Weight: Double): Double; inline;
begin
  Result := A + (B - A) * Weight;
end;

function MixSample(const A, B: TAquaSurfaceSample; Weight: Double): TAquaSurfaceSample; inline;
begin
  Result.R := Lerp(A.R, B.R, Weight);
  Result.G := Lerp(A.G, B.G, Weight);
  Result.B := Lerp(A.B, B.B, Weight);
  Result.Mask := Lerp(A.Mask, B.Mask, Weight);
  Result.DX := Lerp(A.DX, B.DX, Weight);
  Result.DY := Lerp(A.DY, B.DY, Weight);
  Result.Shade := Lerp(A.Shade, B.Shade, Weight);
  Result.Light := Lerp(A.Light, B.Light, Weight);
end;

function MixOil(const A, B: TAquaOilSample; Weight: Double): TAquaOilSample; inline;
begin
  Result.R := Lerp(A.R, B.R, Weight); Result.G := Lerp(A.G, B.G, Weight);
  Result.B := Lerp(A.B, B.B, Weight); Result.Alpha := Lerp(A.Alpha, B.Alpha, Weight);
  Result.Shine := Lerp(A.Shine, B.Shine, Weight);
  Result.Shadow := Lerp(A.Shadow, B.Shadow, Weight);
end;

// RGBをアルファで重み付けし、透明画素の色が輪郭へにじむのを防ぐ。
function SampleImage(const Pixels: TAquaPixels; Width, Height: Integer;
  X, Y: Double): TPIXEL_RGBA;
var
  IX, IY, NX, NY, I: Integer;
  FX, FY, Alpha, R, G, B, Weight: Double;
  P: array[0..3] of TPIXEL_RGBA;
  Weights: array[0..3] of Double;
begin
  X := EnsureRange(X, 0.0, Width - 1.0);
  Y := EnsureRange(Y, 0.0, Height - 1.0);
  IX := Trunc(X); IY := Trunc(Y);
  NX := Min(IX + 1, Width - 1); NY := Min(IY + 1, Height - 1);
  FX := X - IX; FY := Y - IY;
  P[0] := Pixels[IY * Width + IX]; P[1] := Pixels[IY * Width + NX];
  P[2] := Pixels[NY * Width + IX]; P[3] := Pixels[NY * Width + NX];
  Weights[0] := (1 - FX) * (1 - FY); Weights[1] := FX * (1 - FY);
  Weights[2] := (1 - FX) * FY; Weights[3] := FX * FY;
  Alpha := 0; R := 0; G := 0; B := 0;
  for I := 0 to 3 do
  begin
    Weight := Weights[I] * P[I].A / 255;
    Alpha := Alpha + Weight;
    R := R + P[I].R * Weight;
    G := G + P[I].G * Weight;
    B := B + P[I].B * Weight;
  end;
  Result := Default(TPIXEL_RGBA);
  if Alpha <= 0 then Exit;
  Result.R := Round(EnsureRange(R / Alpha, 0.0, 255.0));
  Result.G := Round(EnsureRange(G / Alpha, 0.0, 255.0));
  Result.B := Round(EnsureRange(B / Alpha, 0.0, 255.0));
  Result.A := ColorByte(Alpha);
end;

procedure TAquaRenderer.Render(const Input: TAquaPixels; Width, Height: Integer;
  Time: Double; const Settings: TAquaSettings; ClipToInput: Boolean;
  var Output: TAquaPixels);
type
  TWave = record KX, KY, Phase, Amplitude: Double; end;
  TRipple = record X, Y, Radius, Width, Strength, MinD2, MaxD2: Double; end;
  PSurfaceSample = ^TAquaSurfaceSample;
var
  Waves: array[0..5] of TWave;
  Ripples: array[0..5] of TRipple;
  GridW, GridH, Step, GX, GY, X, Y, Index, I, RippleCount: Integer;
  IX, IY, NX, NY, BaseIndex: Integer;
  HasInput, NeedsInputMask, HasOil, KeepOilGrid, IsOilOverlay: Boolean;
  Projection: TAquaProjection;
  OilSurface: TAquaOilSurface;
  OilSample, OilA, OilB: TAquaOilSample;
  P00, P10, P01, P11: PSurfaceSample;
  Seed, T, Viscosity, Strength, Detail, Flow, FlowAngle: Double;
  OffsetU, OffsetV, Opacity, SourceX, SourceY, OverlayAlpha: Double;
  BaseR, BaseG, BaseB, Reflection, Highlight, FoamAmount: Double;
  OilTintR, OilTintG, OilTintB: Double;
  ScreenX, ScreenY, U, V, RotU, RotV, Depth, Mask: Double;
  WaveHeight, GradU, GradV, Phase, CosPhase, Distance, RadiusDelta: Double;
  Envelope, DX, DY, InvNormal, NormalX, NormalY, NormalZ: Double;
  Diffuse, Specular, Sky, Fresnel, Ref, Foam, Light, Shade: Double;
  Scale, Edge, Age, Interval, Life, Speed, FX, FY, GridX, GridY, Alpha: Double;
  EventID: Int64;
  S, RowA, RowB: TAquaSurfaceSample;
  Pixel, SourcePixel: TPIXEL_RGBA;
begin
  if (Width <= 0) or (Height <= 0) or (Width > 8192) or (Height > 8192) or
    (Int64(Width) * Height > AQUA_MAX_PIXELS) then
  begin
    SetLength(Output, 0);
    Exit;
  end;
  HasInput := Length(Input) = Width * Height;
  SetLength(Output, Width * Height);
  IsOilOverlay := Settings.DisplayMode = adOilOverlay;
  if IsOilOverlay and (not HasInput) then
  begin
    FillChar(Output[0], Length(Output) * SizeOf(TPIXEL_RGBA), 0);
    Exit;
  end;
  NeedsInputMask := (ClipToInput or (Settings.DisplayMode = adImage) or
    (Settings.Shape = asImage)) and (not IsOilOverlay);
  Projection := TAquaProjection.Create(Width, Height, Settings, NeedsInputMask);
  Opacity := Saturate(1 - Settings.Tracks[atTransparency] * 0.01);
  if (not Projection.Valid) or (Opacity <= 0) or
    (IsOilOverlay and (Settings.Tracks[atOilAmount] <= 0)) then
  begin
    if IsOilOverlay then Move(Input[0], Output[0], Length(Output) * SizeOf(TPIXEL_RGBA))
    else FillChar(Output[0], Length(Output) * SizeOf(TPIXEL_RGBA), 0);
    Exit;
  end;
  if IsNan(Time) or IsInfinite(Time) then Time := 0;
  T := EnsureRange(Time, -1.0E9, 1.0E9);
  Seed := Settings.Tracks[atSeed];
  Viscosity := Settings.Tracks[atViscosity] * 0.01;
  Strength := Settings.Tracks[atWaveStrength] * 0.01;
  Detail := 0.6 + Settings.Tracks[atWaveDetail] * 0.025;
  Speed := Settings.Tracks[atWaveSpeed] / (1 + Viscosity * 2.5);
  Flow := Settings.Tracks[atFlowSpeed] * 0.012 / (1 + Viscosity * 2);
  FlowAngle := DegToRad(Settings.Tracks[atFlowDirection]);
  OffsetU := T * Flow * Cos(FlowAngle);
  OffsetV := T * Flow * Sin(FlowAngle);
  HasOil := Settings.Tracks[atOilAmount] > 0;
  KeepOilGrid := HasOil and (Settings.DisplayMode <> adBackground);
  if HasOil then OilSurface := TAquaOilSurface.Create(Settings, T, OffsetU, OffsetV);
  Reflection := Settings.Tracks[atReflection] * 0.01;
  Highlight := Settings.Tracks[atHighlight] * 0.01;
  FoamAmount := Settings.Tracks[atFoam] * 0.01;
  BaseR := ((Settings.ColorRGB shr 16) and $FF) / 255;
  BaseG := ((Settings.ColorRGB shr 8) and $FF) / 255;
  BaseB := (Settings.ColorRGB and $FF) / 255;
  OilTintR := ((Settings.OilColorRGB shr 16) and $FF) / 255;
  OilTintG := ((Settings.OilColorRGB shr 8) and $FF) / 255;
  OilTintB := (Settings.OilColorRGB and $FF) / 255;
  for I := 0 to High(Waves) do
  begin
    Phase := 0.3 + I * 1.37 + Noise(I, 3, Seed) * 0.8;
    Scale := Detail * Power(1.75, I);
    Waves[I].KX := Cos(Phase) * Scale;
    Waves[I].KY := (0.6 + Abs(Sin(Phase))) * Scale;
    Waves[I].Phase := Noise(I, 5, Seed) * TAU - T * Speed * Sqrt(Scale) * 1.3;
    Waves[I].Amplitude := Strength * 0.32 / Power(1.85, I);
  end;

  RippleCount := Min(Length(Ripples), Ceil(Settings.Tracks[atRippleAmount] * 0.06));
  Life := 3.5 + Settings.Tracks[atRippleSize] * 0.025;
  Interval := Life / Max(1, RippleCount);
  EventID := Floor(T / Interval);
  for I := 0 to RippleCount - 1 do
  begin
    Age := T - (EventID - I) * Interval;
    Ripples[I].X := (Noise(EventID - I, 1, Seed) - 0.5) * 1.8;
    Ripples[I].Y := (Noise(EventID - I, 2, Seed) - 0.5) * 1.8;
    if Settings.Shape = asPlane then
    begin
      Ripples[I].X := Ripples[I].X * 2.5;
      Ripples[I].Y := Ripples[I].Y * 2.5;
    end;
    Ripples[I].Radius := Age * Settings.Tracks[atRippleSpeed] *
      (0.2 + Settings.Tracks[atRippleSize] * 0.008) / (1 + Viscosity * 2);
    Ripples[I].Width := 0.12 + Settings.Tracks[atRippleSize] * 0.003;
    Ripples[I].MinD2 := Sqr(Max(0.0, Ripples[I].Radius - Ripples[I].Width));
    Ripples[I].MaxD2 := Sqr(Ripples[I].Radius + Ripples[I].Width);
    Ripples[I].Strength := Sqr(Saturate(1 - Age / Life)) *
      Settings.Tracks[atRippleAmount] * 0.006 / (1 + Viscosity);
  end;

  Step := Max(1, Ceil(Sqrt(Width * Height / 1100000.0)));
  GridW := Max(2, (Width + Step - 1) div Step);
  GridH := Max(2, (Height + Step - 1) div Step);
  SetLength(FGrid, GridW * GridH);
  SetLength(FColumns, Width);
  for X := 0 to Width - 1 do
  begin
    GridX := X * (GridW - 1) / Max(1, Width - 1);
    FColumns[X].Left := Trunc(GridX);
    FColumns[X].Right := Min(FColumns[X].Left + 1, GridW - 1);
    FColumns[X].Fraction := GridX - FColumns[X].Left;
  end;
  if KeepOilGrid then SetLength(FOilGrid, GridW * GridH) else SetLength(FOilGrid, 0);
  Edge := 3 / Min(Width, Height);
  for GY := 0 to GridH - 1 do
  begin
    ScreenY := GY * (Height - 1) / (GridH - 1) + 0.5;
    for GX := 0 to GridW - 1 do
    begin
      S := Default(TAquaSurfaceSample);
      if KeepOilGrid then FOilGrid[GY * GridW + GX] := Default(TAquaOilSample);
      ScreenX := GX * (Width - 1) / (GridW - 1) + 0.5;
      if not Projection.ScreenToSurface(ScreenX, ScreenY, RotU, RotV) then
      begin
        FGrid[GY * GridW + GX] := S;
        Continue;
      end;
      Depth := Saturate(1.5 - Projection.DepthAt(RotU, RotV) * 0.5);
      Mask := 1;
      if Settings.Shape = asRectangle then
        Mask := Saturate((1 - Max(Abs(RotU), Abs(RotV))) / Edge + 0.5)
      else if Settings.Shape = asEllipse then
        Mask := Saturate((1 - Sqrt(Sqr(RotU) + Sqr(RotV))) / Edge + 0.5);
      if Mask > 0 then
      begin
        // 形状で波の倍率を変えず、「魔法液体」と同じ基準で模様を生成する。
        U := RotU - OffsetU; V := RotV - OffsetV;
        WaveHeight := 0; GradU := 0; GradV := 0;
        for I := 0 to High(Waves) do
        begin
          Phase := U * Waves[I].KX + V * Waves[I].KY + Waves[I].Phase;
          CosPhase := FastSin(Phase + Pi * 0.5) * Waves[I].Amplitude;
          WaveHeight := WaveHeight + FastSin(Phase) * Waves[I].Amplitude;
          GradU := GradU + CosPhase * Waves[I].KX;
          GradV := GradV + CosPhase * Waves[I].KY;
        end;
        for I := 0 to RippleCount - 1 do
        begin
          DX := RotU - Ripples[I].X; DY := RotV - Ripples[I].Y;
          Distance := DX * DX + DY * DY;
          // 波紋の細い帯以外は平方根と三角関数を省略する。
          if (Distance < Ripples[I].MinD2) or (Distance > Ripples[I].MaxD2) then Continue;
          Distance := Sqrt(Distance);
          RadiusDelta := Distance - Ripples[I].Radius;
          Envelope := Saturate(1 - Abs(RadiusDelta) / Ripples[I].Width);
          if (Envelope > 0) and (Distance > 0.0001) then
          begin
            Scale := 12 / Ripples[I].Width;
            CosPhase := FastSin(RadiusDelta * Scale + Pi * 0.5) *
              Sqr(Envelope) * Ripples[I].Strength;
            GradU := GradU + CosPhase * DX / Distance;
            GradV := GradV + CosPhase * DY / Distance;
          end;
        end;
        InvNormal := 1 / Sqrt(1 + GradU * GradU + GradV * GradV);
        NormalX := -GradU * InvNormal; NormalY := -GradV * InvNormal;
        NormalZ := InvNormal;
        Diffuse := Saturate(NormalX * -0.3 + NormalY * -0.4 + NormalZ * 0.86);
        Specular := Saturate(NormalX * -0.18 + NormalY * -0.36 + NormalZ * 0.915);
        Specular := Sqr(Sqr(Sqr(Sqr(Specular))));
        Specular := Sqr(Specular) * Highlight * 0.85;
        Sky := 0.65 + 0.35 * FastSin(GradV * 2.5 + U * 0.35 + V * 0.7);
        Fresnel := 0.08 + Sqr(1 - Depth) * 0.5;
        Ref := Reflection * Fresnel * (0.4 + 0.6 * Sky);
        Foam := Saturate((WaveHeight * 1.6 + (1 - NormalZ) * 0.8 - 0.3) * 2) * FoamAmount;
        Shade := 0.55 + Diffuse * 0.55 + WaveHeight * 0.12;
        Light := Saturate(Specular + Foam * 0.9);
        S.R := Saturate(Lerp(BaseR * Shade, 0.62, Ref) + Light);
        S.G := Saturate(Lerp(BaseG * Shade, 0.82, Ref) + Light);
        S.B := Saturate(Lerp(BaseB * Shade, 0.94, Ref) + Light);
        S.Mask := Mask;
        S.DX := GradU * 9 * Width / 1280;
        S.DY := GradV * 9 * Height / 720;
        S.Shade := Shade;
        S.Light := Light;
        if HasOil then
        begin
          OilSample := OilSurface.Sample(RotU, RotV, GradU, GradV, Light);
          if KeepOilGrid then FOilGrid[GY * GridW + GX] := OilSample;
          S.R := Lerp(S.R, OilSample.R, OilSample.Alpha);
          S.G := Lerp(S.G, OilSample.G, OilSample.Alpha);
          S.B := Lerp(S.B, OilSample.B, OilSample.Alpha);
        end;
      end;
      FGrid[GY * GridW + GX] := S;
    end;
  end;

  for Y := 0 to Height - 1 do
  begin
    GridY := Y * (GridH - 1) / Max(1, Height - 1);
    IY := Trunc(GridY); NY := Min(IY + 1, GridH - 1); FY := GridY - IY;
    BaseIndex := Y * Width;
    for X := 0 to Width - 1 do
    begin
      Index := BaseIndex + X;
      Pixel := Default(TPIXEL_RGBA);
      SourcePixel := Default(TPIXEL_RGBA);
      if IsOilOverlay then
      begin
        Pixel := Input[Index];
        if Pixel.A = 0 then
        begin
          Output[Index] := Pixel;
          Continue;
        end;
      end;
      if NeedsInputMask then
      begin
        if (not HasInput) or (not Projection.ScreenToSurface(X + 0.5, Y + 0.5, U, V)) or
          (Abs(U) > 1) or (Abs(V) > 1) then
        begin
          Output[Index] := Pixel;
          Continue;
        end;
        SourceX := (U + 1) * Width * 0.5 - 0.5;
        SourceY := (V + 1) * Height * 0.5 - 0.5;
        SourcePixel := SampleImage(Input, Width, Height, SourceX, SourceY);
        if SourcePixel.A = 0 then
        begin
          Output[Index] := Pixel;
          Continue;
        end;
      end;
      IX := FColumns[X].Left; NX := FColumns[X].Right; FX := FColumns[X].Fraction;
      if (GridW = Width) and (GridH = Height) then S := FGrid[Index]
      else if Settings.DisplayMode = adBackground then
      begin
        // 背景ありでは未使用の画像変形・光沢成分まで補間しない。
        P00 := @FGrid[IY * GridW + IX]; P10 := @FGrid[IY * GridW + NX];
        P01 := @FGrid[NY * GridW + IX]; P11 := @FGrid[NY * GridW + NX];
        S.R := Lerp(Lerp(P00^.R, P10^.R, FX), Lerp(P01^.R, P11^.R, FX), FY);
        S.G := Lerp(Lerp(P00^.G, P10^.G, FX), Lerp(P01^.G, P11^.G, FX), FY);
        S.B := Lerp(Lerp(P00^.B, P10^.B, FX), Lerp(P01^.B, P11^.B, FX), FY);
        S.Mask := Lerp(Lerp(P00^.Mask, P10^.Mask, FX), Lerp(P01^.Mask, P11^.Mask, FX), FY);
      end else
      begin
        RowA := MixSample(FGrid[IY * GridW + IX], FGrid[IY * GridW + NX], FX);
        RowB := MixSample(FGrid[NY * GridW + IX], FGrid[NY * GridW + NX], FX);
        S := MixSample(RowA, RowB, FY);
      end;
      OilSample := Default(TAquaOilSample);
      if KeepOilGrid then
      begin
        OilA := MixOil(FOilGrid[IY * GridW + IX], FOilGrid[IY * GridW + NX], FX);
        OilB := MixOil(FOilGrid[NY * GridW + IX], FOilGrid[NY * GridW + NX], FX);
        OilSample := MixOil(OilA, OilB, FY);
      end;
      Alpha := S.Mask * Opacity;
      if NeedsInputMask then Alpha := Alpha * SourcePixel.A / 255;
      if IsOilOverlay then
      begin
        // 元画像の位置・色・アルファは油膜のない場所ではそのまま維持する。
        OverlayAlpha := S.Mask * Opacity * OilSample.Alpha;
        // 色は薄く乗せ、膜の縁と照りを別に合成して麺や具材の質感を残す。
        Pixel.R := ColorByte(Lerp(Pixel.R / 255, OilTintR, OverlayAlpha * 0.16) *
          (1 - OilSample.Shadow * OverlayAlpha) + OilSample.Shine * OverlayAlpha * 0.9);
        Pixel.G := ColorByte(Lerp(Pixel.G / 255, OilTintG, OverlayAlpha * 0.16) *
          (1 - OilSample.Shadow * OverlayAlpha) + OilSample.Shine * OverlayAlpha * 0.88);
        Pixel.B := ColorByte(Lerp(Pixel.B / 255, OilTintB, OverlayAlpha * 0.16) *
          (1 - OilSample.Shadow * OverlayAlpha) + OilSample.Shine * OverlayAlpha * 0.8);
        Alpha := Pixel.A / 255;
      end else if Settings.DisplayMode = adEffectsOnly then
      begin
        OverlayAlpha := S.Light * (1 - OilSample.Alpha) + OilSample.Alpha;
        Alpha := Alpha * OverlayAlpha;
        if OverlayAlpha > 0 then
        begin
          Pixel.R := ColorByte((220 / 255 * S.Light * (1 - OilSample.Alpha) + OilSample.R * OilSample.Alpha) / OverlayAlpha);
          Pixel.G := ColorByte((240 / 255 * S.Light * (1 - OilSample.Alpha) + OilSample.G * OilSample.Alpha) / OverlayAlpha);
          Pixel.B := ColorByte((S.Light * (1 - OilSample.Alpha) + OilSample.B * OilSample.Alpha) / OverlayAlpha);
        end;
      end else if Settings.DisplayMode = adImage then
      begin
        Pixel := SampleImage(Input, Width, Height, SourceX + S.DX, SourceY + S.DY);
        Alpha := S.Mask * Opacity * Min(Pixel.A, SourcePixel.A) / 255;
        Pixel.R := ColorByte(Lerp(Saturate(Pixel.R / 255 * S.Shade + S.Light), OilSample.R, OilSample.Alpha));
        Pixel.G := ColorByte(Lerp(Saturate(Pixel.G / 255 * S.Shade + S.Light), OilSample.G, OilSample.Alpha));
        Pixel.B := ColorByte(Lerp(Saturate(Pixel.B / 255 * S.Shade + S.Light), OilSample.B, OilSample.Alpha));
      end else
      begin
        Pixel.R := ColorByte(S.R); Pixel.G := ColorByte(S.G); Pixel.B := ColorByte(S.B);
      end;
      Pixel.A := ColorByte(Alpha);
      if Pixel.A = 0 then Pixel := Default(TPIXEL_RGBA);
      Output[Index] := Pixel;
    end;
  end;
end;

procedure InitializeSinTable;
var
  I: Integer;
begin
  for I := 0 to High(SinTable) do SinTable[I] := Sin(I * TAU / LUT_SIZE);
end;

initialization
  InitializeSinTable;

end.
