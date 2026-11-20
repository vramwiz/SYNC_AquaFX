program AquaFX_RenderTests;

// 本番AUF2の描画コールバックと共通描画器を検査する。ホストアプリは起動しない。
// 検査画像は検査EXEと同じフォルダー以下へ書き、本番のパラメータは保存しない。

{$APPTYPE CONSOLE}
{$R+}
{$Q+}

uses
  System.SysUtils, System.Math, System.Diagnostics, System.Classes,
  System.Hash, Winapi.Windows,
  Vcl.Imaging.pngimage,
  AviUtl2FilterTypes in '..\Source\Lib\AviUtl2FilterTypes.pas',
  AquaFX_Settings in '..\Source\Common\AquaFX_Settings.pas',
  AquaFX_SurfaceShape in '..\Source\Common\AquaFX_SurfaceShape.pas',
  AquaFX_Flush in '..\Source\Common\AquaFX_Flush.pas',
  AquaFX_OilSurface in '..\Source\Common\AquaFX_OilSurface.pas',
  AquaFX_Projection in '..\Source\Common\AquaFX_Projection.pas',
  AquaFX_Flow in '..\Source\Common\AquaFX_Flow.pas',
  AquaFX_VortexSurface in '..\Source\Common\AquaFX_VortexSurface.pas',
  AquaFX_Shore in '..\Source\Common\AquaFX_Shore.pas',
  AquaFX_Renderer in '..\Source\Common\AquaFX_Renderer.pas';

type
  TGetTable = function: PFILTER_PLUGIN_TABLE; cdecl;
  TInitialize = function(Version: Cardinal): Byte; cdecl;
  TUninitialize = procedure; cdecl;

var
  Captured, HostInput: TAquaPixels;
  CaptureWidth, CaptureHeight, SetCount: Integer;
  ImageDirectory: string;
  PluginPath: string;

procedure Check(Condition: Boolean; const Message_: string);
begin
  if not Condition then raise Exception.Create(Message_);
end;

function Same(const A, B: TAquaPixels): Boolean;
begin
  Result := (Length(A) = Length(B)) and
    ((Length(A) = 0) or CompareMem(@A[0], @B[0], Length(A) * SizeOf(TPIXEL_RGBA)));
end;

procedure SavePNG(const Pixels: TAquaPixels; Width, Height: Integer; const Name: string);
var
  PNG: TPngImage;
  Row: PByte;
  X, Y: Integer;
begin
  PNG := TPngImage.CreateBlank(COLOR_RGBALPHA, 8, Width, Height);
  try
    for Y := 0 to Height - 1 do
    begin
      Row := PNG.Scanline[Y];
      for X := 0 to Width - 1 do
      begin
        Row[X * 3] := Pixels[Y * Width + X].B;
        Row[X * 3 + 1] := Pixels[Y * Width + X].G;
        Row[X * 3 + 2] := Pixels[Y * Width + X].R;
        PNG.AlphaScanline[Y]^[X] := Pixels[Y * Width + X].A;
      end;
    end;
    PNG.SaveToFile(ImageDirectory + Name);
  finally
    PNG.Free;
  end;
end;

procedure GetImage(Buffer: PPIXEL_RGBA); cdecl;
begin
  if Length(HostInput) > 0 then
    Move(HostInput[0], Buffer^, Length(HostInput) * SizeOf(TPIXEL_RGBA));
end;

procedure SetImage(Buffer: PPIXEL_RGBA; Width, Height: Integer); cdecl;
begin
  Inc(SetCount);
  CaptureWidth := Width; CaptureHeight := Height;
  SetLength(Captured, Width * Height);
  Move(Buffer^, Captured[0], Length(Captured) * SizeOf(TPIXEL_RGBA));
end;

function AcceptItem(Obj: OBJECT_HANDLE; Effect, Item: PWideChar;
  Value: PAnsiChar): Boolean; cdecl;
begin
  Result := (Obj = Pointer(1234)) and (string(Effect) = '水面演出:2') and
    (Item <> nil) and (Value <> nil);
end;

function FindItem(Table: PFILTER_PLUGIN_TABLE; const Name, Kind: string): Pointer;
var
  Items: PPointer;
  Header: PFILTER_ITEM_STRING;
  I: Integer;
begin
  Items := PPointer(Table^.Items);
  for I := 0 to 98 do
  begin
    if Items^ = nil then Break;
    Header := PFILTER_ITEM_STRING(Items^);
    if (string(Header^.Name) = Name) and (string(Header^.ItemType) = Kind) then Exit(Items^);
    Inc(Items);
  end;
  raise Exception.Create('Missing standard item: ' + Name);
end;

function AlphaCenter(const Pixels: TAquaPixels; Width: Integer;
  out X, Y: Double): Double;
var
  I: Integer;
begin
  X := 0; Y := 0; Result := 0;
  for I := 0 to High(Pixels) do
  begin
    Result := Result + Pixels[I].A;
    X := X + (I mod Width) * Pixels[I].A;
    Y := Y + (I div Width) * Pixels[I].A;
  end;
  if Result > 0 then
  begin
    X := X / Result; Y := Y / Result;
  end;
end;

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

procedure VerifyNativePlacement(Table: PFILTER_PLUGIN_TABLE; var Video: TFILTER_PROC_VIDEO);
const
  Names: array[0..11] of PWideChar = ('X', 'Y', 'Z', '中心X', '中心Y', '中心Z',
    'X軸回転', 'Y軸回転', 'Z軸回転', '拡大率', '縦横比', '透明度');
  Values: array[0..11] of Double = (11, -7, 13, 2, 3, 4, 5, -6, 7, 123, 20, 25);
var
  Edit: TEDIT_SECTION;
  Preset: PFILTER_ITEM_SELECT;
  Button: PFILTER_ITEM_BUTTON;
  Item: PFILTER_ITEM_TRACK;
  A, Positive, Negative, Combined: TAquaPixels;
  I, X, Y: Integer;
  X1, Y1, X2, Y2, Area1, Area2: Double;

  procedure SetNumber(const Name: string; Value: Double);
  begin
    PFILTER_ITEM_TRACK(FindItem(Table, Name, 'track'))^.Value := Value;
  end;

  procedure Frame;
  begin
    SetCount := 0;
    Check(Table^.Func_Proc_Video(@Video) = 1, 'Transform frame callback');
    Check((SetCount = 1) and (CaptureWidth = 204) and (CaptureHeight = 204), 'Transform frame size');
  end;

