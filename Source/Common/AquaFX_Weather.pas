unit AquaFX_Weather;

// Copyright (c) 2026 VRAMの魔術師
// SPDX-License-Identifier: GPL-3.0-only

// 地面上の着地点と降下中の粒を共通投影で結ぶ。フレーム履歴や乱数状態を保存しない。
// 水たまり、着水の波紋・飛沫、雨筋と雪片を、出力に触れる範囲だけラスタライズする。

interface

uses
  AviUtl2FilterTypes, AquaFX_Settings;

// 呼出側がサイズを検証・確保したストレートRGBA出力へ描く。入力と設定は借用する。
// Timeはオブジェクト内の秒。ClipToInputは画像オブジェクトへの適用を表す。
// 画像へ重ねる場合は同位置の入力アルファを維持する。フィルタオブジェクトは透過レイヤーを返す。
procedure RenderAquaWeather(const Input: array of TPIXEL_RGBA; Width, Height: Integer;
  Time: Double; const Settings: TAquaSettings; ClipToInput: Boolean;
  var Output: array of TPIXEL_RGBA);

implementation

uses
  System.Math, System.Types, AquaFX_Projection;

{$POINTERMATH ON}

const
  TAU = 2 * Pi;
  RAIN_COLOR = $E0F2FF;
  SPLASH_COLOR = $E4F5FF;
  RIPPLE_COLOR = $BBDDEB;
  SNOW_COLOR = $F2F8FF;

type
  TWeatherPoint = record
    X, Y: Double;
  end;

  TWeatherPuddle = record
    U, V, RadiusU, RadiusV, SinPhase, CosPhase, SinDoublePhase, CosDoublePhase: Double;
    Bounds: TRect;
    function Distance(DX, DY: Double): Double;
  end;
  PWeatherPuddle = ^TWeatherPuddle;

  TWeatherFrame = record
  private
    FPixels: PPIXEL_RGBA;
    FWidth, FHeight: Integer;
    FUnitSize, FPixelScale, FWind: Double;
    FProjection, FLayout: TAquaProjection;
    FPuddles: array[0..2] of TWeatherPuddle;
    FPuddleCount: Integer;
    procedure Blend(X, Y: Integer; Color: Cardinal; Coverage: Double);
    procedure Stroke(const A, B: TWeatherPoint; Radius, Opacity: Double;
      Color: Cardinal; FadeTail: Boolean = False);
    procedure Snowflake(const P: TWeatherPoint; Radius, Opacity: Double);
    function GroundPoint(U, V: Double; out P: TWeatherPoint): Boolean;
    function GroundBounds(U, V, RadiusU, RadiusV: Double; out Bounds: TRect): Boolean;
    procedure DrawPuddles(Amount: Double; Color: Cardinal; Seed: Int64);
    function PuddleAt(U, V: Double): PWeatherPuddle;
    procedure Ripple(U, V, Radius, Opacity, Phase: Double; Puddle: PWeatherPuddle);
    procedure RainImpact(U, V, Age, Strength, DepthScale: Double);
    procedure DrawPrecipitation(Time, Amount: Double; Seed: Int64; Snow: Boolean);
  end;

function UnitNoise(Key: Int64; Salt: Integer): Double; inline;
var
  Bits: UInt64;
begin
  // 32ビットずつマスクし、オーバーフロー検査付きの構成でも同じ乱数を得る。
  Bits := UInt64(Key and $FFFFFFFF) xor ((UInt64(Salt) * $9E3779B9) and $FFFFFFFF);
  Bits := ((Bits xor (Bits shr 16)) * $7FEB352D) and $FFFFFFFF;
  Bits := ((Bits xor (Bits shr 15)) * $846CA68B) and $FFFFFFFF;
  Result := (Bits xor (Bits shr 16)) / 4294967296.0;
end;

function TWeatherPuddle.Distance(DX, DY: Double): Double;
var
  R, S, C, S2, C2, S3, C3, S5, C5, S7, C7: Double;
