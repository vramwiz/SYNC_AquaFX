program AquaFX_ToiletTests;

// 本番AUF2をロードし、角丸・流水・元画像を保つ水面合成を検査する。
// 追加のプラグインやホスト画面は使用せず、確認用の2層画像も同じコールバックで出す。
{$APPTYPE CONSOLE}
{$R+}
{$Q+}

uses
  System.SysUtils, System.Math, System.Classes, System.Diagnostics, Winapi.Windows,
  Vcl.Imaging.pngimage,
  AviUtl2FilterTypes in '..\Source\Lib\AviUtl2FilterTypes.pas',
  AquaFX_Settings in '..\Source\Common\AquaFX_Settings.pas',
  AquaFX_SurfaceShape in '..\Source\Common\AquaFX_SurfaceShape.pas',
  AquaFX_Flush in '..\Source\Common\AquaFX_Flush.pas';

type
  TPixels = array of TPIXEL_RGBA;
  TGetTable = function: PFILTER_PLUGIN_TABLE; cdecl;
  TInitialize = function(Version: Cardinal): Byte; cdecl;
  TUninitialize = procedure; cdecl;
var
  Table: PFILTER_PLUGIN_TABLE;
  Video: TFILTER_PROC_VIDEO;
  Obj: TOBJECT_INFO;
  Input, Output: TPixels;
  ImageDirectory: string;
  Returned: Boolean;

procedure Check(Condition: Boolean; const Message_: string);
begin
  if not Condition then raise Exception.Create(Message_);
end;

function Same(const A, B: TPixels): Boolean;
begin
  Result := (Length(A) = Length(B)) and
    ((Length(A) = 0) or CompareMem(@A[0], @B[0], Length(A) * SizeOf(TPIXEL_RGBA)));
end;

procedure GetImage(Buffer: PPIXEL_RGBA); cdecl;
begin
  Move(Input[0], Buffer^, Length(Input) * SizeOf(TPIXEL_RGBA));
end;

procedure SetImage(Buffer: PPIXEL_RGBA; Width, Height: Integer); cdecl;
begin
  Check((Width = Obj.Width) and (Height = Obj.Height), 'Unexpected output size');
  SetLength(Output, Width * Height);
  Move(Buffer^, Output[0], Length(Output) * SizeOf(TPIXEL_RGBA));
  Returned := True;
end;

function FindItem(const Name, Kind: string): Pointer;
var P: PPointer; I: Integer; Header: PFILTER_ITEM_STRING;
begin
  P := PPointer(Table^.Items);
  for I := 0 to 98 do
  begin
    if P^ = nil then Break;
    Header := PFILTER_ITEM_STRING(P^);
    if (string(Header^.Name) = Name) and (string(Header^.ItemType) = Kind) then Exit(P^);
    Inc(P);
  end;
  raise Exception.Create('Missing item: ' + Name);
end;

procedure Settings(const S: TAquaSettings);
var T: TAquaTrack; Color: PFILTER_ITEM_COLOR;
begin
  PFILTER_ITEM_SELECT(FindItem('表示モード', 'select'))^.Value := Ord(S.DisplayMode);
  PFILTER_ITEM_SELECT(FindItem('水面形状', 'select'))^.Value := Ord(S.Shape);
  Color := FindItem('液体色', 'color');
  Color^.R := (S.ColorRGB shr 16) and $FF; Color^.G := (S.ColorRGB shr 8) and $FF;
  Color^.B := S.ColorRGB and $FF;
  for T := Low(TAquaTrack) to High(TAquaTrack) do
    PFILTER_ITEM_TRACK(FindItem(AQUA_TRACK_DEFINITIONS[T].Name, 'track'))^.Value := S.Tracks[T];
end;

procedure Frame(Number, Total: Integer; Time: Double = -1);
begin
  Obj.Frame := Number; Obj.FrameTotal := Total; Obj.Time := Number / 30;
  if Time >= 0 then Obj.Time := Time;
  Obj.TimeTotal := Total / 30; Returned := False;
  Table^.Func_Proc_Video(@Video);
  Check(Returned, 'Native callback did not return a frame');
end;