begin
  Video.Object_^.Flag := OBJECT_FLAG_FILTER_OBJECT;
  Edit := Default(TEDIT_SECTION); Edit.SetObjectItemValue := AcceptItem;
  Preset := FindItem(Table, 'プリセット', 'select');
  Button := FindItem(Table, '設定', 'button');
  for I := 0 to High(Names) do SetNumber(string(Names[I]), Values[I]);
  Preset^.Value := Ord(apPool);
  Button^.Callback2(@Edit, Pointer(1234), '水面演出:2', '設定');
  for I := 0 to High(Names) do
  begin
    Item := FindItem(Table, string(Names[I]), 'track');
    Check(SameValue(Item^.Value, Values[I]), 'Preset changed placement: ' + string(Names[I]));
    SetNumber(string(Names[I]), 0);
  end;
  SetNumber('拡大率', 100);
  Item := FindItem(Table, '3D傾斜角度', 'track');
  Check((Item^.S = -89) and (Item^.E = 89), 'Signed tilt control range');
  SetNumber('3D傾斜角度', 45); Frame; Positive := Copy(Captured);
  SavePNG(Positive, 204, 204, 'tilt_positive.png');
  SetNumber('3D傾斜角度', -45); Frame; Negative := Copy(Captured);
  SavePNG(Negative, 204, 204, 'tilt_negative.png');
  Check(not Same(Positive, Negative), 'Signed tilt produced the same frame');
  SetLength(Combined, 408 * 204);
  for Y := 0 to 203 do
    for X := 0 to 203 do
    begin
      Combined[Y * 408 + X] := Positive[Y * 204 + X];
      Combined[Y * 408 + X + 204] := Negative[Y * 204 + X];
    end;
  SavePNG(Combined, 408, 204, 'tilt_comparison.png');

  // 3軸回転と中心XYZが、本番の各トラックから描画へ接続されていることを確認する。
  SetNumber('3D傾斜角度', 0); SetNumber('拡大率', 60);
  Frame; A := Copy(Captured);
  for I := 6 to 8 do
  begin
    SetNumber(string(Names[I]), 30); Frame;
    Check(not Same(A, Captured), 'Rotation control did not affect native output: ' + string(Names[I]));
    SetNumber(string(Names[I]), 0);
  end;
  SetNumber('X軸回転', 20); SetNumber('Y軸回転', 17); SetNumber('Z軸回転', 19);
  Frame; A := Copy(Captured);
  for I := 3 to 5 do
  begin
    SetNumber(string(Names[I]), 15); Frame;
    Check(not Same(A, Captured), 'Center control did not affect native output: ' + string(Names[I]));
    SetNumber(string(Names[I]), 0);
  end;
  SetNumber('X軸回転', 0); SetNumber('Y軸回転', 0); SetNumber('Z軸回転', 0);
  Frame; A := Copy(Captured);
  SetNumber('縦横比', 50); Frame;
  Check(not Same(A, Captured), 'Positive aspect control had no effect');
  Positive := Copy(Captured);
  SetNumber('縦横比', -50); Frame;
  Check(not Same(A, Captured) and not Same(Positive, Captured), 'Negative aspect control had no effect');
  SetNumber('縦横比', 0);

  SetNumber('3D傾斜角度', 0); SetNumber('遠近感', 0); SetNumber('拡大率', 60);
  Frame; A := Copy(Captured); Area1 := AlphaCenter(A, 204, X1, Y1);
  SetNumber('X', 25); SetNumber('Y', -15); Frame;
  Area2 := AlphaCenter(Captured, 204, X2, Y2);
  Check((Area1 > 0) and SameValue(Area1, Area2, 1E-6) and
    SameValue(X2 - X1, 25, 0.05) and SameValue(Y2 - Y1, -15, 0.05), 'Native XY placement');
  SetNumber('X', 0); SetNumber('Y', 0); SetNumber('遠近感', 65); SetNumber('Z', 100);
  Frame; Area2 := AlphaCenter(Captured, 204, X2, Y2);
  Check((Area2 > 0) and (Area2 < Area1), 'Native Z depth');
  SetNumber('Z', 0); SetNumber('遠近感', 0); SetNumber('透明度', 50); Frame;
  Check(Captured[102 * 204 + 102].A = 128, 'Native transparency percentage');
  SetNumber('透明度', 100); Frame;
  for I := 0 to High(Captured) do Check(Captured[I].A = 0, 'Fully transparent surface');
  SetNumber('透明度', 0); SetNumber('拡大率', 0); Frame;
  for I := 0 to High(Captured) do Check(Captured[I].A = 0, 'Zero scale surface');

  // 画像の透明領域も同じ投影で移動し、透明色が描画範囲へにじまないことを確認する。
  SetNumber('拡大率', 100);
  PFILTER_ITEM_SELECT(FindItem(Table, '表示モード', 'select'))^.Value := Ord(adImage);
  PFILTER_ITEM_SELECT(FindItem(Table, '水面形状', 'select'))^.Value := Ord(asImage);
  FillChar(HostInput[0], Length(HostInput) * SizeOf(TPIXEL_RGBA), 0);
  for Y := 80 to 119 do
    for X := 80 to 119 do
    begin
      HostInput[Y * 204 + X].R := 150; HostInput[Y * 204 + X].A := 128;
    end;
  Frame; A := Copy(Captured); Area1 := AlphaCenter(A, 204, X1, Y1);
  SetNumber('X', 20); Frame; Area2 := AlphaCenter(Captured, 204, X2, Y2);
  Check((Area1 > 0) and (Area2 > 0) and SameValue(X2 - X1, 20, 0.1) and
    SameValue(Y2, Y1, 0.1), 'Projected input alpha did not move with the image');
  SavePNG(Captured, 204, 204, 'image_placement.png');
  Writeln('PASS native placement: 12 controls, preset preservation, both tilt signs, XYZ, transparency, zero scale and image alpha');
end;

procedure VerifyNativeOil(Table: PFILTER_PLUGIN_TABLE; var Video: TFILTER_PROC_VIDEO);
var
  Edit: TEDIT_SECTION;
  OilColor: PFILTER_ITEM_COLOR;
  WithOil, WithoutOil, Frozen: TAquaPixels;
  I, Changed, Unchanged: Integer;

  procedure SetNumber(const Name: string; Value: Double);
  begin
    PFILTER_ITEM_TRACK(FindItem(Table, Name, 'track'))^.Value := Value;
  end;

  procedure Frame;
  begin
    SetCount := 0; Table^.Func_Proc_Video(@Video);
    Check(SetCount = 1, 'Oil frame was not returned');
  end;

  procedure Preset(Value: TAquaPreset);
  begin
    PFILTER_ITEM_SELECT(FindItem(Table, 'プリセット', 'select'))^.Value := Ord(Value);
    PFILTER_ITEM_BUTTON(FindItem(Table, '設定', 'button'))^.Callback2(
      @Edit, Pointer(1234), '水面演出:2', '設定');
  end;

begin
  Video.Object_^.Flag := OBJECT_FLAG_FILTER_OBJECT;
  Edit := Default(TEDIT_SECTION); Edit.SetObjectItemValue := AcceptItem;
  for I := Ord(atX) to Ord(atTransparency) do
    SetNumber(string(AQUA_TRACK_DEFINITIONS[TAquaTrack(I)].Name), 0);
  SetNumber('拡大率', 100);
  PFILTER_ITEM_SELECT(FindItem(Table, '表示モード', 'select'))^.Value := Ord(adBackground);
  Preset(apOil);
  Frame; WithOil := Copy(Captured);
  SetNumber('油膜の量', 0); Frame; WithoutOil := Copy(Captured);
  Changed := 0; Unchanged := 0;
  for I := 0 to High(Captured) do
  begin
    Check(WithOil[I].A = WithoutOil[I].A, 'Oil film changed the background alpha');
    if WithoutOil[I].A <> 255 then Continue;
    if CompareMem(@WithOil[I], @WithoutOil[I], SizeOf(TPIXEL_RGBA)) then Inc(Unchanged)
    else Inc(Changed);
  end;
  Check((Changed > 500) and (Unchanged > 500), 'Oil must form separate patches over visible water');
  SetNumber('油膜サイズ', 25); SetNumber('油膜光沢', 0);
  OilColor := FindItem(Table, '油膜色', 'color');
  OilColor^.R := 255; OilColor^.G := 0; OilColor^.B := 0;
  Frame;
  Check(Same(WithoutOil, Captured), 'Disabled film depends on its color, size or gloss');
  Preset(apOil);
  SetNumber('油膜サイズ', 25); Frame;
  Check(not Same(WithOil, Captured), 'Oil size control did not change native output');
  Preset(apOil); SetNumber('油膜光沢', 0); Frame;
  Check(not Same(WithOil, Captured), 'Oil gloss control did not change native output');
  Preset(apOil); OilColor^.R := 50; OilColor^.G := 100; OilColor^.B := 240; Frame;
  Check(not Same(WithOil, Captured), 'Oil color control did not change native output');
  Preset(apOil);
  Video.Object_^.Time := 1.25; Frame; Frozen := Copy(Captured);
  Video.Object_^.Time := 3; Frame;
  Check(not Same(Frozen, Captured), 'Oil film does not animate');
  Video.Object_^.Time := 1.25; Frame;
  Check(Same(Frozen, Captured), 'Reverse seeking changed the native oil film');
  Preset(apPool);
  Check(PFILTER_ITEM_TRACK(FindItem(Table, '油膜の量', 'track'))^.Value = 0,
    'Switching from oil to water left an unwanted oil film');
  Writeln('PASS native oil: separate patches, visible water, amount zero, size, gloss, color, animation, reverse seek and reset');
end;

// 本番の画像モードで、膜だけの配置・透明度・シークと元画像の保持を検査する。
procedure VerifyNativeOilOverlay(Table: PFILTER_PLUGIN_TABLE; var Video: TFILTER_PROC_VIDEO);
var
  Edit: TEDIT_SECTION;
  First, Comparison: TAquaPixels;
  I, X, Y, Changed, TexturePairs: Integer;
  TextureContrast: Double;

  procedure SetNumber(const Name: string; Value: Double);
  begin
    PFILTER_ITEM_TRACK(FindItem(Table, Name, 'track'))^.Value := Value;
  end;

  procedure Frame;
  begin
    SetCount := 0; Table^.Func_Proc_Video(@Video);
    Check(SetCount = 1, 'Oil overlay frame was not returned');
  end;