begin
  R := DX * DX + DY * DY;
  if R > Sqr(1.27) then Exit(0.27);
  R := Sqrt(R);
  if R < 0.73 then Exit(R - 1);
  // 輪郭を作る3・5・7倍角を加法定理で求め、画素ごとの逆三角関数を省く。
  C := DX / R; S := DY / R;
  C2 := C * C - S * S; S2 := 2 * S * C;
  C3 := C * C2 - S * S2; S3 := S * C2 + C * S2;
  C5 := C3 * C2 - S3 * S2; S5 := S3 * C2 + C3 * S2;
  C7 := C5 * C2 - S5 * S2; S7 := S5 * C2 + C5 * S2;
  Result := R - 1 - (S3 * CosPhase + C3 * SinPhase) * 0.12 -
    (C5 * CosPhase + S5 * SinPhase) * 0.09 - (S7 * CosDoublePhase + C7 * SinDoublePhase) * 0.045;
end;

procedure TWeatherFrame.Blend(X, Y: Integer; Color: Cardinal; Coverage: Double);
var
  Pixel: PPIXEL_RGBA;
  Alpha, Base, Total, R, G, B: Integer;
begin
  Alpha := Round(EnsureRange(Coverage, 0.0, 1.0) * 255);
  if Alpha = 0 then Exit;
  Pixel := FPixels + (Y * FWidth + X);
  R := (Color shr 16) and $FF; G := (Color shr 8) and $FF; B := Color and $FF;
  if (Pixel^.A = 0) or (Alpha = 255) then
  begin
    Pixel^.R := R; Pixel^.G := G; Pixel^.B := B; Pixel^.A := Alpha;
    Exit;
  end;
  Base := ((255 - Alpha) * Pixel^.A + 127) div 255;
  Total := Base + Alpha;
  Pixel^.R := (R * Alpha + Pixel^.R * Base + Total div 2) div Total;
  Pixel^.G := (G * Alpha + Pixel^.G * Base + Total div 2) div Total;
  Pixel^.B := (B * Alpha + Pixel^.B * Base + Total div 2) div Total;
  Pixel^.A := Total;
end;

procedure TWeatherFrame.Stroke(const A, B: TWeatherPoint; Radius, Opacity: Double;
  Color: Cardinal; FadeTail: Boolean);
var
  SwapAxes: Boolean;
  AX, AY, BX, BY, DX, DY, LengthSquared, Reach, HalfBand, Center, Offset, T, Weight: Double;
  I, J, MaxI, MaxJ, FirstI, LastI, FirstJ, LastJ: Integer;
begin
  if Opacity <= 0 then Exit;
  SwapAxes := Abs(B.Y - A.Y) > Abs(B.X - A.X);
  if SwapAxes then
  begin
    AX := A.Y; AY := A.X; BX := B.Y; BY := B.X;
    MaxI := FHeight - 1; MaxJ := FWidth - 1;
  end
  else
  begin
    AX := A.X; AY := A.Y; BX := B.X; BY := B.Y;
    MaxI := FWidth - 1; MaxJ := FHeight - 1;
  end;
  Reach := Radius + 0.5;
  if (Max(AX, BX) + Reach < 0) or (Min(AX, BX) - Reach > MaxI + 1) or
    (Max(AY, BY) + Reach < 0) or (Min(AY, BY) - Reach > MaxJ + 1) then Exit;
  FirstI := Floor(Max(0.0, Min(AX, BX) - Reach));
  LastI := Ceil(Min(MaxI * 1.0, Max(AX, BX) + Reach));
  DX := BX - AX; DY := BY - AY;
  LengthSquared := DX * DX + DY * DY;
  if LengthSquared < 1.0E-8 then Exit;
  // 長軸に沿って細い帯だけ走査し、角度や解像度が大きくても外接矩形全体を塗らない。
  HalfBand := Reach * 1.42;
  for I := FirstI to LastI do
  begin
    Offset := I + 0.5 - AX;
    Center := AY + DY * EnsureRange(Offset / DX, 0.0, 1.0);
    FirstJ := Floor(Max(0.0, Center - HalfBand));
    LastJ := Ceil(Min(MaxJ * 1.0, Center + HalfBand));
    for J := FirstJ to LastJ do
    begin
      T := EnsureRange((Offset * DX + (J + 0.5 - AY) * DY) / LengthSquared, 0.0, 1.0);
      Weight := Reach - Sqrt(Sqr(Offset - T * DX) + Sqr(J + 0.5 - AY - T * DY));
      if Weight <= 0 then Continue;
      Weight := Min(1.0, Weight) * Opacity;
      if FadeTail then Weight := Weight * (0.04 + T * T * 0.96);
      if SwapAxes then Blend(J, I, Color, Weight) else Blend(I, J, Color, Weight);
    end;
  end;