function AlphaSum(const P: TPixels): Int64;
var I: Integer;
begin
  Result := 0; for I := 0 to High(P) do Inc(Result, P[I].A);
end;

function DistanceFromDrain(const P: TPixels): Double;
var X, Y, I: Integer; Mass: Double;
begin
  Result := 0; Mass := 0;
  for I := 0 to High(P) do
  begin
    X := I mod Obj.Width; Y := I div Obj.Width;
    Result := Result + Hypot(X - Obj.Width * 0.5, Y - Obj.Height * 0.5) * P[I].A;
    Mass := Mass + P[I].A;
  end;
  Result := Result / Max(1.0, Mass);
end;

procedure Verify;
var
  S: TAquaSettings; A, B: TPixels; I: Integer; EarlyDistance: Double;
  Flush: TAquaFlush; StartSample, TailSample: TAquaFlushSample;
begin
  Check(Ord(apDrain) = 17, 'Existing preset ID changed');
  Check(Ord(asShore) = 4, 'Existing shape ID changed');
  Check(Abs(AquaRoundedDistance(1, 0, 0.65)) < 1E-12, 'Rounded side moved');
  Check(AquaRoundedDistance(0.95, 0.95, 0.65) > 0, 'Rounded corner is square');
  Check(AquaRoundedDistance(0, 0, 0.65) < 0, 'Rounded interior missing');
  Obj.Width := 256; Obj.Height := 256; Obj.Flag := OBJECT_FLAG_FILTER_OBJECT;
  Video.GetImageData := nil;
  S := AquaPresetSettings(apDrain); S.Shape := asRoundedRectangle;
  S.Tracks[atCornerRoundness] := 70; Settings(S); Frame(0, 241); A := Copy(Output);
  S.Tracks[atCornerRoundness] := 0; Settings(S); Frame(0, 241);
  Check(AlphaSum(A) < AlphaSum(Output), 'Corner roundness did not remove corners');
  S.Tracks[atCornerRoundness] := 70; Settings(S); Frame(210, 241);
  Check((AlphaSum(Output) > 0) and (AlphaSum(Output) < AlphaSum(A)), 'Rounded drain did not shrink');
  Frame(240, 241); Check(AlphaSum(Output) = 0, 'Rounded drain did not empty');
  Frame(0, 241); Check(Same(A, Output), 'Rounded drain reverse seek changed start');
  S := AquaPresetSettings(apFlush); Settings(S); Frame(0, 241);
  Check(AlphaSum(Output) = 0, 'Flush visible before supply starts');
  Frame(90, 241); A := Copy(Output); EarlyDistance := DistanceFromDrain(A);
  Check(AlphaSum(A) > 0, 'Flush does not emit water');
  Check(AlphaSum(A) > 256 * 256 * 255 * 0.23, 'Flush water is too faint over the bowl');
  Frame(220, 241);
  Check((AlphaSum(Output) > 0) and (DistanceFromDrain(Output) < EarlyDistance * 0.65),
    'Stopped supply did not move towards drain');
  Frame(240, 241); Check(AlphaSum(Output) = 0, 'Flush remains on last frame');
  Frame(90, 241); Check(Same(A, Output), 'Flush reverse seek changed result');
  Frame(180, 481, 3); Check(Same(A, Output), 'Flush envelope does not follow timeline');
  S.Tracks[atVortexStrength] := -50; Settings(S); Frame(90, 241);
  Check(not Same(A, Output), 'Flush direction has no effect');
  S := AquaPresetSettings(apFlush); S.Tracks[atVortexCenterX] := 30; Settings(S); Frame(90, 241);
  Check(not Same(A, Output), 'Flush drain coordinate has no effect');
  S.Tracks[atFlushAmount] := 0; Settings(S); Frame(90, 241);
  Check(AlphaSum(Output) = 0, 'Flush amount zero still emits water');
  S := AquaPresetSettings(apFlush);
  Flush := TAquaFlush.Create(S, 1, 0.05, 0, 0);
  StartSample := Flush.Sample(0.93, 0, 0.003); TailSample := Flush.Sample(0.25, 0, 0.003);
  Check((StartSample.Coverage > 0) and (TailSample.Coverage = 0), 'Water does not arrive from rim');
  Flush := TAquaFlush.Create(S, 7, 0.85, 0, 0);
  StartSample := Flush.Sample(0.93, 0, 0.003); TailSample := Flush.Sample(0.25, 0, 0.003);
  Check((StartSample.Coverage = 0) and (TailSample.Coverage > 0), 'Supply stops everywhere at once');
  SetLength(Input, 256 * 256);
  for I := 0 to High(Input) do
  begin Input[I].R := I mod 251; Input[I].G := (I div 256) mod 239;
    Input[I].B := 170; Input[I].A := I mod 256; end;
  Video.GetImageData := GetImage; Obj.Flag := 0;
  S := AquaPresetSettings(apDrain); S.Shape := asRoundedRectangle;
  S.DisplayMode := adWaterOverlay; S.Tracks[atCornerRoundness] := 70;
  S.Tracks[atZoom] := 60; Settings(S); Frame(90, 241);
  Check(not Same(Input, Output), 'Water overlay does not affect image');
  for I := 0 to High(Input) do Check(Input[I].A = Output[I].A, 'Water overlay changed alpha');
  Check(CompareMem(@Input[0], @Output[0], 30 * SizeOf(TPIXEL_RGBA)), 'Water overlay changed outside');
  Frame(240, 241); Check(Same(Input, Output), 'Empty water overlay did not restore source');
  S.Tracks[atTransparency] := 100; Settings(S); Frame(90, 241);
  Check(Same(Input, Output), 'Water overlay transparency zero changed source');
  S.Tracks[atTransparency] := 0; S.Tracks[atZoom] := 0; Settings(S); Frame(90, 241);
  Check(Same(Input, Output), 'Water overlay zoom zero changed source');
  S := AquaPresetSettings(apFlush); Settings(S); Frame(90, 241);
  for I := 0 to High(Input) do Check(Output[I].A <= Input[I].A, 'Flush exceeded source alpha');
  B := Copy(Output); Frame(140, 241); Frame(90, 241);
  Check(Same(B, Output), 'Image flush reverse seek changed result');
  Writeln('PASS rounded drain, flush travel/timeline/direction/seek/alpha, water overlay');