begin
  Edit := Default(TEDIT_SECTION); Edit.SetObjectItemValue := AcceptItem;
  PFILTER_ITEM_SELECT(FindItem(Table, '表示モード', 'select'))^.Value := Ord(adOilOverlay);
  PFILTER_ITEM_SELECT(FindItem(Table, 'プリセット', 'select'))^.Value := Ord(apOil);
  PFILTER_ITEM_BUTTON(FindItem(Table, '設定', 'button'))^.Callback2(
    @Edit, Pointer(1234), '水面演出:2', '設定');
  Check(PFILTER_ITEM_SELECT(FindItem(Table, '表示モード', 'select'))^.Value = Ord(adOilOverlay),
    'Preset changed oil overlay mode');
  for I := Ord(atX) to Ord(atTransparency) do
    SetNumber(string(AQUA_TRACK_DEFINITIONS[TAquaTrack(I)].Name), 0);
  SetNumber('拡大率', 100); SetNumber('3D傾斜角度', 0); SetNumber('遠近感', 0);
  Video.Object_^.Flag := 0; Video.Object_^.Width := 204; Video.Object_^.Height := 204;
  Video.Object_^.Time := 1.25; Video.GetImageData := GetImage;
  SetLength(HostInput, 204 * 204);
  for Y := 0 to 203 do
    for X := 0 to 203 do
    begin
      I := Y * 204 + X;
      HostInput[I].R := 70 + ((X + Y) mod 2) * 100;
      HostInput[I].G := 60 + (Y mod 24) * 3;
      HostInput[I].B := 30 + (X mod 24) * 2;
      HostInput[I].A := 80 + (X mod 176);
      if Y < 8 then HostInput[I].A := 0;
    end;
  Frame; First := Copy(Captured); Changed := 0; TexturePairs := 0; TextureContrast := 0;
  for I := 0 to High(First) do
  begin
    Check(First[I].A = HostInput[I].A, 'Overlay changed original alpha or moved the image');
    if not CompareMem(@First[I], @HostInput[I], SizeOf(TPIXEL_RGBA)) then Inc(Changed);
    if (I div 204 < 8) or ((I mod 204 < 8) and (I div 204 > 195)) then
      Check(CompareMem(@First[I], @HostInput[I], SizeOf(TPIXEL_RGBA)), 'Overlay painted outside its mask');
    if (I mod 204 > 0) and (I div 204 > 8) then
    begin
      TextureContrast := TextureContrast + Abs(Integer(First[I].R) - First[I - 1].R);
      Inc(TexturePairs);
    end;
  end;
  Check(Changed > 500, 'Overlay did not produce visible oil');
  Check(TextureContrast / TexturePairs > 85, 'Overlay erased source texture contrast');
  SetLength(Comparison, 408 * 204);
  for Y := 0 to 203 do
  begin
    Move(HostInput[Y * 204], Comparison[Y * 408], 204 * SizeOf(TPIXEL_RGBA));
    Move(First[Y * 204], Comparison[Y * 408 + 204], 204 * SizeOf(TPIXEL_RGBA));
  end;
  SavePNG(Comparison, 408, 204, 'oil_overlay_check.png');
  Video.Object_^.Time := 4; Frame;
  Check(not Same(First, Captured), 'Overlay did not animate');
  Video.Object_^.Time := 1.25; Frame;
  Check(Same(First, Captured), 'Overlay reverse seek changed the result');
  SetNumber('X', 10000); Frame;
  Check(Same(HostInput, Captured), 'Moving film also moved the input image');
  SetNumber('X', 0); SetNumber('透明度', 100); Frame;
  Check(Same(HostInput, Captured), 'Hidden film changed the input image');
  SetNumber('透明度', 0); SetNumber('拡大率', 0); Frame;
  Check(Same(HostInput, Captured), 'Zero film scale changed the input image');
  SetNumber('拡大率', 100); SetNumber('油膜の量', 0); Frame;
  Check(Same(HostInput, Captured), 'Zero film amount changed the input image');
  SetNumber('油膜の量', 48); Video.GetImageData := nil; Frame;
  for I := 0 to High(Captured) do Check(Captured[I].A = 0, 'Overlay without input generated a background');
  Writeln('PASS native oil overlay: source texture, alpha, mask, placement, opacity, zero amount, animation and reverse seek');
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

// 本番AUF2でカップ外・入力アルファ・無効化と、波/油膜の渦の保存値を確認する。
procedure VerifyNativeWavesAndVortex(Table: PFILTER_PLUGIN_TABLE; var Video: TFILTER_PROC_VIDEO);
var
  Edit: TEDIT_SECTION;
  First, Clockwise: TAquaPixels;
  I, X, Y, Changed: Integer;

  procedure Number(const Name: string; Value: Double);
  begin PFILTER_ITEM_TRACK(FindItem(Table, Name, 'track'))^.Value := Value; end;

  procedure Frame(Time: Double);
  begin
    Video.Object_^.Time := Time; SetCount := 0;
    Table^.Func_Proc_Video(@Video);
    Check(SetCount = 1, 'Wave/vortex native frame missing');
  end;

begin
  Edit := Default(TEDIT_SECTION); Edit.SetObjectItemValue := AcceptItem;
  PFILTER_ITEM_SELECT(FindItem(Table, '表示モード', 'select'))^.Value := Ord(adWaveOverlay);
  PFILTER_ITEM_SELECT(FindItem(Table, 'プリセット', 'select'))^.Value := Ord(apCoffee);
  PFILTER_ITEM_BUTTON(FindItem(Table, '設定', 'button'))^.Callback2(@Edit, Pointer(1234), '水面演出:2', '設定');
  for I := Ord(atX) to Ord(atTransparency) do Number(string(AQUA_TRACK_DEFINITIONS[TAquaTrack(I)].Name), 0);
  Number('拡大率', 68); Number('3D傾斜角度', 0); Number('遠近感', 0);
  Video.Object_^.Flag := 0; Video.Object_^.Width := 384; Video.Object_^.Height := 256;
  Video.GetImageData := GetImage;
  SetLength(HostInput, 384 * 256);
  for Y := 0 to 255 do
    for X := 0 to 383 do
    begin
      I := Y * 384 + X;
      HostInput[I].R := 40 + (X mod 24) * 4;
      HostInput[I].G := 25 + (Y mod 30) * 3; HostInput[I].B := 12;
      HostInput[I].A := 80 + X mod 176;
      if Y < 8 then HostInput[I].A := 0;
    end;
  Frame(1); First := Copy(Captured); Changed := 0;
  for I := 0 to High(Captured) do
  begin
    Check(Captured[I].A = HostInput[I].A, 'Wave changed source alpha');
    if not CompareMem(@Captured[I], @HostInput[I], SizeOf(TPIXEL_RGBA)) then Inc(Changed);
    X := I mod 384; Y := I div 384;
    if (Abs(X - 192) > 100) or (Abs(Y - 128) > 100) or (HostInput[I].A = 0) then
      Check(CompareMem(@Captured[I], @HostInput[I], SizeOf(TPIXEL_RGBA)), 'Wave changed cup/outside mask');
  end;
  Check(Changed > 500, 'Coffee waves not visible');
  Frame(2); Check(not Same(First, Captured), 'Coffee waves did not animate');
  Frame(1); Check(Same(First, Captured), 'Coffee reverse seek changed output');
  Number('透明度', 100); Frame(1); Check(Same(HostInput, Captured), 'Wave transparency did not restore source');
  Number('透明度', 0); Number('拡大率', 0); Frame(1);
  Check(Same(HostInput, Captured), 'Wave zero zoom did not restore source');
  Number('拡大率', 68); Number('波の強さ', 0); Number('波紋の量', 0); Frame(1);
  Check(Same(HostInput, Captured), 'Zero waves did not restore source');
  Number('波の強さ', 25); Number('渦の強さ', 65); Number('流速', 0); Frame(2);
  Clockwise := Copy(Captured); Number('渦の強さ', -65); Frame(2);
  Check(not Same(Clockwise, Captured), 'Wave vortex direction did not change image');
  PFILTER_ITEM_SELECT(FindItem(Table, '表示モード', 'select'))^.Value := Ord(adOilOverlay);
  Number('油膜の量', 48); Number('渦の強さ', 65); Frame(2); Clockwise := Copy(Captured);
  Frame(3); Check(not Same(Clockwise, Captured), 'Oil vortex did not animate');
  Frame(2); Check(Same(Clockwise, Captured), 'Oil vortex reverse seek changed output');
  Number('渦の強さ', -65); Frame(2);
  Check(not Same(Clockwise, Captured), 'Oil vortex direction did not change image');
  PFILTER_ITEM_SELECT(FindItem(Table, 'プリセット', 'select'))^.Value := Ord(apVortex);
  PFILTER_ITEM_BUTTON(FindItem(Table, '設定', 'button'))^.Callback2(@Edit, Pointer(1234), '水面演出:2', '設定');
  Check(PFILTER_ITEM_TRACK(FindItem(Table, '渦の強さ', 'track'))^.Value = 70, 'Native vortex preset not applied');
  PFILTER_ITEM_SELECT(FindItem(Table, 'プリセット', 'select'))^.Value := Ord(apSea);
  PFILTER_ITEM_BUTTON(FindItem(Table, '設定', 'button'))^.Callback2(@Edit, Pointer(1234), '水面演出:2', '設定');
  Check(PFILTER_ITEM_TRACK(FindItem(Table, '渦の強さ', 'track'))^.Value = 0, 'Water preset did not reset vortex');
  // 間引いた格子の境界でも、波と光沢をほぼ止めた一様画像に暗い縁を作らない。
  PFILTER_ITEM_SELECT(FindItem(Table, '表示モード', 'select'))^.Value := Ord(adWaveOverlay);
  PFILTER_ITEM_SELECT(FindItem(Table, '水面形状', 'select'))^.Value := Ord(asEllipse);
  Number('波の強さ', 0); Number('波紋の量', 1); Number('泡の量', 0);
  Number('ハイライトの強さ', 0); Number('3D傾斜角度', 0); Number('遠近感', 0);
  Video.Object_^.Width := 1152; Video.Object_^.Height := 1024;
  SetLength(HostInput, 1152 * 1024);
  for I := 0 to High(HostInput) do
  begin
    HostInput[I].R := 100; HostInput[I].G := 100; HostInput[I].B := 100; HostInput[I].A := 200;
  end;
  Frame(0);
  for I := 0 to High(Captured) do
    Check((Captured[I].R >= 98) and (Captured[I].A = 200), 'Wave interpolation created a dark border');
  First := Copy(Captured); Frame(1); Frame(0);
  Check(Same(First, Captured), 'Parallel wave rows changed reverse-seek output');
  Number('画像の陰影', 0); Number('波の強さ', 50); Number('波紋の量', 0);
  for I := 0 to High(HostInput) do
  begin
    HostInput[I].R := 240; HostInput[I].G := 240; HostInput[I].B := 240; HostInput[I].A := 255;
  end;
  Frame(1);
  for I := 0 to High(Captured) do
    Check((Captured[I].R = 240) and (Captured[I].G = 240) and
      (Captured[I].B = 240) and (Captured[I].A = 255), 'Zero image shading darkened white liquid');
  Writeln('PASS native waves/vortex: cup bounds, alpha, disable, animation, signed rotation, seek and presets');