end;

procedure TWeatherFrame.Snowflake(const P: TWeatherPoint; Radius, Opacity: Double);
var
  X, Y, Left, Top, Right, Bottom: Integer;
  Reach, T: Double;
begin
  Reach := Radius + 0.5;
  if (P.X + Reach < 0) or (P.Y + Reach < 0) or
    (P.X - Reach >= FWidth) or (P.Y - Reach >= FHeight) then Exit;
  Left := Floor(Max(0.0, P.X - Reach)); Top := Floor(Max(0.0, P.Y - Reach));
  Right := Ceil(Min(FWidth - 1.0, P.X + Reach)); Bottom := Ceil(Min(FHeight - 1.0, P.Y + Reach));
  for Y := Top to Bottom do
    for X := Left to Right do
    begin
      T := 1 - Sqrt(Sqr(X + 0.5 - P.X) + Sqr(Y + 0.5 - P.Y)) / Reach;
      if T > 0 then Blend(X, Y, SNOW_COLOR, Opacity * T * (2 - T));
    end;
end;

function TWeatherFrame.GroundPoint(U, V: Double; out P: TWeatherPoint): Boolean;
begin
  Result := FProjection.SurfaceToScreen(U, V, P.X, P.Y);
end;

function TWeatherFrame.GroundBounds(U, V, RadiusU, RadiusV: Double; out Bounds: TRect): Boolean;
var
  I, J: Integer;
  P: TWeatherPoint;
  Left, Top, Right, Bottom: Double;
begin
  Left := FWidth; Top := FHeight; Right := 0; Bottom := 0;
  for I := 0 to 1 do
    for J := 0 to 1 do
    begin
      if not GroundPoint(U + (I * 2 - 1) * RadiusU, V + (J * 2 - 1) * RadiusV, P) then Exit(False);
      Left := Min(Left, P.X); Top := Min(Top, P.Y);
      Right := Max(Right, P.X); Bottom := Max(Bottom, P.Y);
    end;
  Bounds := Rect(Floor(Max(0.0, Left - 2)), Floor(Max(0.0, Top - 2)),
    Ceil(Min(FWidth * 1.0, Right + 2)), Ceil(Min(FHeight * 1.0, Bottom + 2)));
  Result := (Bounds.Right > Bounds.Left) and (Bounds.Bottom > Bounds.Top);
end;

procedure TWeatherFrame.DrawPuddles(Amount: Double; Color: Cardinal; Seed: Int64);
const
  ScreenU: array[0..2] of Double = (0.51, 0.22, 0.80);
  ScreenV: array[0..2] of Double = (0.76, 0.57, 0.60);
  Span: array[0..2] of Double = (0.17, 0.079, 0.068);
var
  I, X, Y, R, G, B, TintR, TintG, TintB: Integer;
  P: PWeatherPuddle;
  U, V, DX, DY, Edge, Coverage, Light, Softness, SizeScale, Phase: Double;