end;

procedure SavePNG(const P: TPixels; Width, Height: Integer; const Name: string);
var PNG: TPngImage; X, Y: Integer; Row: PByte;
begin
  PNG := TPngImage.CreateBlank(COLOR_RGBALPHA, 8, Width, Height);
  try
    for Y := 0 to Height - 1 do
    begin
      Row := PNG.Scanline[Y];
      for X := 0 to Width - 1 do
      begin
        Row[X * 3] := P[Y * Width + X].B; Row[X * 3 + 1] := P[Y * Width + X].G;
        Row[X * 3 + 2] := P[Y * Width + X].R; PNG.AlphaScanline[Y]^[X] := P[Y * Width + X].A;
      end;
    end;
    PNG.SaveToFile(ImageDirectory + Name);
  finally PNG.Free; end;
end;

procedure Preview(const SourcePath: string);
const W = 768; Count = 96;
var
  PNG: TPngImage; X, Y, SX, SY, I, J: Integer; Row: PByte;
  Lower, Upper, Both: TPixels; Pool, Flush: TAquaSettings; A: Double;
  Times: TStringList; Timer: TStopwatch;
begin
  PNG := TPngImage.Create; Times := TStringList.Create;
  try
    PNG.LoadFromFile(SourcePath); SetLength(Input, W * W);
    for Y := 0 to W - 1 do
    begin
      SY := Min(PNG.Height - 1, Trunc((Y + 0.5) * PNG.Height / W)); Row := PNG.Scanline[SY];
      for X := 0 to W - 1 do
      begin
        SX := Min(PNG.Width - 1, Trunc((X + 0.5) * PNG.Width / W)); J := Y * W + X;
        Input[J].R := Row[SX * 3 + 2]; Input[J].G := Row[SX * 3 + 1];
        Input[J].B := Row[SX * 3]; Input[J].A := 255;
      end;
    end;
    Obj.Width := W; Obj.Height := W; Obj.Flag := 0; Video.GetImageData := GetImage;
    Pool := AquaPresetSettings(apDrain); Pool.Shape := asRoundedRectangle;
    Pool.DisplayMode := adWaterOverlay; Pool.ColorRGB := $83C5D2;
    Pool.Tracks[atCornerRoundness] := 65; Pool.Tracks[atX] := -2 * W / 1254;
    Pool.Tracks[atY] := 65 * W / 1254; Pool.Tracks[atZoom] := 39;
    Pool.Tracks[atAspect] := -45; Pool.Tracks[atTransparency] := 55;
    Pool.Tracks[atVortexCenterX] := -7 * W / 1254; Pool.Tracks[atVortexCenterY] := -97 * W / 1254;
    Flush := AquaPresetSettings(apFlush);
    Flush.Tracks[atZoom] := 74; Flush.Tracks[atAspect] := -12;
    Flush.Tracks[atX] := -2 * W / 1254; Flush.Tracks[atY] := 10 * W / 1254;
    Flush.Tracks[atVortexCenterX] := Pool.Tracks[atVortexCenterX];
    Flush.Tracks[atVortexCenterY] := Pool.Tracks[atVortexCenterY];
    Times.Add('frame,timeline_frame,callback_ms');
    for I := 0 to Count - 1 do
    begin
      Timer := TStopwatch.StartNew;
      Settings(Pool); Frame(Round(I * 239 / (Count - 1)), 240); Lower := Copy(Output);
      Settings(Flush); Frame(Obj.Frame, 240); Upper := Copy(Output); Timer.Stop;
      Both := Copy(Lower);
      for J := 0 to High(Both) do
      begin
        A := Upper[J].A / 255;
        Both[J].R := Round(Lower[J].R * (1 - A) + Upper[J].R * A);
        Both[J].G := Round(Lower[J].G * (1 - A) + Upper[J].G * A);
        Both[J].B := Round(Lower[J].B * (1 - A) + Upper[J].B * A);
      end;
      SavePNG(Both, W, W, Format('toilet_%.3d.png', [I]));
      if I in [0, 24, 64, 88, 95] then
      begin
        SavePNG(Lower, W, W, Format('pool_%.3d.png', [I]));
        SavePNG(Upper, W, W, Format('flush_%.3d.png', [I]));
      end;
      Times.Add(Format('%d,%d,%.3f', [I, Obj.Frame, Timer.Elapsed.TotalMilliseconds], TFormatSettings.Invariant));
    end;
    Check(Same(Input, Both), 'Combined final frame differs from dry toilet');
    Times.SaveToFile(ImageDirectory + 'render_times.csv', TEncoding.UTF8);
    Writeln('Exported 96 toilet frames from two native callbacks.');
  finally PNG.Free; Times.Free; end;
