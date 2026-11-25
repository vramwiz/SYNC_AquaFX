unit AquaFX_Projection;

// Copyright (c) 2026 VRAMの魔術師
// SPDX-License-Identifier: GPL-3.0-only

// 水面の位置・中心・拡縮・3軸回転を、順変換と逆変換の共通行列へまとめる。
// 正の傾斜は上側が奥、負の傾斜は下側が奥。ピクセル座標は右・下が正。

interface

uses
  AquaFX_Settings;

type
  TAquaMatrix3 = array[0..2, 0..2] of Double;
  TAquaProjection = record
  private
    FForward, FInverse: TAquaMatrix3;
    FCenterX, FCenterY: Double;
    FHeightX, FHeightY, FHeightDepth: Double;
    FValid: Boolean;
  public
    // Width/Heightはピクセル。設定から呼出側所有の変換を作る。無効な寸法・変換ではValidが偽。
    // 設定を値として読み、描画器所有の変換を返す。ホストや設定を変更しない。
    // ImageBounds=Trueは正規化座標±1を入力画像の各辺、それ以外は水面の辺へ対応する。
    // 拡大率0または縦横比±100で面積が0になる場合は無効な投影を返す。
    class function Create(Width, Height: Integer; const Settings: TAquaSettings;
      ImageBounds: Boolean = False): TAquaProjection; static;
    // X/Yは画像中心基準ではなく画像内のピクセル座標。U/Vは水面の正規化座標。
    // カメラの背面・近すぎる面・変換不能な面ではFalseを返す。
    function ScreenToSurface(X, Y: Double; out U, V: Double): Boolean;
    // 水面上のU/Vをピクセル座標X/Yへ投影する。画面外も返すので必要なら呼出側で切り取る。
    // カメラの背面・近すぎる面・無効な変換ではFalseを返す。
    function SurfaceToScreen(U, V: Double; out X, Y: Double): Boolean;
    // 水面に垂直な高さを加えて投影する。高さ1は拡大・回転前の水面基準の半辺長。
    // Height=0は水面そのもの。カメラ背面と近すぎる点はFalseを返す。
    function ElevatedToScreen(U, V, Height: Double; out X, Y: Double): Boolean;
    // 透視投影の距離係数。1より大きい面は遠く、小さい面は近い。
    function DepthAt(U, V: Double): Double;
    property Valid: Boolean read FValid;
  end;

implementation

uses
  System.Math;

function Multiply(const A, B: TAquaMatrix3): TAquaMatrix3;
var
  I, J, K: Integer;
begin
  Result := Default(TAquaMatrix3);
  for I := 0 to 2 do
    for J := 0 to 2 do
      for K := 0 to 2 do Result[I, J] := Result[I, J] + A[I, K] * B[K, J];
end;

function Invert(const M: TAquaMatrix3; out R: TAquaMatrix3): Boolean;
var
  Det: Double;
begin
  R[0, 0] := M[1, 1] * M[2, 2] - M[1, 2] * M[2, 1];
  R[0, 1] := M[0, 2] * M[2, 1] - M[0, 1] * M[2, 2];
  R[0, 2] := M[0, 1] * M[1, 2] - M[0, 2] * M[1, 1];
  R[1, 0] := M[1, 2] * M[2, 0] - M[1, 0] * M[2, 2];
  R[1, 1] := M[0, 0] * M[2, 2] - M[0, 2] * M[2, 0];
  R[1, 2] := M[0, 2] * M[1, 0] - M[0, 0] * M[1, 2];
  R[2, 0] := M[1, 0] * M[2, 1] - M[1, 1] * M[2, 0];
  R[2, 1] := M[0, 1] * M[2, 0] - M[0, 0] * M[2, 1];
  R[2, 2] := M[0, 0] * M[1, 1] - M[0, 1] * M[1, 0];
  Det := M[0, 0] * R[0, 0] + M[0, 1] * R[1, 0] + M[0, 2] * R[2, 0];
  Result := Abs(Det) > 1.0E-8;
  if Result then
  begin
    Det := 1 / Det;
    R[0, 0] := R[0, 0] * Det; R[0, 1] := R[0, 1] * Det; R[0, 2] := R[0, 2] * Det;
    R[1, 0] := R[1, 0] * Det; R[1, 1] := R[1, 1] * Det; R[1, 2] := R[1, 2] * Det;
    R[2, 0] := R[2, 0] * Det; R[2, 1] := R[2, 1] * Det; R[2, 2] := R[2, 2] * Det;
  end;
end;

class function TAquaProjection.Create(Width, Height: Integer;
  const Settings: TAquaSettings; ImageBounds: Boolean): TAquaProjection;
var
  RX, RY, RZ, Heading, R: TAquaMatrix3;
  S, C, ScaleX, ScaleY, ScaleZ, HalfX, HalfY, Aspect, Perspective: Double;
  Center: array[0..2] of Double;
  Translation: array[0..2] of Double;
  I: Integer;
