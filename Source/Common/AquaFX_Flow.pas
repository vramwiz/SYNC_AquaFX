unit AquaFX_Flow;

// Copyright (c) 2026 VRAMの魔術師
// SPDX-License-Identifier: GPL-3.0-only

// 水面の局所座標を時刻から直接移流する。前フレームやホストの状態は保持しない。
// 中心ほど速く回る滑らかな流れで、平行移動とは異なる渦を波と油膜へ与える。

interface

uses
  AquaFX_Settings;

type
  TAquaFlowField = record
  private
    FPhase, FInverseRadiusSquared, FCU, FCV: Double;
  public
    // 設定と秒単位のTimeからこの時刻の変換を作る。強さの正は時計回り。
    // CenterU/Vは共通投影の水面座標。既定値0では従来どおり水面原点を回る。
    class function Create(const Settings: TAquaSettings; Time: Double;
      CenterU: Double = 0; CenterV: Double = 0): TAquaFlowField; static;
    // U/Vは水面中心基準の座標。元模様を読む座標と、その逆写像のヤコビ行列を返す。
    // 行列を波の勾配へ適用することで、渦で変わった面の向きも光沢へ反映する。
    procedure Map(U, V: Double; out FlowU, FlowV, J00, J01, J10, J11: Double);
    // この時刻の回転位相が0以外のときTrue。0なら呼出側は座標の変換を省ける。
    function Active: Boolean;
  end;

implementation

uses
  System.Math;

class function TAquaFlowField.Create(const Settings: TAquaSettings;
  Time, CenterU, CenterV: Double): TAquaFlowField;
var
  Radius: Double;
begin
  Result := Default(TAquaFlowField);
  Result.FCU := CenterU; Result.FCV := CenterV;
  Result.FPhase := -Time * Settings.Tracks[atVortexStrength] * 0.01 *
    Settings.Tracks[atVortexSpeed] * 0.8 / (1 + Settings.Tracks[atViscosity] * 0.02);
  Radius := 0.2 + Settings.Tracks[atVortexRadius] * 0.02;
  Result.FInverseRadiusSquared := 1 / Sqr(Radius);
end;

function TAquaFlowField.Active: Boolean;
begin
  Result := FPhase <> 0;
end;

procedure TAquaFlowField.Map(U, V: Double;
  out FlowU, FlowV, J00, J01, J10, J11: Double);
var
  Weight, Angle, S, C, DerivativeU, DerivativeV, Factor, X, Y, RX, RY: Double;
begin
  FlowU := U; FlowV := V;
  J00 := 1; J01 := 0; J10 := 0; J11 := 1;
  if not Active then Exit;
  X := U - FCU; Y := V - FCV;
  Weight := 1 - (X * X + Y * Y) * FInverseRadiusSquared;
  if Weight <= 0 then Exit;
  Angle := FPhase * Weight * Weight;
  SinCos(Angle, S, C);
  RX := C * X - S * Y; RY := S * X + C * Y;
  FlowU := RX + FCU; FlowV := RY + FCV;
  Factor := -4 * FPhase * Weight * FInverseRadiusSquared;
  DerivativeU := Factor * X; DerivativeV := Factor * Y;
  J00 := C - RY * DerivativeU; J01 := -S - RY * DerivativeV;
  J10 := S + RX * DerivativeU; J11 := C + RX * DerivativeV;
end;

end.
