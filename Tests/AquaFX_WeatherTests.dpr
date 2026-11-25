program AquaFX_WeatherTests;

// 本番AUF2の雨・雪を検査する。出力PNGは検査用で、AviUtl2やAUP2を操作しない。

{$APPTYPE CONSOLE}
{$R+}
{$Q+}

uses
  System.SysUtils, System.Math, System.Diagnostics, Winapi.Windows, Vcl.Imaging.pngimage,
  AviUtl2FilterTypes in '..\Source\Lib\AviUtl2FilterTypes.pas',
  AquaFX_Settings in '..\Source\Common\AquaFX_Settings.pas';

type
  TPixels = array of TPIXEL_RGBA;
  TInitialize = function(Version: Cardinal): Byte; cdecl;
  TUninitialize = procedure; cdecl;
  TGetTable = function: PFILTER_PLUGIN_TABLE; cdecl;

var
  Table: PFILTER_PLUGIN_TABLE;
  Scene: TSCENE_INFO;
  Obj: TOBJECT_INFO;
  Video: TFILTER_PROC_VIDEO;
  Captured, HostInput: TPixels;
  ImageDirectory: string;
  CaptureWidth, CaptureHeight, SetCount: Integer;

procedure Check(Condition: Boolean; const Message_: string);
begin
  if not Condition then raise Exception.Create(Message_);
end;

procedure GetImage(Buffer: PPIXEL_RGBA); cdecl;
begin
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
  Result := (Obj = Pointer(1234)) and (Effect <> nil) and (Item <> nil) and (Value <> nil);
end;

function Item(const Name, Kind: string): Pointer;
var
  Items: PPointer;
  Header: PFILTER_ITEM_STRING;
begin
  Items := PPointer(Table^.Items);
  while Items^ <> nil do
  begin
    Header := PFILTER_ITEM_STRING(Items^);
    if (string(Header^.Name) = Name) and (string(Header^.ItemType) = Kind) then Exit(Items^);
    Inc(Items);
  end;
  raise Exception.Create('Missing weather item: ' + Name);
end;

procedure Preset(Value: TAquaPreset; Mode: TAquaDisplayMode);
var
  Edit: TEDIT_SECTION;
begin
  Edit := Default(TEDIT_SECTION); Edit.SetObjectItemValue := AcceptItem;
  PFILTER_ITEM_SELECT(Item('表示モード', 'select'))^.Value := Ord(Mode);
  PFILTER_ITEM_SELECT(Item('プリセット', 'select'))^.Value := Ord(Value);
  PFILTER_ITEM_BUTTON(Item('設定', 'button'))^.Callback2(@Edit, Pointer(1234), '水面演出:2', '設定');
  Check(PFILTER_ITEM_SELECT(Item('表示モード', 'select'))^.Value = Ord(Mode), 'Preset changed display mode');
end;

procedure Number(Track: TAquaTrack; Value: Double);
begin
  PFILTER_ITEM_TRACK(Item(string(AQUA_TRACK_DEFINITIONS[Track].Name), 'track'))^.Value := Value;
end;

procedure Frame(Time: Double);
begin
  SetCount := 0; Obj.Time := Time;
  Check(Table^.Func_Proc_Video(@Video) = 1, 'Weather callback');
  Check((SetCount = 1) and (CaptureWidth = Scene.Width) and (CaptureHeight = Scene.Height), 'Weather frame size');
end;

function Same(const A, B: TPixels): Boolean;
begin
  Result := CompareMem(@A[0], @B[0], Length(A) * SizeOf(TPIXEL_RGBA));
end;

function VisibleCount(const Pixels: TPixels): Integer;
var
  Pixel: TPIXEL_RGBA;
begin
  Result := 0;
  for Pixel in Pixels do if Pixel.A <> 0 then Inc(Result);
end;

procedure SavePNG(const Name: string);
var
  PNG: TPngImage;
  Row: PByte;
  Pixel: TPIXEL_RGBA;
  X, Y: Integer;
begin
  PNG := TPngImage.CreateBlank(COLOR_RGBALPHA, 8, CaptureWidth, CaptureHeight);
  try
    for Y := 0 to CaptureHeight - 1 do
    begin
      Row := PNG.Scanline[Y];
      for X := 0 to CaptureWidth - 1 do
      begin
        Pixel := Captured[Y * CaptureWidth + X];
        Row[X * 3] := Pixel.B; Row[X * 3 + 1] := Pixel.G; Row[X * 3 + 2] := Pixel.R;
        PNG.AlphaScanline[Y]^[X] := Pixel.A;
      end;
    end;
    PNG.SaveToFile(ImageDirectory + Name);
  finally
    PNG.Free;
  end;
