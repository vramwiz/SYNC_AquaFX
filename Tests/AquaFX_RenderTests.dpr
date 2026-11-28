program AquaFX_RenderTests;

// 本番AUF2のコールバック検査、プレビュー画像出力、描画時間の計測を受け持つ。
// コマンドラインの出力先へ画像・計測結果を書き、共通描画器の検査は専用ユニットを呼ぶ。

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
  AquaFX_Weather in '..\Source\Common\AquaFX_Weather.pas',
  AquaFX_WaterDepth in '..\Source\Common\AquaFX_WaterDepth.pas',
  AquaFX_OilSurface in '..\Source\Common\AquaFX_OilSurface.pas',
  AquaFX_Projection in '..\Source\Common\AquaFX_Projection.pas',
  AquaFX_Flow in '..\Source\Common\AquaFX_Flow.pas',
  AquaFX_VortexSurface in '..\Source\Common\AquaFX_VortexSurface.pas',
  AquaFX_Shore in '..\Source\Common\AquaFX_Shore.pas',
  AquaFX_Renderer in '..\Source\Common\AquaFX_Renderer.pas',
  AquaFX_RenderTestSupport in 'AquaFX_RenderTestSupport.pas',
  AquaFX_RenderCoreTests in 'AquaFX_RenderCoreTests.pas';

type
  TGetTable = function: PFILTER_PLUGIN_TABLE; cdecl;
  TInitialize = function(Version: Cardinal): Byte; cdecl;
  TUninitialize = procedure; cdecl;

var
  // 検査EXEが入出力バッファを所有する。描画の結果は次のSetImageで更新される。
  Captured, HostInput: TAquaPixels;
  CaptureWidth, CaptureHeight, SetCount: Integer;
  ImageDirectory: string;
  PluginPath: string;

procedure SavePNG(const Pixels: TAquaPixels; Width, Height: Integer; const Name: string);
begin
  SaveRenderTestPNG(Pixels, Width, Height, ImageDirectory + Name);
end;

procedure GetImage(Buffer: PPIXEL_RGBA); cdecl;
begin
  if Length(HostInput) > 0 then
    Move(HostInput[0], Buffer^, Length(HostInput) * SizeOf(TPIXEL_RGBA));
end;

// AUF2の出力バッファは借用し、コールバック内で検査側の配列へコピーする。
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

procedure SetComponents(Table: PFILTER_PLUGIN_TABLE; Components: TAquaComponents);
var
  Component: TAquaComponent;
begin
  for Component := Low(TAquaComponent) to High(TAquaComponent) do
    PFILTER_ITEM_CHECK(FindItem(Table, AQUA_COMPONENT_NAMES[Component], 'check'))^.Value :=
      Ord(Component in Components);
end;

procedure CheckComponents(Table: PFILTER_PLUGIN_TABLE; Components: TAquaComponents);
var
  Component: TAquaComponent;
