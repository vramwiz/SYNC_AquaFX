unit AquaFX_Renderer;

// Copyright (c) 2026 VRAMの魔術師
// SPDX-License-Identifier: GPL-3.0-only

// 時刻から直接計算する波面。履歴やグローバル乱数に依存しない。
// 波面を作業格子で評価し、出力解像度へ補間してCPU負荷を抑える。

interface

uses
  System.Threading, AviUtl2FilterTypes, AquaFX_Settings, AquaFX_OilSurface, AquaFX_Projection,
  AquaFX_Shore, AquaFX_VortexSurface
  {$IFDEF DEBUG}, AquaFX_Profiling{$ENDIF};

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
    // 水平な海岸では同じUの岸形状を列内で再利用する。内容は各フレームで失効する。
    FShoreColumns: array of TAquaShoreColumn;
    FWavePool: TThreadPool;
    {$IFDEF DEBUG}
    FLastProfile: TAquaRenderProfile;
    {$ENDIF}
    function SurfaceBounds(Width, Height, GridW, GridH: Integer;
      out Left, Top, Right, Bottom: Integer): Boolean;
    // 入力を一度コピーし、油膜に必要な4成分だけを有効範囲で補間する。
    procedure CompositeOilOverlay(const Input: TAquaPixels;
      Width, Height, GridW, GridH: Integer; Opacity, TintR, TintG, TintB: Double;
      var Output: TAquaPixels);
    // 液面内の変形と光沢を元画像へ合成する。カップ等の範囲外と元アルファは保つ。
    procedure CompositeImageWaves(const Input: TAquaPixels;
      Width, Height, GridW, GridH: Integer; Opacity, Shading: Double; var Output: TAquaPixels);
    // 生成した水面の色とアルファだけを合成する。画像色の再サンプリングは不要。
    procedure CompositeBackground(const Input: TAquaPixels;
      Width, Height, GridW, GridH: Integer; Opacity: Double;
      const Projection: TAquaProjection; NeedsInputMask: Boolean; var Output: TAquaPixels);
  public
    // 大きな液面で必要になったワーカーを所有し、SDKの破棄通知中に回収する。
    destructor Destroy; override;
    {$IFDEF DEBUG}
    property LastProfile: TAquaRenderProfile read FLastProfile;
    {$ENDIF}
    // Inputは借用するストレートRGBA、Timeはオブジェクト先頭からの秒数。
    // Outputは呼出側所有の配列を指定サイズへ更新する。Inputや保存設定は変更しない。
    // ClipToInput=Trueでは投影後の入力アルファ内だけへ描き、無効サイズではOutputを空にする。
    // 「画像に油膜」は入力を移動せず油だけ合成する。透明度は油だけへ適用する。
    // TimelineProgressはオブジェクト先頭0～最終フレーム1。排水だけに使用する。
    procedure Render(const Input: TAquaPixels; Width, Height: Integer;
      Time: Double; const Settings: TAquaSettings; ClipToInput: Boolean;
      var Output: TAquaPixels; TimelineProgress: Double = 0);
  end;

const
  AQUA_MAX_PIXELS = 16777216;

implementation

uses
  System.Math, System.Classes, System.SysUtils, AquaFX_Flow;

const
  LUT_SIZE = 8192;
  LUT_MASK = LUT_SIZE - 1;
  TAU = 2 * Pi;

var
  SinTable: array[0..LUT_SIZE - 1] of Single;

destructor TAquaRenderer.Destroy;
begin
  FWavePool.Free;
  inherited;
end;

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

// 従来のレコード補間と同じく、各行の結果をSingleへ丸めてから縦を補間する。
// Doubleの式へまとめると既存出力の丸めが変わるため、行ごとの精度を維持する。
function BilinearSingle(A, B, C, D: Single; FX, FY: Double): Single; inline;
var
  Top, Bottom: Single;
begin
  Top := Lerp(A, B, FX); Bottom := Lerp(C, D, FX);
  Result := Lerp(Top, Bottom, FY);
end;

function TAquaRenderer.SurfaceBounds(Width, Height, GridW, GridH: Integer;
  out Left, Top, Right, Bottom: Integer): Boolean;
var
  GX, GY, GridLeft, GridTop, GridRight, GridBottom: Integer;