end;

procedure VerifyWeather;
const
  StartTime = 2.45;
var
  WetRain, DryRain, Snow, Frozen: TPixels;
  I, DryCount, Tilt: Integer;
begin
  Preset(apRain, adEffectsOnly); Frame(StartTime);
  WetRain := Copy(Captured); SavePNG('rain_puddles.png');
  Frame(StartTime + 0.13); Check(not Same(WetRain, Captured), 'Rain did not move');
  Frame(StartTime); Check(Same(WetRain, Captured), 'Rain reverse seek changed the result');
  Frame(-1.25); Check(VisibleCount(Captured) > 0, 'Negative time suppressed rain');
  Frame(StartTime); Check(Same(WetRain, Captured), 'Negative seek changed rain');
  Number(atRainPuddles, 0); Frame(StartTime); DryRain := Copy(Captured); SavePNG('rain_only.png');
  DryCount := VisibleCount(DryRain);
  Check((DryCount > 100) and (DryCount < Length(DryRain) div 25), 'Rain-only is empty or fills the background');
  Check((VisibleCount(WetRain) > DryCount * 2) and (VisibleCount(WetRain) < Length(WetRain) div 4),
    'Rain needs small transparent puddles');
  Number(atRainPuddles, 35); Number(atTilt, 35); Frame(StartTime);
  Check(not Same(WetRain, Captured), 'Ground tilt did not change the weather projection');
  Number(atTilt, 58); Number(atWeatherWind, -65); Frame(StartTime);
  Check(not Same(WetRain, Captured), 'Wind did not move the falling rain');
  Number(atWeatherWind, 18); Number(atSeed, 8192); Frame(StartTime);
  Check(not Same(WetRain, Captured), 'Rain seed has no effect');
  Number(atSeed, 1); Number(atWeatherSpeed, 0); Frame(StartTime); Frozen := Copy(Captured);
  Frame(StartTime + 3); Check(Same(Frozen, Captured), 'Zero speed did not stop rain');
  Number(atWeatherSpeed, 100); Number(atWeatherAmount, 0); Frame(StartTime);
  Check(VisibleCount(Captured) = 0, 'Zero weather amount did not clear all rain and puddles');

  Preset(apSnow, adBackground); Frame(StartTime); Snow := Copy(Captured); SavePNG('snow.png');
  Check((VisibleCount(Snow) > 100) and (VisibleCount(Snow) < Length(Snow) div 25) and
    not Same(Snow, DryRain), 'Snow is empty, opaque or identical to rain');
  Number(atRainPuddles, 100); Frame(StartTime); Check(Same(Snow, Captured), 'Snow drew rain puddles');
  Frame(StartTime + 0.3); Check(not Same(Snow, Captured), 'Snow did not drift');
  Frame(StartTime); Check(Same(Snow, Captured), 'Snow reverse seek changed the result');
  Number(atTransparency, 100); Frame(StartTime); Check(VisibleCount(Captured) = 0, 'Weather ignored opacity');
  Number(atTransparency, 0); Number(atZoom, 0); Frame(StartTime);
  Check(VisibleCount(Captured) = 0, 'Weather ignored zero zoom');
  Number(atZoom, 100);
  for Tilt in TArray<Integer>.Create(-89, 0, 89) do
  begin
    Number(atTilt, Tilt); Frame(-1.0E12); Frame(1.0E12);
  end;

  // 素材の位置・透過を保って合成し、効果だけも素材アルファ内に制限できる。
  Obj.Flag := 0; Obj.Width := Scene.Width; Obj.Height := Scene.Height;
  SetLength(HostInput, Scene.Width * Scene.Height);
  for I := 0 to High(HostInput) do
  begin
    HostInput[I].R := 27; HostInput[I].G := 41; HostInput[I].B := 59;
    if I >= Length(HostInput) div 2 then HostInput[I].A := 128;
  end;
  Video.GetImageData := GetImage;
  Preset(apRain, adWaterOverlay); Frame(StartTime);
  Check(not Same(HostInput, Captured), 'Image overlay did not draw weather');
  for I := 0 to High(HostInput) do
  begin
    Check(Captured[I].A = HostInput[I].A, 'Weather changed input alpha');
    if HostInput[I].A = 0 then Check(CompareMem(@Captured[I], @HostInput[I], SizeOf(TPIXEL_RGBA)),
      'Weather painted beyond the input alpha');
  end;
  Number(atWeatherAmount, 0); Frame(StartTime); Check(Same(HostInput, Captured), 'Disabled overlay changed input');
  Preset(apSnow, adEffectsOnly); Frame(StartTime);
  Check(VisibleCount(Captured) > 0, 'Masked weather is empty');
  for I := 0 to High(HostInput) do Check(Captured[I].A <= HostInput[I].A, 'Weather exceeded source alpha');
  Obj.Flag := OBJECT_FLAG_FILTER_OBJECT;
  FillChar(HostInput[0], Length(HostInput) * SizeOf(TPIXEL_RGBA), 0);
  Frame(StartTime); Check(VisibleCount(Captured) > 0, 'Transparent filter input blocked weather');
  Obj.Width := 0; Obj.Height := 0; Video.GetImageData := nil;
  Writeln('PASS rain and snow: standalone alpha, puddles, motion, seed, wind, signed tilt, seek, disable and image alpha');