end;

var
  Module: HMODULE; Initialize: TInitialize; Uninitialize: TUninitialize; GetTable: TGetTable;
begin
  try
    ImageDirectory := IncludeTrailingPathDelimiter(ExpandFileName(ParamStr(2)));
    ForceDirectories(ImageDirectory);
    Module := LoadLibrary(PChar(ExpandFileName(ParamStr(1))));
    Check(Module <> 0, 'LoadLibrary failed');
    try
      @Initialize := GetProcAddress(Module, 'InitializePlugin');
      @Uninitialize := GetProcAddress(Module, 'UninitializePlugin');
      @GetTable := GetProcAddress(Module, 'GetFilterPluginTable');
      Check(Initialize(2011700) = 1, 'Initialize failed'); Table := GetTable;
      Obj := Default(TOBJECT_INFO); Video := Default(TFILTER_PROC_VIDEO);
      Video.Object_ := @Obj; Video.SetImageData := SetImage;
      Video.UserData := Table^.Func_Create(500);
      Check(Video.UserData <> nil, 'Session allocation failed');
      try
        if ParamStr(3) = '--preview' then Preview(ParamStr(4)) else Verify;
      finally Table^.Func_Destroy(500, Video.UserData); end;
      Uninitialize;
    finally FreeLibrary(Module); end;
  except on E: Exception do begin Writeln(E.ClassName, ': ', E.Message); Halt(1); end; end;
end.