begin
  for Component := Low(TAquaComponent) to High(TAquaComponent) do
    Check(PFILTER_ITEM_CHECK(FindItem(Table, AQUA_COMPONENT_NAMES[Component], 'check'))^.Value =
      Byte(Ord(Component in Components)), 'Preset display check: ' + string(AQUA_COMPONENT_NAMES[Component]));
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
  PFILTER_ITEM_SELECT(FindItem(Table, '表示モード', 'select'))^.Value := Ord(adBackground);
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

  // 縦横比で短辺だけを縮め、拡大率で縦横を一緒に調整できることを確認する。
  Item := FindItem(Table, '縦横比', 'track');
  Check((Item^.S = -100) and (Item^.E = 100) and SameValue(Item^.Step, 0.001),
    'Aspect range and precision');
  SetNumber('遠近感', 0); SetNumber('拡大率', 40); Frame; A := Copy(Captured);
  SetNumber('縦横比', 75); Frame; Positive := Copy(Captured);
  SetNumber('縦横比', -75); Frame; Negative := Copy(Captured);
  Check((A[117 * 204 + 102].A = 255) and (A[102 * 204 + 117].A = 255) and
    (Positive[117 * 204 + 102].A = 0) and (Negative[102 * 204 + 117].A = 0),
    'Aspect did not narrow the rectangle');
  for I := 0 to 203 do
  begin
    Check(Positive[102 * 204 + I].A = A[102 * 204 + I].A, 'Positive aspect changed width');
    Check(Negative[I * 204 + 102].A = A[I * 204 + 102].A, 'Negative aspect changed height');
  end;

  SetNumber('縦横比', 75); SetNumber('拡大率', 80); Frame;
  Check((Positive[102 * 204 + 150].A = 0) and (Captured[102 * 204 + 150].A = 255) and
    (Captured[117 * 204 + 102].A = 255), 'Zoom did not enlarge both sides of the narrow rectangle');
  SetNumber('縦横比', 99); Frame;
  Check((Captured[102 * 204 + 150].A = 255) and (Captured[100 * 204 + 150].A = 0),
    'Positive aspect must approach a thin horizontal strip');
  SetNumber('縦横比', -99); Frame;
  Check((Captured[150 * 204 + 102].A = 255) and (Captured[150 * 204 + 100].A = 0),
    'Negative aspect must approach a thin vertical strip');
  SetNumber('縦横比', 100); Frame;
  Check(AlphaCenter(Captured, 204, X1, Y1) = 0, 'Positive endpoint must produce zero height');
  SetNumber('縦横比', -100); Frame;
  Check(AlphaCenter(Captured, 204, X1, Y1) = 0, 'Negative endpoint must produce zero width');
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
  CheckComponents(Table, [acSurface, acWaves]);
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
  PFILTER_ITEM_SELECT(FindItem(Table, '表示モード', 'select'))^.Value := Ord(adImage);
  PFILTER_ITEM_SELECT(FindItem(Table, 'プリセット', 'select'))^.Value := Ord(apOil);
  PFILTER_ITEM_BUTTON(FindItem(Table, '設定', 'button'))^.Callback2(
    @Edit, Pointer(1234), '水面演出:2', '設定');
  Check(PFILTER_ITEM_SELECT(FindItem(Table, '表示モード', 'select'))^.Value = Ord(adImage),
    'Preset changed display mode');
  CheckComponents(Table, [acOil]);
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
  SetComponents(Table, []); Frame;
  Check(Same(HostInput, Captured), 'Oil display off still rendered a film');
  SetComponents(Table, [acOil]);
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