begin
  Result := False;
  Left := 0; Top := 0; Right := -1; Bottom := -1;
  GridLeft := GridW; GridTop := GridH; GridRight := -1; GridBottom := -1;
  for GY := 0 to GridH - 1 do
    for GX := 0 to GridW - 1 do
      if FGrid[GY * GridW + GX].Mask > 0 then
      begin
        GridLeft := Min(GridLeft, GX); GridRight := Max(GridRight, GX);
        GridTop := Min(GridTop, GY); GridBottom := Max(GridBottom, GY);
      end;
  if GridRight < 0 then Exit;
  // 補間で隣の格子へ広がる分を1セル含める。範囲外の元画像はコピーだけで保つ。
  Left := Max(0, Floor((GridLeft - 1) * (Width - 1) / (GridW - 1)));
  Right := Min(Width - 1, Ceil((GridRight + 1) * (Width - 1) / (GridW - 1)));
  Top := Max(0, Floor((GridTop - 1) * (Height - 1) / (GridH - 1)));
  Bottom := Min(Height - 1, Ceil((GridBottom + 1) * (Height - 1) / (GridH - 1)));
  Result := True;
end;

procedure TAquaRenderer.CompositeOilOverlay(const Input: TAquaPixels;
  Width, Height, GridW, GridH: Integer; Opacity, TintR, TintG, TintB: Double;
  var Output: TAquaPixels);
var
  Left, Top, Right, Bottom, X, Y, IX, NX, IY, NY, Index: Integer;
  A, B, C, D, RowA, RowB: Integer;
  FX, FY, GridY, OverlayAlpha: Double;
  Mask, OilAlpha, Shine, Shadow: Single;
  Direct: Boolean;
  Pixel: TPIXEL_RGBA;
begin
  Move(Input[0], Output[0], Length(Output) * SizeOf(TPIXEL_RGBA));
  if not SurfaceBounds(Width, Height, GridW, GridH, Left, Top, Right, Bottom) then Exit;
  Direct := (GridW = Width) and (GridH = Height);
  // Directはフレーム中不変。間接補間の値を使う分岐へ初期値も明示する。
  A := 0; B := 0; C := 0; D := 0; FX := 0;
  for Y := Top to Bottom do
  begin
    GridY := Y * (GridH - 1) / Max(1, Height - 1);
    IY := Trunc(GridY); NY := Min(IY + 1, GridH - 1); FY := GridY - IY;
    RowA := IY * GridW; RowB := NY * GridW;
    for X := Left to Right do
    begin
      Index := Y * Width + X;
      Pixel := Input[Index];
      if Pixel.A = 0 then Continue;
      if Direct then
      begin
        Mask := FGrid[Index].Mask;
        OilAlpha := FOilGrid[Index].Alpha;
      end else
      begin
        IX := FColumns[X].Left; NX := FColumns[X].Right; FX := FColumns[X].Fraction;
        A := RowA + IX; B := RowA + NX; C := RowB + IX; D := RowB + NX;
        Mask := BilinearSingle(FGrid[A].Mask, FGrid[B].Mask, FGrid[C].Mask, FGrid[D].Mask, FX, FY);
        if Mask <= 0 then Continue;
        OilAlpha := BilinearSingle(FOilGrid[A].Alpha, FOilGrid[B].Alpha,
          FOilGrid[C].Alpha, FOilGrid[D].Alpha, FX, FY);
      end;
      OverlayAlpha := Mask * Opacity * OilAlpha;
      if OverlayAlpha <= 0 then Continue;
      if Direct then
      begin
        Shine := FOilGrid[Index].Shine; Shadow := FOilGrid[Index].Shadow;
      end else
      begin
        Shine := BilinearSingle(FOilGrid[A].Shine, FOilGrid[B].Shine,
          FOilGrid[C].Shine, FOilGrid[D].Shine, FX, FY);
        Shadow := BilinearSingle(FOilGrid[A].Shadow, FOilGrid[B].Shadow,
          FOilGrid[C].Shadow, FOilGrid[D].Shadow, FX, FY);
      end;
      Pixel.R := ColorByte(Lerp(Pixel.R / 255, TintR, OverlayAlpha * 0.16) *
        (1 - Shadow * OverlayAlpha) + Shine * OverlayAlpha * 0.9);
      Pixel.G := ColorByte(Lerp(Pixel.G / 255, TintG, OverlayAlpha * 0.16) *
        (1 - Shadow * OverlayAlpha) + Shine * OverlayAlpha * 0.88);
      Pixel.B := ColorByte(Lerp(Pixel.B / 255, TintB, OverlayAlpha * 0.16) *
        (1 - Shadow * OverlayAlpha) + Shine * OverlayAlpha * 0.8);
      Output[Index] := Pixel;
    end;
  end;
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