begin
  Result := Default(TAquaProjection);
  if (Width <= 0) or (Height <= 0) or (Settings.Tracks[atZoom] <= 0) then Exit;
  Aspect := Settings.Tracks[atAspect] * 0.01;
  if Abs(Aspect) >= 1 then Exit;
  Result.FCenterX := Width * 0.5; Result.FCenterY := Height * 0.5;
  HalfX := Min(Width, Height) * 0.46; HalfY := HalfX;
  if ImageBounds then
  begin
    HalfX := Width * 0.5; HalfY := Height * 0.5;
  end;
  ScaleZ := Settings.Tracks[atZoom] * 0.01;
  // 拡大率で基準寸法を決め、横長の場合は高さ、縦長の場合は幅を縮める。
  ScaleX := ScaleZ * (1 - Max(0.0, -Aspect));
  ScaleY := ScaleZ * (1 - Max(0.0, Aspect));

  RX := Default(TAquaMatrix3); RY := RX; RZ := RX; Heading := RX;
  // 下側を手前へ倒す向きを正にし、従来の透視方向の逆転を修正する。
  SinCos(DegToRad(-Settings.Tracks[atTilt] - Settings.Tracks[atRotateX]), S, C);
  RX[0, 0] := 1; RX[1, 1] := C; RX[1, 2] := -S; RX[2, 1] := S; RX[2, 2] := C;
  SinCos(DegToRad(Settings.Tracks[atRotateY]), S, C);
  RY[1, 1] := 1; RY[0, 0] := C; RY[0, 2] := S; RY[2, 0] := -S; RY[2, 2] := C;
  SinCos(DegToRad(Settings.Tracks[atRotateZ]), S, C);
  RZ[2, 2] := 1; RZ[0, 0] := C; RZ[0, 1] := -S; RZ[1, 0] := S; RZ[1, 1] := C;
  SinCos(DegToRad(-Settings.Tracks[atRotation]), S, C);
  Heading[2, 2] := 1; Heading[0, 0] := C; Heading[0, 1] := -S;
  Heading[1, 0] := S; Heading[1, 1] := C;
  R := Multiply(RZ, Multiply(RY, Multiply(RX, Heading)));

  Center[0] := Settings.Tracks[atCenterX]; Center[1] := Settings.Tracks[atCenterY];
  Center[2] := Settings.Tracks[atCenterZ];
  Translation[0] := Settings.Tracks[atX]; Translation[1] := Settings.Tracks[atY];
  Translation[2] := Settings.Tracks[atZ];
  for I := 0 to 2 do
  begin
    Result.FForward[I, 0] := R[I, 0] * ScaleX * HalfX;
    Result.FForward[I, 1] := R[I, 1] * ScaleY * HalfY;
    Result.FForward[I, 2] := Translation[I] + Center[I] -
      (R[I, 0] * ScaleX * Center[0] + R[I, 1] * ScaleY * Center[1] +
       R[I, 2] * ScaleZ * Center[2]);
  end;
  Perspective := Settings.Tracks[atPerspective] * 0.006 / (Min(Width, Height) * 0.46);
  for I := 0 to 2 do Result.FForward[2, I] := Result.FForward[2, I] * Perspective;
  Result.FForward[2, 2] := Result.FForward[2, 2] + 1;
  S := -ScaleZ * Min(Width, Height) * 0.46;
  Result.FHeightX := R[0, 2] * S;
  Result.FHeightY := R[1, 2] * S;
  Result.FHeightDepth := R[2, 2] * S * Perspective;
  Result.FValid := Invert(Result.FForward, Result.FInverse);
end;

function TAquaProjection.ScreenToSurface(X, Y: Double; out U, V: Double): Boolean;
var
  Weight: Double;
begin
  U := 0; V := 0;
  Result := False;
  if not FValid then Exit;
  X := X - FCenterX; Y := Y - FCenterY;
  Weight := FInverse[2, 0] * X + FInverse[2, 1] * Y + FInverse[2, 2];
  if (Weight <= 1.0E-8) or (Weight > 50) then Exit;
  U := (FInverse[0, 0] * X + FInverse[0, 1] * Y + FInverse[0, 2]) / Weight;
  V := (FInverse[1, 0] * X + FInverse[1, 1] * Y + FInverse[1, 2]) / Weight;
  // 地平線付近の無限座標を三角関数の整数インデックスへ渡さない。
  Result := (Abs(U) < 1.0E6) and (Abs(V) < 1.0E6);
end;

function TAquaProjection.SurfaceToScreen(U, V: Double; out X, Y: Double): Boolean;
var
  Weight: Double;
begin
  X := 0; Y := 0;
  Result := False;
  if not FValid then Exit;
  Weight := FForward[2, 0] * U + FForward[2, 1] * V + FForward[2, 2];
  if Weight < 0.02 then Exit;
  X := (FForward[0, 0] * U + FForward[0, 1] * V + FForward[0, 2]) / Weight + FCenterX;
  Y := (FForward[1, 0] * U + FForward[1, 1] * V + FForward[1, 2]) / Weight + FCenterY;
  Result := True;
end;

function TAquaProjection.ElevatedToScreen(U, V, Height: Double; out X, Y: Double): Boolean;
var
  Weight: Double;
begin
  X := 0; Y := 0;
  Result := False;
  if not FValid then Exit;
  Weight := DepthAt(U, V) + Height * FHeightDepth;
  if Weight < 0.02 then Exit;
  X := (FForward[0, 0] * U + FForward[0, 1] * V + FForward[0, 2] +
    Height * FHeightX) / Weight + FCenterX;
  Y := (FForward[1, 0] * U + FForward[1, 1] * V + FForward[1, 2] +
    Height * FHeightY) / Weight + FCenterY;
  Result := True;
end;

function TAquaProjection.DepthAt(U, V: Double): Double;
begin
  Result := FForward[2, 0] * U + FForward[2, 1] * V + FForward[2, 2];
end;

end.
