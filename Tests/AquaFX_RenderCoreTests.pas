unit AquaFX_RenderCoreTests;

// 共通描画器と数値計算をメモリ上で検査する。
// 合成前の幾何や水面の値を調べ、SDKコールバック経由の検査と失敗原因を区別する。

{$R+}
{$Q+}

interface

// ImageDirectoryへ検査画像を書き、結果を標準出力へ返す。条件を満たさなければ例外を送出する。
// 描画器と画素配列は検査中のみ所有する。
procedure VerifyAquaFXRenderCore(const ImageDirectory: string);

implementation

uses
  System.SysUtils, System.Math, System.Diagnostics,
  AviUtl2FilterTypes, AquaFX_Settings, AquaFX_Projection, AquaFX_Flow, AquaFX_Shore,
  AquaFX_Renderer, AquaFX_RenderTestSupport;

procedure VerifyProjection;
var
  Settings: TAquaSettings;
  Projection: TAquaProjection;
  X1, Y1, X2, Y2, U, V, X, Y: Double;
  I, J: Integer;
begin
  Settings := AquaPresetSettings(apPool);
  Settings.Tracks[atTilt] := 0; Settings.Tracks[atPerspective] := 0;
  Projection := TAquaProjection.Create(640, 360, Settings);
  Check(Projection.SurfaceToScreen(0, 0, X, Y) and
    SameValue(X, 320) and SameValue(Y, 180), 'Default plane center');
  Settings.Tracks[atX] := 25; Settings.Tracks[atY] := -15;
  Projection := TAquaProjection.Create(640, 360, Settings);
  Check(Projection.SurfaceToScreen(0, 0, X, Y) and
    SameValue(X, 345) and SameValue(Y, 165), 'XYZ pixel position');
  Settings.Tracks[atX] := 0; Settings.Tracks[atY] := 0;
  Settings.Tracks[atPerspective] := 65;
  Settings.Tracks[atTilt] := 45;
  Projection := TAquaProjection.Create(640, 360, Settings);
  Check(Projection.SurfaceToScreen(1, -0.75, X1, Y1) and
    Projection.SurfaceToScreen(1, 0.75, X2, Y2) and (X1 < X2), 'Positive tilt must put upper edge farther away');
  Check(Projection.ElevatedToScreen(1, 0.75, 0, X, Y) and
    SameValue(X, X2) and SameValue(Y, Y2), 'Precipitation height zero missed the ground');
  Check(Projection.ElevatedToScreen(1, 0.75, 0.45, X, Y) and
    (Y < Y2), 'Precipitation above the ground was not projected upward');
  Settings.Tracks[atTilt] := -45;
  Projection := TAquaProjection.Create(640, 360, Settings);
  Check(Projection.SurfaceToScreen(1, -0.75, X1, Y1) and
    Projection.SurfaceToScreen(1, 0.75, X2, Y2) and (X1 > X2), 'Negative tilt must put lower edge farther away');

  Settings.Tracks[atTilt] := 0; Settings.Tracks[atZ] := 0;
  Projection := TAquaProjection.Create(640, 360, Settings);
  Check(Projection.SurfaceToScreen(1, 0, X1, Y1), 'Base depth');
  Settings.Tracks[atZ] := 100;
  Projection := TAquaProjection.Create(640, 360, Settings);
  Check(Projection.SurfaceToScreen(1, 0, X2, Y2) and (X2 < X1), 'Positive Z must move the surface farther away');

  Settings.Tracks[atZ] := 0; Settings.Tracks[atPerspective] := 0;
  Settings.Tracks[atRotateZ] := 90;
  Projection := TAquaProjection.Create(640, 360, Settings);
  Check(Projection.SurfaceToScreen(1, 0, X, Y) and SameValue(X, 320, 1E-8) and
    (Y > 180), 'Positive Z rotation must be clockwise');
  Settings.Tracks[atCenterX] := 20;
  Projection := TAquaProjection.Create(640, 360, Settings);
  Check(Projection.SurfaceToScreen(20 / (360 * 0.46), 0, X, Y) and
    SameValue(X, 340, 1E-8) and SameValue(Y, 180, 1E-8), 'Rotation pivot did not stay fixed');

  Settings.Tracks[atTilt] := -32; Settings.Tracks[atRotateX] := 17;
  Settings.Tracks[atRotateY] := -24; Settings.Tracks[atRotateZ] := 13;
  Settings.Tracks[atRotation] := 22; Settings.Tracks[atCenterY] := -18;
  Settings.Tracks[atCenterZ] := 15; Settings.Tracks[atX] := 31;
  Settings.Tracks[atY] := -9; Settings.Tracks[atZ] := 40;
  Settings.Tracks[atZoom] := 135; Settings.Tracks[atAspect] := 25;
  Settings.Tracks[atPerspective] := 65;
  Projection := TAquaProjection.Create(640, 360, Settings);
  for I := -4 to 4 do
    for J := -4 to 4 do
    begin
      Check(Projection.SurfaceToScreen(I * 0.2, J * 0.2, X, Y), 'Combined transform projection');
      Check(Projection.ScreenToSurface(X, Y, U, V) and
        SameValue(U, I * 0.2, 1E-8) and SameValue(V, J * 0.2, 1E-8), 'Projection inverse mismatch');
    end;
  Settings.Tracks[atZoom] := 0;
  Projection := TAquaProjection.Create(640, 360, Settings);
  Check(not Projection.Valid, 'Zero zoom must make the surface invisible');
  Settings := AquaPresetSettings(apPool); Settings.Tracks[atTilt] := 0;
  Settings.Tracks[atZ] := -10000;
  Projection := TAquaProjection.Create(640, 360, Settings);
  Check(not Projection.SurfaceToScreen(0, 0, X, Y), 'Surface behind the camera was visible');
  Writeln('PASS projection: signed tilt, XYZ, depth, rotation pivot, 81 inverse samples, zero zoom and camera clipping');