begin
  if Amount <= 0 then Exit;
  TintR := (Color shr 16) and $FF; TintG := (Color shr 8) and $FF; TintB := Color and $FF;
  SizeScale := 0.65 + 0.60 * Sqrt(Amount);
  for I := 0 to High(FPuddles) do
  begin
    P := @FPuddles[FPuddleCount];
    if not FLayout.ScreenToSurface((ScreenU[I] + (UnitNoise(Seed, 31 + I) - 0.5) * 0.034) * FWidth,
      ScreenV[I] * FHeight, P^.U, P^.V) then Continue;
    P^.RadiusU := Span[I] * FWidth * SizeScale * FLayout.DepthAt(P^.U, P^.V) / FUnitSize;
    P^.RadiusV := P^.RadiusU * 0.53;
    Phase := UnitNoise(Seed, 40 + I) * TAU;
    SinCos(Phase, P^.SinPhase, P^.CosPhase);
    SinCos(Phase * 2, P^.SinDoublePhase, P^.CosDoublePhase);
    if not GroundBounds(P^.U, P^.V, P^.RadiusU * 1.27, P^.RadiusV * 1.27, P^.Bounds) then Continue;
    Inc(FPuddleCount);
    Softness := EnsureRange(3.0 / Max(1, P^.Bounds.Right - P^.Bounds.Left), 0.008, 0.24);
    for Y := P^.Bounds.Top to P^.Bounds.Bottom - 1 do
      for X := P^.Bounds.Left to P^.Bounds.Right - 1 do
      begin
        if not FProjection.ScreenToSurface(X + 0.5, Y + 0.5, U, V) then Continue;
        DX := (U - P^.U) / P^.RadiusU; DY := (V - P^.V) / P^.RadiusV;
        Edge := P^.Distance(DX, DY);
        if Edge >= Softness then Continue;
        Coverage := EnsureRange(0.5 - Edge / (2 * Softness), 0.0, 1.0);
        Light := Max(0.0, 1 - Sqr((DX + 0.32 + DY * 0.25) * 1.7)) * 0.37 +
          Max(0.0, 1 - Abs(Edge) / (Softness * 2.5)) * 0.19;
        R := Round(TintR * (0.60 + Light) + 70 * Light);
        G := Round(TintG * (0.65 + Light) + 78 * Light);
        B := Round(TintB * (0.69 + Light) + 82 * Light);
        Blend(X, Y, (Cardinal(Min(255, R)) shl 16) or (Cardinal(Min(255, G)) shl 8) or
          Cardinal(Min(255, B)), Coverage * (0.17 + 0.55 * Sqrt(Amount)));
      end;
  end;
end;

function TWeatherFrame.PuddleAt(U, V: Double): PWeatherPuddle;
var
  I: Integer;
  P: PWeatherPuddle;
begin
  for I := 0 to FPuddleCount - 1 do
  begin
    P := @FPuddles[I];
    if P^.Distance((U - P^.U) / P^.RadiusU, (V - P^.V) / P^.RadiusV) <= 0 then Exit(P);
  end;
  Result := nil;
end;

procedure TWeatherFrame.Ripple(U, V, Radius, Opacity, Phase: Double; Puddle: PWeatherPuddle);
var
  I, Divisions: Integer;
  Angle, Span, RingU, RingV, Edge: Double;
  Start, Finish: TWeatherPoint;
  WasVisible, Visible: Boolean;
begin
  if Puddle = nil then
  begin
    Span := TAU * 0.62;
    Divisions := 11;
  end
  else
  begin
    Span := TAU;
    Divisions := 22;
  end;
  WasVisible := False;
  for I := 0 to Divisions do
  begin
    Angle := Phase + I * Span / Divisions;
    RingU := U + Radius * Cos(Angle); RingV := V + Radius * Sin(Angle);
    Visible := GroundPoint(RingU, RingV, Finish);
    if Visible and (Puddle <> nil) then
    begin
      Edge := Puddle^.Distance((RingU - Puddle^.U) / Puddle^.RadiusU,
        (RingV - Puddle^.V) / Puddle^.RadiusV);
      Visible := Edge <= 0;
    end;
    if WasVisible and Visible then
      Stroke(Start, Finish, Max(0.23, FPixelScale * 0.30), Opacity, RIPPLE_COLOR);
    Start := Finish;
    WasVisible := Visible;
  end;
end;

procedure TWeatherFrame.RainImpact(U, V, Age, Strength, DepthScale: Double);
var
  Puddle: PWeatherPuddle;
  Life, Progress, Radius, Opacity, Rise: Double;
  Center, Tip: TWeatherPoint;
  Side: Integer;