end;

procedure ExportPreview;
const
  Names: array[0..2] of string = ('rain_puddles', 'rain_only', 'snow');
var
  Mode, I: Integer;
begin
  for Mode := 0 to High(Names) do
  begin
    if Mode = 2 then Preset(apSnow, adEffectsOnly) else Preset(apRain, adEffectsOnly);
    if Mode = 1 then Number(atRainPuddles, 0);
    ForceDirectories(ImageDirectory + Names[Mode]);
    for I := 0 to 47 do
    begin
      Frame(2.45 + I / 12);
      SavePNG(Format('%s\%.2d.png', [Names[Mode], I]));
    end;
  end;
end;

procedure MeasureWeather;
var
  Mode, I, J: Integer;
  Timer: TStopwatch;
  Durations: array[0..8] of Double;
  Swap: Double;
begin
  Scene.Width := 1920; Scene.Height := 1080;
  for Mode := 0 to 2 do
  begin
    if Mode = 2 then Preset(apSnow, adEffectsOnly) else Preset(apRain, adEffectsOnly);
    if Mode = 1 then Number(atRainPuddles, 0);
    Frame(0);
    for I := 0 to High(Durations) do
    begin
      Timer := TStopwatch.StartNew;
      Frame(2.45 + I / 30);
      Durations[I] := Timer.Elapsed.TotalMilliseconds;
    end;
    for I := 0 to High(Durations) - 1 do
      for J := I + 1 to High(Durations) do
        if Durations[J] < Durations[I] then
        begin Swap := Durations[I]; Durations[I] := Durations[J]; Durations[J] := Swap; end;
    Writeln('Full HD mode ', Mode, ' median ms: ', Durations[4]:0:3);
  end;
end;

procedure Run;
var
  Module: HMODULE;
  Initialize: TInitialize;
  Uninitialize: TUninitialize;
  GetTable: TGetTable;
begin
  Module := LoadLibrary(PChar(ParamStr(1)));
  Check(Module <> 0, 'Weather LoadLibrary');
  try
    @Initialize := GetProcAddress(Module, 'InitializePlugin');
    @Uninitialize := GetProcAddress(Module, 'UninitializePlugin');
    @GetTable := GetProcAddress(Module, 'GetFilterPluginTable');
    Check(Initialize(2011700) = 1, 'Weather InitializePlugin');
    try
      Table := GetTable;
      Scene.Width := 768; Scene.Height := 432;
      Obj.Flag := OBJECT_FLAG_FILTER_OBJECT;
      Video.Scene := @Scene; Video.Object_ := @Obj; Video.SetImageData := SetImage;
      Video.UserData := Table^.Func_Create(701);
      Check(Video.UserData <> nil, 'Weather session');
      try
        if ParamStr(3) = '--preview' then ExportPreview
        else
        begin
          VerifyWeather;
          MeasureWeather;
        end;
      finally
        Table^.Func_Destroy(701, Video.UserData);
      end;
    finally
      Uninitialize;
    end;
  finally
    FreeLibrary(Module);
  end;
end;

begin
  try
    ImageDirectory := IncludeTrailingPathDelimiter(ParamStr(2));
    Check(ForceDirectories(ImageDirectory), 'Weather image directory');
    Run;
  except
    on E: Exception do
    begin
      Writeln(E.ClassName, ': ', E.Message);
      Halt(1);
    end;
  end;
end.