// 写真の4近傍がすべて不透明ならアルファの正規化を省く。
// 透明境界は既存のアルファ重み付き補間へ戻して、隠れたRGBのにじみを防ぐ。
function SampleWaveImage(const Pixels: TAquaPixels; Width, Height: Integer;
  X, Y: Double): TPIXEL_RGBA;
var
  IX, IY, NX, NY: Integer;
  FX, FY: Double;
  A, B, C, D: PPIXEL_RGBA;
begin
  X := EnsureRange(X, 0.0, Width - 1.0); Y := EnsureRange(Y, 0.0, Height - 1.0);
  IX := Trunc(X); IY := Trunc(Y); NX := Min(IX + 1, Width - 1); NY := Min(IY + 1, Height - 1);
  A := @Pixels[IY * Width + IX]; B := @Pixels[IY * Width + NX];
  C := @Pixels[NY * Width + IX]; D := @Pixels[NY * Width + NX];
  if (A^.A <> 255) or (B^.A <> 255) or (C^.A <> 255) or (D^.A <> 255) then
    Exit(SampleImage(Pixels, Width, Height, X, Y));
  FX := X - IX; FY := Y - IY;
  Result.R := Round(Lerp(Lerp(A^.R, B^.R, FX), Lerp(C^.R, D^.R, FX), FY));
  Result.G := Round(Lerp(Lerp(A^.G, B^.G, FX), Lerp(C^.G, D^.G, FX), FY));
  Result.B := Round(Lerp(Lerp(A^.B, B^.B, FX), Lerp(C^.B, D^.B, FX), FY));
  Result.A := 255;
end;

procedure TAquaRenderer.CompositeBackground(const Input: TAquaPixels;
  Width, Height, GridW, GridH: Integer; Opacity: Double;
  const Projection: TAquaProjection; NeedsInputMask: Boolean; var Output: TAquaPixels);
var
  Left, Top, Right, Bottom, Row, I: Integer;
  Opaque: Boolean;
  Source, Destination: TAquaPixels;
  RenderRow: TProc<Integer>;
begin
  FillChar(Output[0], Length(Output) * SizeOf(TPIXEL_RGBA), 0);
  if NeedsInputMask and (Length(Input) <> Width * Height) then Exit;
  if not SurfaceBounds(Width, Height, GridW, GridH, Left, Top, Right, Bottom) then Exit;
  Opaque := True;
  if NeedsInputMask then
    for I := 0 to High(Input) do
      if Input[I].A <> 255 then begin Opaque := False; Break; end;
  Source := Input; Destination := Output;
  RenderRow := procedure(Y: Integer)
  var
    X, IX, NX, IY, NY, A, B, C, D: Integer;
    FX, FY, GridY, U, V, Alpha: Double;
    S: TAquaSurfaceSample;
    Pixel, SourcePixel: TPIXEL_RGBA;
  begin
    GridY := Y * (GridH - 1) / Max(1, Height - 1);
    IY := Trunc(GridY); NY := Min(IY + 1, GridH - 1); FY := GridY - IY;
    for X := Left to Right do
    begin
      SourcePixel := Default(TPIXEL_RGBA);
      if NeedsInputMask then
      begin
        if (not Projection.ScreenToSurface(X + 0.5, Y + 0.5, U, V)) or
          (Abs(U) > 1) or (Abs(V) > 1) then Continue;
        if Opaque then SourcePixel.A := 255
        else SourcePixel := SampleImage(Source, Width, Height,
          (U + 1) * Width * 0.5 - 0.5, (V + 1) * Height * 0.5 - 0.5);
        if SourcePixel.A = 0 then Continue;
      end;
      if (GridW = Width) and (GridH = Height) then S := FGrid[Y * Width + X]
      else
      begin
        IX := FColumns[X].Left; NX := FColumns[X].Right; FX := FColumns[X].Fraction;
        A := IY * GridW + IX; B := IY * GridW + NX;
        C := NY * GridW + IX; D := NY * GridW + NX;
        // 既存の背景ありと同じDouble補間・最後のSingle丸めを保つ。
        S.Mask := Lerp(Lerp(FGrid[A].Mask, FGrid[B].Mask, FX), Lerp(FGrid[C].Mask, FGrid[D].Mask, FX), FY);
        if S.Mask <= 0 then Continue;
        S.R := Lerp(Lerp(FGrid[A].R, FGrid[B].R, FX), Lerp(FGrid[C].R, FGrid[D].R, FX), FY);
        S.G := Lerp(Lerp(FGrid[A].G, FGrid[B].G, FX), Lerp(FGrid[C].G, FGrid[D].G, FX), FY);
        S.B := Lerp(Lerp(FGrid[A].B, FGrid[B].B, FX), Lerp(FGrid[C].B, FGrid[D].B, FX), FY);
      end;
      Alpha := S.Mask * Opacity;
      if NeedsInputMask then Alpha := Alpha * SourcePixel.A / 255;
      Pixel := Default(TPIXEL_RGBA); Pixel.A := ColorByte(Alpha);
      if Pixel.A > 0 then
      begin Pixel.R := ColorByte(S.R); Pixel.G := ColorByte(S.G); Pixel.B := ColorByte(S.B); end;
      Destination[Y * Width + X] := Pixel;
    end;
  end;
  if ((Right - Left + 1) * (Bottom - Top + 1) >= 80000) and (TThread.ProcessorCount > 1) then
  begin
    if FWavePool = nil then
    begin
      FWavePool := TThreadPool.Create;
      FWavePool.SetMinWorkerThreads(1); FWavePool.SetMaxWorkerThreads(2);
      FWavePool.UnlimitedWorkerThreadsWhenBlocked := False;
    end;
    TParallel.&For(8, Top, Bottom, RenderRow, FWavePool);
  end else
    for Row := Top to Bottom do RenderRow(Row);