begin
  Puddle := PuddleAt(U, V);
  if Puddle <> nil then Life := 0.65 else Life := 0.22;
  if Age >= Life then Exit;
  Progress := Age / Life;
  Radius := (0.009 + Age * (0.12 + 0.07 * Strength));
  Opacity := Sqr(1 - Progress) * Strength;
  if Puddle <> nil then
  begin
    Ripple(U, V, Radius * 1.45, Opacity * 0.54, Strength * TAU, Puddle);
    if Progress > 0.18 then
      Ripple(U, V, Radius * 0.74, Opacity * 0.25, Strength * TAU, Puddle);
  end
  else
    Ripple(U, V, Radius, Opacity * 0.42, Strength * TAU, nil);

  if (Age >= 0.15) or (Strength < 0.52) or not GroundPoint(U, V, Center) then Exit;
  Opacity := 1 - Age / 0.15;
  Rise := 0.85 * Age * Opacity;
  for Side := -1 to 1 do
    if (Side <> 0) and FProjection.ElevatedToScreen(U + Side * (0.004 + 0.23 * Age),
      V + Age * 0.08, Rise, Tip.X, Tip.Y) then
      Stroke(Center, Tip, FPixelScale * DepthScale * 0.44, Opacity * 0.65, SPLASH_COLOR);
end;

procedure TWeatherFrame.DrawPrecipitation(Time, Amount: Double; Seed: Int64; Snow: Boolean);
var
  Count, I: Integer;
  Key, Cycle, EventKey: Int64;
  Clock, Period, Phase, FallTime, Age, U, V, Altitude, TailHeight, DepthScale: Double;
  Strength, Wind, Drift, Feather, Rate, ScreenX, ScreenY: Double;
  Tip, Tail: TWeatherPoint;
begin
  if Snow then Count := Round(268 * Amount) else Count := Round(520 * Amount);
  for I := 0 to Count - 1 do
  begin
    Key := Seed * 70001 + I * 19 + 37;
    Clock := Time + UnitNoise(Key, 1) * 11;
    if Snow then FallTime := 2.8 + UnitNoise(Key, 2) * 2.3
    else FallTime := 0.43 + UnitNoise(Key, 2) * 0.25;
    Period := FallTime + 0.82 + UnitNoise(Key, 3) * 1.40;
    Cycle := Trunc(Clock / Period);
    if Clock < Cycle * Period then Dec(Cycle);
    Phase := Clock - Cycle * Period;
    Age := Phase - FallTime;
    if (Snow and (Age >= 0)) or (Age > 0.65) then Continue;
    EventKey := Key + Cycle * 6997;
    ScreenX := (UnitNoise(EventKey, 4) * 1.28 - 0.14) * FWidth;
    ScreenY := (UnitNoise(EventKey, 5) * 1.13 + 0.02) * FHeight;
    if not FLayout.ScreenToSurface(ScreenX, ScreenY, U, V) or (Abs(U) > 24) or (Abs(V) > 24) then Continue;
    Strength := 0.30 + UnitNoise(EventKey, 6) * 0.70;
    DepthScale := 1 / EnsureRange(FProjection.DepthAt(U, V), 0.54, 3.7);
    if Age >= 0 then
    begin
      RainImpact(U, V, Age, Strength, DepthScale);
      Continue;
    end;

    if Snow then
    begin
      Altitude := -Age * (0.34 + UnitNoise(Key, 7) * 0.24);
      Wind := FWind * 0.82;
      Drift := Sin(Phase * (1.9 + Strength * 1.6) + UnitNoise(Key, 8) * TAU);
      if FProjection.ElevatedToScreen(U - Altitude * Wind + Drift * (0.06 + Strength * 0.10),
        V + Sin(Phase * 1.4 + Strength * TAU) * 0.06, Altitude, Tip.X, Tip.Y) then
      begin
        Feather := Min(1.0, Min(Phase / 0.28, -Age / 0.29));
        Snowflake(Tip, FPixelScale * DepthScale * (0.65 + 2.70 * Sqr(Strength)),
          Feather * (0.32 + 0.62 * Strength));
      end;
    end
    else
    begin
      Rate := 1.70 + UnitNoise(Key, 7) * 0.90;
      Altitude := -Age * Rate;
      TailHeight := Altitude + Rate * (0.016 + UnitNoise(Key, 8) * 0.042);
      Wind := FWind * (0.43 + Strength * 0.16);
      if FProjection.ElevatedToScreen(U - Altitude * Wind, V, Altitude, Tip.X, Tip.Y) and
        FProjection.ElevatedToScreen(U - TailHeight * Wind, V, TailHeight, Tail.X, Tail.Y) then
        Stroke(Tail, Tip, FPixelScale * DepthScale * (0.48 + Strength * 0.51),
          Min(1.0, Phase / 0.06) * Strength * (0.38 + DepthScale * 0.33), RAIN_COLOR, True);
    end;
  end;
