unit AquaFX_WaterDepth;

// Copyright (c) 2026 VRAMの魔術師
// SPDX-License-Identifier: GPL-3.0-only

// 水面からの高さを使って、波の模様・水底の集光模様・浮上して弾ける気泡を描く。
// フレーム内だけ有効な設定と投影を値として持ち、再生順やホストのメモリに依存しない。

interface

uses
  AquaFX_Settings, AquaFX_Projection;

type
  TAquaBubbleBlend = reference to procedure(X, Y: Integer; Strength: Double);

  TAquaWaterDepth = record
  private
    FProjection: TAquaProjection;
    FShape: TAquaShape;
    FCorner, FDepth, FCaustics, FCausticPhase, FBubbles, FSeed, FTime, FRelief: Double;
    function EdgeDistance(U, V: Double): Double;
  public
    // 設定と高さを含む投影から、フレーム内で共有する値を作る。
    class function Create(const Settings: TAquaSettings; Time: Double;
      const Projection: TAquaProjection): TAquaWaterDepth; static;
    // 波の高さと平面座標から、同じ画素に映る波模様のサンプル座標を返す。
    procedure SurfaceCoordinates(U, V, WaveHeight: Double; out SampleU, SampleV: Double);
    // 水面のU/Vと波の勾配から、同じ視線が通る水底の光量（0～1）を返す。
    function BottomLight(U, V, GradU, GradV: Double): Double;
    // 気泡と着水面の波紋の被覆率を、画像内の画素ごとにBlendへ渡す。
    // Strengthは全体の不透明度込みで、Blendの保持と画素の書込みは行わない。
    procedure DrawBubbles(Width, Height: Integer; Opacity, Zoom: Double;
      const Blend: TAquaBubbleBlend);
    property Relief: Double read FRelief;
  end;

implementation

uses
  System.Math, AquaFX_SurfaceShape;

const
  TAU = 2 * Pi;

function Saturate(Value: Double): Double; inline;
begin
  Result := EnsureRange(Value, 0.0, 1.0);
end;

function Smooth(Value: Double): Double; inline;
begin
  Value := Saturate(Value);
  Result := Sqr(Value) * (3 - 2 * Value);
end;

function BubbleRandom(Index, Salt: Integer; Cycle: Int64; Seed: Double): Double;
var
  Value: Double;
begin
  Value := Sin(Index * 17.182 + Salt * 41.081 +
    (Cycle mod 65521) * 4.942 + Seed * 0.019) * 11931.259;
  Result := Value - Floor(Value);
end;

class function TAquaWaterDepth.Create(const Settings: TAquaSettings;
  Time: Double; const Projection: TAquaProjection): TAquaWaterDepth;
begin
  Result.FProjection := Projection;
  Result.FShape := Settings.Shape;
  Result.FCorner := Settings.Tracks[atCornerRoundness] * 0.01;
  Result.FDepth := Settings.Tracks[atWaterDepth] * 0.0033;
  Result.FCaustics := Settings.Tracks[atCaustics] * 0.01;
  Result.FBubbles := Settings.Tracks[atBubbles] * 0.01;
  Result.FSeed := Settings.Tracks[atSeed];
  Result.FTime := Time;
  Result.FCausticPhase := Frac(Time * 0.12) * TAU + Result.FSeed * 0.017;
  Result.FRelief := 0;
  if acWaves in Settings.Components then
    Result.FRelief := Settings.Tracks[atWaveRelief] * 0.015;
end;

function TAquaWaterDepth.EdgeDistance(U, V: Double): Double;
begin
  case FShape of
    asRectangle: Result := 1 - Max(Abs(U), Abs(V));
    asEllipse: Result := 1 - Sqrt(Sqr(U) + Sqr(V));
    asRoundedRectangle: Result := -AquaRoundedDistance(U, V, FCorner);
  else
    Result := 1;
  end;
end;

procedure TAquaWaterDepth.SurfaceCoordinates(U, V, WaveHeight: Double;
  out SampleU, SampleV: Double);
var
  Lift, Edge: Double;
begin
  SampleU := U; SampleV := V;
  Edge := Smooth(EdgeDistance(U, V) * 9);
  Lift := EnsureRange(WaveHeight * FRelief, -0.095, 0.095) * Edge;
  if (Lift <> 0) and not FProjection.SampleAtHeight(U, V, Lift, SampleU, SampleV) then
  begin
    SampleU := U; SampleV := V;
  end;
end;

function TAquaWaterDepth.BottomLight(U, V, GradU, GradV: Double): Double;
var
  BottomU, BottomV, Bend, A, B, C, Ridge, Edge: Double;
begin
  Result := 0;
  if (FDepth <= 0) or (FCaustics <= 0) or
    not FProjection.SampleAtHeight(U, V, -FDepth, BottomU, BottomV) then Exit;
  Edge := Smooth(EdgeDistance(BottomU, BottomV) * 6);
  if Edge <= 0 then Exit;
  // 勾配で水底に届く光を少し曲げ、独立した細い集光模様を動かす。
  BottomU := BottomU + EnsureRange(GradU * 0.006, -0.035, 0.035);
  BottomV := BottomV + EnsureRange(GradV * 0.006, -0.035, 0.035);
  Bend := 1.25 * Sin(7 * BottomU + 9 * BottomV + FCausticPhase);
  A := Sin(24 * BottomU + 12 * BottomV + Bend + FCausticPhase);
  B := Sin(-10 * BottomU + 27 * BottomV - Bend - FCausticPhase);
  C := Sin(16 * BottomU - 21 * BottomV + A * 1.4 + FCausticPhase * 2);
  Ridge := 1 - Min(Abs(A + B * 0.58), Abs(B + C * 0.64));
  Result := Sqr(Smooth((Ridge - 0.60) / 0.40)) *
    FCaustics * Edge * (0.79 - FDepth);