// 本番AUF2でカップ外・入力アルファ・無効化と、波/油膜の渦の保存値を確認する。
procedure VerifyNativeWavesAndVortex(Table: PFILTER_PLUGIN_TABLE; var Video: TFILTER_PROC_VIDEO);
var
  Edit: TEDIT_SECTION;
  First, Clockwise: TAquaPixels;
  LiquidColor: PFILTER_ITEM_COLOR;
  I, X, Y, Changed, SmallChanged: Integer;

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
  PFILTER_ITEM_SELECT(FindItem(Table, '表示モード', 'select'))^.Value := Ord(adImage);
  PFILTER_ITEM_SELECT(FindItem(Table, 'プリセット', 'select'))^.Value := Ord(apCoffee);
  PFILTER_ITEM_BUTTON(FindItem(Table, '設定', 'button'))^.Callback2(@Edit, Pointer(1234), '水面演出:2', '設定');
  for I := Ord(atX) to Ord(atTransparency) do Number(string(AQUA_TRACK_DEFINITIONS[TAquaTrack(I)].Name), 0);
  PFILTER_ITEM_SELECT(FindItem(Table, '水面形状', 'select'))^.Value := Ord(asEllipse);
  CheckComponents(Table, [acWaves]);
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
  // 「画像に波」は元の色を使い、「なし」では指定した色も液面だけに重ねる。
  LiquidColor := FindItem(Table, '液体色', 'color');
  LiquidColor^.R := 101; LiquidColor^.G := 185; LiquidColor^.B := 220;
  Frame(1);
  Check(Same(First, Captured), 'Untinted waves unexpectedly used the liquid color');
  SetComponents(Table, []); Frame(1);
  Check(Same(HostInput, Captured), 'Wave display off still distorted the image');
  SetComponents(Table, [acSurface, acWaves]);
  Frame(1); First := Copy(Captured);
  LiquidColor^.R := 220; LiquidColor^.G := 100; LiquidColor^.B := 50;
  Frame(1); Changed := 0;
  Check(not Same(First, Captured), 'User image ignores the liquid color');
  for I := 0 to High(Captured) do
  begin
    Check(Captured[I].A = HostInput[I].A, 'User image changed source alpha');
    if not CompareMem(@Captured[I], @HostInput[I], SizeOf(TPIXEL_RGBA)) then
    begin
      X := I mod 384; Y := I div 384;
      Check((Abs(X - 192) <= 82) and (Abs(Y - 128) <= 82), 'User image changed pixels outside the liquid');
      Inc(Changed);
    end;
  end;
  Number('拡大率', 32); Frame(1); SmallChanged := 0;
  for I := 0 to High(Captured) do
  begin
    Check(Captured[I].A = HostInput[I].A, 'Image filter zoom changed source alpha');
    if not CompareMem(@Captured[I], @HostInput[I], SizeOf(TPIXEL_RGBA)) then
    begin
      X := I mod 384; Y := I div 384;
      Check((Abs(X - 192) <= 40) and (Abs(Y - 128) <= 40), 'Image filter zoom moved the source');
      Inc(SmallChanged);
    end;
  end;
  Check((SmallChanged > 0) and (SmallChanged < Changed), 'Image filter zoom did not resize the liquid');
  Number('拡大率', 0); Frame(1);
  Check(Same(HostInput, Captured), 'Image filter zero zoom did not restore the source');
  Number('拡大率', 68); Number('縦横比', 100); Frame(1);
  Check(Same(HostInput, Captured), 'Image filter zero height did not restore the source');
  Number('縦横比', -100); Frame(1);
  Check(Same(HostInput, Captured), 'Image filter zero width did not restore the source');
  Number('縦横比', 0);
  Video.Object_^.Flag := OBJECT_FLAG_FILTER_OBJECT; Frame(1);
  Check((Captured[0].A = 0) and
    (Captured[128 * 384 + 192].A > 0) and (Captured[230 * 384 + 192].A = 0),
    'Standalone user image must still project its surface');
  Video.Object_^.Flag := 0;
  SetComponents(Table, [acWaves]);
  Number('透明度', 100); Frame(1); Check(Same(HostInput, Captured), 'Wave transparency did not restore source');
  Number('透明度', 0); Number('拡大率', 0); Frame(1);
  Check(Same(HostInput, Captured), 'Wave zero zoom did not restore source');
  Number('拡大率', 68); Number('波の強さ', 0); Number('波紋の量', 0); Frame(1);
  Check(Same(HostInput, Captured), 'Zero waves did not restore source');
  Number('波の強さ', 25); Number('渦の強さ', 65); Number('流速', 0); Frame(2);
  Clockwise := Copy(Captured); Number('渦の強さ', -65); Frame(2);
  Check(not Same(Clockwise, Captured), 'Wave vortex direction did not change image');
  SetComponents(Table, [acOil]);
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
  SetComponents(Table, [acWaves]);
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
  Number('油膜の量', 48); Frame(1);
  Check(Same(HostInput, Captured), 'Unchecked oil affected the image');
  SetComponents(Table, [acWaves, acOil]); Frame(1);
  Check(not Same(HostInput, Captured), 'Wave and oil checks did not combine');
  Writeln('PASS native waves/vortex: cup bounds, alpha, disable, animation, signed rotation, seek and presets');
end;

