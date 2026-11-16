unit AquaFX_VortexSurface;

// Copyright (c) 2026 VRAMの魔術師
// SPDX-License-Identifier: GPL-3.0-only

// 渦の凹み・螺旋状の吸い込みと、タイムライン全長に対応する排水を評価する。
// フレーム間の履歴やホスト所有ポインターを保持せず、逆シークでも同じ値を返す。

interface

uses
  AquaFX_Settings, AviUtl2FilterTypes;

type
  TAquaVortexSample = record
    Mask, Height, GradU, GradV, Shade, Light, Foam, PullU, PullV: Double;
  end;
  TAquaVortexSurface = record
  private
    FCU, FCV, FMX, FMY, FRadius, FDepth, FPull, FPhase, FRemaining, FProgress: Double;
    FDrain, FSpinDirection, FCornerRoundness: Double;
    FPoolSize, FPoolRound, FOpening, FInverseRadiusSquared: Double;
    FLate, FLongScale, FSideScale, FDirectionX, FDirectionY, FTransportU, FTransportV: Double;
    FUpstreamReach, FStreamShape: Double;
    FShape: TAquaShape;
  public
    // 中心は共通投影の局所座標、MX/MYは見かけの縦横差を補う距離係数。
    // Progressはオブジェクト先頭0～最終フレーム1。保存設定を変更しない。
    class function Create(const Settings: TAquaSettings; Time, Progress,
      CU, CV, MX, MY: Double): TAquaVortexSurface; static;
    // 水面座標から法線・淡い陰影・屈折・被覆率を返す。結果はこの時刻だけで有効。
    function Sample(U, V, Edge: Double): TAquaVortexSample;
    // 終盤の水面模様を上流から読むための逆移流。被覆率を薄めず、栓への流れを出す。
    // U/Vは呼出側の数値だけを更新する。通常の渦と排水前半では値を維持する。
    procedure Advect(var U, V: Double);
    function Empty: Boolean;
  end;

// SDKの現在フレームと総フレーム数から0～1を返す。1フレームは終了状態。
// 総フレーム数がない検査呼出しでは秒数を使い、長さも不明なら先頭状態にする。
function AquaObjectProgress(const Obj: TOBJECT_INFO): Double;

implementation

uses
  System.Math, AquaFX_SurfaceShape;

function Clamp01(X: Double): Double; inline;
begin
  Result := Max(0.0, Min(1.0, X));
end;

function Smooth(A, B, X: Double): Double; inline;
begin
  Result := Clamp01((X - A) / (B - A));
  Result := Result * Result * (3 - 2 * Result);
end;

function AquaObjectProgress(const Obj: TOBJECT_INFO): Double;
begin
  if Obj.FrameTotal > 1 then Exit(Clamp01(Obj.Frame / (Obj.FrameTotal - 1)));
  if Obj.FrameTotal = 1 then Exit(1);
  if (not IsNan(Obj.TimeTotal)) and (not IsInfinite(Obj.TimeTotal)) and
    (Obj.TimeTotal > 0) and (not IsNan(Obj.Time)) and (not IsInfinite(Obj.Time)) then
    Exit(Clamp01(Obj.Time / Obj.TimeTotal));
  Result := 0;
end;

class function TAquaVortexSurface.Create(const Settings: TAquaSettings;
  Time, Progress, CU, CV, MX, MY: Double): TAquaVortexSurface;
var
  VortexPower, Length, EndScale: Double;
begin
  Result := Default(TAquaVortexSurface);
  Result.FCU := CU; Result.FCV := CV;
  Result.FMX := Max(0.01, MX); Result.FMY := Max(0.01, MY);
  Result.FShape := Settings.Shape;
  Result.FCornerRoundness := Settings.Tracks[atCornerRoundness] * 0.01;
  Result.FDrain := Settings.Tracks[atDrainAmount] * 0.01;
  Result.FProgress := Clamp01(Progress);
  Result.FRemaining := 1 - Result.FDrain * Smooth(0, 1, Result.FProgress);
  Result.FRadius := 0.28 + Settings.Tracks[atVortexRadius] * 0.009;
  Result.FInverseRadiusSquared := 1 / Sqr(Result.FRadius);
  Result.FPoolSize := Power(Result.FRemaining, 0.23);
  Result.FPoolRound := Smooth(0.45, 0.95, Min(0.60, Result.FProgress));
  Result.FOpening := Result.FDrain * Smooth(0.03, 0.55, Result.FProgress) * 0.12;
  // 前半の吸い込みを保ち、後半だけ水の尾を栓へ運ぶ。水面全体のフェードは行わない。
  Result.FLate := Smooth(0.60, 1, Result.FDrain * Result.FProgress);
  if Result.FLate > 0 then
  begin
    Result.FDirectionX := -CU * Result.FMX; Result.FDirectionY := -CV * Result.FMY;
    Length := Hypot(Result.FDirectionX, Result.FDirectionY);
    if Length < 0.01 then
    begin
      Result.FDirectionX := -1; Result.FDirectionY := 0;
      if Result.FMY > Result.FMX then begin Result.FDirectionX := 0; Result.FDirectionY := -1; end;
    end else
    begin
      Result.FDirectionX := Result.FDirectionX / Length;
      Result.FDirectionY := Result.FDirectionY / Length;
    end;
    Length := Hypot((1 + Abs(CU)) * Result.FMX, (1 + Abs(CV)) * Result.FMY);
    EndScale := Result.FOpening * Result.FRadius * 0.75 / Length;
    Result.FLongScale := Result.FPoolSize + (EndScale - Result.FPoolSize) * Result.FLate;
    Result.FSideScale := Result.FPoolSize * (1 - Result.FLate * 0.90);
    Result.FUpstreamReach := (1 + Abs(CU)) * Result.FMX * Abs(Result.FDirectionX) +
      (1 + Abs(CV)) * Result.FMY * Abs(Result.FDirectionY);
    Result.FStreamShape := Smooth(0.15, 0.85, Result.FLate);
    Result.FTransportU := Result.FDirectionX * Length * Result.FLate * 0.65 / Result.FMX;
    Result.FTransportV := Result.FDirectionY * Length * Result.FLate * 0.65 / Result.FMY;
  end;
  VortexPower := Abs(Settings.Tracks[atVortexStrength]) * 0.01;
  Result.FDepth := Settings.Tracks[atVortexDepth] * 0.01 * VortexPower;
  Result.FPull := Settings.Tracks[atVortexPull] * 0.01 * VortexPower;
  if Result.FDrain > 0 then
  begin
    Result.FDepth := Result.FDepth * (0.25 + 0.75 * Smooth(0, 0.45, Result.FProgress));
    Result.FPull := Result.FPull * Smooth(0, 0.10, Result.FProgress);
  end;
  Result.FPhase := Time * Settings.Tracks[atVortexSpeed] * 2.4;
  Result.FSpinDirection := 1;
  if Settings.Tracks[atVortexStrength] < 0 then Result.FSpinDirection := -1;