end;

procedure TAquaWaterDepth.DrawBubbles(Width, Height: Integer;
  Opacity, Zoom: Double; const Blend: TAquaBubbleBlend);
const
  PopTime = 0.45;
var
  Count, I: Integer;
  Cycle: Int64;
  Period, Life, Progress, U, V, Z, Radius, Size, Alpha: Double;
  Phase, X, Y, AX, AY, BX, BY, PixelsPerHeight, Offset: Double;

  procedure DrawMark(X, Y, AX, AY, BX, BY, Strength: Double; Bubble: Boolean);
  var
    IX, IY, Left, Right, Top, Bottom: Integer;
    ExtentX, ExtentY, Det, P, Q, D2, Rim, Glint, Coverage: Double;
  begin
    Det := AX * BY - AY * BX;
    if Abs(Det) < 0.2 then Exit;
    ExtentX := Abs(AX) + Abs(BX) + 1;
    ExtentY := Abs(AY) + Abs(BY) + 1;
    if (X < -ExtentX) or (X > Width + ExtentX) or
       (Y < -ExtentY) or (Y > Height + ExtentY) then Exit;
    Left := Floor(Max(0.0, X - ExtentX));
    Right := Ceil(Min(Width - 1.0, X + ExtentX));
    Top := Floor(Max(0.0, Y - ExtentY));
    Bottom := Ceil(Min(Height - 1.0, Y + ExtentY));
    for IY := Top to Bottom do
      for IX := Left to Right do
      begin
        P := ((IX + 0.5 - X) * BY - (IY + 0.5 - Y) * BX) / Det;
        Q := ((IY + 0.5 - Y) * AX - (IX + 0.5 - X) * AY) / Det;
        D2 := Sqr(P) + Sqr(Q);
        if D2 >= 1.2 then Continue;
        Rim := Saturate(1 - Abs(D2 - 0.78) * 2.6);
        Coverage := Rim;
        if Bubble then
        begin
          Glint := Saturate(1 - (Sqr(P + 0.36) + Sqr(Q + 0.38)) * 11);
          Coverage := Rim * (0.50 - 0.23 * Q) + Glint * 0.56 + (1 - Min(1.0, D2)) * 0.07;
        end;
        if Coverage > 0 then Blend(IX, IY, Saturate(Coverage) * Strength);
      end;
  end;

begin
  if (FDepth <= 0) or (FBubbles <= 0) then Exit;
  Count := Ceil(FBubbles * 32);
  PixelsPerHeight := Min(Width, Height) * 0.46 * Zoom;
  for I := 0 to Count - 1 do
  begin
    Period := 2.1 + BubbleRandom(I, 1, 0, FSeed) * 2.6;
    Offset := Period * BubbleRandom(I, 2, 0, FSeed);
    Cycle := Floor((FTime + Offset) / Period);
    Life := FTime + Offset - Cycle * Period;
    Progress := Saturate(Life / (Period - PopTime));
    Phase := Progress * TAU + BubbleRandom(I, 3, Cycle, FSeed) * TAU;
    U := (BubbleRandom(I, 4, Cycle, FSeed) - 0.5) * 1.76 + Sin(Phase) * 0.027;
    V := (BubbleRandom(I, 5, Cycle, FSeed) - 0.5) * 1.76 + Cos(Phase) * 0.018;
    if EdgeDistance(U, V) < 0.06 then Continue;
    Size := 0.010 + BubbleRandom(I, 6, Cycle, FSeed) * 0.027;
    if Progress < 1 then
    begin
      Z := -FDepth * (1 - Progress);
      if not FProjection.ElevatedToScreen(U, V, Z, X, Y) then Continue;
      Radius := EnsureRange(PixelsPerHeight * Size * (0.65 + Progress * 0.45) /
        Max(0.20, FProjection.DepthAt(U, V)), 0.9, 24.0);
      Alpha := (0.39 + 0.48 * Progress) * Smooth(Progress * 9) *
        Smooth((1 - Progress) * 18) * Opacity;
      DrawMark(X, Y, Radius, 0, 0, Radius, Alpha, True);
    end
    else
    begin
      Progress := (Life - (Period - PopTime)) / PopTime;
      Radius := Size * (0.9 + Progress * 2.5);
      if not FProjection.SurfaceToScreen(U, V, X, Y) or
         not FProjection.SurfaceToScreen(U + Radius, V, AX, AY) or
         not FProjection.SurfaceToScreen(U, V + Radius, BX, BY) then Continue;
      // AとBは波紋の局所軸。真上では円、斜めからは縮んだ輪になる。
      Alpha := Smooth(0.17 + Progress * 6) * Sqr(Saturate(1 - Progress)) *
        0.40 * Opacity;
      DrawMark(X, Y, AX - X, AY - Y, BX - X, BY - Y, Alpha, False);
    end;
  end;
end;

end.