end;

// 同じ本番AUF2で水際の生成・保存項目・無効化・入力アルファを確認する。
procedure VerifyNativeShore(Table: PFILTER_PLUGIN_TABLE; var Video: TFILTER_PROC_VIDEO);
var
  Edit: TEDIT_SECTION;
  Track: TAquaTrack;
  A, B: TAquaPixels;
  I, Visible, Transparent: Integer;
  X, Y, Area, BeforeY: Double;

  procedure Number(const Name: string; Value: Double);
  begin
    PFILTER_ITEM_TRACK(FindItem(Table, Name, 'track'))^.Value := Value;
  end;

  procedure Preset(Value: TAquaPreset);
  begin
    PFILTER_ITEM_SELECT(FindItem(Table, 'プリセット', 'select'))^.Value := Ord(Value);
    PFILTER_ITEM_BUTTON(FindItem(Table, '設定', 'button'))^.Callback2(
      @Edit, Pointer(1234), '水面演出:2', '設定');
  end;

  procedure Frame(Time: Double);
  begin
    Video.Object_^.Time := Time; SetCount := 0;
    Check(Table^.Func_Proc_Video(@Video) = 1, 'Shore native callback');
    Check((SetCount = 1) and (Length(Captured) = 204 * 204), 'Shore frame size');
  end;

begin
  Edit := Default(TEDIT_SECTION); Edit.SetObjectItemValue := AcceptItem;
  for Track := atX to atTransparency do Number(string(AQUA_TRACK_DEFINITIONS[Track].Name), 0);
  Number('拡大率', 100); Number('シード', 1);
  Video.Object_^.Flag := OBJECT_FLAG_FILTER_OBJECT;
  Video.Object_^.Width := 204; Video.Object_^.Height := 204;
  PFILTER_ITEM_SELECT(FindItem(Table, '表示モード', 'select'))^.Value := Ord(adBackground);
  Preset(apShore);
  Check(PFILTER_ITEM_SELECT(FindItem(Table, '水面形状', 'select'))^.Value = Ord(asShore),
    'Shore preset did not select shoreline shape');
  SetLength(HostInput, 204 * 204);
  FillChar(HostInput[0], Length(HostInput) * SizeOf(TPIXEL_RGBA), 0);
  Frame(1.25); A := Copy(Captured);
  Visible := 0; Transparent := 0;
  for I := 0 to High(A) do
  begin
    if A[I].A = 0 then
    begin
      Inc(Transparent);
      Check((A[I].R = 0) and (A[I].G = 0) and (A[I].B = 0), 'Shore invisible RGB');
    end else Inc(Visible);
  end;
  Check((Visible > 204) and (Transparent > 204), 'Shore must have sea and transparent beach');
  Check((A[102].A > 150) and (A[203 * 204 + 102].A = 0), 'Shore orientation');
  Frame(2.15); Check(not Same(A, Captured), 'Shore run-up did not animate');
  Frame(1.25); Check(Same(A, Captured), 'Shore reverse seek changed pixels');
  Frame(-0.5); Frame(1.25); Check(Same(A, Captured), 'Shore negative seek changed pixels');
  Number('シード', 113); Frame(1.25); Check(not Same(A, Captured), 'Shore seed has no effect');
  Number('シード', 1);
  Number('Z軸回転', 90); Frame(1.25); B := Copy(Captured);
  Check(not Same(A, B), 'Shore rotation has no effect');
  Frame(2.15); Frame(1.25); Check(Same(B, Captured), 'Rotated shore cache changed on seek');
  Number('Z軸回転', 0);
  Number('波の到達幅', 0); Frame(1.25); Check(not Same(A, Captured), 'Shore reach has no effect');
  Preset(apShore); Number('寄せ返しの周期', 3); Frame(1.25);
  Check(not Same(A, Captured), 'Shore period has no effect');
  Preset(apShore); Number('水際の不規則さ', 0); Frame(1.25);
  Check(not Same(A, Captured), 'Shore roughness has no effect');
  Preset(apShore); Frame(3.2); B := Copy(Captured);
  Number('泡の残り', 0); Frame(3.2); Check(not Same(B, Captured), 'Shore foam persistence has no effect');
  Preset(apShore); Number('海水の不透明度', 0); Frame(1.25); B := Copy(Captured);
  Visible := 0;
  for I := 0 to High(B) do if B[I].A > 0 then Inc(Visible);
  Check((Visible > 0) and (Visible < 204 * 70), 'Shore foam-only coverage');
  Number('泡の量', 0); Frame(1.25);
  for I := 0 to High(Captured) do Check(Captured[I].A = 0, 'Disabled sea and foam left pixels');
  Preset(apShore); Frame(1.25); Area := AlphaCenter(Captured, 204, X, BeforeY);
  Check(Area > 0, 'Shore alpha center was empty');
  Number('Y', 30); Frame(1.25); Area := AlphaCenter(Captured, 204, X, Y);
  Check((Area > 0) and (Y > BeforeY + 5), 'Shore placement did not move');
  Number('Y', 0); Number('透明度', 100); Frame(1.25);
  for I := 0 to High(Captured) do Check(Captured[I].A = 0, 'Shore transparency');
  Number('透明度', 0); Number('拡大率', 0); Frame(1.25);
  for I := 0 to High(Captured) do Check(Captured[I].A = 0, 'Shore zero zoom');
  Number('拡大率', 100);
  Video.Object_^.Flag := 0;
  for I := 0 to High(HostInput) do
    if (I mod 204) >= 102 then HostInput[I].A := 128;
  Frame(1.25);
  for I := 0 to High(Captured) do
    Check(Captured[I].A <= HostInput[I].A, 'Shore exceeded input alpha');
  Video.Object_^.Flag := OBJECT_FLAG_FILTER_OBJECT;
  PFILTER_ITEM_SELECT(FindItem(Table, '表示モード', 'select'))^.Value := Ord(adEffectsOnly);
  Frame(1.25); B := Copy(Captured);
  PFILTER_ITEM_SELECT(FindItem(Table, '表示モード', 'select'))^.Value := Ord(adBackground);
  Number('海水の不透明度', 0); Frame(1.25);
  Check(Same(B, Captured), 'Shore effects-only differs from isolated foam');
  Preset(apSea);
  Check(PFILTER_ITEM_SELECT(FindItem(Table, '水面形状', 'select'))^.Value = Ord(asPlane),
    'Leaving shoreline preset did not restore the original shape');
  Writeln('PASS native shore: standalone alpha, reach, period, roughness, foam, seed, seek, placement and disable');
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

