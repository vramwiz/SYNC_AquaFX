unit AquaFX_SurfaceShape;

// Copyright (c) 2026 VRAMの魔術師
// SPDX-License-Identifier: GPL-3.0-only

// 角丸の水面と流水で共用する輪郭。描画・保存状態は保持しない。

interface

// 正規化半幅・半高1の角丸四角の符号付き距離。負が内側、0が境界。
// Roundnessは0が直角、1が円。呼出側の座標・設定を変更しない。
function AquaRoundedDistance(U, V, Roundness: Double): Double;

implementation

uses System.Math;

function AquaRoundedDistance(U, V, Roundness: Double): Double;
var X, Y, R: Double;
begin
  R := EnsureRange(Roundness, 0.0, 1.0);
  X := Abs(U) - (1 - R); Y := Abs(V) - (1 - R);
  Result := Hypot(Max(0.0, X), Max(0.0, Y)) + Min(Max(X, Y), 0.0) - R;
end;

end.
