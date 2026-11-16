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
    FPhase, FInverseRadiusSquared: Double;
  public
    // 正の強さは画面上で時計回り。速さ0・強さ0では既存の描画を保つ。
    class function Create(const Settings: TAquaSettings; Time: Double): TAquaFlowField; static;
    // U/Vは水面中心基準の座標。元模様を読む座標と、その逆写像のヤコビ行列を返す。
    // 行列を波の勾配へ適用することで、渦で変わった面の向きも光沢へ反映する。
    procedure Map(U, V: Double; out FlowU, FlowV, J00, J01, J10, J11: Double);
    function Active: Boolean;
  end;

implementation

uses
  System.Math;

class function TAquaFlowField.Create(const Settings: TAquaSettings; Time: Double): TAquaFlowField;
var
  Radius: Double;
begin
  Result := Default(TAquaFlowField);
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
  Weight, Angle, S, C, DerivativeU, DerivativeV, Factor: Double;
begin
  FlowU := U; FlowV := V;
  J00 := 1; J01 := 0; J10 := 0; J11 := 1;
  if not Active then Exit;
  Weight := 1 - (U * U + V * V) * FInverseRadiusSquared;
  if Weight <= 0 then Exit;
  Angle := FPhase * Weight * Weight;
  SinCos(Angle, S, C);
  FlowU := C * U - S * V; FlowV := S * U + C * V;
  Factor := -4 * FPhase * Weight * FInverseRadiusSquared;
  DerivativeU := Factor * U; DerivativeV := Factor * V;
  J00 := C - FlowV * DerivativeU; J01 := -S - FlowV * DerivativeV;
  J10 := S + FlowU * DerivativeU; J11 := C + FlowU * DerivativeV;
end;

end.