// 同じ本番AUF2で水際の生成・保存項目・無効化・入力アルファを確認する。
procedure VerifyNativeShore(Table: PFILTER_PLUGIN_TABLE; var Video: TFILTER_PROC_VIDEO);
var
  Edit: TEDIT_SECTION;
  Track: TAquaTrack;
  A, B, LayerInput: TAquaPixels;
  I, Visible, Transparent, Changed: Integer;
  LiquidColor: PFILTER_ITEM_COLOR;
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

  PFILTER_ITEM_SELECT(FindItem(Table, '表示モード', 'select'))^.Value := Ord(adImage);
  for I := 0 to High(HostInput) do
    if HostInput[I].A > 0 then
    begin
      HostInput[I].R := 188; HostInput[I].G := 165; HostInput[I].B := 120;
    end;
  LiquidColor := FindItem(Table, '液体色', 'color');
  LiquidColor^.R := 101; LiquidColor^.G := 185; LiquidColor^.B := 220;
  Frame(1.25); B := Copy(Captured);
  I := 20 * 204 + 152;
  Check((B[I].B > HostInput[I].B + 25) and (B[I].B > B[I].R), 'User image did not tint the sea light blue');
  Number('海水の不透明度', 0); Frame(1.25);
  Check(CompareMem(@Captured[I], @HostInput[I], SizeOf(TPIXEL_RGBA)), 'Zero sea opacity changed offshore image');
  Number('海水の不透明度', 85);
  for I := 203 * 204 to High(B) do
    Check(CompareMem(@B[I], @HostInput[I], SizeOf(TPIXEL_RGBA)), 'User image tint reached the dry beach');
  for I := 0 to High(B) do
    Check(B[I].A = HostInput[I].A, 'Tinted shore changed original alpha');

  // 入力画像に効果を重ねても、元アルファと波が届かない砂浜の画素を保つ。
  PFILTER_ITEM_SELECT(FindItem(Table, '表示モード', 'select'))^.Value := Ord(adEffectsOnly);
  Frame(1.25); Changed := 0;
  for I := 0 to High(Captured) do
  begin
    Check(Captured[I].A = HostInput[I].A, 'Effects filter discarded the input alpha');
    if not CompareMem(@Captured[I], @HostInput[I], SizeOf(TPIXEL_RGBA)) then Inc(Changed);
  end;
  Check(Changed > 0, 'Effects filter did not composite foam over the image');
  for I := 203 * 204 to High(Captured) do
    Check(CompareMem(@Captured[I], @HostInput[I], SizeOf(TPIXEL_RGBA)), 'Effects filter erased the dry beach');
  SetComponents(Table, []); Frame(1.25);
  Check(Same(HostInput, Captured), 'Disabled effects erased the input');
  SetComponents(Table, [acSurface, acWaves]);
  Number('透明度', 100); Frame(1.25);
  Check(Same(HostInput, Captured), 'Hidden effects erased the input');
  Number('透明度', 0); Number('拡大率', 0); Frame(1.25);
  Check(Same(HostInput, Captured), 'Zero-scale effects erased the input');
  Number('拡大率', 100);

  // 単体に入力が渡る場合はアルファ合成し、空の入力では透明な効果画像を返す。
  Video.Object_^.Flag := OBJECT_FLAG_FILTER_OBJECT;
  LayerInput := Copy(HostInput);
  Frame(1.25); A := Copy(Captured);
  FillChar(HostInput[0], Length(HostInput) * SizeOf(TPIXEL_RGBA), 0);
  Frame(1.25); B := Copy(Captured);
  for I := 0 to High(A) do
  begin
    Check(A[I].A = Round(B[I].A + (255 - B[I].A) * LayerInput[I].A / 255),
      'Effects layer replaced its input instead of compositing it');
    if B[I].A = 0 then
      Check(CompareMem(@A[I], @LayerInput[I], SizeOf(TPIXEL_RGBA)), 'Effects layer changed pixels outside the foam');
  end;
  PFILTER_ITEM_SELECT(FindItem(Table, '表示モード', 'select'))^.Value := Ord(adBackground);
  Number('海水の不透明度', 0); Frame(1.25);
  Check(Same(B, Captured), 'Shore effects-only differs from isolated foam');
  Preset(apSea);
  Check(PFILTER_ITEM_SELECT(FindItem(Table, '水面形状', 'select'))^.Value = Ord(asPlane),
    'Leaving shoreline preset did not restore the original shape');
  Writeln('PASS native shore: standalone alpha, reach, period, roughness, foam, seek and input compositing');
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