procedure VerifyNativeDrain(Table: PFILTER_PLUGIN_TABLE; var Video: TFILTER_PROC_VIDEO);
var
  Edit: TEDIT_SECTION;
  A, B: TAquaPixels;
  Track: TAquaTrack;
  I: Integer;
  StartArea, MidArea, X, Y: Double;
  Obj: TOBJECT_INFO;
  Settings: TAquaSettings;
  Surface: TAquaVortexSurface;
  Core, Rim: TAquaVortexSample;

  procedure Number(const Name: string; Value: Double);
  begin PFILTER_ITEM_TRACK(FindItem(Table, Name, 'track'))^.Value := Value; end;
  procedure Preset(Value: TAquaPreset);
  begin
    PFILTER_ITEM_SELECT(FindItem(Table, 'プリセット', 'select'))^.Value := Ord(Value);
    PFILTER_ITEM_BUTTON(FindItem(Table, '設定', 'button'))^.Callback2(@Edit, Pointer(1234), '水面演出:2', '設定');
  end;
  procedure Frame(Index, Total: Integer);
  begin
    Video.Object_^.Frame := Index; Video.Object_^.FrameTotal := Total;
    Video.Object_^.Time := Index / 30; Video.Object_^.TimeTotal := Total / 30;
    Check(Table^.Func_Proc_Video(@Video) = 1, 'Native drain callback');
  end;
begin
  Obj := Default(TOBJECT_INFO); Obj.FrameTotal := 301; Obj.Frame := 300;
  Check(AquaObjectProgress(Obj) = 1, 'Drain did not finish on last frame');
  Obj.Frame := -3; Check(AquaObjectProgress(Obj) = 0, 'Negative drain progress');
  Settings := AquaPresetSettings(apVortex);
  Surface := TAquaVortexSurface.Create(Settings, 1, 0.5, 0, 0, 1, 1);
  Core := Surface.Sample(0, 0, 0.01); Rim := Surface.Sample(1.5, 0, 0.01);
  Check((Core.Height < Rim.Height) and (Core.Shade < Rim.Shade), 'Vortex center is not depressed');
  Core := Surface.Sample(0.2, 0.1, 0.01); Rim := Surface.Sample(0.200001, 0.1, 0.01);
  Check(SameValue((Rim.Height - Core.Height) / 0.000001, Core.GradU, 1E-5), 'Funnel normal U');
  Rim := Surface.Sample(0.2, 0.100001, 0.01);
  Check(SameValue((Rim.Height - Core.Height) / 0.000001, Core.GradV, 1E-5), 'Funnel normal V');
  for I := 0 to 31 do
  begin
    Core := Surface.Sample(0.10 + I * 0.02, 0.10, 0.01);
    Check((Core.Light = 0) and (Core.Foam = 0), 'Vortex draws bright ripple-like spiral lines');
  end;
  Check((AquaPresetSettings(apVortex).Tracks[atFoam] = 0) and
    (AquaPresetSettings(apDrain).Tracks[atFoam] = 0), 'Vortex/drain preset still adds foam');
  Settings := AquaPresetSettings(apDrain);
  Surface := TAquaVortexSurface.Create(Settings, 7.36, 0.92, 0.75, 0, 2.55, 1);
  Core := Surface.Sample(0.68, 0, 3 / 432);
  Check(Core.Mask > 0.99, 'Late drain globally fades instead of flowing into the outlet');
  X := 0.4; Y := 0; Surface.Advect(X, Y);
  Check((X < 0.4) and (Y = 0), 'Right outlet does not pull texture from upstream');
  Surface := TAquaVortexSurface.Create(Settings, 7.36, 0.92, -0.75, 0, 2.55, 1);
  X := -0.4; Y := 0; Surface.Advect(X, Y);
  Check((X > -0.4) and (Y = 0), 'Left outlet does not reverse the incoming stream');
  Surface := TAquaVortexSurface.Create(Settings, 2, 0.5, 0.75, 0, 2.55, 1);
  X := 0.4; Y := 0; Surface.Advect(X, Y);
  Check((X = 0.4) and (Y = 0), 'Transport changed the accepted early absorption');
  Edit := Default(TEDIT_SECTION); Edit.SetObjectItemValue := AcceptItem;
  for Track := atX to atTransparency do Number(string(AQUA_TRACK_DEFINITIONS[Track].Name), 0);
  Number('拡大率', 100); Number('渦中心X', 0); Number('渦中心Y', 0);
  Video.Object_^.Width := 204; Video.Object_^.Height := 204; Video.Object_^.Flag := OBJECT_FLAG_FILTER_OBJECT;
  PFILTER_ITEM_SELECT(FindItem(Table, '表示モード', 'select'))^.Value := Ord(adBackground);
  Preset(apDrain); Frame(0, 301); A := Copy(Captured);
  StartArea := AlphaCenter(A, 204, X, Y); Frame(150, 301);
  MidArea := AlphaCenter(Captured, 204, X, Y);
  Check((MidArea > 0) and (MidArea < StartArea), 'Drain did not reduce the water');
  Frame(300, 301); for I := 0 to High(Captured) do Check(Captured[I].A = 0, 'Drain water remains on last frame');
  Frame(0, 301); Check(Same(A, Captured), 'Drain reverse seek changed start');
  Number('渦の強さ', 0); Number('波の強さ', 0); Number('泡の量', 0);
  Frame(270, 301); A := Copy(Captured); Frame(540, 601);
  Check(Same(A, Captured), 'Drain duration does not follow timeline length');
  Preset(apDrain); Number('排水の量', 0); Frame(300, 301);
  Check(AlphaCenter(Captured, 204, X, Y) > 0, 'Disabled drain still removed the water');
  Preset(apVortex); Frame(100, 301); A := Copy(Captured); Number('渦の凹み', 0); Frame(100, 301);
  Check(not Same(A, Captured), 'Vortex depth has no visible effect');
  Number('渦中心X', 35); Number('渦中心Y', 20); Preset(apDrain);
  Check(PFILTER_ITEM_TRACK(FindItem(Table, '渦中心X', 'track'))^.Value = 35, 'Preset changed drain center');
  Frame(150, 301); A := Copy(Captured); Number('渦中心X', -35); Frame(150, 301);
  Check(not Same(A, Captured), 'Drain center position has no effect');
  Number('渦中心X', 0); Number('渦中心Y', 0); Video.Object_^.Flag := 0;
  SetLength(HostInput, 204 * 204); FillChar(HostInput[0], Length(HostInput) * SizeOf(TPIXEL_RGBA), 0);
  for I := 204 * 102 to High(HostInput) do HostInput[I].A := 128;
  Frame(100, 301);
  for I := 0 to High(Captured) do Check(Captured[I].A <= HostInput[I].A, 'Drain exceeded source alpha');
  Video.Object_^.Flag := OBJECT_FLAG_FILTER_OBJECT; Video.Object_^.FrameTotal := 0;
  Video.Object_^.TimeTotal := 0; Preset(apSea);
  B := Copy(Captured); Check(Length(B) = 204 * 204, 'Drain output size');
  Writeln('PASS drain: depression, center, preserved placement, timeline duration, final empty, seek, zero and source alpha');
end;

procedure VerifyPlugin(const Path: string);
var
  Module: HMODULE;
  Initialize: TInitialize;
  Uninitialize: TUninitialize;
  GetTable: TGetTable;
  Table: PFILTER_PLUGIN_TABLE;
  Video: TFILTER_PROC_VIDEO;
  Scene: TSCENE_INFO;
  Obj: TOBJECT_INFO;
  Edit: TEDIT_SECTION;
  Items: PPointer;
  Preset: PFILTER_ITEM_SELECT;
  Button: PFILTER_ITEM_BUTTON;
  First: TAquaPixels;
  PresetImages: array[0..AQUA_PRESET_COUNT - 1] of TAquaPixels;
  I, J: Integer;