end;

procedure TAquaRenderer.CompositeImageWaves(const Input: TAquaPixels;
  Width, Height, GridW, GridH: Integer; Opacity, Shading: Double; var Output: TAquaPixels);
var
  Left, Top, Right, Bottom, Row: Integer;
  Source, Destination: TAquaPixels;
  RenderRow: TProc<Integer>;
begin
  Move(Input[0], Output[0], Length(Output) * SizeOf(TPIXEL_RGBA));
  if not SurfaceBounds(Width, Height, GridW, GridH, Left, Top, Right, Bottom) then Exit;
  // コールバック中だけ配列の参照を共有する。格子・入力は読取り専用、出力は行で分離する。
  Source := Input; Destination := Output;
  RenderRow := procedure(Y: Integer)
  var
    X, I, IX, NX, IY, NY, A, B, C, D: Integer;
    FX, FY, GridY, Weight, R, G, Blue: Double;
    Mask, DX, DY, Shade, Light: Single;
    Oil: TAquaOilSample;
    Pixel, Sampled: TPIXEL_RGBA;
  begin
    GridY := Y * (GridH - 1) / Max(1, Height - 1);
    IY := Trunc(GridY); NY := Min(IY + 1, GridH - 1); FY := GridY - IY;
    for X := Left to Right do
    begin
      I := Y * Width + X; Pixel := Source[I];
      if Pixel.A = 0 then Continue;
      IX := FColumns[X].Left; NX := FColumns[X].Right; FX := FColumns[X].Fraction;
      A := IY * GridW + IX; B := IY * GridW + NX;
      C := NY * GridW + IX; D := NY * GridW + NX;
      Mask := BilinearSingle(FGrid[A].Mask, FGrid[B].Mask, FGrid[C].Mask, FGrid[D].Mask, FX, FY);
      if Mask <= 0 then Continue;
      DX := BilinearSingle(FGrid[A].DX, FGrid[B].DX, FGrid[C].DX, FGrid[D].DX, FX, FY);
      DY := BilinearSingle(FGrid[A].DY, FGrid[B].DY, FGrid[C].DY, FGrid[D].DY, FX, FY);
      Shade := BilinearSingle(FGrid[A].Shade, FGrid[B].Shade, FGrid[C].Shade, FGrid[D].Shade, FX, FY);
      // 白い液体には陰影だけを弱め、画像の変形と明るい反射は残す。
      if Shading < 1 then Shade := 1 + (Shade - 1) * Shading;
      Light := BilinearSingle(FGrid[A].Light, FGrid[B].Light, FGrid[C].Light, FGrid[D].Light, FX, FY);
      Sampled := SampleWaveImage(Source, Width, Height, X + DX * Mask, Y + DY * Mask);
      if Sampled.A = 0 then Continue;
      R := Saturate(Sampled.R / 255 * Shade + Light * 0.2);
      G := Saturate(Sampled.G / 255 * Shade + Light * 0.2);
      Blue := Saturate(Sampled.B / 255 * Shade + Light * 0.2);
      if Length(FOilGrid) > 0 then
      begin
        Oil := MixOil(MixOil(FOilGrid[A], FOilGrid[B], FX), MixOil(FOilGrid[C], FOilGrid[D], FX), FY);
        R := Lerp(R, Oil.R, Oil.Alpha); G := Lerp(G, Oil.G, Oil.Alpha);
        Blue := Lerp(Blue, Oil.B, Oil.Alpha);
      end;
      Weight := Mask * Opacity;
      Pixel.R := ColorByte(Lerp(Pixel.R / 255, R, Weight));
      Pixel.G := ColorByte(Lerp(Pixel.G / 255, G, Weight));
      Pixel.B := ColorByte(Lerp(Pixel.B / 255, Blue, Weight));
      Destination[I] := Pixel;
    end;
  end;
  if ((Right - Left + 1) * (Bottom - Top + 1) >= 80000) and (TThread.ProcessorCount > 1) then
  begin
    if FWavePool = nil then
    begin
      FWavePool := TThreadPool.Create;
      FWavePool.SetMinWorkerThreads(1);
      FWavePool.SetMaxWorkerThreads(2);
      FWavePool.UnlimitedWorkerThreadsWhenBlocked := False;
    end;
    // 全行の完了を待ってからホストへ戻す。小さな画像は起動コストをかけず直列に処理する。
    TParallel.&For(8, Top, Bottom, RenderRow, FWavePool);
  end else
    for Row := Top to Bottom do RenderRow(Row);