var
  HostDepthAngleX, HostDepthAngleY: Single;
  HostDepthReads: Integer;

function GetTestOutputImageParam(Obj: OBJECT_HANDLE; Offset: Double;
  Param: POBJECT_IMAGE_PARAM; ParamSize: Integer): Byte; cdecl;
begin
  Result := 0;
  if (Obj <> nil) or (Offset <> 0) or (Param = nil) or
    (ParamSize <> SizeOf(TOBJECT_IMAGE_PARAM)) then Exit;
  Inc(HostDepthReads);
  Param^ := Default(TOBJECT_IMAGE_PARAM);
  Param^.RX := HostDepthAngleX;
  Param^.RY := HostDepthAngleY;
  Result := 1;
end;

procedure VerifyNativeWaterDepth(Table: PFILTER_PLUGIN_TABLE; var Video: TFILTER_PROC_VIDEO);
const
  W = 640;
  H = 360;
  LayerTracks: array[0..2] of TAquaTrack = (atWaveRelief, atCaustics, atBubbles);
var
  Edit: TEDIT_SECTION;
  Settings: TAquaSettings;
  Top, Layer, Base, Positive: TAquaPixels;
  Track, LayerTrack: TAquaTrack;
  I: Integer;

  procedure SetTrack(Track: TAquaTrack; Value: Double);
  begin
    PFILTER_ITEM_TRACK(FindItem(Table, string(AQUA_TRACK_DEFINITIONS[Track].Name),
      'track'))^.Value := Value;
  end;

  procedure Frame;
  begin
    SetCount := 0;
    Check(Table^.Func_Proc_Video(@Video) = 1, 'Water depth callback');
    Check((SetCount = 1) and (CaptureWidth = W) and (CaptureHeight = H), 'Water depth frame size');
  end;

  procedure CheckAlpha(const Reference: TAquaPixels);
  var
    I: Integer;
  begin
    for I := 0 to High(Captured) do
      Check(Captured[I].A = Reference[I].A, 'Water depth changed coverage');
  end;

