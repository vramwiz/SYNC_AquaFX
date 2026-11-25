unit AquaFX_Flush;

// Copyright (c) 2026 VRAMの魔術師
// SPDX-License-Identifier: GPL-3.0-only

// 内周から排水口へ回り込む薄い水膜を時刻・進行度から直接評価する。
// 給水の開始と終了を各場所への到達時間だけ遅らせ、履歴やホスト画像を保持しない。

interface

uses AquaFX_Settings;

type
  TAquaFlushSample = record
    Coverage, Shade, Light: Double;
  end;
  TAquaFlush = record
  private
    FCU, FCV, FProgress, FPhase, FSpin, FAmount, FWidth, FStop, FRound, FFoam: Double;
  public
    // CU/CVは排水口の水面座標。Timeは秒、Progressはオブジェクト全長に対する0～1。
    // 保存設定は借用中も変更せず、結果はこのフレーム内だけ使用する。
    class function Create(const Settings: TAquaSettings; Time, Progress,
      CU, CV: Double): TAquaFlush; static;
    // U/Vは外周の半幅・半高を1とする。Edgeは境界をぼかす水面座標での幅。
    // 水膜の被覆率と陰影・照りを返し、この時刻の評価器を使い回せる。
    function Sample(U, V, Edge: Double): TAquaFlushSample;
  end;

implementation

uses System.Math, AquaFX_SurfaceShape;

function Smooth(A, B, X: Double): Double; inline;
begin
  Result := EnsureRange((X - A) / (B - A), 0.0, 1.0);
  Result := Result * Result * (3 - 2 * Result);
end;

class function TAquaFlush.Create(const Settings: TAquaSettings; Time, Progress,
  CU, CV: Double): TAquaFlush;
begin
  Result := Default(TAquaFlush);
  Result.FCU := CU; Result.FCV := CV;
  Result.FProgress := EnsureRange(Progress, 0.0, 1.0);
  Result.FSpin := Settings.Tracks[atVortexStrength] * 0.02;
  Result.FPhase := Time * Settings.Tracks[atVortexSpeed] * 2.4 * Result.FSpin;
  Result.FAmount := Settings.Tracks[atFlushAmount] * 0.01;
  Result.FWidth := Settings.Tracks[atFlushWidth] * 0.01;
  Result.FStop := Settings.Tracks[atFlushStop] * 0.01;
  Result.FRound := Settings.Tracks[atCornerRoundness] * 0.01;
  Result.FFoam := Settings.Tracks[atFoam] * 0.01;
end;

function TAquaFlush.Sample(U, V, Edge: Double): TAquaFlushSample;
var
  D, R, Radial, Angle, Travel, Emitted, Envelope, Material, Broad, Streak, Outside, Breakup, Film: Double;
begin
  Result := Default(TAquaFlushSample); Result.Shade := 1;
  if (FProgress <= 0) or (FProgress >= 1) or (FAmount <= 0) then Exit;
  D := AquaRoundedDistance(U, V, FRound);
  Outside := 1 - Smooth(-Edge, Edge, D);
  if Outside <= 0 then Exit;
  R := Hypot(U - FCU, V - FCV);
  Radial := R / Max(0.00001, R + Max(0.0, -D));
  Angle := ArcTan2(V - FCV, U - FCU);
  // 同じ水が外周で先に現れ、止水後も内側へ進んでから消える。
  Travel := (1 - Radial) * (0.97 - FStop);
  Emitted := FProgress - Travel - 0.012 * (1 + Sin(Angle));
  Envelope := Smooth(0, 0.055, Emitted) * (1 - Smooth(FStop - 0.055, FStop, Emitted));
  if Envelope <= 0 then Exit;
  // 角度一定の筋は時間とともに半径が小さくなる符号にし、中心へ流す。
  Material := Angle + FSpin * (1 - Radial) * 2.7 - FPhase;
  Broad := 0.5 + 0.5 * Sin(Material * 3 + Sin(Material * 2 + Radial * 8) * 0.8);
  Streak := Smooth(1 - FWidth * 0.55, 1,
    Sin(Material * 9 + Radial * 18 + Sin(Material * 3) * 1.3 +
      Sin(Radial * 29 + FPhase * 0.7) * 0.8));
  Breakup := Smooth(-0.15, 0.65, Sin(Material * 5 + Radial * 13 + FPhase * 0.45));
  Streak := Streak * Breakup;
  // 同じ流れを重なった水膜の厚みで見せる。到達・止水と筋の位相は変えない。
  Film := (0.10 + 0.20 * Broad + 0.06 * Streak) * (0.55 + 0.45 * Smooth(0.1, 0.9, Radial));
  Film := 1 - Sqr(1 - Film) * (1 - Film);
  Result.Coverage := Outside * Envelope * FAmount * Smooth(0.045, 0.12, R) * Film;
  Result.Shade := 0.90 + 0.13 * Broad;
  Result.Light := Streak * (0.025 + FFoam * 0.12);
end;

end.