end;

procedure TAquaRenderer.Render(const Input: TAquaPixels; Width, Height: Integer;
  Time: Double; const Settings: TAquaSettings; ClipToInput: Boolean;
  var Output: TAquaPixels; TimelineProgress: Double);
type
  TWave = record KX, KY, Phase, Amplitude: Double; end;
  TRipple = record X, Y, Radius, Width, Strength, MinD2, MaxD2: Double; end;
var
  Waves: array[0..5] of TWave;
  Ripples: array[0..5] of TRipple;
  GridW, GridH, Step, GX, GY, X, Y, Index, I, RippleCount: Integer;
  IX, IY, NX, NY, BaseIndex: Integer;
  HasInput, NeedsInputMask, HasOil, KeepOilGrid, IsOilOverlay, IsWaveOverlay, IsOverlay, HasVortex: Boolean;
  HasVortexSurface: Boolean;
  Projection: TAquaProjection;
  OilSurface: TAquaOilSurface;
  FlowField: TAquaFlowField;
  Shore: TAquaShore;
  ShoreSample: TAquaShoreSample;
  VortexSurface: TAquaVortexSurface;
  VortexSample: TAquaVortexSample;
  VortexCU, VortexCV, MetricX, MetricY, OriginX, OriginY, PointX, PointY, MetricBase: Double;
  OilSample, OilA, OilB: TAquaOilSample;
  Seed, T, Viscosity, Strength, Detail, Flow, FlowAngle: Double;
  RippleScaleX, RippleScaleY: Double;
  OffsetU, OffsetV, Opacity, SourceX, SourceY, OverlayAlpha: Double;
  BaseR, BaseG, BaseB, Reflection, Highlight, FoamAmount: Double;
  OilTintR, OilTintG, OilTintB: Double;
  ScreenX, ScreenY, U, V, RotU, RotV, Depth, Mask: Double;
  FlowU, FlowV, J00, J01, J10, J11, OriginalGradU: Double;
  WaveHeight, GradU, GradV, Phase, CosPhase, Distance, RadiusDelta: Double;
  Envelope, DX, DY, InvNormal, NormalX, NormalY, NormalZ: Double;
  Diffuse, Specular, Sky, Fresnel, Ref, Foam, Light, Shade: Double;
  Scale, Edge, Age, Interval, Life, Speed, FX, FY, GridX, GridY, Alpha: Double;
  EventID: Int64;
  S, RowA, RowB: TAquaSurfaceSample;
  Pixel, SourcePixel: TPIXEL_RGBA;