end;

// 回転の向き、半径保存、逆時刻と勾配を、画像の見た目とは独立に検査する。
procedure VerifyVortexFlow;
var
  Settings: TAquaSettings;
  Flow, Reverse: TAquaFlowField;
  U, V, A, B, C, D, X, Y, E, F, G, H: Double;
begin
  Check((Ord(adOilOverlay) = 3) and (Ord(apMagic) = 13), 'Existing saved indices changed');
  Settings := AquaPresetSettings(apCoffee);
  Flow := TAquaFlowField.Create(Settings, 2);
  Flow.Map(0.5, 0.2, U, V, A, B, C, D);
  Check((U = 0.5) and (V = 0.2), 'Zero vortex changed coordinates');
  Settings.Tracks[atViscosity] := 0;
  Settings.Tracks[atVortexStrength] := 60;
  Settings.Tracks[atVortexSpeed] := 1.2;
  Flow := TAquaFlowField.Create(Settings, 2);
  Flow.Map(0.5, 0, U, V, A, B, C, D);
  Check((V < 0) and SameValue(Sqr(U) + Sqr(V), 0.25, 1E-12), 'Vortex direction/radius');
  Reverse := TAquaFlowField.Create(Settings, -2);
  Reverse.Map(U, V, X, Y, E, F, G, H);
  Check(SameValue(X, 0.5, 1E-12) and SameValue(Y, 0, 1E-12), 'Vortex inverse time');
  Flow.Map(0.3, 0.2, U, V, A, B, C, D);
  Flow.Map(0.300001, 0.2, X, Y, E, F, G, H);
  Check(SameValue((X - U) / 0.000001, A, 1E-5) and
    SameValue((Y - V) / 0.000001, C, 1E-5), 'Vortex derivative U');
  Flow.Map(0.3, 0.200001, X, Y, E, F, G, H);
  Check(SameValue((X - U) / 0.000001, B, 1E-5) and
    SameValue((Y - V) / 0.000001, D, 1E-5), 'Vortex derivative V');
  Flow.Map(4, 3, U, V, A, B, C, D);
  Check((U = 4) and (V = 3), 'Vortex changed coordinates outside radius');
  Flow := TAquaFlowField.Create(Settings, 2, 0.3, -0.2);
  Flow.Map(0.3, -0.2, U, V, A, B, C, D);
  Check(SameValue(U, 0.3) and SameValue(V, -0.2), 'Moved vortex center is not fixed');
  Flow.Map(0.8, -0.2, U, V, A, B, C, D);
  Check(SameValue(Sqr(U - 0.3) + Sqr(V + 0.2), 0.25, 1E-12), 'Moved vortex radius changed');
  Settings.Tracks[atVortexSpeed] := 0;
  Flow := TAquaFlowField.Create(Settings, 2);
  Check(not Flow.Active, 'Zero vortex speed remains active');
  Settings := AquaPresetSettings(apVortex);
  Check((Settings.Tracks[atVortexStrength] > 0) and
    (Settings.Tracks[atFlowSpeed] = 0), 'Vortex preset is not rotational');
  Writeln('PASS vortex flow: saved indices, zero, direction, radius, inverse time and derivatives');