end;

procedure RenderAquaWeather(const Input: array of TPIXEL_RGBA; Width, Height: Integer;
  Time: Double; const Settings: TAquaSettings; ClipToInput: Boolean;
  var Output: array of TPIXEL_RGBA);
var
  Frame: TWeatherFrame;
  LayoutSettings: TAquaSettings;
  Track: TAquaTrack;
  HasInput, PreserveInput, MaskInput: Boolean;
  Opacity, Amount: Double;
  I, Alpha: Integer;
  Seed: Int64;
begin
  HasInput := Length(Input) = Length(Output);
  PreserveInput := (Settings.DisplayMode in [adImage, adOilOverlay, adWaveOverlay, adWaterOverlay]) or
    (ClipToInput and (Settings.DisplayMode = adBackground));
  MaskInput := ClipToInput and (Settings.DisplayMode = adEffectsOnly);
  FillChar(Output[0], Length(Output) * SizeOf(TPIXEL_RGBA), 0);
  if (PreserveInput or MaskInput) and not HasInput then Exit;

  Opacity := EnsureRange(1 - Settings.Tracks[atTransparency] * 0.01, 0.0, 1.0);
  Amount := EnsureRange(Settings.Tracks[atWeatherAmount] * 0.01, 0.0, 1.0);
  if (Opacity > 0) and (Amount > 0) then
  begin
    Frame := Default(TWeatherFrame);
    Frame.FProjection := TAquaProjection.Create(Width, Height, Settings);
    if Frame.FProjection.Valid then
    begin
      // 初期の撒き方は画面へ合わせ、利用者の座標・変形はその後の投影へ適用する。
      LayoutSettings := Settings;
      for Track := atX to atTransparency do LayoutSettings.Tracks[Track] := 0;
      LayoutSettings.Tracks[atZoom] := 100;
      LayoutSettings.Tracks[atRotation] := 0;
      Frame.FLayout := TAquaProjection.Create(Width, Height, LayoutSettings);
      Frame.FPixels := @Output[0]; Frame.FWidth := Width; Frame.FHeight := Height;
      Frame.FUnitSize := Min(Width, Height) * 0.46;
      Frame.FPixelScale := EnsureRange(Min(Width, Height) / 540, 0.65, 4.0);
      Frame.FWind := Settings.Tracks[atWeatherWind] * 0.01;
      Seed := Round(Settings.Tracks[atSeed]);
      if IsNan(Time) or IsInfinite(Time) then Time := 0;
      Time := EnsureRange(Time, -1.0E9, 1.0E9) * Settings.Tracks[atWeatherSpeed] * 0.01;
      if Settings.Shape = asRain then
        Frame.DrawPuddles(EnsureRange(Settings.Tracks[atRainPuddles] * 0.01, 0.0, 1.0),
          Settings.ColorRGB, Seed);
      Frame.DrawPrecipitation(Time, Amount, Seed, Settings.Shape = asSnow);
    end;
  end;

  if not (PreserveInput or MaskInput) and (Opacity = 1) then Exit;
  for I := 0 to High(Output) do
  begin
    Alpha := Round(Output[I].A * Opacity);
    if PreserveInput then
    begin
      if (Alpha = 0) or (Input[I].A = 0) then Output[I] := Input[I]
      else
      begin
        Output[I].R := (Input[I].R * (255 - Alpha) + Output[I].R * Alpha + 127) div 255;
        Output[I].G := (Input[I].G * (255 - Alpha) + Output[I].G * Alpha + 127) div 255;
        Output[I].B := (Input[I].B * (255 - Alpha) + Output[I].B * Alpha + 127) div 255;
        Output[I].A := Input[I].A;
      end;
    end
    else
    begin
      if MaskInput then Alpha := (Alpha * Input[I].A + 127) div 255;
      if Alpha = 0 then Output[I] := Default(TPIXEL_RGBA) else Output[I].A := Alpha;
    end;
  end;
end;

end.