begin
  Module := LoadLibrary(PChar(Path));
  Check(Module <> 0, 'LoadLibrary: ' + Path);
  try
    @Initialize := GetProcAddress(Module, 'InitializePlugin');
    @Uninitialize := GetProcAddress(Module, 'UninitializePlugin');
    @GetTable := GetProcAddress(Module, 'GetFilterPluginTable');
    Check(Assigned(Initialize) and Assigned(Uninitialize) and Assigned(GetTable), 'Exports');
    Check((Initialize(2011599) = 0) and (Initialize(2011700) = 1), 'Version gate');
    Table := GetTable;
    Check(Assigned(Table^.Func_Create) and Assigned(Table^.Func_Destroy), 'Session callbacks');
    Check(Table^.Flag = 25, 'Production filter flags');
    Items := PPointer(Table^.Items);
    Preset := PFILTER_ITEM_SELECT(Items^); Inc(Items);
    Button := PFILTER_ITEM_BUTTON(Items^);
    Check((string(Preset^.Name) = 'プリセット') and (string(Button^.Name) = '設定'), 'Preset order');
    Scene := Default(TSCENE_INFO); Scene.Width := 204; Scene.Height := 204;
    Obj := Default(TOBJECT_INFO); Obj.Time := 32 / 30;
    Obj.Flag := OBJECT_FLAG_FILTER_OBJECT;
    Video := Default(TFILTER_PROC_VIDEO);
    Video.Scene := @Scene; Video.Object_ := @Obj;
    Video.SetImageData := SetImage;
    Video.UserData := Table^.Func_Create(1);
    Check(Video.UserData <> nil, 'Session allocation');
    try
      // 利用者の確認プロジェクトと同じ、素材なし・204x204・背景あり・海。
      SetCount := 0;
      Check(Table^.Func_Proc_Video(@Video) = 1, 'Video callback');
      Check((SetCount = 1) and (CaptureWidth = 204) and (CaptureHeight = 204), 'No image was returned');
      for I := 0 to High(Captured) do Check(Captured[I].A = 255, 'Sea is transparent');
      First := Copy(Captured);
      SavePNG(Captured, 204, 204, 'sea_204.png');
      // 入力取得APIがあり、入力画像が全面透明の場合も同じ水面を返す。
      Obj.Width := 204; Obj.Height := 204;
      SetLength(HostInput, 204 * 204);
      FillChar(HostInput[0], Length(HostInput) * SizeOf(TPIXEL_RGBA), 0);
      Video.GetImageData := GetImage;
      SetCount := 0; Table^.Func_Proc_Video(@Video);
      Check((SetCount = 1) and Same(First, Captured), 'Empty filter input suppressed the generated sea');
      Obj.Time := 2.5; Table^.Func_Proc_Video(@Video);
      Check(not Same(First, Captured), 'Water does not animate');
      Obj.Time := 32 / 30; Table^.Func_Proc_Video(@Video);
      Check(Same(First, Captured), 'Seeking changed the result');
      Edit := Default(TEDIT_SECTION); Edit.SetObjectItemValue := AcceptItem;
      for I := 0 to AQUA_PRESET_COUNT - 1 do
      begin
        Preset^.Value := I;
        Button^.Callback2(@Edit, Pointer(1234), '水面演出:2', '設定');
        if I = Ord(apFlush) then begin Obj.Frame := 90; Obj.FrameTotal := 241; end;
        SetCount := 0; Table^.Func_Proc_Video(@Video);
        Check(SetCount = 1, 'Preset did not produce a frame');
        if I <> Ord(apFlush) then
          Check(Captured[102 * 204 + 102].A > 0, 'Preset surface is invisible');
        for J := 0 to I - 1 do
          Check(not Same(PresetImages[J], Captured), 'Preset images are identical');
        PresetImages[I] := Copy(Captured);
      end;
      Obj.Frame := 0; Obj.FrameTotal := 0;
      // 通常の画像へのフィルターでは透明部分を維持する。
      begin
        Obj.Flag := 0; Obj.Width := 204; Obj.Height := 204;
        SetLength(HostInput, 204 * 204);
        FillChar(HostInput[0], Length(HostInput) * SizeOf(TPIXEL_RGBA), 0);
        for I := 204 * 102 to High(HostInput) do HostInput[I].A := 255;
        Video.GetImageData := GetImage;
        Preset^.Value := 0; Button^.Callback2(@Edit, Pointer(1234), '水面演出:2', '設定');
        Table^.Func_Proc_Video(@Video);
        for I := 0 to 204 * 102 - 1 do Check(Captured[I].A = 0, 'Transparent input was painted');
      end;
      VerifyNativePlacement(Table, Video);
      VerifyNativeOil(Table, Video);
      VerifyNativeOilOverlay(Table, Video);
      VerifyNativeWavesAndVortex(Table, Video);
      VerifyNativeShore(Table, Video);
      VerifyNativeDrain(Table, Video);
      Video.Object_ := nil;
      Check(Table^.Func_Proc_Video(@Video) = 1, 'Invalid callback handling');
    finally
      Table^.Func_Destroy(1, Video.UserData);
    end;
    Uninitialize;
    Writeln('PASS native callback: ', ExtractFileName(Path));
  finally
    FreeLibrary(Module);
  end;
end;

// 本番AUF2から同じ時刻の各プリセットをPNGへ出す。ホストアプリは起動しない。
procedure ExportNativePresets(const Path: string);
var
  Module: HMODULE;
  Initialize: TInitialize;
  Uninitialize: TUninitialize;
  GetTable: TGetTable;
  Table: PFILTER_PLUGIN_TABLE;
  Scene: TSCENE_INFO;
  Obj: TOBJECT_INFO;
  Video: TFILTER_PROC_VIDEO;
  Edit: TEDIT_SECTION;
  I, Y: Integer;
  Sea, Oil, Comparison: TAquaPixels;
begin
  Module := LoadLibrary(PChar(Path));
  Check(Module <> 0, 'Preview LoadLibrary');
  try
    @Initialize := GetProcAddress(Module, 'InitializePlugin');
    @Uninitialize := GetProcAddress(Module, 'UninitializePlugin');
    @GetTable := GetProcAddress(Module, 'GetFilterPluginTable');
    Check(Initialize(2011700) = 1, 'Preview InitializePlugin');
    Table := GetTable;
    Scene := Default(TSCENE_INFO); Scene.Width := 640; Scene.Height := 360;
    Obj := Default(TOBJECT_INFO); Obj.Flag := OBJECT_FLAG_FILTER_OBJECT; Obj.Time := 1.25;
    Video := Default(TFILTER_PROC_VIDEO); Video.Scene := @Scene; Video.Object_ := @Obj;
    Video.SetImageData := SetImage; Video.UserData := Table^.Func_Create(100);
    Check(Video.UserData <> nil, 'Preview session');
    try
      Edit := Default(TEDIT_SECTION); Edit.SetObjectItemValue := AcceptItem;
      for I := 0 to AQUA_PRESET_COUNT - 1 do
      begin
        PFILTER_ITEM_SELECT(FindItem(Table, 'プリセット', 'select'))^.Value := I;
        PFILTER_ITEM_BUTTON(FindItem(Table, '設定', 'button'))^.Callback2(
          @Edit, Pointer(1234), '水面演出:2', '設定');
        if I = Ord(apFlush) then begin Obj.Frame := 90; Obj.FrameTotal := 241; end;
        SetCount := 0; Table^.Func_Proc_Video(@Video);
        Check((SetCount = 1) and (CaptureWidth = 640) and (CaptureHeight = 360), 'Preview frame');
        SavePNG(Captured, 640, 360, Format('preset_%.2d.png', [I]));
        if I = Ord(apSea) then Sea := Copy(Captured);
        if I = Ord(apOil) then Oil := Copy(Captured);
      end;
      SetLength(Comparison, 1280 * 360);
      for Y := 0 to 359 do
      begin
        Move(Sea[Y * 640], Comparison[Y * 1280], 640 * SizeOf(TPIXEL_RGBA));
        Move(Oil[Y * 640], Comparison[Y * 1280 + 640], 640 * SizeOf(TPIXEL_RGBA));
      end;
      SavePNG(Comparison, 1280, 360, 'water_oil.png');
    finally
      Table^.Func_Destroy(100, Video.UserData);
    end;
    Uninitialize;
  finally
    FreeLibrary(Module);
  end;
  Writeln('Exported ', AQUA_PRESET_COUNT, ' native preset previews: ', ImageDirectory);
end;

// 本番AUF2から海岸1周期または排水全長の透過PNGを出す。背景合成は検査スクリプト側。
procedure ExportNativeShore(const Path: string);
var
  Module: HMODULE;
  Initialize: TInitialize;
  Uninitialize: TUninitialize;
  GetTable: TGetTable;
  Table: PFILTER_PLUGIN_TABLE;
  Scene: TSCENE_INFO;
  Obj: TOBJECT_INFO;
  Video: TFILTER_PROC_VIDEO;
  Edit: TEDIT_SECTION;
  I, W, H, Count: Integer;
  Drain: Boolean;
  Prefix: string;
  Timer: TStopwatch;
  Samples: TStringList;