end;

// 岸ごとの折返し時刻をまたいでも、広い泡が一度に現れないことを確認する。
procedure VerifyShoreRetreatContinuity;
const
  Periods: array[0..2] of Double = (0.5, 6, 30);
  Roughness: array[0..2] of Double = (0, 50, 100);
  Edge = 3 / 432;
var
  Settings, WithoutTrail: TAquaSettings;
  Field, Earlier, Later, NoTrail: TAquaShore;
  Column, BeforeColumn, AfterColumn: TAquaShoreColumn;
  A, B, C: TAquaShoreSample;
  I, J, K, N: Integer;
  U, V, Offset, TurnTime, MaxJump, MaxOffshoreTrail, Peak: Double;
begin
  MaxJump := 0; MaxOffshoreTrail := 0;
  for I := 0 to High(Periods) do
    for J := 0 to High(Roughness) do
    begin
      Settings := AquaPresetSettings(apShore);
      Settings.Tracks[atShorePeriod] := Periods[I];
      Settings.Tracks[atShoreRoughness] := Roughness[J];
      Settings.Tracks[atShoreFoamLife] := 100;
      for K := -16 to 16 do
      begin
        U := K * 0.12;
        Field := TAquaShore.Create(Settings, 0);
        Column := Field.PrepareColumn(U);
        Offset := Column.Phase;
        if Offset > 0.5 then Offset := Offset - 1;
        TurnTime := (0.36 - Offset) * Periods[I];
        Earlier := TAquaShore.Create(Settings, TurnTime - Periods[I] * 1E-6);
        Later := TAquaShore.Create(Settings, TurnTime + Periods[I] * 1E-6);
        BeforeColumn := Earlier.PrepareColumn(U); AfterColumn := Later.PrepareColumn(U);
        for N := 0 to 47 do
        begin
          V := BeforeColumn.Front - 0.5 + N * 0.012;
          A := Earlier.Sample(U, V, Edge, BeforeColumn);
          B := Later.Sample(U, V, Edge, AfterColumn);
          MaxJump := Max(MaxJump, Abs(A.Foam - B.Foam));
          MaxJump := Max(MaxJump, Abs(A.Wet - B.Wet));
        end;
        Check(MaxJump < 0.002, Format('Shore foam popped at turnaround: %.6f', [MaxJump], TFormatSettings.Invariant));
        Field := TAquaShore.Create(Settings, TurnTime);
        Column := Field.PrepareColumn(U); Peak := Column.Peak;
        Later := TAquaShore.Create(Settings, TurnTime + Periods[I] * 0.10);
        AfterColumn := Later.PrepareColumn(U);
        // 残る泡は水が離れた砂浜側だけ。沖に広い泡の面を突然追加しない。
        WithoutTrail := Settings; WithoutTrail.Tracks[atShoreFoamLife] := 0;
        NoTrail := TAquaShore.Create(WithoutTrail, TurnTime + Periods[I] * 0.10);
        for N := 0 to 31 do
        begin
          V := AfterColumn.Front - 0.10 - N * 0.012;
          B := Later.Sample(U, V, Edge, AfterColumn);
          C := NoTrail.Sample(U, V, Edge, AfterColumn);
          MaxOffshoreTrail := Max(MaxOffshoreTrail, Abs(B.Foam - C.Foam));
          MaxOffshoreTrail := Max(MaxOffshoreTrail, B.Wet);
        end;
        Check(SameValue(Peak, AfterColumn.Peak, 1E-12), 'Shore maximum reach moved during retreat');
        Check(SameValue(Column.Front, Peak, 1E-12), 'Shore maximum reach differs from turning edge');
      end;
    end;
  Check(MaxOffshoreTrail < 1E-12, 'Shore residual foam appeared offshore');
  Writeln('PASS shore retreat: continuous turnaround, fixed maximum reach and no offshore foam slab; max jump ', MaxJump:0:6);
end;