end;

function TAquaVortexSurface.Empty: Boolean;
begin
  Result := FRemaining <= 0;
end;

procedure TAquaVortexSurface.Advect(var U, V: Double);
begin
  if FLate <= 0 then Exit;
  U := U + FTransportU; V := V + FTransportV;
end;

function TAquaVortexSurface.Sample(U, V, Edge: Double): TAquaVortexSample;
var
  X, Y, R2, Q, R, Angle, Spiral, Ring, Core, A, B, Norm, Along, Across, Tail, Width: Double;
begin
  Result := Default(TAquaVortexSample); Result.Mask := 1; Result.Shade := 1;
  if Empty then begin Result.Mask := 0; Exit; end;
  if FDrain > 0 then
  begin
    // 終盤は上流側の尾が細くなりながら栓へ進み、小さな排水口の内側へ吸い込まれる。
    if FLate > 0 then
    begin
      X := (U - FCU) * FMX; Y := (V - FCV) * FMY;
      Along := X * FDirectionX + Y * FDirectionY;
      Tail := Clamp01(Along / (FLongScale * FUpstreamReach));
      // 栓の手前で細くなり、上流端は丸い水の尾にする。四角い切り抜きを運ばない。
      Width := (0.16 + 0.84 * Sqrt(Tail)) * Sqrt(Max(0.0, 1 - Tail * Tail));
      Width := 1 + (Max(0.02, Width) - 1) * FStreamShape;
      Along := Along / FLongScale;
      Across := (-X * FDirectionY + Y * FDirectionX) / (FSideScale * Width);
      A := Abs((Along * FDirectionX - Across * FDirectionY) / FMX + FCU);
      B := Abs((Along * FDirectionY + Across * FDirectionX) / FMY + FCV);
    end else
    begin
      A := Abs((U - FCU) / FPoolSize + FCU); B := Abs((V - FCV) / FPoolSize + FCV);
    end;
    Norm := Max(A, B);
    if FShape = asEllipse then Norm := Sqrt(A * A + B * B)
    else if FShape = asRoundedRectangle then
      Norm := 1 + AquaRoundedDistance(A, B, FCornerRoundness)
    else Norm := Norm + (Sqrt(A * A + B * B) - Norm) * FPoolRound;
    if FProgress > 0 then Result.Mask := 1 - Smooth(1 - Edge * 2, 1 + Edge * 2, Norm);
    if Result.Mask <= 0 then Exit;
  end;
  X := (U - FCU) * FMX; Y := (V - FCV) * FMY;
  R2 := (X * X + Y * Y) * FInverseRadiusSquared;
  if R2 >= 1 then Exit;
  Q := 1 - R2;
  Result.Height := -FDepth * Q * Q * Q * 0.55;
  Result.GradU := FDepth * 3.3 * X * FMX * FInverseRadiusSquared * Q * Q;
  Result.GradV := FDepth * 3.3 * Y * FMY * FInverseRadiusSquared * Q * Q;
  R := Sqrt(R2);
  Core := 1 - Smooth(0.015, 0.30, R);
  Result.Shade := 1 - FDepth * (0.20 * Core + 0.08 * Q * Q);
  if FPull > 0 then
  begin
    Angle := ArcTan2(Y, X);
    // 吸い込みの位相・速度・屈折は保ち、独立して浮いて見える白い線を加算しない。
    // 同じ螺旋はごく淡い水面の濃淡だけへ使う。中心の特異点は包絡で消す。
    Spiral := Sin(-Angle * 3 * FSpinDirection + R * 27 + FPhase);
    Ring := Smooth(0.05, 0.18, R) * Q * Q;
    Result.Shade := Result.Shade * (1 - (1 - Spiral) * Ring * FPull * 0.018);
    Result.PullU := X / FMX * Q * Q * FPull * 0.12;
    Result.PullV := Y / FMY * Q * Q * FPull * 0.12;
  end;
  if FDrain > 0 then
  begin
    if FOpening > 0 then Result.Mask := Result.Mask * Smooth(FOpening * 0.45, FOpening, R);
  end;
end;

end.