begin
  Module := LoadLibrary(PChar(Path));
  Check(Module <> 0, 'Shore preview LoadLibrary');
  Samples := TStringList.Create;
  try
    @Initialize := GetProcAddress(Module, 'InitializePlugin');
    @Uninitialize := GetProcAddress(Module, 'UninitializePlugin');
    @GetTable := GetProcAddress(Module, 'GetFilterPluginTable');
    Check(Initialize(2011700) = 1, 'Shore preview initialize');
    Table := GetTable;
    Drain := ParamStr(3) = '--drain-preview'; W := 768; H := 432; Count := 72; Prefix := 'shore';
    if Drain then begin H := 512; Count := 96; Prefix := 'bath_drain'; end;
    Scene := Default(TSCENE_INFO); Scene.Width := W; Scene.Height := H; Scene.Rate := 30; Scene.Scale := 1;
    Obj := Default(TOBJECT_INFO); Obj.Flag := OBJECT_FLAG_FILTER_OBJECT;
    Video := Default(TFILTER_PROC_VIDEO); Video.Scene := @Scene; Video.Object_ := @Obj;
    Video.SetImageData := SetImage; Video.UserData := Table^.Func_Create(200);
    Check(Video.UserData <> nil, 'Shore preview session');
    try
      Edit := Default(TEDIT_SECTION); Edit.SetObjectItemValue := AcceptItem;
      PFILTER_ITEM_SELECT(FindItem(Table, 'プリセット', 'select'))^.Value := Ord(apShore);
      PFILTER_ITEM_BUTTON(FindItem(Table, '設定', 'button'))^.Callback2(
        @Edit, Pointer(1234), '水面演出:2', '設定');
      if Drain then
      begin
        PFILTER_ITEM_SELECT(FindItem(Table, 'プリセット', 'select'))^.Value := Ord(apDrain);
        PFILTER_ITEM_BUTTON(FindItem(Table, '設定', 'button'))^.Callback2(@Edit, Pointer(1234), '水面演出:2', '設定');
        Obj.Flag := 0; Obj.Width := W; Obj.Height := H; Obj.FrameTotal := 240; Obj.TimeTotal := 8;
        Video.GetImageData := GetImage; SetLength(HostInput, W * H);
        for I := 0 to High(HostInput) do HostInput[I].A := 255;
        PFILTER_ITEM_TRACK(FindItem(Table, 'Y', 'track'))^.Value := -3.5;
        PFILTER_ITEM_TRACK(FindItem(Table, '拡大率', 'track'))^.Value := 51;
        PFILTER_ITEM_TRACK(FindItem(Table, '縦横比', 'track'))^.Value := 70;
        PFILTER_ITEM_TRACK(FindItem(Table, '透明度', 'track'))^.Value := 35;
        PFILTER_ITEM_TRACK(FindItem(Table, '渦中心X', 'track'))^.Value := 261;
        PFILTER_ITEM_TRACK(FindItem(Table, '渦中心Y', 'track'))^.Value := -0.5;
      end;
      Samples.Add('frame,time_seconds,render_ms');
      for I := 0 to Count - 1 do
      begin
        Obj.Time := I / 12;
        if Drain then begin Obj.Frame := Round(I * 239 / (Count - 1)); Obj.Time := Obj.Frame / 30; end;
        SetCount := 0; Timer := TStopwatch.StartNew;
        Check(Table^.Func_Proc_Video(@Video) = 1, 'Shore preview callback');
        Timer.Stop;
        Check((SetCount = 1) and (Length(Captured) = W * H), 'Shore preview output');
        Samples.Add(Format('%d,%.6f,%.3f', [I, Obj.Time, Timer.Elapsed.TotalMilliseconds],
          TFormatSettings.Invariant));
        SavePNG(Captured, W, H, Format('%s_%.3d.png', [Prefix, I]));
      end;
      Samples.SaveToFile(ImageDirectory + 'render_times.csv', TEncoding.UTF8);
    finally
      Table^.Func_Destroy(200, Video.UserData);
    end;
    Uninitialize;
  finally
    Samples.Free; FreeLibrary(Module);
  end;
  Writeln('Exported ', Count, ' native ', Prefix, ' frames: ', ImageDirectory);
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

procedure VerifyRenderer;
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
    SavePNG(A, 1280, 720, 'sea.png');
    Renderer.Render(Input, 1280, 720, 1.25, Settings, False, B);
    Check(not Same(A, B), 'Sea animation is static');
    SavePNG(B, 1280, 720, 'sea_next.png');
    Renderer.Render(Input, 1280, 720, 0, Settings, False, C);
    Check(Same(A, C), 'Reverse seek is not deterministic');
    Settings.Tracks[atSeed] := 99;
    Renderer.Render(Input, 1280, 720, 0, Settings, False, C);
    Check(not Same(A, C), 'Seed has no effect');
    Settings := AquaPresetSettings(apCoffee);
    Renderer.Render(Input, 640, 360, 0, Settings, False, A);
    Check((A[0].A = 0) and (A[180 * 640 + 320].A = 255), 'Projected shape mask');
    SavePNG(A, 640, 360, 'coffee.png');
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

// 同じ本番DLLを複数解像度・表示モードで測る。PNG保存とハッシュは計測外。
// 元画像と設定を固定し、変更前後の画像一致も照合できるようにする。
procedure ReadBenchmarkAlias(const Path: string; var Settings: TAquaSettings);
var
  Lines: TStringList;
  Line, Name, Value: string;
  Reading: Boolean;
  EqualsAt: Integer;
  Track: TAquaTrack;
  Mode: TAquaDisplayMode;
  Shape: TAquaShape;
  Number: Double;
begin
  Lines := TStringList.Create;
  try
    Lines.LoadFromFile(Path, TEncoding.UTF8); Reading := False;
    for Line in Lines do
    begin
      if Line.StartsWith('effect.name=') then Reading := Line = 'effect.name=水面演出';
      if not Reading then Continue;
      EqualsAt := Pos('=', Line); if EqualsAt = 0 then Continue;
      Name := Copy(Line, 1, EqualsAt - 1); Value := Copy(Line, EqualsAt + 1, MaxInt);
      for Track := Low(TAquaTrack) to High(TAquaTrack) do
        if Name = string(AQUA_TRACK_DEFINITIONS[Track].Name) then
        begin
          Check(TryStrToFloat(Value, Number, TFormatSettings.Invariant), 'Benchmark requires constant track: ' + Name);
          Settings.Tracks[Track] := Number;
        end;
      for Mode := Low(TAquaDisplayMode) to High(TAquaDisplayMode) do
        if (Name = '表示モード') and (Value = string(AQUA_DISPLAY_NAMES[Mode])) then Settings.DisplayMode := Mode;
      for Shape := Low(TAquaShape) to High(TAquaShape) do
        if (Name = '水面形状') and (Value = string(AQUA_SHAPE_NAMES[Shape])) then Settings.Shape := Shape;
      if Name = '液体色' then Settings.ColorRGB := StrToInt('$' + Value);
      if Name = '油膜色' then Settings.OilColorRGB := StrToInt('$' + Value);
    end;
  finally
    Lines.Free;
  end;
end;

procedure BenchmarkPlugin(const Path, SourcePath: string);
const
  FrameCount = 9;
  Names: array[0..8] of string = ('ramen_overlay', 'fullhd_overlay',
    'fullhd_sea', 'fullhd_oil', 'fullhd_image', 'image_waves', 'water_vortex', 'ramen_vortex', 'bath_ripples');
var
  Module: HMODULE;
  Initialize: TInitialize;
  Uninitialize: TUninitialize;
  GetTable: TGetTable;
  Table: PFILTER_PLUGIN_TABLE;
  Video: TFILTER_PROC_VIDEO;
  Scene: TSCENE_INFO;
  Obj: TOBJECT_INFO;
  Settings: TAquaSettings;
  Track: TAquaTrack;
  Source: TAquaPixels;
  PNG: TPngImage;
  CSV: TStringList;
  Timer: TStopwatch;
  Samples: array[0..FrameCount - 1] of Double;
  Scenario, W, H, X, Y, I, J: Integer;
  Color: Cardinal;
  Swap, Sum: Double;
  ImagePath, Digest: string;