// 着水点がシードで移動せず、時刻で広がり、逆シークで復元することを確認する。
procedure VerifyDropRipples;
var
  Renderer: TAquaRenderer;
  Settings: TAquaSettings;
  Input, A, B, C: TAquaPixels;
  Preset: TAquaPreset;
begin
  for Preset := apSea to apVortex do
    Check(AquaPresetSettings(Preset).Tracks[atRippleScatter] = 100,
      'Existing preset changed ripple distribution');
  Renderer := TAquaRenderer.Create;
  try
    Settings := AquaPresetSettings(apDropRipples);
    Renderer.Render(Input, 320, 240, 1, Settings, False, A);
    Settings.Tracks[atSeed] := 999;
    Renderer.Render(Input, 320, 240, 1, Settings, False, B);
    Check(Same(A, B), 'Fixed impact point depends on seed');
    Renderer.Render(Input, 320, 240, 1.5, Settings, False, C);
    Check(not Same(A, C), 'Drop ripples did not expand');
    Renderer.Render(Input, 320, 240, 1, Settings, False, C);
    Check(Same(A, C), 'Drop ripples changed on reverse seek');
    Settings.Tracks[atRippleAspect] := 100;
    Renderer.Render(Input, 320, 240, 1, Settings, False, C);
    Check(not Same(A, C), 'Ripple aspect correction has no effect');
    Settings.Tracks[atRippleAspect] := 0;
    Settings.Tracks[atRippleScatter] := 100;
    Renderer.Render(Input, 320, 240, 1, Settings, False, C);
    Check(not Same(A, C), 'Ripple scatter has no effect');
  finally
    Renderer.Free;
  end;
  Writeln('PASS drop ripples: fixed impact, expansion, reverse seek, aspect and old defaults');
end;

procedure VerifyRenderer(const ImageDirectory: string);
var
  Renderer: TAquaRenderer;
  Settings: TAquaSettings;
  Input, A, B, C: TAquaPixels;
  I: Integer;
  Visible, Transparent: Boolean;
  Timer: TStopwatch;
begin
  Renderer := TAquaRenderer.Create;
  try
    Settings := AquaPresetSettings(apSea);
    Renderer.Render(Input, 1280, 720, 0, Settings, False, A);
    SaveRenderTestPNG(A, 1280, 720, ImageDirectory + 'sea.png');
    Renderer.Render(Input, 1280, 720, 1.25, Settings, False, B);
    Check(not Same(A, B), 'Sea animation is static');
    SaveRenderTestPNG(B, 1280, 720, ImageDirectory + 'sea_next.png');
    Renderer.Render(Input, 1280, 720, 0, Settings, False, C);
    Check(Same(A, C), 'Reverse seek is not deterministic');
    Settings.Tracks[atSeed] := 99;
    Renderer.Render(Input, 1280, 720, 0, Settings, False, C);
    Check(not Same(A, C), 'Seed has no effect');
    Settings := AquaPresetSettings(apCoffee);
    Renderer.Render(Input, 640, 360, 0, Settings, False, A);
    Check((A[0].A = 0) and (A[180 * 640 + 320].A = 255), 'Projected shape mask');
    SaveRenderTestPNG(A, 640, 360, ImageDirectory + 'coffee.png');
    Settings := AquaPresetSettings(apSea); Settings.DisplayMode := adEffectsOnly;
    Renderer.Render(Input, 640, 360, 0, Settings, False, A);
    Visible := False; Transparent := False;
    for I := 0 to High(A) do
    begin
      Visible := Visible or (A[I].A > 0); Transparent := Transparent or (A[I].A < 255);
    end;
    Check(Visible and Transparent, 'Effects-only mode has no transparent overlay');
    Settings.Tracks[atHighlight] := 0; Settings.Tracks[atFoam] := 0;
    Renderer.Render(Input, 640, 360, 0, Settings, False, A);
    for I := 0 to High(A) do
      Check((A[I].A = 0) and (A[I].R = 0) and (A[I].G = 0) and (A[I].B = 0), 'Transparent RGB is not zero');
    Settings := AquaPresetSettings(apSea); Settings.DisplayMode := adImage;
    SetLength(Input, 64 * 64);
    FillChar(Input[0], Length(Input) * SizeOf(TPIXEL_RGBA), 0);
    for I := Length(Input) div 2 to High(Input) do
    begin
      Input[I].R := 160; Input[I].G := 90; Input[I].B := 40; Input[I].A := 128;
    end;
    Renderer.Render(Input, 64, 64, 0, Settings, True, A);
    for I := 0 to High(A) do
      Check((A[I].A <= Input[I].A) and ((Input[I].A <> 0) or (A[I].A = 0)), 'Image alpha boundary');
    Renderer.Render(Input, 0, 64, 0, Settings, False, A);
    Check(Length(A) = 0, 'Invalid size');
    Settings := AquaPresetSettings(apSea); SetLength(Input, 0);
    Timer := TStopwatch.StartNew;
    for I := 0 to 2 do Renderer.Render(Input, 1920, 1080, I * 0.1, Settings, False, A);
    Writeln('Full HD average milliseconds: ', Timer.Elapsed.TotalMilliseconds / 3:0:1);
    Writeln('PASS renderer: animation, reverse seek, seed, projected shape, transparency, input alpha and invalid size');
  finally
    Renderer.Free;
  end;