begin
  Check(SizeOf(TOBJECT_IMAGE_PARAM) = 52, 'Host image parameter size');
  Settings := AquaPresetSettings(apShallowPool);
  Edit := Default(TEDIT_SECTION);
  Edit.SetObjectItemValue := AcceptItem;
  PFILTER_ITEM_SELECT(FindItem(Table, 'プリセット', 'select'))^.Value := Ord(apShallowPool);
  PFILTER_ITEM_BUTTON(FindItem(Table, '設定', 'button'))^.Callback2(
    @Edit, Pointer(1234), '水面演出:2', '設定');
  PFILTER_ITEM_SELECT(FindItem(Table, '表示モード', 'select'))^.Value := Ord(adBackground);
  for Track := atWaveRelief to atBubbles do
    Check(PFILTER_ITEM_TRACK(FindItem(Table, string(AQUA_TRACK_DEFINITIONS[Track].Name),
      'track'))^.Value = Settings.Tracks[Track], 'Water depth preset parameter');
  for Track := atX to atTransparency do
    SetTrack(Track, Settings.Tracks[Track]);
  Video.Object_^.Flag := OBJECT_FLAG_FILTER_OBJECT;
  Video.Scene^.Width := W; Video.Scene^.Height := H;
  Video.Object_^.Width := W; Video.Object_^.Height := H;
  Video.Object_^.Frame := 0; Video.Object_^.FrameTotal := 0;
  Video.GetImageData := nil;
  Video.Object_^.Time := 1.25;
  Frame;
  Check((Captured[H div 2 * W + W div 2].A = 255) and (Captured[0].A = 0),
    'Water depth top view coverage');
  Top := Copy(Captured);
  SavePNG(Top, W, H, 'shallow_pool_top.png');
  Video.Object_^.Time := 2.10;
  Frame;
  Check(not Same(Top, Captured), 'Water depth did not animate');
  Video.Object_^.Time := 1.25;
  Frame;
  Check(Same(Top, Captured), 'Water depth reverse seek');
  SetTrack(atTilt, 58);
  Frame;
  Check(not Same(Top, Captured), 'Water depth built-in tilt');
  SavePNG(Captured, W, H, 'shallow_pool_tilt.png');
  PFILTER_ITEM_SELECT(FindItem(Table, '表示モード', 'select'))^.Value := Ord(adEffectsOnly);
  Frame;
  Check((Captured[0].A = 0) and (Captured[H div 2 * W + W div 2].A < 255),
    'Water depth effects-only alpha');
  SavePNG(Captured, W, H, 'shallow_pool_effects_tilt.png');
  SetTrack(atTilt, 0);
  Frame;
  SavePNG(Captured, W, H, 'shallow_pool_effects_top.png');
  PFILTER_ITEM_SELECT(FindItem(Table, '表示モード', 'select'))^.Value := Ord(adBackground);

  // 通常画像の標準描画から回転角を得る。ホストに渡す画像の輪郭は回転前のまま。
  SetTrack(atTilt, 0);
  Video.Object_^.Flag := 0;
  Video.GetImageData := GetImage;
  Video.GetOutputImageParam := GetTestOutputImageParam;
  SetLength(HostInput, W * H);
  FillChar(HostInput[0], Length(HostInput) * SizeOf(TPIXEL_RGBA), 255);
  for I := 0 to High(HostInput) do
    if I mod W < 60 then HostInput[I].A := 0;
  for LayerTrack in LayerTracks do SetTrack(LayerTrack, 0);
  HostDepthAngleX := 67; HostDepthAngleY := 0; HostDepthReads := 0;
  Frame;
  Check(HostDepthReads = 0, 'Disabled water depth called the host');
  Base := Copy(Captured);
  for LayerTrack in LayerTracks do
  begin
    SetTrack(LayerTrack, Settings.Tracks[LayerTrack]);
    HostDepthAngleX := 0;
    Frame;
    Layer := Copy(Captured);
    if LayerTrack <> atWaveRelief then
      Check(not Same(Base, Layer), 'Water depth layer missing in top view');
    HostDepthAngleX := 67;
    Frame;
    Check(not Same(Layer, Captured), 'Host rotation did not move a water depth layer');
    CheckAlpha(Base);
    Positive := Copy(Captured);
    HostDepthAngleX := -67;
    Frame;
    Check(not Same(Positive, Captured), 'Water depth ignored the direction of host rotation');
    CheckAlpha(Base);
    SetTrack(LayerTrack, 0);
  end;
  Check(HostDepthReads = 9, 'Expected one host rotation read per enabled frame');
  for LayerTrack in LayerTracks do SetTrack(LayerTrack, Settings.Tracks[LayerTrack]);
  HostDepthAngleX := 89.9; HostDepthAngleY := 34;
  Frame;
  CheckAlpha(Base);
  Check(Captured[H div 2 * W].A = 0, 'Water depth escaped input alpha');
  PFILTER_ITEM_SELECT(FindItem(Table, '表示モード', 'select'))^.Value := Ord(adEffectsOnly);
  HostDepthAngleX := 0; HostDepthAngleY := 0;
  Frame;
  Top := Copy(Captured);
  HostDepthAngleX := -62;
  Frame;
  Check(not Same(Top, Captured), 'Effects-only water depth ignored the standard rotation');
  CheckAlpha(HostInput);
  Video.GetOutputImageParam := nil;
  Writeln('PASS water depth: top view, layers, host tilt, alpha and reverse seek');
end;

procedure VerifyPlugin(const Path: string);
const
  ModeNames: array[adBackground..adEffectsOnly] of string = ('背景', 'なし', 'エフェクト');
  ComponentGroups: array[TAquaComponent] of string = ('水面', '波', '表面の油');