begin
  Check(FileExists(SourcePath), 'Benchmark source image missing: ' + SourcePath);
  PNG := TPngImage.Create;
  try
    PNG.LoadFromFile(SourcePath);
    W := PNG.Width; H := PNG.Height;
    SetLength(Source, W * H);
    for Y := 0 to H - 1 do
      for X := 0 to W - 1 do
      begin
        I := Y * W + X; Color := PNG.Pixels[X, Y];
        Source[I].R := GetRValue(Color); Source[I].G := GetGValue(Color);
        Source[I].B := GetBValue(Color); Source[I].A := 255;
        if PNG.AlphaScanline[Y] <> nil then Source[I].A := PNG.AlphaScanline[Y]^[X];
      end;
  finally
    PNG.Free;
  end;
  CSV := TStringList.Create;
  Module := LoadLibrary(PChar(Path));
  Check(Module <> 0, 'Benchmark LoadLibrary: ' + Path);
  try
    @Initialize := GetProcAddress(Module, 'InitializePlugin');
    @Uninitialize := GetProcAddress(Module, 'UninitializePlugin');
    @GetTable := GetProcAddress(Module, 'GetFilterPluginTable');
    Check(Assigned(Initialize) and Assigned(GetTable) and Assigned(Uninitialize), 'Benchmark exports');
    Check(Initialize(2011700) = 1, 'Benchmark initialization');
    Table := GetTable;
    Video := Default(TFILTER_PROC_VIDEO);
    Scene := Default(TSCENE_INFO); Obj := Default(TOBJECT_INFO);
    Video.Scene := @Scene; Video.Object_ := @Obj;
    Video.GetImageData := GetImage; Video.SetImageData := SetImage;
    Video.UserData := Table^.Func_Create(900);
    Check(Video.UserData <> nil, 'Benchmark session');
    CSV.Add('scenario,width,height,frames,median_ms,mean_ms,min_ms,max_ms,png_sha256');
    try
      for Scenario := 0 to High(Names) do
      begin
        if (ParamStr(5) <> '') and (ParamStr(5) <> Names[Scenario]) then Continue;
        Settings := AquaPresetSettings(apOil);
        Settings.DisplayMode := adOilOverlay;
        if Scenario in [0, 5, 7, 8] then
        begin
          Obj.Width := W; Obj.Height := H;
          Settings.Tracks[atX] := 0; Settings.Tracks[atY] := 208;
          Settings.Tracks[atZoom] := 42.460; Settings.Tracks[atAspect] := 90;
          Settings.Tracks[atTilt] := 0; Settings.Tracks[atPerspective] := 0;
          Settings.Tracks[atOilAmount] := 32; Settings.Tracks[atOilSize] := 30;
          Settings.Tracks[atOilGloss] := 55;
          if Scenario = 5 then
          begin
            Settings := AquaPresetSettings(apCoffee); Settings.DisplayMode := adWaveOverlay;
            Settings.Tracks[atTilt] := 0; Settings.Tracks[atPerspective] := 0;
            Settings.Tracks[atX] := -20; Settings.Tracks[atY] := -155;
            Settings.Tracks[atZoom] := 50; Settings.Tracks[atAspect] := 38;
          end;
          if Scenario = 7 then
          begin
            Settings.Tracks[atFlowSpeed] := 0;
            Settings.Tracks[atVortexStrength] := 65; Settings.Tracks[atVortexSpeed] := 1.2;
          end;
          if Scenario = 8 then
          begin
            Settings := AquaPresetSettings(apDropRipples);
            Settings.Tracks[atY] := -8;
            Settings.Tracks[atZoom] := 54;
            Settings.Tracks[atAspect] := 65;
            Settings.Tracks[atRippleAspect] := 148;
            Settings.Tracks[atTransparency] := 35;
          end;
        end else
        begin
          Obj.Width := 1920; Obj.Height := 1080;
          case Scenario of
            2: Settings := AquaPresetSettings(apSea);
            3: Settings.DisplayMode := adBackground;
            4: begin Settings.DisplayMode := adImage; Settings.Shape := asImage; end;
            6: Settings := AquaPresetSettings(apVortex);
          end;
        end;
        if ParamStr(6) <> '' then ReadBenchmarkAlias(ParamStr(6), Settings);
        Obj.Flag := 0;
        if (Settings.DisplayMode = adBackground) and (Scenario <> 8) then
          Obj.Flag := OBJECT_FLAG_FILTER_OBJECT;
        Scene.Width := Obj.Width; Scene.Height := Obj.Height;
        SetLength(HostInput, Obj.Width * Obj.Height);
        for I := 0 to High(HostInput) do HostInput[I] := Source[I mod Length(Source)];
        PFILTER_ITEM_SELECT(FindItem(Table, '表示モード', 'select'))^.Value := Ord(Settings.DisplayMode);
        PFILTER_ITEM_SELECT(FindItem(Table, '水面形状', 'select'))^.Value := Ord(Settings.Shape);
        PFILTER_ITEM_COLOR(FindItem(Table, '液体色', 'color'))^.R := (Settings.ColorRGB shr 16) and $FF;
        PFILTER_ITEM_COLOR(FindItem(Table, '液体色', 'color'))^.G := (Settings.ColorRGB shr 8) and $FF;
        PFILTER_ITEM_COLOR(FindItem(Table, '液体色', 'color'))^.B := Settings.ColorRGB and $FF;
        PFILTER_ITEM_COLOR(FindItem(Table, '油膜色', 'color'))^.R := (Settings.OilColorRGB shr 16) and $FF;
        PFILTER_ITEM_COLOR(FindItem(Table, '油膜色', 'color'))^.G := (Settings.OilColorRGB shr 8) and $FF;
        PFILTER_ITEM_COLOR(FindItem(Table, '油膜色', 'color'))^.B := Settings.OilColorRGB and $FF;
        for Track := Low(TAquaTrack) to High(TAquaTrack) do
          PFILTER_ITEM_TRACK(FindItem(Table, string(AQUA_TRACK_DEFINITIONS[Track].Name), 'track'))^.Value := Settings.Tracks[Track];
        Obj.Time := 0;
        Table^.Func_Proc_Video(@Video);
        Sum := 0;
        for I := 0 to FrameCount - 1 do
        begin
          Obj.Time := I / 30;
          SetCount := 0; Timer := TStopwatch.StartNew;
          Check(Table^.Func_Proc_Video(@Video) = 1, 'Benchmark callback');
          Samples[I] := Timer.Elapsed.TotalMilliseconds; Sum := Sum + Samples[I];
          Check((SetCount = 1) and (Length(Captured) = Obj.Width * Obj.Height), 'Benchmark output');
        end;
        for I := 0 to FrameCount - 2 do
          for J := I + 1 to FrameCount - 1 do
            if Samples[J] < Samples[I] then
            begin Swap := Samples[I]; Samples[I] := Samples[J]; Samples[J] := Swap; end;
        Obj.Time := 1;
        Table^.Func_Proc_Video(@Video);
        SavePNG(Captured, Obj.Width, Obj.Height, Names[Scenario] + '.png');
        ImagePath := ImageDirectory + Names[Scenario] + '.png';
        Digest := THashSHA2.GetHashStringFromFile(ImagePath);
        CSV.Add(Format('%s,%d,%d,%d,%.3f,%.3f,%.3f,%.3f,%s',
          [Names[Scenario], Obj.Width, Obj.Height, FrameCount, Samples[FrameCount div 2],
           Sum / FrameCount, Samples[0], Samples[FrameCount - 1], Digest], TFormatSettings.Invariant));
        Writeln(Names[Scenario], ': median ', Samples[FrameCount div 2]:0:2, ' ms');
        // Optional offline frames avoid repeated seeks in the user's live editor.
        if ParamStr(7) = '--frames' then
          for I := 0 to 17 do
          begin
            Obj.Time := I / 6;
            Check(Table^.Func_Proc_Video(@Video) = 1, 'Offline frame callback');
            SavePNG(Captured, Obj.Width, Obj.Height, Format('%s_%0.2d.png', [Names[Scenario], I]));
          end;
      end;
    finally
      Table^.Func_Destroy(900, Video.UserData);
    end;
    Uninitialize;
    Check(CSV.Count > 1, 'Unknown benchmark case');
    CSV.SaveToFile(ImageDirectory + 'benchmark.csv', TEncoding.UTF8);
  finally
    FreeLibrary(Module); CSV.Free;
  end;
end;

begin
  try
    ImageDirectory := IncludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0))) + 'Images\';
    if ParamStr(2) <> '' then ImageDirectory := IncludeTrailingPathDelimiter(ParamStr(2));
    PluginPath := ParamStr(1);
    if PluginPath = '' then PluginPath := 'C:\ProgramData\aviutl2\Plugin\SYNC_AquaFX\SYNC_AquaFX.auf2';
    ForceDirectories(ImageDirectory);
    if ParamStr(3) = '--benchmark' then
      BenchmarkPlugin(PluginPath, ParamStr(4))
    else if (ParamStr(3) = '--shore-preview') or (ParamStr(3) = '--drain-preview') then
      ExportNativeShore(PluginPath)
    else
    begin
      if ParamStr(3) <> '--previews-only' then
      begin
        VerifyProjection;
        VerifyVortexFlow;
        VerifyDropRipples;
        VerifyShoreRetreatContinuity;
        VerifyRenderer;
        VerifyOilRenderer;
        VerifyPlugin(PluginPath);
        Writeln('ALL TESTS PASSED');
      end;
      ExportNativePresets(PluginPath);
    end;
  except
    on E: Exception do
    begin
      Writeln(E.ClassName, ': ', E.Message);
      Halt(1);
    end;
  end;
end.