end;

procedure VerifyOilRenderer;
var
  Renderer: TAquaRenderer;
  Settings: TAquaSettings;
  Input, A, B, C: TAquaPixels;
  I: Integer;
  Visible: Boolean;
  Timer: TStopwatch;
begin
  Renderer := TAquaRenderer.Create;
  try
    Settings := AquaPresetSettings(apOil);
    Renderer.Render(Input, 320, 240, 0, Settings, False, A);
    Renderer.Render(Input, 320, 240, 2, Settings, False, B);
    Check(not Same(A, B), 'Oil renderer animation');
    Renderer.Render(Input, 320, 240, 0, Settings, False, C);
    Check(Same(A, C), 'Oil renderer reverse seek');
    Settings.Tracks[atSeed] := 99;
    Renderer.Render(Input, 320, 240, 0, Settings, False, C);
    Check(not Same(A, C), 'Oil renderer seed');
    Settings.DisplayMode := adEffectsOnly;
    Settings.Tracks[atHighlight] := 0; Settings.Tracks[atFoam] := 0;
    Renderer.Render(Input, 320, 240, 0, Settings, False, A);
    Visible := False;
    for I := 0 to High(A) do
    begin
      Visible := Visible or (A[I].A > 0);
      Check(A[I].A < 255, 'Effects-only film must retain transparency');
      if A[I].A = 0 then Check((A[I].R = 0) and (A[I].G = 0) and (A[I].B = 0), 'Oil transparent RGB');
    end;
    Check(Visible, 'Effects-only oil is invisible');
    Settings.Tracks[atOilAmount] := 0;
    Renderer.Render(Input, 320, 240, 0, Settings, False, A);
    for I := 0 to High(A) do Check(A[I].A = 0, 'Disabled oil left an overlay');
    Settings := AquaPresetSettings(apOil); Settings.DisplayMode := adImage;
    Settings.Tracks[atTilt] := 0; Settings.Tracks[atPerspective] := 0;
    SetLength(Input, 64 * 64);
    FillChar(Input[0], Length(Input) * SizeOf(TPIXEL_RGBA), 0);
    for I := Length(Input) div 2 to High(Input) do
    begin
      Input[I].R := 70; Input[I].G := 120; Input[I].B := 160; Input[I].A := 128;
    end;
    Renderer.Render(Input, 64, 64, 0, Settings, True, A);
    for I := 0 to High(A) do Check(A[I].A <= Input[I].A, 'Oil painted outside input alpha');
    Settings := AquaPresetSettings(apOil); SetLength(Input, 0);
    Timer := TStopwatch.StartNew;
    for I := 0 to 2 do Renderer.Render(Input, 1920, 1080, I * 0.1, Settings, False, A);
    Writeln('Oil Full HD average milliseconds: ', Timer.Elapsed.TotalMilliseconds / 3:0:1);
    Writeln('PASS oil renderer: seed, reverse seek, transparent overlay, zero amount and image alpha');
  finally
    Renderer.Free;
  end;
end;

procedure VerifyAquaFXRenderCore(const ImageDirectory: string);
begin
  VerifyProjection;
  VerifyVortexFlow;
  VerifyDropRipples;
  VerifyShoreRetreatContinuity;
  VerifyRenderer(IncludeTrailingPathDelimiter(ImageDirectory));
  VerifyOilRenderer;
end;

end.