type
  PSelectChoice = ^TFILTER_ITEM_SELECT_ITEM;
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
  DisplayMode: PFILTER_ITEM_SELECT;
  Choice: PSelectChoice;
  Mode: TAquaDisplayMode;
  Component: TAquaComponent;
  GroupItem: Pointer;
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
    DisplayMode := FindItem(Table, '表示モード', 'select');
    Check(DisplayMode^.Value = Ord(adBackground), 'Default display mode must be background');
    Choice := PSelectChoice(DisplayMode^.List);
    for Mode := adBackground to adEffectsOnly do
    begin
      Check((Choice^.Name <> nil) and (string(Choice^.Name) = ModeNames[Mode]) and
        (Choice^.Value = Ord(Mode)), 'Display mode choice: ' + ModeNames[Mode]);
      Inc(Choice);
    end;
    Check(Choice^.Name = nil, 'Display mode must contain exactly three choices');
    for Component := Low(TAquaComponent) to High(TAquaComponent) do
    begin
      GroupItem := FindItem(Table, ComponentGroups[Component], 'group');
      Items := PPointer(Table^.Items);
      while (Items^ <> nil) and (Items^ <> GroupItem) do Inc(Items);
      Check(Items^ = GroupItem, 'Missing settings group');
      Inc(Items);
      Check(Items^ = FindItem(Table, AQUA_COMPONENT_NAMES[Component], 'check'),
        'Display check must be first in its group');
    end;
    Scene := Default(TSCENE_INFO); Scene.Width := 204; Scene.Height := 204;
    Obj := Default(TOBJECT_INFO); Obj.Time := 32 / 30;
    Obj.Flag := OBJECT_FLAG_FILTER_OBJECT;
    Video := Default(TFILTER_PROC_VIDEO);
    Video.Scene := @Scene; Video.Object_ := @Obj;
    Video.SetImageData := SetImage;
    Video.UserData := Table^.Func_Create(1);
    Check(Video.UserData <> nil, 'Session allocation');
    try
      // 初期表示モードのまま、素材なしの204x204に内蔵の海を生成する。
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
      PFILTER_ITEM_SELECT(FindItem(Table, '水面形状', 'select'))^.Value := Ord(asImage);
      Table^.Func_Proc_Video(@Video);
      Check(Same(First, Captured), 'Embedded background must render without a source mask');
      PFILTER_ITEM_SELECT(FindItem(Table, '水面形状', 'select'))^.Value := Ord(asPlane);
      DisplayMode^.Value := Ord(adImage);
      Table^.Func_Proc_Video(@Video);
      Check(Same(HostInput, Captured), 'No-background mode generated water without a source');
      DisplayMode^.Value := Ord(adEffectsOnly);
      Table^.Func_Proc_Video(@Video);
      Check(not Same(First, Captured), 'Effects mode filled the background');
      DisplayMode^.Value := Ord(adBackground);
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
        if I < Ord(apFlush) then
          Check(Captured[102 * 204 + 102].A > 0, 'Preset surface is invisible');
        for J := 0 to I - 1 do
          Check(not Same(PresetImages[J], Captured), 'Preset images are identical');
        PresetImages[I] := Copy(Captured);
      end;
      Obj.Frame := 0; Obj.FrameTotal := 0;
      // 通常の画像へのフィルターでは透明部分を維持する。
      begin
        Obj.Flag := 0; Obj.Width := 204; Obj.Height := 204;
        DisplayMode^.Value := Ord(adImage);
        SetLength(HostInput, 204 * 204);
        FillChar(HostInput[0], Length(HostInput) * SizeOf(TPIXEL_RGBA), 0);
        Video.GetImageData := GetImage;
        Table^.Func_Proc_Video(@Video);
        Check(Same(HostInput, Captured), 'A transparent image object must not generate standalone sea');
        for I := 204 * 102 to High(HostInput) do HostInput[I].A := 255;
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
      VerifyNativeWaterDepth(Table, Video);
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
        PFILTER_ITEM_TRACK(FindItem(Table, '拡大率', 'track'))^.Value := 86.7;
        PFILTER_ITEM_TRACK(FindItem(Table, '縦横比', 'track'))^.Value := 41.176;
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

