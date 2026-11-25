unit AquaFX_RenderTestSupport;

// 共通描画器と本番AUF2の検査で、画素比較の条件とPNGの出力形式を揃える。

{$R+}
{$Q+}

interface

uses
  AquaFX_Renderer;

// Conditionが偽なら、失敗の理由をMessage_に含む例外を送出する。
procedure Check(Condition: Boolean; const Message_: string);
// 借用した二つのストレートRGBA配列を、透明画素のRGBを含めて比較する。
function Same(const A, B: TAquaPixels): Boolean;
// Width/Heightはピクセル。PixelsのWidth*Height要素をストレートRGBAでPathへ書く。
// 保存先に同名PNGがあれば置き換える。入力配列は検査側が所有する。
procedure SaveRenderTestPNG(const Pixels: TAquaPixels; Width, Height: Integer; const Path: string);

implementation

uses
  System.SysUtils, Vcl.Imaging.pngimage, AviUtl2FilterTypes;

procedure Check(Condition: Boolean; const Message_: string);
begin
  if not Condition then raise Exception.Create(Message_);
end;

function Same(const A, B: TAquaPixels): Boolean;
begin
  Result := (Length(A) = Length(B)) and
    ((Length(A) = 0) or CompareMem(@A[0], @B[0], Length(A) * SizeOf(TPIXEL_RGBA)));
end;

procedure SaveRenderTestPNG(const Pixels: TAquaPixels; Width, Height: Integer; const Path: string);
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
    PNG.SaveToFile(Path);
  finally
    PNG.Free;
  end;
end;

end.