begin
  {$IFDEF DEBUG}
  FLastProfile := Default(TAquaRenderProfile);
  FLastProfile.Started := AquaProfileTick;
  try
  {$ENDIF}
  if (Width <= 0) or (Height <= 0) or (Width > 8192) or (Height > 8192) or
    (Int64(Width) * Height > AQUA_MAX_PIXELS) then
  begin
    SetLength(Output, 0);
    Exit;
  end;
  HasInput := Length(Input) = Width * Height;
  SetLength(Output, Width * Height);
  IsOilOverlay := Settings.DisplayMode = adOilOverlay;
  IsWaveOverlay := Settings.DisplayMode = adWaveOverlay;
  IsOverlay := IsOilOverlay or IsWaveOverlay;
  if IsOverlay and (not HasInput) then
  begin
    FillChar(Output[0], Length(Output) * SizeOf(TPIXEL_RGBA), 0);
    Exit;
  end;
  NeedsInputMask := (ClipToInput or (Settings.DisplayMode = adImage) or
    (Settings.Shape = asImage)) and (not IsOverlay);
  Projection := TAquaProjection.Create(Width, Height, Settings, NeedsInputMask);
  Opacity := Saturate(1 - Settings.Tracks[atTransparency] * 0.01);
  if (not Projection.Valid) or (Opacity <= 0) or
    (IsOilOverlay and (Settings.Tracks[atOilAmount] <= 0)) or
    (IsWaveOverlay and (Settings.Tracks[atWaveStrength] <= 0) and
      (Settings.Tracks[atRippleAmount] <= 0) and (Settings.Tracks[atOilAmount] <= 0)) then
  begin
    if IsOverlay then Move(Input[0], Output[0], Length(Output) * SizeOf(TPIXEL_RGBA))
    else FillChar(Output[0], Length(Output) * SizeOf(TPIXEL_RGBA), 0);
    Exit;
  end;
  if IsNan(Time) or IsInfinite(Time) then Time := 0;
  T := EnsureRange(Time, -1.0E9, 1.0E9);
  HasVortexSurface := (Settings.Tracks[atVortexDepth] > 0) or
    (Settings.Tracks[atVortexPull] > 0) or (Settings.Tracks[atDrainAmount] > 0);
  VortexCU := 0; VortexCV := 0; MetricX := 1; MetricY := 1;
  if HasVortexSurface or (Settings.Tracks[atVortexCenterX] <> 0) or
    (Settings.Tracks[atVortexCenterY] <> 0) then
  begin
    Projection.ScreenToSurface(Width * 0.5 + Settings.Tracks[atVortexCenterX],
      Height * 0.5 + Settings.Tracks[atVortexCenterY], VortexCU, VortexCV);
    if Projection.SurfaceToScreen(VortexCU, VortexCV, OriginX, OriginY) then
    begin
      if Projection.SurfaceToScreen(VortexCU + 1, VortexCV, PointX, PointY) then
        MetricX := Max(0.01, Hypot(PointX - OriginX, PointY - OriginY));
      if Projection.SurfaceToScreen(VortexCU, VortexCV + 1, PointX, PointY) then
        MetricY := Max(0.01, Hypot(PointX - OriginX, PointY - OriginY));
      MetricBase := Min(MetricX, MetricY); MetricX := MetricX / MetricBase; MetricY := MetricY / MetricBase;
    end;
  end;
  if HasVortexSurface then
  begin
    if IsNan(TimelineProgress) or IsInfinite(TimelineProgress) then TimelineProgress := 0;
    VortexSurface := TAquaVortexSurface.Create(Settings, T, TimelineProgress,
      VortexCU, VortexCV, MetricX, MetricY);
    if VortexSurface.Empty then
    begin
      if IsOverlay then Move(Input[0], Output[0], Length(Output) * SizeOf(TPIXEL_RGBA))
      else FillChar(Output[0], Length(Output) * SizeOf(TPIXEL_RGBA), 0);
      Exit;
    end;
  end;
  if Settings.Shape = asShore then Shore := TAquaShore.Create(Settings, T);
  Seed := Settings.Tracks[atSeed];
  Viscosity := Settings.Tracks[atViscosity] * 0.01;
  Strength := Settings.Tracks[atWaveStrength] * 0.01;
  Detail := 0.6 + Settings.Tracks[atWaveDetail] * 0.025;
  Speed := Settings.Tracks[atWaveSpeed] / (1 + Viscosity * 2.5);
  Flow := Settings.Tracks[atFlowSpeed] * 0.012 / (1 + Viscosity * 2);
  FlowAngle := DegToRad(Settings.Tracks[atFlowDirection]);
  OffsetU := T * Flow * Cos(FlowAngle);
  OffsetV := T * Flow * Sin(FlowAngle);
  FlowField := TAquaFlowField.Create(Settings, T, VortexCU, VortexCV);
  HasVortex := FlowField.Active;
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
  // 長方形へ合わせた水面でも、波紋だけを円形へ補正できる。
  RippleScaleX := 1 + Max(0.0, Settings.Tracks[atRippleAspect] * 0.01);
  RippleScaleY := 1 + Max(0.0, -Settings.Tracks[atRippleAspect] * 0.01);
  for I := 0 to RippleCount - 1 do
  begin
    Age := T - (EventID - I) * Interval;
    Ripples[I].X := (Noise(EventID - I, 1, Seed) - 0.5) * 1.8;
    Ripples[I].Y := (Noise(EventID - I, 2, Seed) - 0.5) * 1.8;
    // 100は従来と同じ分布、0は毎回同じ中心から発生する。
    if Settings.Tracks[atRippleScatter] <> 100 then
    begin
      Ripples[I].X := Ripples[I].X * Settings.Tracks[atRippleScatter] * 0.01;
      Ripples[I].Y := Ripples[I].Y * Settings.Tracks[atRippleScatter] * 0.01;
    end;
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
  if Settings.Shape = asShore then
  begin
    SetLength(FShoreColumns, GridW);
    for GX := 0 to GridW - 1 do FShoreColumns[GX].U := MaxDouble;
  end;
  for X := 0 to Width - 1 do
  begin
    GridX := X * (GridW - 1) / Max(1, Width - 1);
    FColumns[X].Left := Trunc(GridX);
    FColumns[X].Right := Min(FColumns[X].Left + 1, GridW - 1);
    FColumns[X].Fraction := GridX - FColumns[X].Left;
  end;
  if KeepOilGrid then SetLength(FOilGrid, GridW * GridH) else SetLength(FOilGrid, 0);
  Edge := 3 / Min(Width, Height);
  {$IFDEF DEBUG}
  FLastProfile.GridWidth := GridW; FLastProfile.GridHeight := GridH;
  FLastProfile.SetupDone := AquaProfileTick;
  {$ENDIF}
  for GY := 0 to GridH - 1 do
  begin
    ScreenY := GY * (Height - 1) / (GridH - 1) + 0.5;
    for GX := 0 to GridW - 1 do
    begin
      S := Default(TAquaSurfaceSample);
      // 写真へ重ねる波の範囲外は中立の明るさにする。
      // Shade=0を境界へ補間すると、元画像に暗い輪郭が付いてしまう。
      if IsWaveOverlay then S.Shade := 1;
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
      if Settings.Shape = asShore then
      begin
        if FShoreColumns[GX].U <> RotU then
          FShoreColumns[GX] := Shore.PrepareColumn(RotU);
        ShoreSample := Shore.Sample(RotU, RotV, Edge, FShoreColumns[GX]);
        Mask := ShoreSample.Coverage;
      end;
      if HasVortexSurface and (Mask > 0) then
      begin
        VortexSample := VortexSurface.Sample(RotU, RotV, Edge);
        Mask := Mask * VortexSample.Mask;
      end;
      if Mask > 0 then
      begin
        // 形状で波の倍率を変えず、「魔法液体」と同じ基準で模様を生成する。
        FlowU := RotU; FlowV := RotV;
        if HasVortexSurface then VortexSurface.Advect(FlowU, FlowV);
        if HasVortex then
        begin
          U := FlowU; V := FlowV;
          FlowField.Map(U, V, FlowU, FlowV, J00, J01, J10, J11);
        end;
        U := FlowU - OffsetU; V := FlowV - OffsetV;
        WaveHeight := 0; GradU := 0; GradV := 0;
        if Strength > 0 then for I := 0 to High(Waves) do
        begin
          Phase := U * Waves[I].KX + V * Waves[I].KY + Waves[I].Phase;
          CosPhase := FastSin(Phase + Pi * 0.5) * Waves[I].Amplitude;
          WaveHeight := WaveHeight + FastSin(Phase) * Waves[I].Amplitude;
          GradU := GradU + CosPhase * Waves[I].KX;
          GradV := GradV + CosPhase * Waves[I].KY;
        end;
        if HasVortex then
        begin
          OriginalGradU := GradU;
          GradU := J00 * GradU + J10 * GradV;
          GradV := J01 * OriginalGradU + J11 * GradV;
        end;
        for I := 0 to RippleCount - 1 do
        begin
          DX := RotU - Ripples[I].X; DY := RotV - Ripples[I].Y;
          if RippleScaleX <> 1 then DX := DX * RippleScaleX;
          if RippleScaleY <> 1 then DY := DY * RippleScaleY;
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
            GradU := GradU + CosPhase * DX / Distance * RippleScaleX;
            GradV := GradV + CosPhase * DY / Distance * RippleScaleY;
          end;
        end;
        if HasVortexSurface then
        begin
          WaveHeight := WaveHeight + VortexSample.Height;
          GradU := GradU + VortexSample.GradU; GradV := GradV + VortexSample.GradV;
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
        if Settings.Shape = asShore then Foam := 0;
        if HasVortexSurface then Foam := Max(Foam, VortexSample.Foam);
        Shade := 0.55 + Diffuse * 0.55 + WaveHeight * 0.12;
        Light := Saturate(Specular + Foam * 0.9);
        if HasVortexSurface then
        begin
          Shade := Shade * VortexSample.Shade;
          Light := Saturate(Light + VortexSample.Light);
        end;
        S.R := Saturate(Lerp(BaseR * Shade, 0.62, Ref) + Light);
        S.G := Saturate(Lerp(BaseG * Shade, 0.82, Ref) + Light);
        S.B := Saturate(Lerp(BaseB * Shade, 0.94, Ref) + Light);
        S.Mask := Mask;
        S.DX := GradU * 9 * Width / 1280;
        S.DY := GradV * 9 * Height / 720;
        if HasVortexSurface then
        begin
          S.DX := S.DX + VortexSample.PullU * Width * 0.5;
          S.DY := S.DY + VortexSample.PullV * Height * 0.5;
        end;
        S.Shade := Shade;
        S.Light := Light;
        if HasOil then
        begin
          OilSample := OilSurface.Sample(FlowU, FlowV, GradU, GradV, Light);
          if KeepOilGrid then FOilGrid[GY * GridW + GX] := OilSample;
          S.R := Lerp(S.R, OilSample.R, OilSample.Alpha);
          S.G := Lerp(S.G, OilSample.G, OilSample.Alpha);
          S.B := Lerp(S.B, OilSample.B, OilSample.Alpha);
        end;
        if Settings.Shape = asShore then
          ShoreSample.Composite(S.R, S.G, S.B, S.Mask, S.Light,
            Settings.DisplayMode = adEffectsOnly);
      end;
      FGrid[GY * GridW + GX] := S;
    end;
  end;

  {$IFDEF DEBUG}
  FLastProfile.SurfaceDone := AquaProfileTick;
  {$ENDIF}
  if IsOilOverlay then
  begin
    CompositeOilOverlay(Input, Width, Height, GridW, GridH, Opacity,
      OilTintR, OilTintG, OilTintB, Output);
    Exit;
  end;
  if IsWaveOverlay then
  begin
    CompositeImageWaves(Input, Width, Height, GridW, GridH, Opacity,
      Saturate(Settings.Tracks[atImageShading] * 0.01), Output);
    Exit;
  end;
  if Settings.DisplayMode = adBackground then
  begin
    CompositeBackground(Input, Width, Height, GridW, GridH, Opacity,
      Projection, NeedsInputMask, Output);
    Exit;
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
      else
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
      if Settings.DisplayMode = adEffectsOnly then
      begin
        OverlayAlpha := S.Light * (1 - OilSample.Alpha) + OilSample.Alpha;
        Alpha := Alpha * OverlayAlpha;
        if OverlayAlpha > 0 then
        begin
          Pixel.R := ColorByte((220 / 255 * S.Light * (1 - OilSample.Alpha) + OilSample.R * OilSample.Alpha) / OverlayAlpha);
          Pixel.G := ColorByte((240 / 255 * S.Light * (1 - OilSample.Alpha) + OilSample.G * OilSample.Alpha) / OverlayAlpha);
          Pixel.B := ColorByte((S.Light * (1 - OilSample.Alpha) + OilSample.B * OilSample.Alpha) / OverlayAlpha);
        end;
        if Settings.Shape = asShore then
        begin
          Pixel.R := ColorByte(S.R); Pixel.G := ColorByte(S.G); Pixel.B := ColorByte(S.B);
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
  {$IFDEF DEBUG}
  finally
    FLastProfile.Finished := AquaProfileTick;
    if FLastProfile.SetupDone = 0 then FLastProfile.SetupDone := FLastProfile.Finished;
    if FLastProfile.SurfaceDone = 0 then FLastProfile.SurfaceDone := FLastProfile.Finished;
  end;
  {$ENDIF}
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