// 同じ本番DLLを複数解像度・表示モードで測る。PNG保存とハッシュは計測外。
// 元画像と設定を固定し、変更前後の画像一致も照合できるようにする。
procedure ReadBenchmarkAlias(const Path: string; var Settings: TAquaSettings);
const
  LegacyNames: array[adBackground..adEffectsOnly] of string = ('背景あり', 'ユーザー画像', '背景なし');
  ImageEffects: array[adOilOverlay..adWaterOverlay] of string = ('画像に油膜', '画像に波', '画像に水面');
  ImageComponents: array[adOilOverlay..adWaterOverlay] of TAquaComponents = ([acOil], [acWaves], [acSurface]);
var
  Lines: TStringList;
  Line, Name, Value: string;
  Reading: Boolean;
  EqualsAt: Integer;
  Track: TAquaTrack;
  Mode: TAquaDisplayMode;
  Component: TAquaComponent;
  Specified, Enabled: TAquaComponents;
  Shape: TAquaShape;
  Number: Double;
begin
  Lines := TStringList.Create;
  try
    Lines.LoadFromFile(Path, TEncoding.UTF8); Reading := False;
    Specified := []; Enabled := [];
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
      if Name = '表示モード' then
      begin
        for Mode := adBackground to adEffectsOnly do
          if (Value = string(AQUA_DISPLAY_NAMES[Mode])) or (Value = LegacyNames[Mode]) then
          begin
            Settings.DisplayMode := Mode;
            Settings.Components := [acSurface, acWaves, acOil];
          end;
        for Mode := adOilOverlay to adWaterOverlay do
          if Value = ImageEffects[Mode] then
          begin
            Settings.DisplayMode := adImage;
            Settings.Components := ImageComponents[Mode];
          end;
      end;
      for Component := Low(TAquaComponent) to High(TAquaComponent) do
        if Name = string(AQUA_COMPONENT_NAMES[Component]) then
        begin
          Include(Specified, Component);
          if Value = '1' then Include(Enabled, Component)
          else Exclude(Enabled, Component);
        end;
      for Shape := Low(TAquaShape) to High(TAquaShape) do
        if (Name = '水面形状') and (Value = string(AQUA_SHAPE_NAMES[Shape])) then Settings.Shape := Shape;
      if Name = '液体色' then Settings.ColorRGB := StrToInt('$' + Value);
      if Name = '油膜色' then Settings.OilColorRGB := StrToInt('$' + Value);
    end;
    Settings.Components := (Settings.Components - Specified) + Enabled;
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
        Settings.DisplayMode := adImage;
        if Scenario in [0, 5, 7, 8] then
        begin
          Obj.Width := W; Obj.Height := H;
          Settings.Tracks[atX] := 0; Settings.Tracks[atY] := 208;
          Settings.Tracks[atZoom] := 80.674; Settings.Tracks[atAspect] := 47.368;
          Settings.Tracks[atTilt] := 0; Settings.Tracks[atPerspective] := 0;
          Settings.Tracks[atOilAmount] := 32; Settings.Tracks[atOilSize] := 30;
          Settings.Tracks[atOilGloss] := 55;
          if Scenario = 5 then
          begin
            Settings := AquaPresetSettings(apCoffee); Settings.DisplayMode := adImage;
            Settings.Tracks[atTilt] := 0; Settings.Tracks[atPerspective] := 0;
            Settings.Tracks[atX] := -20; Settings.Tracks[atY] := -155;
            Settings.Tracks[atZoom] := 69; Settings.Tracks[atAspect] := 27.536;
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
            Settings.Tracks[atZoom] := 89.1;
            Settings.Tracks[atAspect] := 39.394;
            Settings.Tracks[atRippleAspect] := 148;
            Settings.Tracks[atTransparency] := 35;
          end;
        end else
        begin
          Obj.Width := 1920; Obj.Height := 1080;
          case Scenario of
            2: Settings := AquaPresetSettings(apSea);
            3: Settings.DisplayMode := adBackground;
            4: begin
              Settings.DisplayMode := adImage; Settings.Shape := asImage;
              Settings.Components := [acSurface, acWaves, acOil];
            end;
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
        SetComponents(Table, Settings.Components);
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
        VerifyAquaFXRenderCore(ImageDirectory);
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
