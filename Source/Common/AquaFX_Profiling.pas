unit AquaFX_Profiling;

// Debug描画の工程別時間を記録する。Releaseには時計・ログ処理を組み込まない。
// 記録先とバッファはDLLが所有し、フレーム間でまとめて書き出す。

interface

{$IFDEF DEBUG}
type
  TAquaRenderProfile = record
    Started, SetupDone, SurfaceDone, Finished: Int64;
    GridWidth, GridHeight: Integer;
  end;
  TAquaFrameProfile = record
    Started, Locked, InputDone, SettingsDone, RenderDone, OutputDone: Int64;
    Renderer: TAquaRenderProfile;
  end;

// 区間計測用のTStopwatchタイムスタンプを返す。AQUAFX_PROFILE=0で無効な場合は0を返す。
function AquaProfileTick: Int64;
// Profileは借用する計測値、Width/Heightはピクセル、Mode/Shapeは登録済みの識別値。
// DLLの共有バッファへCSV行を追加し、一定の間隔でファイルへ書く。出力失敗は描画へ伝えない。
procedure WriteAquaProfile(const Profile: TAquaFrameProfile;
  Width, Height, Mode, Shape: Integer);
{$ENDIF}

implementation

{$IFDEF DEBUG}
uses
  System.SysUtils, System.Classes, System.Diagnostics, System.SyncObjs,
  System.IOUtils, Winapi.Windows;

var
  Enabled: Boolean;
  LogPath: string;
  LogLock: TCriticalSection;
  Pending: TStringBuilder;
  PendingCount: Integer;
  LastFlush: UInt64;

function AquaProfileTick: Int64;
begin
  if Enabled then Result := TStopwatch.GetTimeStamp else Result := 0;
end;

function Milliseconds(First, Last: Int64): Double;
begin
  Result := (Last - First) * 1000.0 / TStopwatch.Frequency;
end;

procedure FlushProfile;
begin
  if Pending.Length = 0 then Exit;
  ForceDirectories(ExtractFilePath(LogPath));
  TFile.AppendAllText(LogPath, Pending.ToString, TEncoding.UTF8);
  Pending.Clear;
  PendingCount := 0;
  LastFlush := GetTickCount64;
end;

procedure WriteAquaProfile(const Profile: TAquaFrameProfile;
  Width, Height, Mode, Shape: Integer);
var
  Line: string;
begin
  if (not Enabled) or (Profile.Started = 0) then Exit;
  try
    Line := Format('%d,%d,%d,%d,%d,%d,%d,%d,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f',
      [GetCurrentProcessId, GetCurrentThreadId, Width, Height, Mode, Shape,
       Profile.Renderer.GridWidth, Profile.Renderer.GridHeight,
       Milliseconds(Profile.Started, Profile.Locked),
       Milliseconds(Profile.Locked, Profile.InputDone),
       Milliseconds(Profile.InputDone, Profile.SettingsDone),
       Milliseconds(Profile.Renderer.Started, Profile.Renderer.SetupDone),
       Milliseconds(Profile.Renderer.SetupDone, Profile.Renderer.SurfaceDone),
       Milliseconds(Profile.Renderer.SurfaceDone, Profile.Renderer.Finished),
       Milliseconds(Profile.RenderDone, Profile.OutputDone),
       Milliseconds(Profile.Started, Profile.OutputDone)], TFormatSettings.Invariant);
    LogLock.Acquire;
    try
      Pending.AppendLine(Line);
      Inc(PendingCount);
      if (PendingCount >= 32) or (GetTickCount64 - LastFlush >= 1000) then FlushProfile;
    finally
      LogLock.Release;
    end;
  except
    // 計測用ファイルの障害でプレビューを停止しない。
    Enabled := False;
    OutputDebugString('SYNC_AquaFX: performance log could not be written.');
  end;
end;

procedure InitializeProfile;
begin
  LogLock := TCriticalSection.Create;
  Pending := TStringBuilder.Create;
  Enabled := GetEnvironmentVariable('AQUAFX_PROFILE') <> '0';
  LogPath := GetEnvironmentVariable('AQUAFX_PROFILE_PATH');
  if LogPath = '' then
    LogPath := IncludeTrailingPathDelimiter(GetEnvironmentVariable('LOCALAPPDATA')) +
      Format('SYNC_AquaFX\Logs\profile-%d.csv', [GetCurrentProcessId]);
  if not FileExists(LogPath) then
    Pending.AppendLine('pid,thread,width,height,mode,shape,grid_width,grid_height,' +
      'lock_ms,input_ms,settings_ms,setup_ms,surface_ms,composite_ms,output_ms,total_ms');
end;

initialization
  InitializeProfile;

finalization
  try
    if Enabled then FlushProfile;
  except
    // 終了時のログ障害もDLL境界から漏らさない。
  end;
  Pending.Free;
  LogLock.Free;
{$ENDIF}

end.
